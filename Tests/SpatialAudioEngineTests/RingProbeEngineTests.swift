import AVFoundation
import CoreAudio
import CSystemAudioRing
import Foundation
import SpatialAudioCore
import Testing
@testable import SpatialAudioEngine

// Step 6b-2. The engine half of the ring probe: the real ring and the real source-node blocks behind a manual-rendering AVAudioEngine (offline, no device, nothing audible),
// producer threads handing blocks over with semaphores (no sleeps, no clocks), the gain guard, the timer-driven ticker, and the simulated backend run through the real runner.
// Everything is SIMULATED input and OFFLINE: it checks our code, nothing about a real tap, a real device or the real-time path. (The production mode forces the output volume
// to 0; a few tests below raise the volume of an OFFLINE engine through the internal `engine` property, which no production code path does, to see the data.)

private let blockFrames = 128

private func pattern(_ ch: UInt32, _ j: Int) -> Float { SimulatedRingBackend.pattern(channel: ch, frame: Int64(j)) }

/// `DispatchGroup.wait` is unavailable in an async test body; the group is always finished by a thread that has been told to stop.
private func joinGroup(_ g: DispatchGroup) { g.wait() }

private func snapshot(_ ring: OpaquePointer) -> SARingSnapshot { var s = SARingSnapshot(); #expect(SARingTakeSnapshot(ring, &s)); return s }

/// One direct call of a reader's render function with a mono list (used to give ONE reader a call the other did not get).
@discardableResult
private func directRender(_ rd: OpaquePointer, frames: Int) -> OSStatus {
    var buf = [Float](repeating: 0, count: frames)
    var silent = false
    var ts = AudioTimeStamp()
    return buf.withUnsafeMutableBytes { raw in
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: raw.baseAddress))
        return SARingRender(rd, &silent, &ts, UInt32(frames), &list)
    }
}

/// An offline engine with both nodes, its volume raised to 1 so the data can be seen (TEST ONLY), started through the underlying engine.
private func visibleEngine(ring: OpaquePointer) throws -> RingProbeEngine {
    let e = try RingProbeEngine(ring: ring, sampleRate: 48_000, mode: .manualOffline(maximumFrames: 512))
    e.engine.mainMixerNode.outputVolume = 1
    try e.engine.start()
    return e
}

private func renderBlock(_ e: RingProbeEngine, into out: AVAudioPCMBuffer, appendTo l: inout [Float], _ r: inout [Float]) throws {
    let status = try e.renderOffline(AVAudioFrameCount(blockFrames), to: out)
    #expect(status == .success)
    l.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    r.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![1], count: Int(out.frameLength)))
}

private func matches(_ got: [Float], channel: UInt32, gain g: Float) -> Bool {
    got.enumerated().allSatisfy { abs($0.element - g * pattern(channel, $0.offset)) <= 1e-3 * max(1, abs($0.element)) }
}

@Suite struct RingProbeEngineTests {
    /// One run of the producer-thread scenario with ONE source node muted before the engine starts. A mono input reaches both mixer outputs at unity (measured), so the
    /// node that is left unmuted is what both output channels carry.
    private func runWithNodeMuted(_ muted: Int) throws -> (left: [Float], right: [Float], stats: [SARingReaderStats], total: Int) {
        let ring = SARingCreate(8192)!
        let core = ProducerCore(ring: ring, frames: blockFrames, channels: 2)
        let e = try RingProbeEngine(ring: ring, sampleRate: 48_000, mode: .manualOffline(maximumFrames: 512))
        (e.nodes[muted] as? AVAudioMixing)?.volume = 0
        e.engine.mainMixerNode.outputVolume = 1                                   // TEST ONLY, offline: production forces 0
        try e.engine.start()
        let out = AVAudioPCMBuffer(pcmFormat: e.manualRenderingFormat, frameCapacity: 512)!
        // A bounded buffer, so nothing depends on timing: the consumer renders block k only after the producer has WRITTEN it (`available`), and the producer
        // never runs more than 8 blocks (1024 frames, far inside the 4096-frame window) ahead of the consumer (`credits`). Both threads run concurrently.
        let ahead = 8, total = 48
        let available = DispatchSemaphore(value: 0), credits = DispatchSemaphore(value: ahead)
        let finished = DispatchGroup(); finished.enter()
        let t = Thread {
            for k in 0..<total {
                if credits.wait(timeout: .now() + .seconds(60)) == .timedOut { break }     // bounded, so a failing test cannot hang the suite
                core.emit(startFrame: Int64(k * blockFrames))                              // the producer thread writes the known interleaved pattern
                available.signal()
            }
            finished.leave()
        }
        t.start()
        var left: [Float] = [], right: [Float] = []
        for _ in 0..<total {
            #expect(available.wait(timeout: .now() + .seconds(60)) == .success)
            try renderBlock(e, into: out, appendTo: &left, &right)
            credits.signal()
        }
        e.engine.stop()
        e.detachSourceNodes()
        finished.wait()
        let s = snapshot(ring)
        SARingFree(ring)
        return (left, right, [s.reader.0, s.reader.1], total)
    }

    @Test func eachSourceNodeCarriesItsOwnChannelOfAProducerThreadsPattern() throws {
        // Node 0 alone (node 1 muted) must give the LEFT channel's frames on the output; node 1 alone, the RIGHT channel's. A swapped wiring, or both nodes on one reader, fails one of the two.
        let leftOnly = try runWithNodeMuted(1), rightOnly = try runWithNodeMuted(0)
        #expect(matches(leftOnly.left, channel: 0, gain: 1) && matches(leftOnly.right, channel: 0, gain: 1), "node 0 does not carry the left channel's frames")
        #expect(matches(rightOnly.left, channel: 1, gain: 1) && matches(rightOnly.right, channel: 1, gain: 1), "node 1 does not carry the right channel's frames")
        #expect(!matches(leftOnly.left, channel: 1, gain: 1) && !matches(rightOnly.left, channel: 0, gain: 1), "the two channels' patterns are distinct, so a swap would show")
        for run in [leftOnly, rightOnly] {
            for (name, c) in [("left", run.stats[0]), ("right", run.stats[1])] {
                // both readers are pulled every render (a muted node is still pulled at the mixer: an OFFLINE fact), each for exactly the frames of the block
                #expect(c.calls == UInt64(run.total) && c.framesRequested == UInt64(run.total * blockFrames) && c.servedBlocks == UInt64(run.total), "\(name): calls \(c.calls) requested \(c.framesRequested) served \(c.servedBlocks)")
                #expect(c.underrunBlocks == 0 && c.overrunBlocks == 0 && c.tornBlocks == 0 && c.badBufferBlocks == 0 && c.phaseSelfChanges == 0, "\(name): \(c)")
            }
        }
    }

    @Test func theCountersEqualTheInjectedFaultsThroughTheRealEngine() throws {
        // Fault: the producer stops after 20 blocks while the engine goes on asking for 30. Every number below is derived, not observed first.
        let ring = SARingCreate(8192)!
        let core = ProducerCore(ring: ring, frames: blockFrames, channels: 2)
        for k in 0..<20 { core.emit(startFrame: Int64(k * blockFrames)) }
        let e = try visibleEngine(ring: ring)
        let out = AVAudioPCMBuffer(pcmFormat: e.manualRenderingFormat, frameCapacity: 512)!
        var l: [Float] = [], r: [Float] = []
        for _ in 0..<30 { try renderBlock(e, into: out, appendTo: &l, &r) }
        e.engine.stop(); e.detachSourceNodes()
        let s = snapshot(ring)
        for (name, c) in [("left", s.reader.0), ("right", s.reader.1)] {
            #expect(c.calls == 30 && c.servedBlocks == 20 && c.underrunBlocks == 10, "\(name): calls \(c.calls) served \(c.servedBlocks) underrun \(c.underrunBlocks)")
            #expect(c.framesRequested == 30 * 128 && c.servedFrames == 20 * 128 && c.silentFrames == 10 * 128)
            #expect(c.cursor == 30 * 128 && c.fill == 20 * 128 - 30 * 128, "the cursor advanced by every frame asked for, served or not: fill \(c.fill)")
            #expect(c.overrunBlocks == 0 && c.tornBlocks == 0 && c.oversizeBlocks == 0 && c.badBufferBlocks == 0)
            #expect(c.calls == c.servedBlocks + c.underrunBlocks + c.overrunBlocks + c.tornBlocks + c.oversizeBlocks + c.badBufferBlocks)
        }
        #expect(snapshot(ring).w == 20 * 128 && snapshot(ring).commits == 20)
        #expect(l.suffix(10 * 128).allSatisfy { $0 == 0 } && r.suffix(10 * 128).allSatisfy { $0 == 0 }, "the starved blocks are silence")
        SARingFree(ring)
    }

    @Test func theSnapshotMapperKeepsTheTwoReadersApartAndLeftIsReaderZero() throws {
        let ring = SARingCreate(8192)!
        defer { SARingFree(ring) }
        let core = ProducerCore(ring: ring, frames: blockFrames, channels: 2)
        for k in 0..<20 { core.emit(startFrame: Int64(k * blockFrames)) }
        for _ in 0..<5 { directRender(SARingGetReader(ring, 0)!, frames: 128) }          // left: 5 calls
        for _ in 0..<8 { directRender(SARingGetReader(ring, 1)!, frames: 64) }           // right: 8 calls of a different size
        let readers = RingSnapshotMapper.readers(snapshot(ring))
        #expect(readers.count == 2)
        #expect(readers[0].calls == 5 && readers[0].framesRequested == 640 && readers[0].cursor == 640)
        #expect(readers[1].calls == 8 && readers[1].framesRequested == 512 && readers[1].cursor == 512)
        #expect(readers[0].fill == 2560 - 640 && readers[1].fill == 2560 - 512)
        let p = RingSnapshotMapper.producer(snapshot(ring))
        #expect(p.w == 2560 && p.commits == 20 && p.lastCommitFrames == 128 && p.capacity == 8192 && p.maxCommit == 4096 && p.rejectedCommits == 0)
    }

    @Test func theOutputVolumeIsForcedToZeroAndTheEngineRefusesToStartOtherwise() throws {
        let ring = SARingCreate(8192)!
        defer { SARingFree(ring) }
        let core = ProducerCore(ring: ring, frames: blockFrames, channels: 2)
        for k in 0..<16 { core.emit(startFrame: Int64(k * blockFrames)) }                // 2048 frames, inside the 4096-frame window of an 8192 ring
        let e = try RingProbeEngine(ring: ring, sampleRate: 48_000, mode: .manualOffline(maximumFrames: 512))
        #expect(e.outputGain == 0, "the default volume of a mixer is 1: the code must have forced it to 0")
        #expect(e.nodes.count == 2)
        // another process of the mixer would be a bug: tamper with the volume and the start must be refused, with the engine not running
        e.engine.mainMixerNode.outputVolume = 0.5
        #expect(throws: RingProbeEngineError.gainNotZero(0.5)) { try e.start() }
        #expect(!e.isRunning)
        #expect(e.startAttempts == 0, "the engine must never be asked to start at a volume other than 0, not even to be stopped again at once")
        e.engine.mainMixerNode.outputVolume = 0
        try e.start()
        #expect(e.isRunning && e.outputGain == 0 && e.startAttempts == 1)
        // at gain 0 the offline output is exactly zero ... and the readers WERE pulled (an offline fact only: the real-time engine is what the real run asks)
        let out = AVAudioPCMBuffer(pcmFormat: e.manualRenderingFormat, frameCapacity: 512)!
        var l: [Float] = [], r: [Float] = []
        for _ in 0..<10 { try renderBlock(e, into: out, appendTo: &l, &r) }
        e.stop(); e.detachSourceNodes()
        #expect(l.allSatisfy { $0 == 0 } && r.allSatisfy { $0 == 0 }, "gain 0 must be digital silence")
        let s = snapshot(ring)
        #expect(s.reader.0.calls == 10 && s.reader.1.calls == 10 && s.reader.0.servedBlocks == 10, "source nodes are still pulled at mixer volume 0 in the OFFLINE engine")
    }

    @Test func anEnginesOwnMainMixerStartsAtVolumeOneSoAnAssignmentOfZeroIsObservable() throws {
        // Measured 2026-11-08: a mixer that is not attached to an engine reads 0.0 (so it says nothing); an engine's own main mixer starts at 1.0, in manual and in device mode.
        let manual = AVAudioEngine()
        try manual.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, maximumFrameCount: 512)
        #expect(manual.mainMixerNode.outputVolume == 1 && AVAudioEngine().mainMixerNode.outputVolume == 1)
    }

    @Test func aConfigurationChangeNotificationIsCountedAndTheCallbackRunsButNotAfterStop() throws {
        let ring = SARingCreate(8192)!
        defer { SARingFree(ring) }
        let e = try RingProbeEngine(ring: ring, sampleRate: 48_000, mode: .manualOffline(maximumFrames: 512))
        let called = DispatchSemaphore(value: 0)
        e.onConfigurationChange = { called.signal() }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: e.engine)
        #expect(called.wait(timeout: .now() + .seconds(30)) == .success)
        #expect(e.configurationChanges.value == 1)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: AVAudioEngine())     // another engine's notification is not ours
        #expect(e.configurationChanges.value == 1)
        e.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: e.engine)
        #expect(e.configurationChanges.value == 1, "the observer is removed at stop")
        e.detachSourceNodes()
    }

    @Test func theSourceNodesAreMonoFloat32AtTheTapsRateAndABadRateIsRefused() throws {
        let ring = SARingCreate(8192)!
        defer { SARingFree(ring) }
        let e = try RingProbeEngine(ring: ring, sampleRate: 44_100, mode: .manualOffline(maximumFrames: 512))
        let f = e.facts()
        #expect(f.sourceSampleRate == 44_100 && f.sourceChannels == 1 && !f.realTime)
        #expect(throws: RingProbeEngineError.self) { _ = try RingProbeEngine(ring: ring, sampleRate: 0, mode: .manualOffline(maximumFrames: 512)) }
        #expect(throws: RingProbeEngineError.self) { _ = try RingProbeEngine(ring: ring, sampleRate: .nan, mode: .manualOffline(maximumFrames: 512)) }
    }
}

// MARK: - The timer-driven ticker

@Suite struct DispatchRingTickerTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func add() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    @Test func ticksComeFromATimerNotFromAFixedSleep() async {
        // 40 ticks of 2 ms. A loop that sleeps a fixed second between samples needs 40 s for the same ticks; the deadline below is on the suspending clock
        // and only bounds how long we wait for the completion (the verdict is the count).
        let ticker = DispatchRingTicker()
        let ticks = Counter()
        let done = DispatchGroup(); done.enter()
        let t = Thread {
            while true { if ticker.wait() == .signal { break }; ticks.add() }
            done.leave()
        }
        t.start()
        ticker.start(periodSeconds: 0.002)
        let reached = await waitUntil(timeout: .seconds(15)) { ticks.value >= 40 }
        ticker.stop()
        ticker.requestStop()
        joinGroup(done)
        #expect(reached, "only \(ticks.value) ticks in 15 s of suspending-clock time")
    }

    @Test func aStopRequestBeatsAnInterruptAndAnInterruptBeatsATickAndBothAreSticky() {
        let ticker = DispatchRingTicker()
        ticker.interrupt(); ticker.requestStop()
        #expect(ticker.wait() == .signal && ticker.wait() == .signal, "a stop request stays pending")
        let b = DispatchRingTicker()
        b.start(periodSeconds: 0.001)
        b.interrupt()
        #expect(b.wait() == .interrupt && b.wait() == .interrupt)
        b.stop()
    }

    @Test func everyCombinationOfPendingEventsIsDeliveredInPriorityOrderWithoutATimer() {
        // Events are posted directly, so a tick really is pending alongside the others (the timer-based test above cannot guarantee that). R26b (a tick returned
        // before a stop request or an interrupt) survived the timer-based test for exactly that reason.
        let all = DispatchRingTicker()
        all.post(tick: true, signal: true, interrupt: true)
        #expect(all.wait() == .signal && all.wait() == .signal, "a stop request beats an interrupt and a tick, and stays pending")
        let signalAndTick = DispatchRingTicker()
        signalAndTick.post(tick: true, signal: true, interrupt: false)
        #expect(signalAndTick.wait() == .signal && signalAndTick.wait() == .signal)
        let interruptAndTick = DispatchRingTicker()
        interruptAndTick.post(tick: true, signal: false, interrupt: true)
        #expect(interruptAndTick.wait() == .interrupt && interruptAndTick.wait() == .interrupt, "an interrupt beats a tick, and stays pending")
        let signalAndInterrupt = DispatchRingTicker()
        signalAndInterrupt.post(tick: false, signal: true, interrupt: true)
        #expect(signalAndInterrupt.wait() == .signal)
        let tickOnly = DispatchRingTicker()
        tickOnly.post(tick: true, signal: false, interrupt: false)
        #expect(tickOnly.wait() == .tick)
        tickOnly.post(tick: false, signal: false, interrupt: true)     // the tick was consumed: only the interrupt is left
        #expect(tickOnly.wait() == .interrupt)
    }

    @Test func aTimerThatWasStoppedCanBeStartedAgainAndStopIsIdempotent() async {
        let ticker = DispatchRingTicker()
        ticker.stop(); ticker.stop()
        for _ in 0..<2 {
            ticker.start(periodSeconds: 0.002)
            #expect(ticker.wait() == .tick)
            ticker.stop(); ticker.stop()
        }
    }
}

// MARK: - The simulated backend through the real runner

/// Advances the simulation by one virtual second per wait, then reports a tick. After `limit` waits it reports a signal.
private final class VirtualTicker: RingProbeTicker {
    let sim: SimulatedRingBackend
    let limit: Int
    var waits = 0
    init(sim: SimulatedRingBackend, limit: Int) { self.sim = sim; self.limit = limit }
    func start(periodSeconds: Double) {}
    func wait() -> RingProbeWake {
        waits += 1
        if waits > limit { return .signal }
        sim.advanceOneSecond()
        return .tick
    }
    func stop() {}
}

private final class StepClock: @unchecked Sendable {
    private let lock = NSLock(); private var t = 0.0
    var clock: TapProbeClock {
        TapProbeClock(now: { [self] in lock.lock(); defer { lock.unlock() }; return t }, sleep: { [self] d in lock.lock(); t += d; lock.unlock() })
    }
}

private func environment(_ seconds: Double) -> RingProbeEnvironment {
    RingProbeEnvironment(createdAt: "2026-11-08T00:00:00Z", macOSVersion: "test", hardwareModel: "test", ownPID: 1, requestedSeconds: seconds)
}

private let freeOrder = ["render pump joined", "engine stopped", "source nodes detached", "producer joined", "ring freed"]

@Suite struct SimulatedRingProbeTests {
    @Test func aVirtualTimeRunThroughTheRealRingAndEngineIsExactAndFreesTheRingLast() throws {
        let sim = SimulatedRingBackend(pacing: .virtualTime(blocksPerSecond: 94))
        let ticker = VirtualTicker(sim: sim, limit: 100)
        let r = RingProbeRunner.run(backend: sim, ticker: ticker, environment: environment(20), clock: StepClock().clock)
        #expect(r.outcome == "ok" && r.stoppedBy == "timeout" && r.teardownClean && r.isSimulated)
        #expect(r.samples.count == 21 && r.samples.map(\.elapsedSeconds) == (0...20).map(Double.init))
        let s = try #require(r.summary)
        #expect(s.producerFramesPerHostSecond == 94 * 512 && s.readers.allSatisfy { $0.framesRequestedPerHostSecond == 94 * 512 }, "producer and readers move 94 x 512 frames per measured second")
        #expect(s.readers.allSatisfy { $0.fillStart == 1536 && $0.fillEnd == 1536 && abs($0.fillSlopeFramesPerSecond ?? .nan) < 1e-9 }, "equal rates: the fill does not move")
        #expect(s.readers.allSatisfy { $0.finalCounters.underrunBlocks == 0 && $0.finalCounters.calls == $0.finalCounters.servedBlocks && $0.finalCounters.calls == 1 + 94 * 20 + 0 })
        #expect(s.readers.allSatisfy { $0.validTimestampShare == 1 && $0.finalCounters.phaseSelfChanges == 0 }, "offline: every call carried a valid sample time (an OFFLINE fact)")
        #expect(s.readers[0].framesPerCallIntervalMeans?.min == 512 && s.readers[0].framesPerCallIntervalMeans?.max == 512)
        #expect(sim.events == freeOrder, "stop the render pump and the engine, detach, join the producer, and only then free: \(sim.events)")
        #expect(r.ring?.freed == true && r.teardownOrder.last == "ring freed")
        #expect(r.outputGain.readBackBeforeStart == 0 && r.outputGain.readBackAfterStart == 0 && r.outputGain.readBackAtEnd == 0)
        #expect(r.teardownOrder == ["sampling timer off", "engine stop", "source nodes detached", "IO stop", "IOProc destroyed", "aggregate destroyed", "tap destroyed", "ring freed"])
    }

    @Test func anInjectedUnderrunLeavesTheReadersStarvedAndTheFillSlopeStillTheRateDifference() throws {
        // The producer runs +10,000 ppm (1 %) fast and stalls for one second at 10 s. The reader advances by every frame it is asked for, served or not, so after the
        // stall it is AHEAD of the producer and stays starved; the claim under test: the fill slope is still (producer rate - reader rate), before and after the underrun.
        let sim = SimulatedRingBackend(pacing: .virtualTime(blocksPerSecond: 94), faults: .init(producerPPM: 10_000, underrunAtSeconds: 10, underrunStallSeconds: 1))
        let r = RingProbeRunner.run(backend: sim, ticker: VirtualTicker(sim: sim, limit: 200), environment: environment(90), clock: StepClock().clock)
        #expect(r.outcome == "ok" && r.injectedFaults?.contains("stalled") == true && r.injectedFaults?.contains("+10000 ppm") == true)
        let expectedSlope = 0.01 * 94 * 512                                          // extra frames per second the faster producer writes
        for reader in 0..<2 {
            let before = r.samples.filter { $0.elapsedSeconds <= 10 }
            let after = r.samples.filter { $0.elapsedSeconds >= 12 }
            let slopeBefore = try #require(RingProbeAnalyzer.slopeOf(RingProbeAnalyzer.fillSeries(before, reader: reader)))
            let slopeAfter = try #require(RingProbeAnalyzer.slopeOf(RingProbeAnalyzer.fillSeries(after, reader: reader)))
            #expect(abs(slopeBefore - expectedSlope) < 0.1 * expectedSlope, "reader \(reader) slope before the stall \(slopeBefore), expected about \(expectedSlope)")
            #expect(abs(slopeAfter - expectedSlope) < 0.03 * expectedSlope, "reader \(reader) slope after the underrun \(slopeAfter), expected about \(expectedSlope)")
            #expect(after.allSatisfy { $0.readers[reader].fill < 0 }, "starved for the whole rest of the run: the reader stays ahead of the producer")
            let c = try #require(r.summary).readers[reader].finalCounters
            let atTwelve = try #require(r.samples.first(where: { $0.elapsedSeconds >= 12 }))
            #expect(c.underrunBlocks > 0 && c.servedBlocks < c.calls)
            #expect(c.servedBlocks == atTwelve.readers[reader].servedBlocks, "no block was served after the underrun began")
        }
        #expect(r.notes.contains { $0.contains("EXPECTED in this count-only spike") })
        #expect(sim.events == freeOrder)
    }

    @Test func aRealTimeSimulatedRunWithBothThreadsEndsCleanlyAndFreesTheRingAfterBothAreJoined() throws {
        let sim = SimulatedRingBackend(pacing: .realTime)
        let ticker = DispatchRingTicker()
        sim.onConfigurationChange = { ticker.interrupt() }
        let suspending = SuspendingClock(); let origin = suspending.now
        let clock = TapProbeClock(now: { let d = origin.duration(to: suspending.now); return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 },
                                  sleep: { Thread.sleep(forTimeInterval: $0) })
        let r = RingProbeRunner.run(backend: sim, ticker: ticker, environment: environment(3), clock: clock)
        #expect(r.outcome == "ok" && r.teardownClean && r.isSimulated, "\(r.outcome) \(r.notes)")
        #expect(r.samples.count >= 3 && r.samples.first?.elapsedSeconds == 0 && (r.samples.last?.elapsedSeconds ?? 0) >= 3)
        let rs = try #require(r.summary)
        #expect(rs.readers.allSatisfy { $0.finalCounters.calls > 0 && $0.finalCounters.phaseSelfChanges == 0 })
        #expect((rs.producerFramesPerHostSecond ?? 0) > 40_000 && (rs.producerFramesPerHostSecond ?? .infinity) < 56_000, "a sanity bound on a SIMULATED producer, not a result")
        #expect(sim.events == freeOrder, "\(sim.events)")
        #expect(r.ring?.freed == true)
    }

    @Test func theRealBackendNeverFreesTheRingAndUsesTheNamedConstants() {
        guard #available(macOS 14.2, *) else { return }
        let real = SystemRingBackend()
        #expect(real.createRing() && real.source == "coreAudioTap" && real.injectedFaults == nil)
        #expect(real.ringConstants == RingProbeConstants(capacityFrames: 32768, primeCallbacks: 4), "N and T stay the named guesses")
        let d = real.finishRing()
        #expect(!d.freed && !real.ringFreed && d.reason.contains("until the process exits"))
        #expect(real.configurationChangeCount() == 0 && real.engineOutputGain() == nil && !real.prime(), "nothing was started, primed or created beyond the ring")
        #expect(!real.composition.lowercased().contains("uid") && !real.composition.contains("/Users"))
        #expect(SimulatedRingBackend(pacing: .realTime).ringConstants == real.ringConstants)
    }
}
