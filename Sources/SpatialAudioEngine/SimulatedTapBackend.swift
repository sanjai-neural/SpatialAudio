import CoreAudio
import CTapProbe
import Foundation
import SpatialAudioCore

/// A stand-in for Core Audio that drives the REAL C callback (`SATapProbeIOProc`) with synthetic buffers from a separate thread.
/// Used by unit tests and by `--tap-probe-simulate`. **Everything it produces is SIMULATED: the report says so, and nothing it
/// shows decides anything about a real Mac.** Tap, aggregate device and IO proc are fictional objects that "disappear" from the
/// lists after `readsUntilGone` reads, so the runner's polling is exercised too.
public final class SimulatedTapBackend: TapProbeBackend {
    public enum Pacing: Sendable {
        /// `start` emits exactly this many callbacks on a helper thread, with a synthetic exact timeline, and joins it:
        /// deterministic, no clock involved (for tests).
        case burst(callbacks: Int)
        /// A helper thread emits callbacks at the nominal cadence on the real host clock until `stop`.
        case realTime
    }

    public static let stereoFloat48k = TapFormat(sampleRate: 48_000, formatID: "lpcm", formatFlags: 0x29 /* float, packed, non-interleaved */,
                                                bytesPerPacket: 4, framesPerPacket: 1, bytesPerFrame: 4, channelsPerFrame: 2, bitsPerChannel: 32)

    public let source = "simulated"
    public var composition: String { "simulated source (no Core Audio): a test thread calls the real C callback" }

    private let pacing: Pacing
    private let format: TapFormat
    private let amplitude: Float
    private let framesPerCallback: Int
    private let readsUntilGone: Int
    private var probe: OpaquePointer?
    private var emitter: Emitter?
    private var aggregateAlive = false, tapAlive = false
    private var readsSinceDestroy = (devices: 0, taps: 0)
    private var aggregateDestroyed = false, tapDestroyed = false

    /// `readsUntilGone`: how many list reads after the destroy call still show the object (it simulates the asynchronous destroy).
    public init(pacing: Pacing, format: TapFormat = SimulatedTapBackend.stereoFloat48k, amplitude: Float = 0.25,
                framesPerCallback: Int = 512, readsUntilGone: Int = 2) {
        self.pacing = pacing; self.format = format; self.amplitude = amplitude
        self.framesPerCallback = framesPerCallback; self.readsUntilGone = readsUntilGone
    }

    deinit { SATapProbeFree(probe) }          // safe: the emitter thread is always joined in `stop`

    public func preflight() -> String? { nil }
    public func translateOwnPID() -> (object: UInt32, status: Int32) { (7777, 0) }
    public func createTap(excludingProcessObjects: [UInt32]) -> (tap: UInt32, status: Int32) { tapAlive = true; return (101, 0) }
    public func readTapUID(_ tap: UInt32) -> (uid: String?, status: Int32) { ("SIMULATED-TAP-UID", 0) }
    public func readTapFormat(_ tap: UInt32) -> (format: TapFormat?, status: Int32) { (format, 0) }

    public func prepareCapture(format: TapFormat, capacity: Int) -> Bool {
        probe = SATapProbeCreate(UInt32(clamping: capacity), format.bytesPerSample, format.isFloat32)
        return probe != nil
    }

    public func createAggregate(tapUID: String) -> (device: UInt32, status: Int32) { aggregateAlive = true; return (202, 0) }
    public func createIOProc(on device: UInt32) -> Int32 { 0 }

    public func start(_ device: UInt32) -> Int32 {
        guard let probe else { return -1 }
        let e = Emitter(probe: probe, format: format, amplitude: amplitude, frames: framesPerCallback, pacing: pacing)
        emitter = e
        e.start()
        if case .burst = pacing { e.join() }          // deterministic: all callbacks are done when start returns
        return 0
    }

    public func stop(_ device: UInt32) -> Int32 { emitter?.requestStopAndJoin(); return 0 }
    public func destroyIOProc(on device: UInt32) -> Int32 { 0 }
    public func destroyAggregate(_ device: UInt32) -> Int32 { aggregateDestroyed = true; return 0 }
    public func destroyTap(_ tap: UInt32) -> Int32 { tapDestroyed = true; return 0 }

    public func listDevices() -> (ids: [UInt32], status: Int32) {
        var ids: [UInt32] = [31, 32, 33]
        if aggregateAlive {
            if aggregateDestroyed { readsSinceDestroy.devices += 1; if readsSinceDestroy.devices <= readsUntilGone { ids.append(202) } else { aggregateAlive = false } }
            else { ids.append(202) }
        }
        return (ids, 0)
    }

    public func listTaps() -> (ids: [UInt32], status: Int32) {
        var ids: [UInt32] = []
        if tapAlive {
            if tapDestroyed { readsSinceDestroy.taps += 1; if readsSinceDestroy.taps <= readsUntilGone { ids.append(101) } else { tapAlive = false } }
            else { ids.append(101) }
        }
        return (ids, 0)
    }

    public func collect() -> TapProbeCollected {
        let ticks: Double
        switch pacing { case .burst: ticks = Emitter.syntheticTicksPerSecond; case .realTime: ticks = AudioGetHostClockFrequency() }
        return TapProbeCollected(records: TapProbeRecords.read(probe), dropped: probe.map(SATapProbeDropped) ?? 0, hostTicksPerSecond: ticks)
    }
}

/// Builds synthetic AudioBufferLists and calls the C callback from its own thread.
private final class Emitter: @unchecked Sendable {
    static let syntheticTicksPerSecond = 1_000_000_000.0

    private let probe: OpaquePointer
    private let format: TapFormat
    private let amplitude: Float
    private let frames: Int
    private let pacing: SimulatedTapBackend.Pacing
    private let lock = NSLock()
    private var stopRequested = false
    private let finished = DispatchGroup()           // waiting on a group is idempotent: any number of joins after the thread ended return at once
    private var thread: Thread?

    init(probe: OpaquePointer, format: TapFormat, amplitude: Float, frames: Int, pacing: SimulatedTapBackend.Pacing) {
        self.probe = probe; self.format = format; self.amplitude = amplitude; self.frames = frames; self.pacing = pacing
    }

    func start() {
        finished.enter()
        let t = Thread { [self] in run(); finished.leave() }
        t.name = "simulated tap IO thread"
        thread = t
        t.start()
    }

    func join() { finished.wait() }

    func requestStopAndJoin() {
        lock.lock(); stopRequested = true; lock.unlock()
        join()
    }

    private var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return stopRequested }

    private func run() {
        let channels = Int(format.channelsPerFrame)
        let bytesPerSample = max(Int(format.bytesPerSample), 1)
        let interleaved = format.isInterleaved
        let buffers = interleaved ? 1 : channels
        let samplesPerBuffer = frames * (interleaved ? channels : 1)
        let abl = AudioBufferList.allocate(maximumBuffers: buffers)
        var storage: [UnsafeMutableRawPointer] = []
        defer { free(abl.unsafeMutablePointer); storage.forEach { $0.deallocate() } }
        for b in 0..<buffers {
            let mem = UnsafeMutableRawPointer.allocate(byteCount: samplesPerBuffer * bytesPerSample, alignment: 16)
            storage.append(mem)
            abl[b] = AudioBuffer(mNumberChannels: interleaved ? UInt32(channels) : 1, mDataByteSize: UInt32(samplesPerBuffer * bytesPerSample), mData: mem)
        }
        let rate = format.sampleRate > 0 ? format.sampleRate : 48_000
        var phase = 0.0
        var k = 0
        let startHost = AudioGetCurrentHostTime()
        let hostTicks = AudioGetHostClockFrequency()
        var burstLeft: Int? = { if case .burst(let n) = pacing { return n } else { return nil } }()
        while !shouldStop {
            if let left = burstLeft { if left == 0 { break }; burstLeft = left - 1 }
            // Fill: a 440 Hz sine for float formats, zeros otherwise.
            if format.isFloat32 {
                for b in 0..<buffers {
                    let p = storage[b].assumingMemoryBound(to: Float.self)
                    for i in 0..<samplesPerBuffer {
                        let frame = interleaved ? i / channels : i
                        p[i] = amplitude * Float(sin(2 * .pi * 440 * (phase + Double(frame) / rate)))
                    }
                }
                phase += Double(frames) / rate
            } else {
                for b in 0..<buffers { memset(storage[b], 0, samplesPerBuffer * bytesPerSample) }
            }
            var now = AudioTimeStamp()
            now.mFlags = .hostTimeValid
            switch pacing {
            case .burst: now.mHostTime = UInt64(1_000_000_000) + UInt64((Double(k) * Double(frames) / rate * Emitter.syntheticTicksPerSecond).rounded())
            case .realTime: now.mHostTime = AudioGetCurrentHostTime()
            }
            var inputTime = now, outputTime = AudioTimeStamp()
            var output = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer())          // a tap has no output streams
            _ = SATapProbeIOProc(0, &now, abl.unsafePointer, &inputTime, &output, &outputTime, UnsafeMutableRawPointer(probe))
            k += 1
            if case .realTime = pacing {
                let due = startHost + UInt64(Double(k) * Double(frames) / rate * hostTicks)
                let nowHost = AudioGetCurrentHostTime()
                if due > nowHost { Thread.sleep(forTimeInterval: Double(due - nowHost) / hostTicks) }
            }
        }
    }
}
