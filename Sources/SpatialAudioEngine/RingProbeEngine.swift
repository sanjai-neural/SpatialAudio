import AVFoundation
import CoreAudio
import CSystemAudioRing
import Foundation
import SpatialAudioCore

// Step 6b-2: the engine half of the ring probe. IMPLEMENTED-UNVERIFIED on hardware (the offline mode is exercised by unit tests only).
//
// Two mono Float32 source nodes (made by the Objective-C factory `SACreateSourceNode`, the only place a render block exists) feed the main mixer; the
// main mixer's output volume is forced to 0. Node 0 reads the ring's left channel, node 1 the right. (There is no pan: measured offline on 2026-11-08, a mono input
// reaches BOTH mixer outputs at unity whatever `pan` says, so the two nodes are told apart in the tests by muting one at a time.) This file never touches `engine.inputNode` (it can open a microphone and switch a Bluetooth headset's
// profile), never uses `EnvironmentRenderer`, the tracker, the pose pump or the camera, and has NO API that raises the gain.
//
// Control-thread code only. Nothing here runs on a render thread: the block that does is in CSystemAudioRing/SASourceNode.m.

enum RingProbeEngineError: Error, Equatable, CustomStringConvertible {
    case format(String)
    case gainNotZero(Float)
    case engine(String)

    var description: String {
        switch self {
        case .format(let s): return "format: \(s)"
        case .gainNotZero(let g): return "the main mixer's output volume is \(g), not 0: refusing to run"
        case .engine(let s): return s
        }
    }
}

/// Counts `AVAudioEngineConfigurationChange` notifications. The handler that increments it must not touch the engine: the header says the
/// notification is posted on an internal dispatch queue and the engine "must not be deallocated from within the client's notification handler".
final class ConfigurationChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// "domain code" of an error, nothing else (a description can carry names or paths).
func ringProbeErrorSummary(_ error: Error) -> String {
    let e = error as NSError
    return "\(e.domain) error \(e.code)"
}

final class RingProbeEngine: @unchecked Sendable {
    enum Mode: Equatable {
        /// Renders to the default output device (the real probe).
        case device
        /// Manual offline rendering, no device (unit tests and the simulated probe).
        case manualOffline(maximumFrames: Int)
    }

    let mode: Mode
    let engine = AVAudioEngine()
    let sourceFormat: AVAudioFormat
    private(set) var nodes: [AVAudioNode] = []          // [left, right]
    let configurationChanges = ConfigurationChangeCounter()
    /// Called (on the notification's queue) after a configuration change was counted; it must not touch the engine.
    var onConfigurationChange: (@Sendable () -> Void)?
    private var observer: NSObjectProtocol?
    private var mixer: AVAudioMixerNode { engine.mainMixerNode }

    /// `ring` must outlive this object, its nodes and every callback (docs/ARCHITECTURE.md, "Lifetime is NOT solved").
    init(ring: OpaquePointer, sampleRate: Double, mode: Mode) throws {
        guard sampleRate.isFinite, sampleRate > 0, let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw RingProbeEngineError.format("no mono Float32 format at \(sampleRate) Hz")
        }
        self.mode = mode
        sourceFormat = mono
        if case .manualOffline(let maximumFrames) = mode {
            guard let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { throw RingProbeEngineError.format("no stereo format") }
            // AVAudioEngine.h: enable manual rendering before touching the mixer / output node.
            do { try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: AVAudioFrameCount(maximumFrames)) }
            catch { throw RingProbeEngineError.engine("enableManualRenderingMode: \(ringProbeErrorSummary(error))") }
        }
        for channel in 0..<2 {
            guard let reader = SARingGetReader(ring, UInt32(channel)), let node = SACreateSourceNode(reader, mono) else {
                throw RingProbeEngineError.engine("could not create the source node of channel \(channel)")
            }
            engine.attach(node)
            try Self.connect(engine, node, mixer, format: mono)
            nodes.append(node)
        }
        mixer.outputVolume = 0                              // THE gain: forced here, read back by the runner, checked again before every start
        let counter = configurationChanges
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            counter.increment()
            self?.onConfigurationChange?()
        }
    }

    deinit { removeObserver() }

    private func removeObserver() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
    }

    /// `connect(_:to:format:)` is deprecated from macOS 27 in favour of a throwing variant (the old one raises an Objective-C exception on error,
    /// which Swift cannot catch). Same pattern as EnvironmentRenderer.
    private static func connect(_ engine: AVAudioEngine, _ a: AVAudioNode, _ b: AVAudioNode, format: AVAudioFormat) throws {
        if #available(macOS 27.0, *) {
            do { try engine.connectNode(a, to: b, format: format) }
            catch { throw RingProbeEngineError.engine("connectNode: \(ringProbeErrorSummary(error))") }
        } else {
            engine.connect(a, to: b, format: format)
        }
    }

    /// The main mixer's output volume, read from the engine.
    var outputGain: Float { mixer.outputVolume }
    var isRunning: Bool { engine.isRunning }
    /// How many times `start()` actually asked the engine to start. A refused start (volume not 0) must leave this at 0: the pre-start check exists so the engine is
    /// never started, not even for an instant, at a volume other than 0 (the check after the start is only a backstop).
    private(set) var startAttempts = 0

    func prepare() { engine.prepare() }

    /// Starts the engine, but only if the output volume reads back as exactly 0 (before and after the start).
    func start() throws {
        guard mixer.outputVolume == 0 else { throw RingProbeEngineError.gainNotZero(mixer.outputVolume) }
        startAttempts += 1
        do { try engine.start() } catch { throw RingProbeEngineError.engine("start: \(ringProbeErrorSummary(error))") }
        guard mixer.outputVolume == 0 else { engine.stop(); throw RingProbeEngineError.gainNotZero(mixer.outputVolume) }
    }

    func stop() {
        engine.stop()
        removeObserver()
    }

    /// Step 6b-3a-2: stops the engine for a re-prime and nothing else: the nodes stay attached and connected and the configuration-change observer stays, so `start()` can run
    /// again. Idempotent. (`AVAudioEngine.stop` is not documented to wait for a render block that is already running; the re-prime therefore also waits for the readers'
    /// call counts to stop changing before it touches the cursors: docs/ARCHITECTURE.md.)
    func pause() { engine.stop() }

    /// Detach both source nodes. AVAudioEngine.h: "If necessary, the engine will safely disconnect the node before detaching it."
    func detachSourceNodes() {
        for n in nodes { engine.detach(n) }
        nodes.removeAll()
    }

    func facts() -> RingEngineFacts {
        let out = engine.outputNode.outputFormat(forBus: 0)
        let realTime: Bool = { if case .device = mode { return true } else { return false } }()
        return RingEngineFacts(realTime: realTime, sourceSampleRate: sourceFormat.sampleRate, sourceChannels: sourceFormat.channelCount,
                               mixerOutputSampleRate: mixer.outputFormat(forBus: 0).sampleRate,
                               outputNodeSampleRate: out.sampleRate > 0 ? out.sampleRate : nil, outputNodeChannels: out.channelCount > 0 ? out.channelCount : nil)
    }

    // MARK: manual offline rendering (tests and the simulated probe)

    /// One offline render of `frames` frames into `buffer`. Only in `.manualOffline` mode.
    func renderOffline(_ frames: AVAudioFrameCount, to buffer: AVAudioPCMBuffer) throws -> AVAudioEngineManualRenderingStatus {
        try engine.renderOffline(frames, to: buffer)
    }

    var manualRenderingFormat: AVAudioFormat { engine.manualRenderingFormat }
}

/// The only place the C snapshot becomes plain Swift numbers (and the only place where "reader 0 is the left channel" is decided for the report).
enum RingSnapshotMapper {
    static func producer(_ s: SARingSnapshot) -> RingProducerCounters {
        var p = RingProducerCounters()
        p.w = s.w; p.commits = s.commits; p.rejectedCommits = s.rejectedCommits; p.rejectFlags = s.rejectFlags
        p.lastCommitFrames = s.lastCommitFrames; p.capacity = s.capacity; p.maxCommit = s.maxCommit
        return p
    }

    static func reader(_ r: SARingReaderStats) -> RingReaderCounters {
        var c = RingReaderCounters()
        c.calls = r.calls; c.framesRequested = r.framesRequested; c.servedBlocks = r.servedBlocks; c.servedFrames = r.servedFrames
        c.underrunBlocks = r.underrunBlocks; c.overrunBlocks = r.overrunBlocks; c.tornBlocks = r.tornBlocks; c.oversizeBlocks = r.oversizeBlocks
        c.badBufferBlocks = r.badBufferBlocks; c.silentFrames = r.silentFrames; c.phaseValidCalls = r.phaseValidCalls
        c.phaseInvalidCalls = r.phaseInvalidCalls; c.phaseSelfChanges = r.phaseSelfChanges; c.phaseMismatches = r.phaseMismatches
        c.weakRuleViolations = r.weakRuleViolations; c.cursor = r.cursor; c.fill = r.fill
        return c
    }

    /// [left, right] = [reader 0, reader 1].
    static func readers(_ s: SARingSnapshot) -> [RingReaderCounters] { [reader(s.reader.0), reader(s.reader.1)] }

    /// The Step 6b-3a-1 side of one reader (the C arrays arrive as Swift tuples, so they are read through a raw buffer).
    static func recovery(_ r: SARingReaderStats, name: String) -> RingReaderRecovery {
        var r = r
        let used = Int(min(r.distinctFrameCounts, UInt32(SA_RING_FRAME_TABLE_SLOTS)))
        var table: [FrameCountEntry] = []
        withUnsafeBytes(of: &r.frameCountValue) { values in
            withUnsafeBytes(of: &r.frameCountCalls) { calls in
                for k in 0..<used {
                    table.append(FrameCountEntry(frameCount: values.load(fromByteOffset: k * MemoryLayout<UInt32>.stride, as: UInt32.self),
                                                 calls: calls.load(fromByteOffset: k * MemoryLayout<UInt64>.stride, as: UInt64.self)))
                }
            }
        }
        let anyCall = used > 0 || r.frameCountOverflowCalls > 0
        return RingReaderRecovery(name: name, frameCounts: table, frameCountOverflowCalls: r.frameCountOverflowCalls,
                                  minFrameCount: anyCall ? r.minFrameCount : nil, maxFrameCount: anyCall ? r.maxFrameCount : nil,
                                  overrunJumps: r.overrunJumps, overrunJumpFrames: r.overrunJumpFrames, divergenceJumps: r.divergenceJumps,
                                  divergenceJumpFrames: r.divergenceJumpFrames, refusedJumps: r.refusedJumps, largestJumpFrames: r.largestJumpFrames,
                                  diverged: r.diverged != 0, needsReprime: r.needsReprime != 0)
    }

    static func recovery(_ s: SARingSnapshot) -> RingRecoverySnapshot {
        RingRecoverySnapshot(standingFill: s.standingFill, needsReprime: s.needsReprime != 0,
                             readers: [recovery(s.reader.0, name: "left (reader 0)"), recovery(s.reader.1, name: "right (reader 1)")])
    }

    /// Takes one snapshot of `ring` and the clock reading that goes with it.
    static func raw(ring: OpaquePointer, outputNominalRate: Double?, outputActualRate: Double?, defaultOutputChanged: Bool) -> RingProbeRawSample? {
        let ticks = AudioGetCurrentHostTime()
        var s = SARingSnapshot()
        guard SARingTakeSnapshot(ring, &s) else { return nil }
        return RingProbeRawSample(hostTicks: ticks, continuousSeconds: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000,
                                  producer: producer(s), readers: readers(s), outputNominalRate: outputNominalRate, outputActualRate: outputActualRate,
                                  defaultOutputChanged: defaultOutputChanged, recovery: recovery(s))
    }
}
