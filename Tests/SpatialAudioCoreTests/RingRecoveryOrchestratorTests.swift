import Testing
import Foundation
@testable import SpatialAudioCore

// Step 6b-3a-2: the orchestrator (controller + backend + clock) against a MODEL of the ring (plain arithmetic, no C ring, no engine) behind the recording FakeRingBackend, with a
// virtual clock that moves only when the code under test sleeps. No wall clock, no fixed sleep: every verdict is about numbers and call order. Everything the model produces is
// SIMULATED. (The real C ring and a real AVAudioEngine are exercised in Tests/SpatialAudioEngineTests/RingRecoveryEngineTests.swift.)

/// A model of the ring that follows the C ring's rules: a reader advances by exactly the frames asked on EVERY call, served or not; an underrun is "cursor + frames > w";
/// SARingPrime re-bases both cursors to w - depth, zeroes the epoch's counters and sets T; it refuses with too few commits.
final class RingModel: @unchecked Sendable {
    let frames: Int64 = 512
    var w: Int64 = 0, commits: UInt64 = 0
    var cursor: [Int64] = [0, 0]
    var calls: [UInt64] = [0, 0], served: [UInt64] = [0, 0], underruns: [UInt64] = [0, 0]
    var tableCalls: [UInt64] = [0, 0]
    var needsReprime = false
    var diverged = [false, false]
    var divergenceJumps: [UInt64] = [0, 0], refusedJumps: [UInt64] = [0, 0]
    var standingFill: Int64 = 2048
    var running = false
    var producerStalled = false
    /// Model of a render block that was already running when the engine was told to stop: this many more calls arrive, one per poll, after the pause.
    var lateRenders = 0
    var producesOnSleep = false
    var refusePrimes = 0
    var second = 0
    // independent totals (never zeroed by a prime): what the cumulative counters must equal
    var totalCalls: [UInt64] = [0, 0], totalUnderruns: [UInt64] = [0, 0], totalServed: [UInt64] = [0, 0]
    // what the tests look at
    var primeCalls = 0, primeSuccesses = 0, primeWhileRunning = 0, lateRendersPendingAtPrime = -1, cursorsEqualAfterPrime = true

    func produce(blocks: Int) {
        guard !producerStalled else { return }
        for _ in 0..<blocks { w += frames; commits += 1 }
    }

    func render(blocks: Int) { for _ in 0..<blocks { for r in 0..<2 { call(r) } } }

    private func call(_ r: Int) {
        calls[r] += 1; totalCalls[r] += 1; tableCalls[r] += 1
        if cursor[r] + frames <= w { served[r] += 1; totalServed[r] += 1 } else { underruns[r] += 1; totalUnderruns[r] += 1 }
        cursor[r] += frames
    }

    func onSleep() {
        if lateRenders > 0 { lateRenders -= 1; for r in 0..<2 { call(r) } } else if running { render(blocks: 1) }
        if producesOnSleep { produce(blocks: 1) }
    }

    func prime(_ callbacks: UInt32) -> Bool {
        primeCalls += 1
        if running { primeWhileRunning += 1 }
        lateRendersPendingAtPrime = lateRenders
        if refusePrimes > 0 { refusePrimes -= 1; return false }
        let depth = Int64(callbacks) * frames
        guard commits >= UInt64(callbacks), depth > 0, depth <= w else { return false }
        cursor = [w - depth, w - depth]
        calls = [0, 0]; served = [0, 0]; underruns = [0, 0]; tableCalls = [0, 0]
        divergenceJumps = [0, 0]; refusedJumps = [0, 0]; needsReprime = false; diverged = [false, false]
        standingFill = depth
        primeSuccesses += 1
        cursorsEqualAfterPrime = cursor[0] == cursor[1]
        return true
    }

    func raw() -> RingProbeRawSample {
        var p = RingProducerCounters(); p.w = w; p.commits = commits; p.capacity = 32768; p.maxCommit = 16384; p.lastCommitFrames = UInt32(frames)
        let readers: [RingReaderCounters] = (0..<2).map { r in
            var c = RingReaderCounters()
            c.calls = calls[r]; c.framesRequested = calls[r] * UInt64(frames); c.servedBlocks = served[r]; c.underrunBlocks = underruns[r]
            c.cursor = cursor[r]; c.fill = w - cursor[r]
            return c
        }
        let rec = RingRecoverySnapshot(standingFill: UInt32(standingFill), needsReprime: needsReprime, readers: (0..<2).map { r in
            RingReaderRecovery(name: r == 0 ? "left (reader 0)" : "right (reader 1)",
                               frameCounts: calls[r] > 0 ? [FrameCountEntry(frameCount: UInt32(frames), calls: tableCalls[r])] : [],
                               minFrameCount: calls[r] > 0 ? UInt32(frames) : nil, maxFrameCount: calls[r] > 0 ? UInt32(frames) : nil,
                               divergenceJumps: divergenceJumps[r], refusedJumps: refusedJumps[r], diverged: diverged[r], needsReprime: needsReprime)
        })
        return RingProbeRawSample(hostTicks: UInt64(1_000_000_000 + second * 1_000_000_000), continuousSeconds: Double(second), producer: p, readers: readers,
                                  outputNominalRate: 48_000, outputActualRate: 48_000, recovery: rec)
    }
}

/// A virtual clock: `now` moves only when something sleeps (and when the test says so); each sleep also gives the model its one block of "time passing".
final class ModelClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = 0.0
    let model: RingModel
    var onSleep: (() -> Void)?
    init(model: RingModel) { self.model = model }
    var now: Double { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ d: Double) { lock.lock(); t += d; lock.unlock() }
    var clock: TapProbeClock { TapProbeClock(now: { [self] in now }, sleep: { [self] d in advance(d); model.onSleep(); onSleep?() }) }
}

/// For tests that need a trigger right after the start: the start counts as the last restart, so the default 5 s minimum interval would (rightly) suppress it.
private let immediate = RePrimeConfig(minIntervalSeconds: 0, maxRePrimesPerWindow: 9, windowSeconds: 60)

private struct Rig {
    let model = RingModel()
    let log = EventLog()
    let backend: FakeRingBackend
    let clk: ModelClock
    let orchestrator: RingRecoveryOrchestrator
    var pausedAt: [Double] { box.pausedAt }
    var startedAt: [Double] { box.startedAt }
    let box = Times()

    final class Times: @unchecked Sendable { var pausedAt: [Double] = []; var startedAt: [Double] = [] }

    init(config: RePrimeConfig = RePrimeConfig(minIntervalSeconds: 5, maxRePrimesPerWindow: 3, windowSeconds: 60), blocksAtStart: Int = 8) {
        let model = self.model
        backend = FakeRingBackend(log: log)
        clk = ModelClock(model: model)
        let clk = self.clk, box = self.box
        backend.snapshotProvider = { model.raw() }
        backend.primeProvider = { model.prime($0) }
        backend.onPause = { model.running = false; box.pausedAt.append(clk.now) }
        backend.onStartEngine = { model.running = true; box.startedAt.append(clk.now) }
        orchestrator = RingRecoveryOrchestrator(backend: backend, config: config, pollSeconds: 0.05)
        model.produce(blocks: blocksAtStart)
    }

    /// One simulated second: the producer commits 94 callbacks, the engine renders 94 blocks (if it runs), the sample is taken, the timer tick reaches the orchestrator.
    mutating func second(produce: Bool = true) {
        if produce { model.produce(blocks: 94) }
        if model.running { model.render(blocks: 94) }
        model.second += 1
        clk.advance(1.0)
        orchestrator.tick(raw: model.raw(), clock: clk.clock)
    }
}

@Suite struct RingRecoveryOrchestratorTests {
    @Test func theStartGoesThroughThePrimeAndStartStatesAndIsNotCountedAsARePrime() {
        var rig = Rig()
        let out = rig.orchestrator.performStart(clock: rig.clk.clock)
        #expect(out.primed && out.started && out.primeAttempts == 1 && out.startDetail == nil)
        #expect(rig.model.primeSuccesses == 1 && rig.model.primeWhileRunning == 0 && rig.model.running)
        #expect(!rig.log.all.contains("engine.pause"), "the start has no stop: the engine was not running")
        #expect(rig.orchestrator.rePrimesPerformed == 0)
        rig.second()
        #expect(rig.orchestrator.rePrimesPerformed == 0)
    }

    @Test func aDrainTriggersAStopThenAPrimeThenARestartAndServingResumes() throws {
        var rig = Rig()
        _ = rig.orchestrator.performStart(clock: rig.clk.clock)
        for s in 0..<30 {
            rig.model.producerStalled = (s == 10)                                  // one stalled second: all 94 blocks of that second underrun
            rig.second()
        }
        let o = rig.orchestrator
        #expect(o.rePrimesPerformed == 1 && o.gaveUp == nil)
        let m = rig.model
        #expect(m.primeWhileRunning == 0, "SARingPrime is never called while the engine reports running")
        #expect(m.cursorsEqualAfterPrime)
        let order = rig.log.all
        let pause = try #require(order.lastIndex(of: "engine.pause")), prime = try #require(order.lastIndex(of: "prime")), start = try #require(order.lastIndex(of: "engine.start"))
        #expect(pause < prime && prime < start, "stop, then prime, then start: \(order)")
        #expect(order.filter { $0 == "engine.start" }.count == 2 && order.filter { $0 == "engine.pause" }.count == 1, "the start and one restart; one stop")
        // serving resumed: after the restart the last 19 seconds were all served, no underruns in the final epoch
        #expect(m.underruns == [0, 0] && m.served[0] >= 94 * 19 && m.served[1] >= 94 * 19, "served \(m.served), underruns \(m.underruns)")
        // the record: numbers from the model and from the clock
        let r = try #require(o.records.first)
        // the stalled second: the 4 blocks (T = 2048 frames) that stood in the ring were served, the other 94 - 4 = 90 underran
        #expect(r.reason == .underruns && r.underrunsBefore == 90, "underruns before: \(r.underrunsBefore)")
        #expect(r.fillAtRestart == [2048, 2048] && r.underrunsAfter == 0 && r.succeeded, "\(r)")
        // the report's cumulative counters equal the model's independent totals (the prime zeroed the epoch counters; nothing was lost)
        let last = rig.model.raw()
        let cum = o.cumulative(last)
        #expect(cum.readers.map(\.calls) == m.totalCalls && cum.readers.map(\.underrunBlocks) == m.totalUnderruns && cum.readers.map(\.servedBlocks) == m.totalServed,
                "cumulative \(cum.readers.map(\.calls)) vs model \(m.totalCalls)")
        let report = o.finish(raw: last)
        #expect(report.rePrimesPerformed == 1 && report.rePrimes.count == 1 && report.start?.succeeded == true && report.gaveUp == nil)
        #expect(report.readers.map(\.callsInTable) == m.totalCalls, "the merged frame-count table accounts for every call of every epoch")
        #expect(report.readers.allSatisfy { $0.frameCounts == [FrameCountEntry(frameCount: 512, calls: $0.callsInTable)] })
        #expect(report.standingFillAtEnd == 2048)
    }

    @Test func theEngineStoppedTimeIsMeasuredFromTheStopRequestToTheRestart() throws {
        var rig = Rig(config: immediate)
        _ = rig.orchestrator.performStart(clock: rig.clk.clock)
        rig.second(); rig.model.producerStalled = true; rig.model.render(blocks: 94); rig.model.producerStalled = false
        rig.model.second += 1; rig.clk.advance(1)
        let triggerAt = rig.clk.now
        rig.orchestrator.tick(raw: rig.model.raw(), clock: rig.clk.clock)
        let r = try #require(rig.orchestrator.records.first)
        let restartedAt = try #require(rig.startedAt.last)
        #expect(r.stopIssuedAtSeconds == triggerAt && r.restartedAtSeconds == restartedAt)
        #expect(abs((r.engineStoppedSeconds ?? .nan) - (restartedAt - triggerAt)) < 1e-9 && (r.engineStoppedSeconds ?? 0) > 0, "stopped for \(r.engineStoppedSeconds ?? -1) s on the virtual clock")
        #expect(rig.pausedAt.last == triggerAt, "the stop was issued at the trigger")
    }

    @Test func aRenderBlockThatWasAlreadyRunningIsWaitedForBeforeThePrime() {
        var rig = Rig(config: immediate)
        _ = rig.orchestrator.performStart(clock: rig.clk.clock)
        rig.model.lateRenders = 2
        rig.model.needsReprime = true
        rig.second()
        #expect(rig.orchestrator.rePrimesPerformed == 1)
        #expect(rig.model.lateRendersPendingAtPrime == 0, "the prime came only after the readers' call counts had stopped changing")
    }

    @Test func aRefusedPrimeIsRetriedAndTheEngineIsStartedOnlyAfterOneSucceeded() {
        var rig = Rig(config: immediate)
        _ = rig.orchestrator.performStart(clock: rig.clk.clock)
        rig.model.needsReprime = true
        rig.model.refusePrimes = 3
        rig.second()
        let after = Array(rig.log.all.drop { $0 != "engine.pause" })
        #expect(after == ["engine.pause", "prime", "prime", "prime", "prime", "engine.start"], "three refusals, the fourth succeeds, and only then the engine starts: \(after)")
        #expect(rig.orchestrator.records.first?.primeAttempts == 4 && rig.orchestrator.rePrimesPerformed == 1)
        let cum = rig.orchestrator.cumulative(rig.model.raw())
        #expect(cum.readers.map(\.calls) == rig.model.totalCalls, "three refused primes must not add the epoch to the sums three times: \(cum.readers.map(\.calls)) vs \(rig.model.totalCalls)")
    }

    @Test func aPrimeThatNeverSucceedsGivesUpAndLeavesTheEngineStopped() {
        var rig = Rig(config: immediate)
        _ = rig.orchestrator.performStart(clock: rig.clk.clock)
        rig.model.needsReprime = true
        rig.model.refusePrimes = 1_000_000
        rig.second()
        #expect(rig.orchestrator.gaveUp?.contains("kept refusing") == true && rig.orchestrator.rePrimesPerformed == 0)
        #expect(!rig.model.running && rig.backend.startEngineCalls == 1, "the engine was not restarted")
    }

    @Test func aTickThatArrivesWhileARePrimeIsBeingDrivenIsRefusedNotNested() {
        var rig = Rig(config: immediate)
        _ = rig.orchestrator.performStart(clock: rig.clk.clock)
        rig.model.needsReprime = true
        let o = rig.orchestrator, model = rig.model, clk = rig.clk
        // a timer tick lands while the controller waits for the engine to go quiet: it carries a trigger-worthy sample too
        rig.clk.onSleep = { [unowned clk] in o.tick(raw: model.raw(), clock: clk.clock) }
        final class Counter: @unchecked Sendable { var n = 0 }
        let snapshotsTaken = Counter()
        let inner = try! #require(rig.backend.snapshotProvider)
        rig.backend.snapshotProvider = { snapshotsTaken.n += 1; return inner() }
        rig.second()
        // The ring snapshots the orchestrator itself took for this one re-prime: 4 polls (the first sets the reference, three are unchanged), the snapshot before and the one after the
        // prime, and one after the restart = 7. A nested drive adds a redundant snapshot for every frame it unwinds.
        #expect(snapshotsTaken.n == 7, "snapshots taken: \(snapshotsTaken.n)")
        #expect(o.reentrantTicksRefused >= 1, "the nested ticks were refused")
        #expect(model.primeSuccesses == 2 && rig.backend.startEngineCalls == 2, "the start and exactly one re-prime: primes \(model.primeSuccesses), starts \(rig.backend.startEngineCalls)")
        #expect(o.records.count == 1 && o.rePrimesPerformed == 1)
        // The nested ticks must not have driven anything: the stop-to-restart time is exactly the four 0.05 s polls of the un-nested sequence (one to set the reference and three
        // unchanged observations), not the polls of a second, nested drive. (Without the guard the same state machine happens to reach the same end state; the clock shows the difference.)
        #expect(abs((o.records.first?.engineStoppedSeconds ?? .nan) - 0.2) < 1e-9, "engine stopped for \(o.records.first?.engineStoppedSeconds ?? -1) s")
        #expect(rig.pausedAt.count == 1 && rig.startedAt.count == 2, "one stop request, the start and one restart: \(rig.pausedAt.count) / \(rig.startedAt.count)")
    }

    @Test func theEngineIsNeverRestartedUnlessTheGainReadsBackAsExactlyZero() {
        for gain in [0.5, 1.0, 0.0001, -0.0001, Double.nan, nil] as [Double?] {
            var rig = Rig(config: immediate)
            _ = rig.orchestrator.performStart(clock: rig.clk.clock)
            rig.backend.gainAfterStart = gain
            rig.model.needsReprime = true
            rig.second()
            #expect(rig.orchestrator.gaveUp?.contains("gain") == true, "gain \(String(describing: gain))")
            #expect(rig.backend.startEngineCalls == 1 && !rig.model.running, "no restart at gain \(String(describing: gain))")
            rig.backend.gainAfterStart = 0                                // the gain reads 0 again: a give-up is final, nothing restarts later
            rig.second(); rig.second()
            #expect(rig.backend.startEngineCalls == 1 && !rig.model.running, "still no restart after the gain read 0 again (gain \(String(describing: gain)))")
        }
    }

    @Test func anEngineThatStillReportsRunningAfterTheStopRequestIsNeverPrimed() {
        var rig = Rig(config: immediate)
        _ = rig.orchestrator.performStart(clock: rig.clk.clock)
        let backend = rig.backend
        rig.backend.onPause = { backend.engineRunning = true }          // the stop request has no effect
        rig.model.needsReprime = true
        let primesBefore = rig.model.primeCalls
        rig.second()
        #expect(rig.orchestrator.gaveUp?.contains("still reported running") == true)
        #expect(rig.model.primeCalls == primesBefore && rig.backend.startEngineCalls == 1, "no prime and no start while the engine reports running")
    }

    @Test func aControllerThatCannotFinishBecauseTheClockIsFrozenIsEndedByTheStepCapNotByHanging() {
        var rig = Rig(config: immediate)
        _ = rig.orchestrator.performStart(clock: rig.clk.clock)
        let backend = rig.backend
        rig.backend.onPause = { backend.engineRunning = true }
        rig.model.needsReprime = true
        let frozen = TapProbeClock(now: { 1_000 }, sleep: { _ in })       // time never advances: no timeout of the controller can fire
        rig.orchestrator.tick(raw: rig.model.raw(), clock: frozen)
        #expect(rig.orchestrator.gaveUp?.contains("did not finish within") == true, "\(rig.orchestrator.gaveUp ?? "nil")")
    }

    @Test func aRestartThatFailsIsAFailureNotASuccessAndEndsTheRecovery() {
        var rig = Rig(config: immediate)
        _ = rig.orchestrator.performStart(clock: rig.clk.clock)
        rig.backend.failStartEngine = true
        rig.model.needsReprime = true
        rig.second()
        #expect(rig.orchestrator.rePrimesPerformed == 0 && rig.orchestrator.gaveUp != nil && rig.orchestrator.records.first?.succeeded == false)
        rig.second()
        #expect(rig.orchestrator.records.count == 1, "nothing is triggered after a give-up")
        let report = rig.orchestrator.finish(raw: rig.model.raw())
        #expect(report.rePrimes.count == 1 && report.rePrimesPerformed == 0 && report.gaveUp != nil, "a failed re-prime is a record but not a performed re-prime")
    }

    @Test func aProducerThatNeverDeliversCannotTurnIntoAStormOfRePrimes() {
        let cfg = RePrimeConfig(minIntervalSeconds: 5, maxRePrimesPerWindow: 3, windowSeconds: 60)
        var rig = Rig(config: cfg)
        _ = rig.orchestrator.performStart(clock: rig.clk.clock)
        rig.model.producerStalled = true                                            // dead from now on: no re-prime can fix this
        for _ in 0..<200 { rig.second() }
        let restarts = rig.orchestrator.records.compactMap(\.restartedAtSeconds)
        #expect(!restarts.isEmpty && restarts.count <= 12, "200 s, window 60 s, at most 3 per window: \(restarts.count) re-primes")
        for (i, r) in restarts.enumerated() {
            #expect(restarts.filter { $0 >= r && $0 < r + 60 }.count <= 3, "more than 3 re-primes within 60 s of the one at \(r)")
            if i > 0 { #expect(r - restarts[i - 1] >= 5, "re-primes closer than the minimum interval") }
        }
        #expect(rig.orchestrator.gaveUp == nil)
        let report = rig.orchestrator.finish(raw: rig.model.raw())
        #expect(report.suppressedByStormLimit > 0 && report.suppressedByMinimumInterval > 0, "the suppressions are counted: \(report.suppressedByStormLimit) / \(report.suppressedByMinimumInterval)")
        #expect(report.rePrimesPerformed == report.rePrimes.count && report.rePrimes.allSatisfy(\.succeeded))
    }

    @Test func theCountersStayCumulativeAndNeverGoBackwardsAcrossRePrimes() {
        var rig = Rig()
        _ = rig.orchestrator.performStart(clock: rig.clk.clock)
        var previous: [UInt64] = [0, 0], previousUnderruns: [UInt64] = [0, 0]
        for s in 0..<40 {
            rig.model.producerStalled = (s == 8 || s == 25)
            rig.second()
            let cum = rig.orchestrator.cumulative(rig.model.raw())
            #expect(zip(cum.readers.map(\.calls), previous).allSatisfy { $0 >= $1 }, "calls went backwards at second \(s)")
            #expect(zip(cum.readers.map(\.underrunBlocks), previousUnderruns).allSatisfy { $0 >= $1 }, "underruns went backwards at second \(s)")
            previous = cum.readers.map(\.calls); previousUnderruns = cum.readers.map(\.underrunBlocks)
            #expect(cum.readers.map(\.cursor) == rig.model.cursor && cum.readers.map(\.fill) == (0..<2).map { rig.model.w - rig.model.cursor[$0] }, "cursor and fill are gauges, not sums")
        }
        #expect(rig.orchestrator.rePrimesPerformed == 2)
        #expect(previous == rig.model.totalCalls)
    }

    @Test func theRingHealthFoldsRefusedJumpsIntoDivergenceAndNeverGuessesWithoutARecoverySnapshot() {
        let m = RingModel(); m.produce(blocks: 8)
        m.divergenceJumps = [5, 0]; m.refusedJumps = [3, 0]; m.diverged = [false, true]; m.needsReprime = true
        let h = RingHealth(raw: m.raw())
        #expect(h?.divergenceEvents == [8, 0] && h?.diverged == [false, true] && h?.needsReprime == true && h?.standingFill == 2048)
        var bare = m.raw(); bare.recovery = nil
        let b = RingHealth(raw: bare)
        #expect(b?.standingFill == 0 && b?.needsReprime == false && b?.diverged == [], "no snapshot: nothing is assumed")
        var one = m.raw(); one.readers.removeLast()
        #expect(RingHealth(raw: one) == nil)
    }
}

@Suite struct RingRecoveryRunnerTests {
    /// Advances the model by one virtual second per wait and reports a tick; after `limit` waits it reports a signal.
    final class ModelTicker: RingProbeTicker {
        let rig: ModelClock; let model: RingModel; let limit: Int; var waits = 0
        var beforeSecond: ((Int) -> Void)?
        init(clk: ModelClock, limit: Int) { rig = clk; model = clk.model; self.limit = limit }
        func start(periodSeconds: Double) {}
        func wait() -> RingProbeWake {
            waits += 1
            if waits > limit { return .signal }
            beforeSecond?(waits)
            model.produce(blocks: 94); if model.running { model.render(blocks: 94) }
            model.second += 1
            rig.advance(1.0)
            return .tick
        }
        func stop() {}
    }

    private func environment(_ seconds: Double) -> RingProbeEnvironment {
        RingProbeEnvironment(createdAt: "2026-11-18T00:00:00Z", macOSVersion: "test", hardwareModel: "test", ownPID: 1, requestedSeconds: seconds)
    }

    private func recoveryRun(seconds: Double = 30, stallAt: Int? = 10) -> (RingProbeReport, RingModel, FakeRingBackend) {
        let rig = Rig()
        let ticker = ModelTicker(clk: rig.clk, limit: 200)
        ticker.beforeSecond = { [model = rig.model] n in model.producerStalled = (n == stallAt) }
        let report = RingProbeRunner.run(backend: rig.backend, ticker: ticker, environment: environment(seconds), clock: rig.clk.clock, recovery: rig.orchestrator)
        return (report, rig.model, rig.backend)
    }

    @Test func aRecoveryRunReportsTheRePrimeCountThePerRePrimeNumbersAndTheCumulativeCounters() throws {
        let (r, m, b) = recoveryRun()
        #expect(r.outcome == "ok" && r.stoppedBy == "timeout" && r.teardownClean, "outcome \(r.outcome), stopped by \(r.stoppedBy)")
        let rec = try #require(r.recovery)
        #expect(rec.rePrimesPerformed == 1 && rec.rePrimes.count == 1 && rec.start?.succeeded == true && rec.gaveUp == nil)
        #expect(rec.rePrimes[0].fillAtRestart == [2048, 2048] && (rec.rePrimes[0].engineStoppedSeconds ?? 0) > 0 && rec.rePrimes[0].underrunsBefore > 0)
        #expect(r.kind.contains("recovery") && r.notes.contains { $0.contains("RECOVERY MODE") && $0.contains("1 time") })
        let md = r.markdown()
        #expect(md.contains("## 8. Recovery") && md.contains("Re-primes performed: 1") && md.contains("UNTUNED") && md.contains("frameCounts asked for"))
        #expect(b.startEngineCalls == 2 && m.primeWhileRunning == 0)
        let s = try #require(r.summary)
        #expect(s.readers.map(\.finalCounters.calls) == m.totalCalls, "the series is cumulative across the re-prime")
        #expect(r.samples.map(\.elapsedSeconds) == r.samples.map(\.elapsedSeconds).sorted())
    }

    @Test func theRecoverySectionRoundTripsThroughJSONAndHoldsNoNamesOrPaths() throws {
        let (r, _, _) = recoveryRun()
        let data = try r.jsonData()
        #expect(try RingProbeReport.decode(data) == r, "lossless, including the per-re-prime records")
        func keys(_ x: Any) -> [String] {
            if let d = x as? [String: Any] { return Array(d.keys) + d.values.flatMap(keys) }
            if let a = x as? [Any] { return a.flatMap(keys) }
            return []
        }
        let all = Set(keys(try JSONSerialization.jsonObject(with: data)))
        #expect(all.isDisjoint(with: ["uid", "UID", "deviceName", "deviceUID", "productName", "path", "directory", "manufacturer"]))
        #expect(all.isSuperset(of: ["rePrimes", "rePrimesPerformed", "frameCounts", "standingFillAtEnd", "suppressedByStormLimit"]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("SENTINEL-UID") && !text.contains("/Users/"))
    }

    @Test func aPlainRunHasNoRecoverySectionAndIsLabelledAsBefore() {
        let b = FakeRingBackend(log: EventLog())
        let ticker = FakeTicker(log: b.log, script: Array(repeating: .tick, count: 10))
        let r = RingProbeRunner.run(backend: b, ticker: ticker, environment: environment(5), clock: FakeClockBox().clock)
        #expect(r.recovery == nil && r.kind == "ring probe (Step 6b-2)" && !r.markdown().contains("## 8. Recovery"))
    }

    @Test func aReportWrittenBeforeTheRecoveryModeExistedStillDecodes() throws {
        let b = FakeRingBackend(log: EventLog())
        let ticker = FakeTicker(log: b.log, script: Array(repeating: .tick, count: 10))
        let r = RingProbeRunner.run(backend: b, ticker: ticker, environment: environment(5), clock: FakeClockBox().clock)
        var obj = try #require(JSONSerialization.jsonObject(with: try r.jsonData()) as? [String: Any])
        obj.removeValue(forKey: "recovery")
        let old = try JSONSerialization.data(withJSONObject: obj)
        #expect(try RingProbeReport.decode(old).recovery == nil)
    }

    @Test func aRecoveryRunRefusesANonZeroGainBeforeStartingAnything() {
        let rig = Rig()
        rig.backend.gainBeforeStart = 0.5
        let ticker = ModelTicker(clk: rig.clk, limit: 50)
        let r = RingProbeRunner.run(backend: rig.backend, ticker: ticker, environment: environment(10), clock: rig.clk.clock, recovery: rig.orchestrator)
        #expect(r.outcome.hasPrefix("refused") && rig.backend.startEngineCalls == 0 && rig.model.primeCalls == 0, "\(r.outcome)")
    }

    @Test func aGiveUpEndsTheRunAndTheReportSaysWhy() throws {
        let rig = Rig()
        let ticker = ModelTicker(clk: rig.clk, limit: 200)
        ticker.beforeSecond = { [model = rig.model, backend = rig.backend] n in if n == 5 { model.needsReprime = true; backend.gainAfterStart = 0.25 } }
        let r = RingProbeRunner.run(backend: rig.backend, ticker: ticker, environment: environment(60), clock: rig.clk.clock, recovery: rig.orchestrator)
        #expect(r.outcome != "ok" && r.stoppedBy == "recovery gave up", "\(r.outcome) / \(r.stoppedBy)")
        let rec = try #require(r.recovery)
        #expect(rec.gaveUp?.contains("gain") == true && rec.rePrimesPerformed == 0)
        #expect(r.teardownClean)
    }
}

@Suite struct RingRecoveryArgumentTests {
    private func parse(_ a: String...) -> RingProbeArguments.Parsed { RingProbeArguments.parse(["app"] + a) }

    @Test func theTwoRecoveryModesParse() {
        guard case .request(let real) = parse("--ring-probe-recovery", "600") else { Issue.record("not a request"); return }
        #expect(real.recovery && !real.simulate && real.seconds == 600)
        guard case .request(let sim) = parse("--ring-probe-recovery-simulate=30", "--ring-sim-underrun=5,1") else { Issue.record("not a request"); return }
        #expect(sim.recovery && sim.simulate && sim.seconds == 30 && sim.simulatedUnderrunAtSeconds == 5)
        guard case .request(let plain) = parse("--ring-probe", "60") else { Issue.record("not a request"); return }
        #expect(!plain.recovery, "the plain modes are not recovery modes")
        #expect(parse("--ring-probe-recovery=60") == parse("--ring-probe-recovery", "60"))
    }

    @Test func badSecondsAreRefusedInTheRecoveryModeToo() {
        for s in ["0", "-1", "601", "nan", "inf", "abc"] {
            guard case .invalid = parse("--ring-probe-recovery", s) else { Issue.record("accepted \(s)"); continue }
        }
        guard case .invalid = parse("--ring-probe-recovery") else { Issue.record("accepted no seconds"); return }
    }

    @Test func theRecoveryModeHasNoGainOptionAndNamingOneIsRefused() {
        for g in ["--gain=1", "--output-gain=0.5", "--volume=1", "--recovery-gain=1", "--Output-Volume"] {
            guard case .invalid(let why) = parse("--ring-probe-recovery", "10", g) else { Issue.record("accepted \(g)"); continue }
            #expect(why.contains("no gain or volume option"), "\(g): \(why)")
            guard case .invalid = parse("--ring-probe-recovery-simulate", "10", g) else { Issue.record("accepted \(g) in simulate"); continue }
        }
    }

    @Test func twoModeFlagsAtOnceAndSimulatedOptionsOnARealRunAreRefused() {
        for args in [["--ring-probe", "10", "--ring-probe-recovery", "10"], ["--ring-probe-recovery", "10", "--ring-probe-recovery-simulate", "10"],
                     ["--ring-probe-recovery", "10", "--ring-sim-ppm=5"], ["--ring-probe-recovery", "10", "--ring-sim-underrun=1,1"]] {
            guard case .invalid = RingProbeArguments.parse(["app"] + args) else { Issue.record("accepted: \(args)"); continue }
        }
    }

    @Test func theFileStemSaysRecoveryAndSimulated() {
        let d = Date(timeIntervalSince1970: 0)
        let utc = TimeZone(identifier: "UTC")!
        #expect(RingProbeReport.fileStem(date: d, timeZone: utc, simulated: false) == "ringprobe-19700101-000000")
        #expect(RingProbeReport.fileStem(date: d, timeZone: utc, simulated: false, recovery: true) == "ringrecovery-19700101-000000")
        #expect(RingProbeReport.fileStem(date: d, timeZone: utc, simulated: true, recovery: true) == "ringrecovery-19700101-000000-SIMULATED")
    }
}

@Suite struct RingRecoveryReportTests {
    @Test func mergingEpochsSumsTablesAndCountsAndWidensRangesAndOrsTheFlags() {
        var a = RingReaderRecovery(name: "left", frameCounts: [FrameCountEntry(frameCount: 512, calls: 10), FrameCountEntry(frameCount: 480, calls: 2)], frameCountOverflowCalls: 1,
                                   minFrameCount: 480, maxFrameCount: 512, overrunJumps: 1, overrunJumpFrames: 100, divergenceJumps: 2, divergenceJumpFrames: 50,
                                   refusedJumps: 0, largestJumpFrames: 80, diverged: false, needsReprime: false)
        let b = RingReaderRecovery(name: "x", frameCounts: [FrameCountEntry(frameCount: 480, calls: 3), FrameCountEntry(frameCount: 1024, calls: 4)], frameCountOverflowCalls: 2,
                                   minFrameCount: 470, maxFrameCount: 1024, overrunJumps: 2, overrunJumpFrames: 7, divergenceJumps: 0, divergenceJumpFrames: 0,
                                   refusedJumps: 3, largestJumpFrames: 200, diverged: true, needsReprime: true)
        a.merge(b)
        #expect(a.name == "left" && a.frameCounts == [FrameCountEntry(frameCount: 512, calls: 10), FrameCountEntry(frameCount: 480, calls: 5), FrameCountEntry(frameCount: 1024, calls: 4)])
        #expect(a.frameCountOverflowCalls == 3 && a.minFrameCount == 470 && a.maxFrameCount == 1024 && a.callsInTable == 10 + 5 + 4 + 3)
        #expect(a.overrunJumps == 3 && a.overrunJumpFrames == 107 && a.divergenceJumps == 2 && a.refusedJumps == 3 && a.largestJumpFrames == 200 && a.diverged && a.needsReprime)
        var empty = RingReaderRecovery(name: "e"); empty.merge(RingReaderRecovery())
        #expect(empty.minFrameCount == nil && empty.maxFrameCount == nil, "no call in either epoch: still no min / max")
    }

    @Test func theMarkdownShowsTheFlagsTheTableAndTheGiveUp() {
        let r = RingRecoveryReport(config: RePrimeConfig(), start: nil, rePrimes: [], suppressedByMinimumInterval: 2, suppressedByStormLimit: 3, gaveUp: "because",
                                   readers: [RingReaderRecovery(name: "left (reader 0)", frameCounts: [FrameCountEntry(frameCount: 512, calls: 9)], diverged: true, needsReprime: false),
                                             RingReaderRecovery(name: "right (reader 1)", diverged: false, needsReprime: true)], standingFillAtEnd: 2048)
        let md = r.markdownLines().joined(separator: "\n")
        #expect(md.contains("GAVE UP: because") && md.contains("512 x 9") && md.contains("suppressed by the minimum interval: 2") && md.contains("suppressed by the storm limit: 3"))
        let rows = md.components(separatedBy: "\n")
        let leftRow = rows.first { $0.hasPrefix("| left (reader 0) |") } ?? "", rightRow = rows.first { $0.hasPrefix("| right (reader 1) |") } ?? ""
        #expect(leftRow.hasSuffix("| set | no |"), "left: diverged set, needsReprime clear: \(leftRow)")
        #expect(rightRow.hasSuffix("| no | set |"), "right: diverged clear, needsReprime set: \(rightRow)")
    }
}
