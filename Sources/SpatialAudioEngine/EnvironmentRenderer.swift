import AVFoundation
import Foundation
import SpatialAudioCore

/// Something that accepts the listener orientation computed by the pose pump.
public protocol ListenerOrientationSink: AnyObject, Sendable {
    func setListener(_ orientation: ListenerOrientation)
}

/// A sink that also lets the scripted listening test move the (single) virtual sound source.
public protocol SpatialSceneSink: ListenerOrientationSink {
    func setSourcePosition(_ position: Vector3)
}

public enum EnvironmentRendererError: Error, CustomStringConvertible {
    case noAudioOutput
    case badFormat(String)
    case engine(String)
    case render(String)

    public var description: String {
        switch self {
        case .noAudioOutput: "No audio output device is available (the output format has no sample rate or channels)."
        case .badFormat(let m): "Audio format problem: \(m)"
        case .engine(let m): "Audio engine error: \(m)"
        case .render(let m): "Offline render error: \(m)"
        }
    }
}

/// Stereo audio rendered offline (manual rendering mode). Channel 0 = left, channel 1 = right (the engine's standard
/// stereo order; confirmed by the "source on the right is louder in channel 1" measurement in the tests).
public struct StereoRender: Sendable {
    public var left: [Float]
    public var right: [Float]
    public var sampleRate: Double

    public var frameCount: Int { min(left.count, right.count) }

    /// RMS of one channel between two times (seconds); `to` nil = end.
    public func rms(_ channel: [Float], from: Double = 0, to: Double? = nil) -> Double {
        let a = max(0, Int(from * sampleRate)), b = min(channel.count, to.map { Int($0 * sampleRate) } ?? channel.count)
        guard b > a else { return 0 }
        var sum = 0.0
        for i in a..<b { sum += Double(channel[i]) * Double(channel[i]) }
        return (sum / Double(b - a)).squareRoot()
    }

    /// 20 log10(right RMS / left RMS) over a time window. Positive = louder in the right ear. 0 if either channel is silent.
    public func rightMinusLeftDecibels(from: Double = 0, to: Double? = nil) -> Double {
        let l = rms(left, from: from, to: to), r = rms(right, from: from, to: to)
        guard l > 0, r > 0 else { return 0 }
        return 20 * log10(r / l)
    }

    /// Relative RMS difference between two renders over their common length, both channels: ||a - b|| / ||a||.
    public static func relativeDifference(_ a: StereoRender, _ b: StereoRender, from: Double = 0) -> Double {
        let n = min(a.frameCount, b.frameCount), start = max(0, Int(from * a.sampleRate))
        guard n > start else { return .infinity }
        var num = 0.0, den = 0.0
        for i in start..<n {
            let dl = Double(a.left[i] - b.left[i]), dr = Double(a.right[i] - b.right[i])
            num += dl * dl + dr * dr
            den += Double(a.left[i]) * Double(a.left[i]) + Double(a.right[i]) * Double(a.right[i])
        }
        return den > 0 ? (num / den).squareRoot() : .infinity
    }
}

/// M1 renderer: one `AVAudioPlayerNode` (mono, looping test tone) -> `AVAudioEnvironmentNode` (HRTFHQ, headphone
/// output type) -> main mixer -> output. The listener is moved with `listenerVectorOrientation`; the source is fixed
/// in the room unless a scripted test moves it.
///
/// Real-time rule (docs/ARCHITECTURE.md): there is NO render callback of ours. The tone is a pre-rendered loop played
/// by Apple's player node, and every setter on this class (`setListener`, `setSourcePosition`, `outputVolume`) is a
/// control-thread call: `AVAudioEngine.h` says that getting or setting node properties can require synchronization with the realtime thread (for properties it does not name).
/// The setters are serialized with a lock, which is fine because none of this code ever runs on the audio thread.
public final class EnvironmentRenderer: SpatialSceneSink, @unchecked Sendable {
    public enum Mode: Equatable, Sendable {
        /// Plays through the default output device.
        case live
        /// Manual offline rendering (no hardware, no sound): for tests and measurements.
        case offline(maximumFrames: Int)
    }

    public struct Diagnostics: Equatable, Sendable {
        public var mode: Mode
        public var sampleRate: Double
        public var outputTypeIsHeadphones: Bool
        public var hrtfHQApplicable: Bool
        public var sourceUsesHRTFHQ: Bool
        /// nil before macOS 15 (the property does not exist there).
        public var systemListenerHeadTrackingOff: Bool?
    }

    public let mode: Mode
    public let sampleRate: Double
    public let tone: TestTone

    private let engine: AVAudioEngine
    private let environment = AVAudioEnvironmentNode()
    private let player = AVAudioPlayerNode()
    private let stereoFormat: AVAudioFormat
    private let loop: AVAudioPCMBuffer
    private let lock = NSLock()
    private var started = false
    private var noticeText: String?
    private var configObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - sampleRate: used for `.offline`; `.live` uses the output device's rate.
    ///   - initialSource: where the tone sits before anything moves it (default 2 m straight ahead).
    ///   - loop: the mono samples the player loops at the (live or requested) sample rate; nil = the `TestTone` burst loop of the Step 3a tests. Step 3b passes a `SteadyNoise` loop.
    public init(mode: Mode, sampleRate requested: Double = 48_000, initialSource: Vector3? = nil, loop customLoop: ((Double) -> [Float])? = nil) throws {
        let engine = AVAudioEngine()
        var rate = requested

        switch mode {
        case .offline(let maximumFrames):
            guard rate > 0, maximumFrames > 0, let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
                throw EnvironmentRendererError.badFormat("offline sample rate \(rate), maximum frames \(maximumFrames)")
            }
            // AVAudioEngine.h: enable manual rendering before touching mainMixerNode / outputNode / inputNode, or the
            // engine may configure the hardware first. (The input node is never touched here: no microphone.)
            do { try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: AVAudioFrameCount(maximumFrames)) }
            catch { throw EnvironmentRendererError.engine("enableManualRenderingMode: \(error.localizedDescription)") }
        case .live:
            let hardware = engine.outputNode.outputFormat(forBus: 0)
            guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw EnvironmentRendererError.noAudioOutput }
            rate = hardware.sampleRate
        }

        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            throw EnvironmentRendererError.badFormat("could not create stereo/mono formats at \(rate) Hz")
        }

        let tone = TestTone(sampleRate: rate)
        let samples = customLoop?(rate) ?? tone.makeLoop()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw EnvironmentRendererError.badFormat("could not allocate the tone buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, v) in samples.enumerated() { channel[i] = v }

        self.mode = mode
        self.sampleRate = rate
        self.tone = tone
        self.engine = engine
        self.stereoFormat = stereo
        self.loop = buffer

        engine.attach(environment)
        engine.attach(player)
        try Self.connect(engine, player, environment, format: mono)
        try Self.connect(engine, environment, engine.mainMixerNode, format: stereo)

        // HRTF rendering for headphones. `.HRTFHQ` is explicit (not `.auto`) so the result does not depend on how the
        // system guesses the output route.
        environment.outputType = .headphones
        player.renderingAlgorithm = .HRTFHQ
        player.position = Self.point(initialSource ?? Vector3.direction(azimuthDegrees: 0, elevationDegrees: 0, distance: ListeningTest.sourceDistance))
        environment.listenerVectorOrientation = Self.orientation(.neutral)
        if #available(macOS 15.0, *) { environment.isListenerHeadTrackingEnabled = false }   // never let the system rotate our listener

        if case .live = mode {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                self?.setNotice("The audio device configuration changed and the engine stopped. Press Start again.")
            }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.stop()
    }

    // MARK: - Control (control-thread calls)

    /// Starts rendering. Live: opens the default output and plays the looping tone. Offline: prepares `renderOffline`.
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        player.scheduleBuffer(loop, at: nil, options: .loops, completionHandler: nil)
        do { try engine.start() } catch { throw EnvironmentRendererError.engine("start: \(error.localizedDescription)") }
        do {
            if #available(macOS 27.0, *) { try player.playAudio() } else { player.play() }
        } catch {
            engine.stop()
            throw EnvironmentRendererError.engine("play: \(error.localizedDescription)")
        }
        started = true
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard started else { return }
        player.stop()
        engine.stop()
        started = false
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return started && engine.isRunning }

    /// Something worth telling the user (device change). nil when all is well.
    public var notice: String? { lock.lock(); defer { lock.unlock() }; return noticeText }

    public func setListener(_ orientation: ListenerOrientation) {
        let v = Self.orientation(orientation)
        lock.lock(); environment.listenerVectorOrientation = v; lock.unlock()
    }

    public func setSourcePosition(_ position: Vector3) {
        let p = Self.point(position)
        lock.lock(); player.position = p; lock.unlock()
    }

    /// Master volume 0...1 (applied at the main mixer).
    public var outputVolume: Float {
        get { lock.lock(); defer { lock.unlock() }; return engine.mainMixerNode.outputVolume }
        set { lock.lock(); engine.mainMixerNode.outputVolume = min(max(newValue, 0), 1); lock.unlock() }
    }

    // MARK: - Inspection

    public var diagnostics: Diagnostics {
        lock.lock(); defer { lock.unlock() }
        var headTrackingOff: Bool?
        if #available(macOS 15.0, *) { headTrackingOff = !environment.isListenerHeadTrackingEnabled }
        return Diagnostics(
            mode: mode, sampleRate: sampleRate,
            outputTypeIsHeadphones: environment.outputType == .headphones,
            hrtfHQApplicable: environment.applicableRenderingAlgorithms.contains { $0.intValue == AVAudio3DMixingRenderingAlgorithm.HRTFHQ.rawValue },
            sourceUsesHRTFHQ: player.renderingAlgorithm == .HRTFHQ,
            systemListenerHeadTrackingOff: headTrackingOff)
    }

    /// What AVAudioEnvironmentNode reports back as the listener's angular orientation (degrees). AVAudio's yaw is
    /// clockwise-positive (turn RIGHT = +), the opposite of ours; this exists so a test can pin that fact.
    public var listenerAngularOrientationReadback: (yaw: Double, pitch: Double, roll: Double) {
        lock.lock(); defer { lock.unlock() }
        let a = environment.listenerAngularOrientation
        return (Double(a.yaw), Double(a.pitch), Double(a.roll))
    }

    // MARK: - Offline rendering

    /// Renders `blocks` blocks of `blockFrames` frames in manual offline mode. `beforeBlock(i)` runs before block `i`
    /// on the calling thread, which is where a test publishes poses and steps the pump deterministically.
    public func renderOffline(blocks: Int, blockFrames: Int = 512, beforeBlock: (Int) throws -> Void = { _ in }) throws -> StereoRender {
        guard case .offline(let maximum) = mode else { throw EnvironmentRendererError.render("not in offline mode") }
        guard blockFrames > 0, blockFrames <= maximum else {
            throw EnvironmentRendererError.render("block size \(blockFrames) is outside 1...\(maximum)")
        }
        guard let out = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: AVAudioFrameCount(blockFrames)) else {
            throw EnvironmentRendererError.render("could not allocate the output buffer")
        }
        var left = [Float](), right = [Float]()
        left.reserveCapacity(blocks * blockFrames); right.reserveCapacity(blocks * blockFrames)
        for block in 0..<blocks {
            try beforeBlock(block)
            let status: AVAudioEngineManualRenderingStatus
            do { status = try engine.renderOffline(AVAudioFrameCount(blockFrames), to: out) }
            catch { throw EnvironmentRendererError.render(error.localizedDescription) }
            guard status == .success, let data = out.floatChannelData else {
                throw EnvironmentRendererError.render("status \(status.rawValue) at block \(block)")
            }
            let n = Int(out.frameLength)
            left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
            right.append(contentsOf: UnsafeBufferPointer(start: data[1], count: n))
        }
        return StereoRender(left: left, right: right, sampleRate: sampleRate)
    }

    // MARK: - Private

    /// `connect(_:to:format:)` is deprecated from macOS 27 in favour of a throwing variant (the old one raises an
    /// Objective-C exception on a bad format, which Swift cannot catch). The package minimum is 14, so both are used.
    private static func connect(_ engine: AVAudioEngine, _ a: AVAudioNode, _ b: AVAudioNode, format: AVAudioFormat) throws {
        if #available(macOS 27.0, *) {
            do { try engine.connectNode(a, to: b, format: format) }
            catch { throw EnvironmentRendererError.engine("connect: \(error.localizedDescription)") }
        } else {
            engine.connect(a, to: b, format: format)
        }
    }

    private func setNotice(_ text: String) {
        lock.lock(); noticeText = text; lock.unlock()
    }

    private static func point(_ v: Vector3) -> AVAudio3DPoint {
        AVAudio3DPoint(x: Float(v.x), y: Float(v.y), z: Float(v.z))
    }

    private static func orientation(_ o: ListenerOrientation) -> AVAudio3DVectorOrientation {
        AVAudio3DVectorOrientation(forward: point(o.forward), up: point(o.up))
    }
}
