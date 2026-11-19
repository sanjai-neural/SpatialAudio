import AVFoundation
import Foundation
import SpatialAudioCore

/// Step 6b-3c-0: the OFFLINE level calibration of the two-source HRTF graph (docs/STATUS.md "Step 6b-3c plan", decision 3). IMPLEMENTED-UNVERIFIED as a statement about anything but this offline graph.
///
/// What it does: manual offline rendering (no audio device, nothing audible) of two mono sources, one at -30 degrees and one at +30 degrees, 2 m (`ListeningTest.sourceDistance`), `.HRTFHQ`, into one environment node
/// (`outputType = .headphones`, neutral listener) and the main mixer at output volume 1, from known inputs (a left-only, a right-only and a both-channels signal at known levels), and reads the level at each ear after a
/// 0.5 s warm-up. The two sources are Apple player nodes feeding the SAME environment node as the real graph's source nodes will: the environment node's processing does not depend on what feeds it, which is an
/// assumption of this measurement, not a result. Numbers only. It proposes a gain cap (`GainCapProposal`); it applies nothing.
public enum StereoCalibration {
    public enum Signal: Sendable, Equatable {
        case sine(hz: Double)
        case noise
        var label: String {
            switch self { case .sine(let hz): return "sine \(Int(hz)) Hz"; case .noise: return "noise" }
        }
    }

    public struct Case: Sendable, Equatable {
        public var signal: Signal
        /// Peak amplitude of each ACTIVE channel's signal (1.0 = full scale).
        public var amplitude: Float
        public var leftActive: Bool
        public var rightActive: Bool
        public var name: String {
            let which = leftActive && rightActive ? "both" : (leftActive ? "left only" : "right only")
            return "\(signal.label), peak \(String(format: "%.2f", amplitude)), \(which)"
        }
        public init(signal: Signal, amplitude: Float, leftActive: Bool, rightActive: Bool) {
            self.signal = signal; self.amplitude = amplitude; self.leftActive = leftActive; self.rightActive = rightActive
        }
    }

    public struct Row: Sendable, Equatable {
        public var caseName: String
        public var sampleRate: Double
        public var fullScale: Bool
        public var inputRMSDecibels: Double
        public var leftEarRMSDecibels: Double
        public var rightEarRMSDecibels: Double
        /// Each ear's RMS relative to ONE active input channel's RMS, dB.
        public var leftEarRelativeDecibels: Double
        public var rightEarRelativeDecibels: Double
        public var outputPeak: Double
        /// How many frames after the start were skipped as warm-up before measuring.
        public var skippedFrames: Int
        /// The larger ear peak divided by the input peak, linear.
        public var peakGain: Double
        public var peakGainDecibels: Double { LevelMath.amplitudeDecibels(peakGain) }
    }

    public static let warmupSeconds = 0.5
    public static let measuredSeconds = 2.0

    public static func standardCases() -> [Case] {
        var cases: [Case] = []
        let channels: [(Bool, Bool)] = [(true, false), (false, true), (true, true)]
        for hz in [100.0, 1000.0, 4000.0, 8000.0] {
            for (l, r) in channels { cases.append(Case(signal: .sine(hz: hz), amplitude: 0.1, leftActive: l, rightActive: r)) }
        }
        for hz in [100.0, 1000.0, 4000.0, 8000.0] {
            for (l, r) in channels { cases.append(Case(signal: .sine(hz: hz), amplitude: 1.0, leftActive: l, rightActive: r)) }
        }
        for (l, r) in channels { cases.append(Case(signal: .noise, amplitude: 1.0, leftActive: l, rightActive: r)) }
        return cases
    }

    /// Deterministic input: one second, integer-Hz sines have whole periods, so the loop has no seam.
    static func input(_ signal: Signal, amplitude: Float, sampleRate: Double) -> [Float] {
        let n = Int(sampleRate)
        switch signal {
        case .sine(let hz):
            return (0..<n).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / sampleRate)) }
        case .noise:
            var state: UInt64 = 0x1234_5678_9ABC_DEF1
            return (0..<n).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return amplitude * (Float(Double(state >> 11) / Double(1 << 53)) * 2 - 1)
            }
        }
    }

    public static func measure(_ c: Case, sampleRate: Double, distance: Double = ListeningTest.sourceDistance) throws -> Row {
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { throw EnvironmentRendererError.badFormat("formats at \(sampleRate) Hz") }
        let engine = AVAudioEngine()
        do { try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 512) }
        catch { throw EnvironmentRendererError.engine("enableManualRenderingMode: \(error.localizedDescription)") }
        let environment = AVAudioEnvironmentNode()
        let leftPlayer = AVAudioPlayerNode(), rightPlayer = AVAudioPlayerNode()
        for node in [environment, leftPlayer, rightPlayer] as [AVAudioNode] { engine.attach(node) }
        engine.connect(leftPlayer, to: environment, format: mono)
        engine.connect(rightPlayer, to: environment, format: mono)
        engine.connect(environment, to: engine.mainMixerNode, format: stereo)
        environment.outputType = .headphones
        leftPlayer.renderingAlgorithm = .HRTFHQ
        rightPlayer.renderingAlgorithm = .HRTFHQ
        func point(_ v: Vector3) -> AVAudio3DPoint { AVAudio3DPoint(x: Float(v.x), y: Float(v.y), z: Float(v.z)) }
        leftPlayer.position = point(Vector3.direction(azimuthDegrees: -30, elevationDegrees: 0, distance: distance))
        rightPlayer.position = point(Vector3.direction(azimuthDegrees: 30, elevationDegrees: 0, distance: distance))
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(forward: AVAudio3DVector(x: 0, y: 0, z: -1), up: AVAudio3DVector(x: 0, y: 1, z: 0))
        engine.mainMixerNode.outputVolume = 1                 // "at gain 1"

        let signal = input(c.signal, amplitude: c.amplitude, sampleRate: sampleRate)
        let silence = [Float](repeating: 0, count: signal.count)
        func buffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
            guard let b = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(samples.count)), let ch = b.floatChannelData?[0] else { throw EnvironmentRendererError.badFormat("buffer") }
            b.frameLength = AVAudioFrameCount(samples.count)
            for (i, v) in samples.enumerated() { ch[i] = v }
            return b
        }
        leftPlayer.scheduleBuffer(try buffer(c.leftActive ? signal : silence), at: nil, options: .loops, completionHandler: nil)
        rightPlayer.scheduleBuffer(try buffer(c.rightActive ? signal : silence), at: nil, options: .loops, completionHandler: nil)
        do { try engine.start() } catch { throw EnvironmentRendererError.engine("start: \(error.localizedDescription)") }
        for p in [leftPlayer, rightPlayer] {
            if #available(macOS 27.0, *) { try p.playAudio() } else { p.play() }
        }

        guard let out = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 512) else { throw EnvironmentRendererError.render("output buffer") }
        let blocks = Int((warmupSeconds + measuredSeconds) * sampleRate / 512)
        var left: [Float] = [], right: [Float] = []
        for _ in 0..<blocks {
            let status: AVAudioEngineManualRenderingStatus
            do { status = try engine.renderOffline(512, to: out) } catch { throw EnvironmentRendererError.render(error.localizedDescription) }
            guard status == .success, let data = out.floatChannelData else { throw EnvironmentRendererError.render("status \(status.rawValue)") }
            left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
            right.append(contentsOf: UnsafeBufferPointer(start: data[1], count: Int(out.frameLength)))
        }
        engine.stop()

        let skip = Int(warmupSeconds * sampleRate)
        let l = left[skip...], r = right[skip...]
        let inRMS = LevelMath.rms(signal[...])
        let lRMS = LevelMath.rms(l), rRMS = LevelMath.rms(r)
        let outPeak = max(LevelMath.peak(l), LevelMath.peak(r))
        return Row(caseName: c.name, sampleRate: sampleRate, fullScale: c.amplitude >= 1.0, inputRMSDecibels: LevelMath.amplitudeDecibels(inRMS),
                   leftEarRMSDecibels: LevelMath.amplitudeDecibels(lRMS), rightEarRMSDecibels: LevelMath.amplitudeDecibels(rRMS),
                   leftEarRelativeDecibels: LevelMath.amplitudeDecibels(lRMS / inRMS), rightEarRelativeDecibels: LevelMath.amplitudeDecibels(rRMS / inRMS),
                   outputPeak: outPeak, skippedFrames: skip, peakGain: outPeak / max(LevelMath.peak(signal[...]), 1e-12))
    }

    /// The worst (largest) peak gain over the FULL-SCALE rows.
    public static func worstFullScalePeakGain(_ rows: [Row]) -> Double? { rows.filter(\.fullScale).map(\.peakGain).max() }

    /// A printed table, numbers only.
    public static func table(_ rows: [Row]) -> String {
        var out = ["| input | rate | in RMS dBFS | left ear RMS dBFS | right ear RMS dBFS | left ear rel. dB | right ear rel. dB | out peak | peak gain dB |", "|---|---|---|---|---|---|---|---|---|"]
        func f(_ v: Double) -> String { String(format: "%.2f", v) }
        for r in rows {
            out.append("| \(r.caseName) | \(Int(r.sampleRate)) | \(f(r.inputRMSDecibels)) | \(f(r.leftEarRMSDecibels)) | \(f(r.rightEarRMSDecibels)) | \(f(r.leftEarRelativeDecibels)) | \(f(r.rightEarRelativeDecibels)) | \(f(r.outputPeak)) | \(f(r.peakGainDecibels)) |")
        }
        return out.joined(separator: "\n")
    }
}
