import AVFoundation
import CoreAudio
import CSystemAudioRing
import Foundation
import SpatialAudioCore

/// A stand-in for Core Audio and the output device that drives the REAL ring (`SARingIOProc`, `SARingRender` through the real `SACreateSourceNode` blocks) with
/// synthetic data. Used by unit tests and by `--ring-probe-simulate`. **Everything it produces is SIMULATED: the report says so, and nothing it shows decides anything
/// about a real Mac** (no sign, latency, drift or hardware claim).
///
/// Producer: our own joinable thread calling the real C IOProc with interleaved Float32 stereo buffers (a known pattern). Consumer: a manual-rendering AVAudioEngine
/// (offline mode, no device) pulled from our own joinable thread. Faults can be injected: a producer rate offset in ppm and one producer stall (an underrun).
///
/// **Teardown (the simulated mode CAN free the ring, because both threads are ours):** the render thread is joined and the engine stopped; the source nodes are
/// detached; the producer thread is joined; only then is the ring freed. Every step is recorded in `events`, so a test can assert the order, and the run under
/// AddressSanitizer catches a free that comes too early (docs/ARCHITECTURE.md, "Step 6b-2").
public final class SimulatedRingBackend: RingProbeBackend, @unchecked Sendable {
    public enum Pacing: Sendable, Equatable {
        /// Two joinable threads paced on the real host clock (the CLI's simulate mode).
        case realTime
        /// No threads and no clock: one call to `advanceOneSecond()` commits and renders `blocksPerSecond` blocks, in a fixed interleaving, on a SYNTHETIC host clock.
        case virtualTime(blocksPerSecond: Int)
    }

    public struct Faults: Sendable, Equatable {
        /// The producer runs this many ppm faster (+) or slower (-) than the tap's declared rate.
        public var producerPPM: Double = 0
        /// The producer commits nothing from `underrunAtSeconds` (since its start) for `underrunStallSeconds`, then resumes at its normal cadence (no catch-up burst).
        public var underrunAtSeconds: Double?
        public var underrunStallSeconds: Double = 0
        public init(producerPPM: Double = 0, underrunAtSeconds: Double? = nil, underrunStallSeconds: Double = 0) {
            self.producerPPM = producerPPM; self.underrunAtSeconds = underrunAtSeconds; self.underrunStallSeconds = underrunStallSeconds
        }
        var summary: String? {
            var parts: [String] = []
            if producerPPM != 0 { parts.append(String(format: "producer rate %+.0f ppm against the declared rate", producerPPM)) }
            if let at = underrunAtSeconds { parts.append(String(format: "producer stalled for %.2f s at %.2f s after it started (an underrun)", underrunStallSeconds, at)) }
            return parts.isEmpty ? nil : parts.joined(separator: "; ")
        }
    }

    /// The format a REAL tap reported in every 6a run (Float32, packed, interleaved, stereo, 48 kHz).
    public static let realTapLikeFormat = TapFormat(sampleRate: 48_000, formatID: "lpcm", formatFlags: 0x9, bytesPerPacket: 8, framesPerPacket: 1,
                                                    bytesPerFrame: 8, channelsPerFrame: 2, bitsPerChannel: 32)
    public static let framesPerCallback = 512

    /// The known pattern the simulated producer writes: >= 1.0, distinct per channel and frame (the same signal as SystemAudioRingTests).
    public static func pattern(channel: UInt32, frame j: Int64) -> Float {
        let h = UInt32(truncatingIfNeeded: j) &* 2654435761 &+ channel &* 40503 &+ 12345
        return Float((h >> 8) & 0xFFFFF) / 1024 + 1
    }

    public let source = "simulated"
    public var composition: String { "simulated source (no Core Audio): our own thread calls the real SARingIOProc; a manual-rendering AVAudioEngine (no device) pulls the two real source nodes" }
    public var hostTicksPerSecond: Double { isVirtual ? Self.syntheticTicksPerSecond : AudioGetHostClockFrequency() }
    public let ringConstants: RingProbeConstants
    public var injectedFaults: String? { faults.summary }
    public var onConfigurationChange: (@Sendable () -> Void)?

    static let syntheticTicksPerSecond = 1_000_000_000.0

    private let pacing: Pacing
    private let faults: Faults
    private let format: TapFormat
    private let capacityFrames: UInt32
    private let readsUntilGone: Int
    private var ring: OpaquePointer?
    private var engine: RingProbeEngine?
    private var producerCore: ProducerCore?
    private var producerThread: PacedThread?
    private var renderThread: PacedThread?
    private var aggregateAlive = false, tapAlive = false, aggregateDestroyed = false, tapDestroyed = false
    private var readsSinceDestroy = (devices: 0, taps: 0)
    private let lock = NSLock()
    private var _events: [String] = []
    /// Test seam: the order of the teardown-relevant happenings ("render pump joined", "engine stopped", "source nodes detached", "producer joined", "ring freed").
    public var events: [String] { lock.lock(); defer { lock.unlock() }; return _events }
    private func record(_ e: String) { lock.lock(); _events.append(e); lock.unlock() }

    // virtual-time state
    private var virtualSecond = 0
    private var emittedFrames: Int64 = 0
    private var producerCarry = 0.0
    private let renderBuffer: AVAudioPCMBuffer?

    private var isVirtual: Bool { if case .virtualTime = pacing { return true } else { return false } }

    public init(pacing: Pacing, faults: Faults = Faults(), format: TapFormat = SimulatedRingBackend.realTapLikeFormat,
                capacityFrames: UInt32 = SA_RING_DEFAULT_CAPACITY_FRAMES, readsUntilGone: Int = 2) {
        self.pacing = pacing; self.faults = faults; self.format = format; self.capacityFrames = capacityFrames; self.readsUntilGone = readsUntilGone
        ringConstants = RingProbeConstants(capacityFrames: capacityFrames, primeCallbacks: SA_RING_DEFAULT_PRIME_CALLBACKS)
        renderBuffer = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate > 0 ? format.sampleRate : 48_000, channels: 2)
            .flatMap { AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: AVAudioFrameCount(Self.framesPerCallback)) }
    }

    deinit {
        // Safe: the threads are always joined by `stop` / `stopEngine`; a ring that was never freed (an aborted run) is freed here.
        producerThread?.requestStopAndJoin(); renderThread?.requestStopAndJoin()
        if let ring { SARingFree(ring) }
    }

    public func preflight() -> String? { nil }
    public func translateOwnPID() -> (object: UInt32, status: Int32) { (7777, 0) }
    public func createTap(excludingProcessObjects: [UInt32]) -> (tap: UInt32, status: Int32) { tapAlive = true; return (101, 0) }
    public func readTapUID(_ tap: UInt32) -> (uid: String?, status: Int32) { ("SIMULATED-TAP-UID", 0) }
    public func readTapFormat(_ tap: UInt32) -> (format: TapFormat?, status: Int32) { (format, 0) }

    public func outputDeviceFacts() -> RingOutputFacts {
        RingOutputFacts(transportType: "virt", transportName: "kAudioDeviceTransportTypeVirtual", nominalSampleRate: 48_000, actualSampleRate: 48_000,
                        bufferFrameSize: 512, outputChannels: 2, inputChannels: 0, statuses: ["simulated": 0])
    }

    public func createRing() -> Bool {
        ring = SARingCreate(capacityFrames)
        if let ring { producerCore = ProducerCore(ring: ring, frames: Self.framesPerCallback, channels: Int(format.channelsPerFrame)) }
        return ring != nil
    }

    public func createAggregate(tapUID: String) -> (device: UInt32, status: Int32) { aggregateAlive = true; return (202, 0) }
    public func createIOProc(on device: UInt32) -> Int32 { 0 }

    public func start(_ device: UInt32) -> Int32 {
        guard let producerCore else { return -1 }
        switch pacing {
        case .virtualTime:
            // The first few tap callbacks are already there when the IO starts, so that priming can succeed without waiting.
            for _ in 0..<8 { commit(producerCore) }
        case .realTime:
            let t = PacedThread(name: "simulated tap IO thread")
            producerThread = t
            let rate = format.sampleRate > 0 ? format.sampleRate : 48_000
            let frames = Self.framesPerCallback
            let ticks = AudioGetHostClockFrequency()
            let periodTicks = Double(frames) / (rate * (1 + faults.producerPPM * 1e-6)) * ticks
            let stallFrom = faults.underrunAtSeconds, stallFor = faults.underrunStallSeconds
            t.start { shouldStop in
                let origin = AudioGetCurrentHostTime()
                var due = Double(origin)
                var stalled = false
                while !shouldStop() {
                    let now = AudioGetCurrentHostTime()
                    let sinceStart = Double(now - origin) / ticks
                    if let from = stallFrom, !stalled, sinceStart >= from {
                        stalled = true
                        // Commit nothing for `stallFor` s, in short slices so a stop request is still honoured, then resume at the normal cadence.
                        let resumeAt = now + UInt64(stallFor * ticks)
                        while AudioGetCurrentHostTime() < resumeAt && !shouldStop() { Thread.sleep(forTimeInterval: 0.002) }
                        due = Double(AudioGetCurrentHostTime())
                        continue
                    }
                    producerCore.emit(startFrame: producerCore.emitted)
                    due += periodTicks
                    let wait = (due - Double(AudioGetCurrentHostTime())) / ticks
                    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                }
            }
        }
        return 0
    }

    /// Virtual time: one producer callback, with the fractional-frame carry of a ppm offset (the callback size itself never changes).
    private func commit(_ core: ProducerCore) { core.emit(startFrame: core.emitted) }

    public func prepareEngine(tapFormat: TapFormat) -> (ok: Bool, detail: String?) {
        guard let ring else { return (false, "no ring") }
        do {
            let e = try RingProbeEngine(ring: ring, sampleRate: tapFormat.sampleRate, mode: .manualOffline(maximumFrames: Self.framesPerCallback))
            e.onConfigurationChange = onConfigurationChange
            e.prepare()
            engine = e
            return (true, nil)
        } catch { return (false, "\(error)") }
    }

    public func engineFacts() -> RingEngineFacts? { engine?.facts() }
    public func engineOutputGain() -> Double? { engine.map { Double($0.outputGain) } }
    public func prime() -> Bool { ring.map { SARingPrime($0, SA_RING_DEFAULT_PRIME_CALLBACKS) } ?? false }

    public func startEngine() -> (ok: Bool, detail: String?) {
        guard let engine else { return (false, "no engine") }
        do { try engine.start() } catch { return (false, "\(error)") }
        switch pacing {
        case .virtualTime:
            renderOne()                                   // both readers are called once, so the runner's first-pull wait is satisfied
        case .realTime:
            let t = PacedThread(name: "simulated render thread")
            renderThread = t
            let rate = format.sampleRate > 0 ? format.sampleRate : 48_000
            let ticks = AudioGetHostClockFrequency()
            let periodTicks = Double(Self.framesPerCallback) / rate * ticks
            t.start { shouldStop in
                let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(Self.framesPerCallback))   // owned by this thread
                var due = Double(AudioGetCurrentHostTime())
                while !shouldStop() {
                    if let buffer { _ = try? engine.renderOffline(AVAudioFrameCount(Self.framesPerCallback), to: buffer) }
                    due += periodTicks
                    let wait = (due - Double(AudioGetCurrentHostTime())) / ticks
                    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                }
            }
        }
        return (true, nil)
    }

    private func renderOne() {
        if let engine, let renderBuffer { _ = try? engine.renderOffline(AVAudioFrameCount(Self.framesPerCallback), to: renderBuffer) }
    }

    /// Virtual time only: the next simulated second. Per block: the producer commits one callback (unless it is stalled), then the consumer renders one block.
    /// A producer offset in ppm shows up as an extra commit now and then (the callback size never changes), so the long-run rates differ by the injected ppm.
    public func advanceOneSecond() {
        guard case .virtualTime(let blocks) = pacing, let core = producerCore else { return }
        let perSecond = Double(blocks) * (1 + faults.producerPPM * 1e-6)
        let second = Double(virtualSecond)
        let stalled = faults.underrunAtSeconds.map { second >= $0 && second < $0 + faults.underrunStallSeconds } ?? false
        producerCarry += perSecond - Double(blocks)
        var extra = 0
        while producerCarry >= 1 { producerCarry -= 1; extra += 1 }
        while producerCarry <= -1 { producerCarry += 1; extra -= 1 }
        let commits = stalled ? 0 : max(0, blocks + extra)
        for b in 0..<max(blocks, commits) {
            if b < commits { commit(core) }
            if b < blocks { renderOne() }
        }
        virtualSecond += 1
    }

    public func configurationChangeCount() -> Int { engine?.configurationChanges.value ?? 0 }

    public func stopEngine() {
        renderThread?.requestStopAndJoin(); renderThread = nil
        record("render pump joined")
        engine?.stop()
        record("engine stopped")
    }

    public func detachSourceNodes() { engine?.detachSourceNodes(); record("source nodes detached") }

    public func stop(_ device: UInt32) -> Int32 {
        producerThread?.requestStopAndJoin(); producerThread = nil
        record("producer joined")
        return 0
    }

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

    public func snapshot() -> RingProbeRawSample? {
        guard let ring else { return nil }
        if isVirtual {
            guard var raw = RingSnapshotMapper.raw(ring: ring, outputNominalRate: 48_000, outputActualRate: 48_000, defaultOutputChanged: false) else { return nil }
            raw.hostTicks = UInt64(1_000_000_000) + UInt64(virtualSecond) * 1_000_000_000          // the SYNTHETIC host clock: exactly one second per advance
            raw.continuousSeconds = Double(virtualSecond)
            return raw
        }
        return RingSnapshotMapper.raw(ring: ring, outputNominalRate: 48_000, outputActualRate: 48_000, defaultOutputChanged: false)
    }

    public func finishRing() -> RingDisposition {
        guard let ring else { return RingDisposition(freed: false, reason: "no ring") }
        SARingFree(ring)
        self.ring = nil
        producerCore = nil
        record("ring freed")
        return RingDisposition(freed: true, reason: "simulated mode: the render thread and the producer thread are our own and were joined, and the engine was stopped, before the free")
    }
}

/// Builds interleaved Float32 stereo AudioBufferLists and calls the real C IOProc.
final class ProducerCore: @unchecked Sendable {
    private let ring: OpaquePointer
    private let frames: Int
    private let channels: Int
    private let abl: UnsafeMutableAudioBufferListPointer
    private let storage: UnsafeMutableRawPointer
    private(set) var emitted: Int64 = 0

    init(ring: OpaquePointer, frames: Int, channels: Int) {
        self.ring = ring; self.frames = frames; self.channels = channels
        storage = UnsafeMutableRawPointer.allocate(byteCount: frames * channels * 4, alignment: 16)
        abl = AudioBufferList.allocate(maximumBuffers: 1)
        abl[0] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(frames * channels * 4), mData: storage)
    }

    deinit { free(abl.unsafeMutablePointer); storage.deallocate() }

    func emit(startFrame: Int64) {
        let p = storage.assumingMemoryBound(to: Float.self)
        for i in 0..<frames { for c in 0..<channels { p[i * channels + c] = SimulatedRingBackend.pattern(channel: UInt32(c), frame: startFrame + Int64(i)) } }
        var now = AudioTimeStamp(); now.mFlags = .hostTimeValid; now.mHostTime = AudioGetCurrentHostTime()
        var inputTime = AudioTimeStamp()
        var outputTime = AudioTimeStamp()
        var output = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer())
        _ = SARingIOProc(0, &now, abl.unsafePointer, &inputTime, &output, &outputTime, UnsafeMutableRawPointer(ring))
        emitted = startFrame + Int64(frames)
    }
}

/// A joinable thread with a stop flag.
final class PacedThread: @unchecked Sendable {
    private let name: String
    private let lock = NSLock()
    private var stopRequested = false
    private let finished = DispatchGroup()
    private var started = false

    init(name: String) { self.name = name }

    func start(_ body: @escaping @Sendable (_ shouldStop: @Sendable () -> Bool) -> Void) {
        started = true
        finished.enter()
        let t = Thread { [self] in body { [self] in shouldStop }; finished.leave() }
        t.name = name
        t.start()
    }

    private var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return stopRequested }

    /// Idempotent: any number of calls after the thread ended return at once.
    func requestStopAndJoin() {
        lock.lock(); stopRequested = true; lock.unlock()
        if started { finished.wait() }
    }
}
