import AVFoundation
import CoreAudio
import CSystemAudioRing
import Foundation
import SpatialAudioCore
import Testing
@testable import SpatialAudioEngine

// Step 6b-3a-2. The control-thread re-prime against the REAL C ring (SARingPrime, SARingTakeSnapshot) and a REAL AVAudioEngine in manual offline rendering (no device, nothing
// audible, output volume 0), on a VIRTUAL clock: no sleep and no wall-clock verdict. Everything here is SIMULATED input and OFFLINE: it checks our code, not a real tap, a real
// device, Bluetooth or the real-time path. The controller's logic is tested in Tests/SpatialAudioCoreTests (RePrimeControllerTests, RingRecoveryOrchestratorTests).

private func snap(_ ring: OpaquePointer) -> SARingSnapshot { var s = SARingSnapshot(); #expect(SARingTakeSnapshot(ring, &s)); return s }

private final class VirtualClockBox: @unchecked Sendable {
    private let lock = NSLock(); private var t = 0.0
    var clock: TapProbeClock {
        TapProbeClock(now: { [self] in lock.lock(); defer { lock.unlock() }; return t }, sleep: { [self] d in lock.lock(); t += d; lock.unlock() })
    }
}

private final class VirtualSimTicker: RingProbeTicker {
    let sim: SimulatedRingBackend; let limit: Int; var waits = 0
    let clockBox: VirtualClockBox
    init(sim: SimulatedRingBackend, limit: Int, clockBox: VirtualClockBox) { self.sim = sim; self.limit = limit; self.clockBox = clockBox }
    func start(periodSeconds: Double) {}
    func wait() -> RingProbeWake {
        waits += 1
        if waits > limit { return .signal }
        sim.advanceOneSecond()
        clockBox.clock.sleep(1.0)                                       // one virtual second passes for the controller's clock too
        return .tick
    }
    func stop() {}
}

@Suite struct RingRecoveryEngineTests {
    @Test func sARingPrimeLeavesBothCursorsAtTheSameFrameWithAtLeastTFramesAndSetsT() throws {
        let ring = try #require(SARingCreate(32768))
        defer { SARingFree(ring) }
        let core = ProducerCore(ring: ring, frames: 512, channels: 2)
        for _ in 0..<10 { core.emit(startFrame: core.emitted) }
        for callbacks: UInt32 in [4, 1, 6] {
            #expect(SARingPrime(ring, callbacks))
            let s = snap(ring)
            #expect(s.reader.0.cursor == s.reader.1.cursor, "both readers at the same frame")
            #expect(s.reader.0.fill == Int64(callbacks) * 512 && s.reader.1.fill == Int64(callbacks) * 512)
            #expect(s.standingFill == callbacks * 512, "T is the depth that was primed")
            #expect(s.reader.0.calls == 0 && s.reader.0.underrunBlocks == 0 && s.needsReprime == 0 && s.reader.0.diverged == 0 && s.reader.1.diverged == 0)
        }
        // refused: more callbacks than were committed; nothing changes
        let before = snap(ring)
        #expect(!SARingPrime(ring, 11))
        let after = snap(ring)
        #expect(after.reader.0.cursor == before.reader.0.cursor && after.standingFill == before.standingFill)
        // the Swift mapping of the 6b-3a-1 fields: health built from it says what the controller needs
        let raw = try #require(RingSnapshotMapper.raw(ring: ring, outputNominalRate: nil, outputActualRate: nil, defaultOutputChanged: false))
        let h = try #require(RingHealth(raw: raw))
        #expect(h.standingFill == 6 * 512 && h.cursors[0] == h.cursors[1] && h.fills == [3072, 3072] && !h.needsReprime && h.diverged == [false, false])
    }

    @Test func theMapperReadsTheFrameCountTableTheFlagsAndTheJumpsOfTheRightReader() throws {
        let ring = try #require(SARingCreate(32768))
        defer { SARingFree(ring) }
        let core = ProducerCore(ring: ring, frames: 512, channels: 2)
        for _ in 0..<10 { core.emit(startFrame: core.emitted) }
        #expect(SARingPrime(ring, 4))
        let left = try #require(SARingGetReader(ring, 0)), right = try #require(SARingGetReader(ring, 1))
        func call(_ rd: OpaquePointer, _ frames: Int) {
            var buf = [Float](repeating: 0, count: frames); var silent = false; var ts = AudioTimeStamp()
            buf.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: raw.baseAddress))
                _ = SARingRender(rd, &silent, &ts, UInt32(frames), &list)
            }
        }
        call(left, 128); call(left, 128); call(left, 64)                // LEFT only: 128 x 2, 64 x 1
        call(right, 256)                                                // RIGHT only: 256 x 1
        let raw = try #require(RingSnapshotMapper.raw(ring: ring, outputNominalRate: nil, outputActualRate: nil, defaultOutputChanged: false))
        let rec = try #require(raw.recovery)
        #expect(rec.readers[0].name.hasPrefix("left") && rec.readers[1].name.hasPrefix("right"))
        #expect(rec.readers[0].frameCounts == [FrameCountEntry(frameCount: 128, calls: 2), FrameCountEntry(frameCount: 64, calls: 1)], "left: \(rec.readers[0].frameCounts)")
        #expect(rec.readers[1].frameCounts == [FrameCountEntry(frameCount: 256, calls: 1)], "right: \(rec.readers[1].frameCounts)")
        #expect(rec.readers[0].minFrameCount == 64 && rec.readers[0].maxFrameCount == 128 && rec.readers[1].minFrameCount == 256 && rec.readers[1].maxFrameCount == 256)
        #expect(rec.readers[0].callsInTable == raw.readers[0].calls && rec.readers[1].callsInTable == raw.readers[1].calls)
        // The calls above are deliberately uneven (left 320 frames, right 256, with no valid timestamp), which the ring's weak rule counts as a divergence it cannot repair:
        // the flags are the ring's own, and the mapper must carry them to the right reader without changing them.
        var c = SARingSnapshot(); #expect(SARingTakeSnapshot(ring, &c))
        #expect(rec.readers[0].diverged == (c.reader.0.diverged != 0) && rec.readers[1].diverged == (c.reader.1.diverged != 0))
        #expect(rec.readers[0].needsReprime == (c.reader.0.needsReprime != 0) && rec.readers[1].needsReprime == (c.reader.1.needsReprime != 0))
        #expect(rec.needsReprime == (c.needsReprime != 0) && rec.needsReprime == rec.readers.contains { $0.needsReprime })
        #expect(rec.needsReprime, "the uneven calls must have raised the ring's request (otherwise this test says nothing about the flags)")
        #expect(rec.standingFill == 2048)
        // a reader that never was called has no min / max
        #expect(RingSnapshotMapper.recovery(SARingReaderStats(), name: "x").minFrameCount == nil)
    }

    @Test func theEngineCanBeStoppedAndStartedAgainWithTheNodesStillAttachedAndTheGainStillZero() throws {
        let ring = try #require(SARingCreate(32768))
        defer { SARingFree(ring) }
        let core = ProducerCore(ring: ring, frames: 512, channels: 2)
        for _ in 0..<10 { core.emit(startFrame: core.emitted) }
        let engine = try RingProbeEngine(ring: ring, sampleRate: 48_000, mode: .manualOffline(maximumFrames: 512))
        engine.prepare()
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512))
        #expect(SARingPrime(ring, 4))
        try engine.start()
        #expect(engine.isRunning)
        _ = try engine.renderOffline(512, to: buffer)
        engine.pause()
        #expect(!engine.isRunning && engine.nodes.count == 2)
        engine.pause()                                                  // idempotent
        #expect(engine.configurationChanges.value == 0)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine.engine)
        #expect(engine.configurationChanges.value == 1, "the configuration-change observer survives a pause (only the final stop removes it)")
        let callsAtPause = snap(ring).reader.0.calls
        #expect(callsAtPause > 0)
        #expect(SARingPrime(ring, 4), "the readers are not running: re-prime")
        try engine.start()
        #expect(engine.isRunning && engine.startAttempts == 2 && engine.outputGain == 0)
        _ = try engine.renderOffline(512, to: buffer)
        let s = snap(ring)
        #expect(s.reader.0.calls > 0 && s.reader.1.calls > 0 && s.reader.0.calls < callsAtPause + 100, "counters were zeroed by the prime and count the new epoch")
        engine.stop()
        engine.detachSourceNodes()
    }

    @Test func aSimulatedDrainIsRepairedByTheRePrimeAndServingResumes() throws {
        // SIMULATED. The producer stalls for one virtual second at 10 s; the real ring and the real source nodes behind an offline engine do the rest.
        let sim = SimulatedRingBackend(pacing: .virtualTime(blocksPerSecond: 94), faults: .init(underrunAtSeconds: 10, underrunStallSeconds: 1))
        let config = RePrimeConfig(primeCallbacks: 6)                      // not the ring's default 4, so a re-prime that ignores the configured depth is visible
        let orchestrator = RingRecoveryOrchestrator(backend: sim, config: config, pollSeconds: 0.05)
        let env = RingProbeEnvironment(createdAt: "2026-11-18T00:00:00Z", macOSVersion: "test", hardwareModel: "test", ownPID: 1, requestedSeconds: 40)
        let clockBox = VirtualClockBox()
        let r = RingProbeRunner.run(backend: sim, ticker: VirtualSimTicker(sim: sim, limit: 100, clockBox: clockBox), environment: env, clock: clockBox.clock, recovery: orchestrator)
        #expect(r.isSimulated && r.outcome == "ok" && r.teardownClean && r.outputGain.readBackAtEnd == 0, "\(r.outcome) / \(r.stoppedBy)")
        let rec = try #require(r.recovery)
        #expect(rec.rePrimesPerformed == 1 && rec.gaveUp == nil && rec.start?.succeeded == true, "re-primes: \(rec.rePrimes.count), gave up: \(rec.gaveUp ?? "no")")
        let rp = try #require(rec.rePrimes.first)
        #expect(rp.reason == .underruns && rp.fillAtRestart == [3072, 3072] && rp.succeeded && rp.underrunsAfter == 0, "T = 6 x 512 = 3072: \(rp)")
        #expect(rp.underrunsBefore > 0 && (rp.engineStoppedSeconds ?? 0) > 0)
        // serving resumed: in the cumulative series the underruns stop growing after the re-prime and the served blocks keep growing by one block per call
        let afterIdx = try #require(r.samples.firstIndex { $0.elapsedSeconds >= 12 })
        let tail = Array(r.samples[afterIdx...])
        #expect(tail.count >= 20)
        for reader in 0..<2 {
            let u = tail.map { $0.readers[reader].underrunBlocks }
            #expect(Set(u).count == 1, "reader \(reader): no new underrun after the re-prime: \(Set(u))")
            let served = tail.map { $0.readers[reader].servedBlocks }
            #expect(zip(served, served.dropFirst()).allSatisfy { $1 - $0 == 94 }, "reader \(reader) is served every block of every second")
            // T = 3072 at the prime; the simulated backend renders ONE block when it starts the engine (so that both readers have been called), hence 3072 - 512 afterwards
            #expect(Set(tail.map { $0.readers[reader].fill }) == [2560], "equal rates: the fill stays put: \(Set(tail.map { $0.readers[reader].fill }))")
        }
        let cum = try #require(r.summary).readers.map(\.finalCounters)
        #expect(cum.allSatisfy { $0.calls == $0.servedBlocks + $0.underrunBlocks }, "calls = served + underrun, summed over both epochs")
        let md = r.markdown()
        #expect(md.contains("SIMULATED SOURCE") && md.contains("## 8. Recovery"))
        #expect(rec.standingFillAtEnd == 3072)
        let ev = sim.events
        let p = try #require(ev.firstIndex(of: "engine paused"))
        #expect(p > 0 && ev[p - 1] == "render pump joined (pause)", "the render pump is joined before the engine is stopped for a re-prime: \(ev)")
        #expect(ev.last == "ring freed")
    }

    @Test func aPlainSimulatedRunIsUnchangedByTheRecoveryCode() throws {
        let sim = SimulatedRingBackend(pacing: .virtualTime(blocksPerSecond: 94), faults: .init(underrunAtSeconds: 10, underrunStallSeconds: 1))
        let env = RingProbeEnvironment(createdAt: "2026-11-18T00:00:00Z", macOSVersion: "test", hardwareModel: "test", ownPID: 1, requestedSeconds: 30)
        let clockBox = VirtualClockBox()
        let r = RingProbeRunner.run(backend: sim, ticker: VirtualSimTicker(sim: sim, limit: 100, clockBox: clockBox), environment: env, clock: clockBox.clock)
        #expect(r.recovery == nil && !sim.events.contains("engine paused"))
        #expect(r.samples.last?.readers[0].fill ?? 0 < 0, "without recovery the readers stay starved, as before (count-only plain mode)")
    }

    @Test func aRealTimeSimulatedRecoveryRunKeepsItsInvariantsWhateverTheTiming() throws {
        // SIMULATED, threaded (our own producer and render threads, an offline engine, no device). The verdict is structural, never a time: whether a re-prime happens depends
        // on how the threads were scheduled, so none is required; IF one happens it must be complete and the run must end clean.
        let sim = SimulatedRingBackend(pacing: .realTime, faults: .init(underrunAtSeconds: 1.0, underrunStallSeconds: 0.5))
        let ticker = DispatchRingTicker()
        sim.onConfigurationChange = { ticker.interrupt() }
        let suspending = SuspendingClock(); let origin = suspending.now
        let clock = TapProbeClock(now: { let d = origin.duration(to: suspending.now); return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 },
                                  sleep: { Thread.sleep(forTimeInterval: $0) })
        let config = RePrimeConfig(minIntervalSeconds: 1, maxRePrimesPerWindow: 6, windowSeconds: 60)
        let orchestrator = RingRecoveryOrchestrator(backend: sim, config: config)
        let env = RingProbeEnvironment(createdAt: "2026-11-18T00:00:00Z", macOSVersion: "test", hardwareModel: "test", ownPID: 1, requestedSeconds: 4)
        let r = RingProbeRunner.run(backend: sim, ticker: ticker, environment: env, clock: clock, recovery: orchestrator)
        #expect(r.isSimulated && r.teardownClean && r.ring?.freed == true && r.outputGain.readBackAtEnd == 0, "\(r.outcome) / \(r.stoppedBy)")
        let rec = try #require(r.recovery)
        if rec.gaveUp == nil {
            #expect(rec.rePrimes.allSatisfy { $0.succeeded && $0.fillAtRestart != nil && $0.restartedAtSeconds != nil && ($0.engineStoppedSeconds ?? -1) >= 0 })
            #expect(rec.rePrimesPerformed == rec.rePrimes.count)
            #expect((rec.rePrimes.isEmpty) == !sim.events.contains("engine paused"), "a pause happened exactly when a re-prime was recorded")
        }
    }
}
