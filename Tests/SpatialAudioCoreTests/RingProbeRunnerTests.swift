import Testing
import Foundation
@testable import SpatialAudioCore

// Step 6b-2. The sequencer of the ring probe against a RECORDING fake backend, ticker and clock: call order, error unwinding, stop reasons, the gain guard, the teardown
// order. No hardware, no real clock (the fake clock advances only when the runner sleeps) and no verdict depends on wall-clock time.

/// One shared, ordered log: the fake backend, ticker and clock all append to it, so a test can assert the order across all three.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

final class FakeClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var t = 0.0
    private(set) var sleeps = 0
    var now: Double { lock.lock(); defer { lock.unlock() }; return t }
    func sleep(_ d: Double) { lock.lock(); t += d; sleeps += 1; lock.unlock() }
    var clock: TapProbeClock { TapProbeClock(now: { [self] in now }, sleep: { [self] in sleep($0) }) }
}

final class FakeTicker: RingProbeTicker {
    let log: EventLog
    var script: [RingProbeWake]
    private(set) var waits = 0
    init(log: EventLog, script: [RingProbeWake]) { self.log = log; self.script = script }
    func start(periodSeconds: Double) { log.add("ticker.start \(periodSeconds)") }
    func wait() -> RingProbeWake {
        waits += 1
        // A script that runs out ends the run with a signal, so a runner bug cannot loop forever.
        return script.isEmpty ? .signal : script.removeFirst()
    }
    func stop() { log.add("ticker.stop") }
}

final class FakeRingBackend: RingProbeBackend {
    let log: EventLog
    let source = "fake"
    let composition = "a fake"
    let hostTicksPerSecond = 1_000_000_000.0
    let ringConstants = RingProbeConstants(capacityFrames: 32768, primeCallbacks: 4)
    var injectedFaults: String? { nil }

    // knobs
    var refusal: String?
    var failCreateTap = false, failAggregate = false, failStart = false, failPrepare = false, failStartEngine = false, failRing = false
    var format: TapFormat? = SimulatedRingFormat.real
    var gainBeforeStart: Double? = 0
    var gainAfterStart: Double? = 0
    var primeSucceedsOnAttempt: Int? = 3
    /// The readers are called from the snapshot with this index on (0-based over ALL snapshots, including the first-pull polls); nil = never.
    var pullsStartAtSnapshot: Int? = 1
    /// If set, the RIGHT reader is first called at this snapshot index instead (so a wait that needs only the left reader is caught).
    var rightPullsStartAtSnapshot: Int?
    /// Host seconds between two consecutive snapshots (measured time: the tests make it differ from the timer's nominal second on purpose).
    var secondsPerSnapshot = 1.0
    /// The configuration-change count becomes 1 when this many snapshots have been taken.
    var configChangeAtSnapshot: Int?
    var destroyStatus: Int32 = 0
    /// What every snapshot reports for each reader's fill, and for its underrun counter.
    var fill: Int64 = 2048
    var underrunBlocks: UInt64 = 0

    private var attempts = 0
    private var snapshots = 0
    private var engineStarted = false
    private var ringExists = false
    private var tapAlive = false, aggAlive = false, destroyedAgg = false, destroyedTap = false, listReads = 0

    init(log: EventLog) { self.log = log }

    func preflight() -> String? { refusal }
    /// Step 6b-3b: the output device's numbers and the tap mode are knobs (the defaults are what every earlier test saw).
    var outputFacts = RingOutputFacts(transportType: "fake", nominalSampleRate: 48_000, actualSampleRate: 48_000)
    var tapMode: RingProbeTapMode = .globalMixdown
    func outputDeviceFacts() -> RingOutputFacts { outputFacts }
    func translateOwnPID() -> (object: UInt32, status: Int32) { (7, 0) }
    func createTap(excludingProcessObjects: [UInt32]) -> (tap: UInt32, status: Int32) { log.add("createTap"); if failCreateTap { return (0, -1) }; tapAlive = true; return (11, 0) }
    func readTapUID(_ tap: UInt32) -> (uid: String?, status: Int32) { ("SENTINEL-UID-9f3a", 0) }
    func readTapFormat(_ tap: UInt32) -> (format: TapFormat?, status: Int32) { format.map { ($0, 0) } ?? (nil, -1) }
    func createRing() -> Bool { log.add("createRing"); if failRing { return false }; ringExists = true; return true }
    func createAggregate(tapUID: String) -> (device: UInt32, status: Int32) { log.add("createAggregate"); if failAggregate { return (0, -1) }; aggAlive = true; return (22, 0) }
    func createIOProc(on device: UInt32) -> Int32 { log.add("createIOProc"); return 0 }
    func start(_ device: UInt32) -> Int32 { log.add("io.start"); return failStart ? -1 : 0 }
    func prepareEngine(tapFormat: TapFormat) -> (ok: Bool, detail: String?) { log.add("engine.prepare"); return failPrepare ? (false, "no") : (true, nil) }
    func engineFacts() -> RingEngineFacts? { RingEngineFacts(realTime: true, sourceSampleRate: 48_000, sourceChannels: 1) }
    func engineOutputGain() -> Double? { engineStarted ? gainAfterStart : gainBeforeStart }
    func prime(callbacks: UInt32) -> Bool {
        attempts += 1; log.add("prime")
        if let primeProvider { return primeProvider(callbacks) }
        return primeSucceedsOnAttempt.map { attempts >= $0 } ?? false
    }
    func startEngine() -> (ok: Bool, detail: String?) {
        log.add("engine.start"); startEngineCalls += 1
        if failStartEngine { return (false, "no") }
        engineStarted = true; engineRunning = true; onStartEngine?(); return (true, nil)
    }

    // Step 6b-3a-2 (recovery mode): a model of the ring can be plugged in through these hooks; without them the fake behaves as before.
    var engineRunning = false
    var startEngineCalls = 0
    var onPause: (() -> Void)?
    var onStartEngine: (() -> Void)?
    var snapshotProvider: (() -> RingProbeRawSample?)?
    var primeProvider: ((UInt32) -> Bool)?
    var isEngineRunning: Bool { engineRunning }
    func pauseEngine() { log.add("engine.pause"); engineRunning = false; onPause?() }

    func snapshot() -> RingProbeRawSample? {
        if let snapshotProvider { snapshots += 1; return snapshotProvider() }
        let n = snapshots
        snapshots += 1
        let pulling = pullsStartAtSnapshot.map { n >= $0 } ?? false
        let k = pulling ? UInt64(n - pullsStartAtSnapshot! + 1) : 0
        var p = RingProducerCounters(); p.w = Int64(48_128 * n); p.commits = UInt64(94 * n); p.capacity = 32768; p.maxCommit = 16384
        var r = RingReaderCounters(); r.calls = 94 * k; r.framesRequested = 48_128 * k; r.servedBlocks = 94 * k; r.phaseValidCalls = 94 * k; r.fill = fill; r.underrunBlocks = underrunBlocks
        var right = r
        if let start = rightPullsStartAtSnapshot {
            let kr = n >= start ? UInt64(n - start + 1) : 0
            right.calls = 94 * kr; right.framesRequested = 48_128 * kr; right.servedBlocks = 94 * kr; right.phaseValidCalls = 94 * kr
        }
        return RingProbeRawSample(hostTicks: UInt64(1e9 + Double(n) * secondsPerSnapshot * 1e9), continuousSeconds: Double(n) * secondsPerSnapshot,
                                  producer: p, readers: [r, right], outputNominalRate: 48_000, outputActualRate: 48_000)
    }

    func configurationChangeCount() -> Int { configChangeAtSnapshot.map { snapshots >= $0 ? 1 : 0 } ?? 0 }
    func stopEngine() { log.add("engine.stop"); engineRunning = false }
    func detachSourceNodes() { log.add("detach") }
    func stop(_ device: UInt32) -> Int32 { log.add("io.stop"); return destroyStatus }
    func destroyIOProc(on device: UInt32) -> Int32 { log.add("ioproc.destroy"); return destroyStatus }
    func destroyAggregate(_ device: UInt32) -> Int32 { log.add("aggregate.destroy"); destroyedAgg = true; return destroyStatus }
    func destroyTap(_ tap: UInt32) -> Int32 { log.add("tap.destroy"); destroyedTap = true; return destroyStatus }
    func listDevices() -> (ids: [UInt32], status: Int32) {
        listReads += 1
        return (aggAlive && !(destroyedAgg && listReads % 3 == 0) ? [1, 22] : [1], 0)
    }
    func listTaps() -> (ids: [UInt32], status: Int32) { (tapAlive && !(destroyedTap && listReads % 3 == 0) ? [11] : [], 0) }
    func finishRing() -> RingDisposition { log.add("ring.finish"); return RingDisposition(freed: false, reason: "fake") }
}

enum SimulatedRingFormat {
    static let real = TapFormat(sampleRate: 48_000, formatID: "lpcm", formatFlags: 0x9, bytesPerPacket: 8, framesPerPacket: 1, bytesPerFrame: 8, channelsPerFrame: 2, bitsPerChannel: 32)
}

private let env = RingProbeEnvironment(createdAt: "2026-11-08T00:00:00Z", macOSVersion: "test", hardwareModel: "test", ownPID: 1, requestedSeconds: 5)

private func run(_ backend: FakeRingBackend, ticks: [RingProbeWake], seconds: Double = 5, clock: FakeClockBox = FakeClockBox(), log: EventLog? = nil) -> (RingProbeReport, FakeTicker, FakeClockBox) {
    let ticker = FakeTicker(log: log ?? backend.log, script: ticks)
    var e = env; e.requestedSeconds = seconds
    let report = RingProbeRunner.run(backend: backend, ticker: ticker, environment: e, clock: clock.clock)
    return (report, ticker, clock)
}

private let teardownTail = ["ticker.stop", "engine.stop", "detach", "io.stop", "ioproc.destroy", "aggregate.destroy", "tap.destroy", "ring.finish"]

@Suite struct RingProbeRunnerTests {
    @Test func theHappyPathCallsEverythingInOrderAndTearsDownInTheDocumentedOrder() {
        let log = EventLog()
        let b = FakeRingBackend(log: log)
        let (r, _, _) = run(b, ticks: Array(repeating: .tick, count: 10))
        #expect(r.outcome == "ok" && r.stoppedBy == "timeout" && r.teardownClean)
        let order = log.all
        #expect(Array(order.prefix(7)) == ["createTap", "createRing", "createAggregate", "createIOProc", "io.start", "engine.prepare", "prime"])
        #expect(order.contains("engine.start") && (order.firstIndex(of: "engine.start") ?? -1) > (order.lastIndex(of: "prime") ?? Int.max), "the engine starts only after a prime that succeeded")
        #expect(Array(order.suffix(8)) == teardownTail)
        #expect(r.teardownOrder == ["sampling timer off", "engine stop", "source nodes detached", "IO stop", "IOProc destroyed", "aggregate destroyed", "tap destroyed", "ring retained"])
        #expect(r.timings.primeAttempts == 3 && r.timings.fillAtFirstPull == [2048, 2048])
        #expect(r.summary?.sampleCount == 6 && r.elapsedSeconds == 5)                  // samples at measured 0, 1, ..., 5 s
        #expect(r.ring?.freed == false)
    }

    @Test func theCadenceComesFromTheTickerAndTheRunnerNeverSleepsWhileSampling() {
        let log = EventLog()
        let b = FakeRingBackend(log: log)
        let clock = FakeClockBox()
        let (r, ticker, _) = run(b, ticks: Array(repeating: .tick, count: 10), clock: clock)
        // The only sleeps: after prime attempts 1 and 2 (they failed) and after the first-pull poll that found no call yet. None while sampling, none in teardown here.
        #expect(ticker.waits == 5 && r.samples.count == 6, "one sample per tick, and a wait per tick")
        #expect(clock.sleeps == 3, "sleeps: \(clock.sleeps)")
        let early = EventLog()
        let b2 = FakeRingBackend(log: early); b2.primeSucceedsOnAttempt = 1; b2.pullsStartAtSnapshot = 0
        let c2 = FakeClockBox()
        _ = run(b2, ticks: Array(repeating: .tick, count: 10), clock: c2)
        #expect(c2.sleeps <= 4, "with nothing to wait for, only the teardown polling sleeps (\(c2.sleeps))")
    }

    @Test func theRunEndsWhenMEASUREDTimeReachesTheRequestedSecondsNotAfterNTicks() {
        let b = FakeRingBackend(log: EventLog()); b.secondsPerSnapshot = 0.5           // every tick is half a measured second
        let (r, _, _) = run(b, ticks: Array(repeating: .tick, count: 50), seconds: 3)
        #expect(r.outcome == "ok" && r.stoppedBy == "timeout")
        #expect(r.samples.count == 7 && r.samples.last?.elapsedSeconds == 3, "samples at 0, 0.5, ..., 3.0: \(r.samples.map(\.elapsedSeconds))")
        #expect(r.samples.allSatisfy { $0.elapsedSeconds == 0.5 * Double($0.index) }, "elapsed is read from the host ticks, not the nominal second")
        let slow = FakeRingBackend(log: EventLog()); slow.secondsPerSnapshot = 2.0     // late ticks: fewer samples reach the same measured time
        #expect(run(slow, ticks: Array(repeating: .tick, count: 50), seconds: 3).0.samples.count == 3)
    }

    @Test func aSignalStopsTheRunKeepsTheFinalSampleAndTearsDown() {
        let log = EventLog()
        let b = FakeRingBackend(log: log)
        let (r, _, _) = run(b, ticks: [.tick, .tick, .signal, .tick])
        #expect(r.stoppedBy == "signal" && r.outcome == "ok")
        #expect(r.samples.count == 4, "the first sample, two ticks and a final sample at the signal")
        #expect(Array(log.all.suffix(8)) == teardownTail)
    }

    @Test func aConfigurationChangeStopsTheRunAsInterruptedAndIsNotRestarted() {
        let log = EventLog()
        let b = FakeRingBackend(log: log); b.configChangeAtSnapshot = 4
        let (r, _, _) = run(b, ticks: [.tick, .tick, .interrupt, .tick, .tick, .tick, .tick], seconds: 60)
        #expect(r.outcome == "interrupted" && r.stoppedBy == "configurationChange" && r.configurationChanges == 1)
        #expect(r.flags.contains { $0.contains("configuration-change") })
        #expect(r.notes.contains { $0.contains("NOT restarted") })
        #expect(log.all.filter { $0 == "engine.start" }.count == 1, "no automatic restart")
        #expect(Array(log.all.suffix(8)) == teardownTail && r.teardownClean)
        #expect(r.samples.count >= 2)
    }

    @Test func theGainGuardRefusesToStartTheEngineUnlessTheVolumeReadsBackAsZero() {
        let bads: [Double?] = [0.5, 1.0, 0.0001, -0.0001, .nan, nil]
        for bad in bads {
            let log = EventLog()
            let b = FakeRingBackend(log: log); b.gainBeforeStart = bad
            let (r, _, _) = run(b, ticks: [.tick, .tick])
            #expect(r.outcome.hasPrefix("refused: output gain"), "gain \(String(describing: bad)) -> \(r.outcome)")
            #expect(!log.all.contains("engine.start") && !log.all.contains("prime"), "nothing past the guard may run")
            #expect(r.samples.isEmpty && r.stoppedBy == "never started")
            #expect(Array(log.all.suffix(8)) == teardownTail && r.teardownClean, "the chain that existed is still torn down, in order")
            #expect(r.outputGain.setTo == 0)
        }
        let ok = FakeRingBackend(log: EventLog()); ok.gainBeforeStart = -0.0           // negative zero is zero
        #expect(run(ok, ticks: Array(repeating: .tick, count: 6)).0.outcome == "ok")
    }

    @Test func aVolumeThatIsNotZeroAfterTheEngineStartedStopsTheRunAsFailed() {
        let log = EventLog()
        let b = FakeRingBackend(log: log); b.gainAfterStart = 1.0
        let (r, _, _) = run(b, ticks: [.tick, .tick])
        #expect(r.outcome.hasPrefix("failed at output gain read back as 1.0 after the engine started"))
        #expect(r.samples.isEmpty && Array(log.all.suffix(8)) == teardownTail)
    }

    @Test func ifPrimingNeverSucceedsTheRunSaysSoAndNeverStartsTheEngine() {
        let log = EventLog()
        let b = FakeRingBackend(log: log); b.primeSucceedsOnAttempt = nil
        let (r, _, clock) = run(b, ticks: [.tick])
        #expect(r.outcome == "never primed" && r.stoppedBy == "never started")
        #expect(!log.all.contains("engine.start") && r.samples.isEmpty)
        #expect(r.timings.primeAttempts > 100 && (r.timings.primeWaitSeconds ?? 0) >= RingProbeRunner.primeDeadlineSeconds, "bounded by the deadline on the fake suspending clock")
        #expect(clock.now >= RingProbeRunner.primeDeadlineSeconds)
        #expect(Array(log.all.suffix(8)) == teardownTail && r.teardownClean)
    }

    @Test func readersThatAreNeverCalledMakeTheRunInvalidNotOk() {
        let log = EventLog()
        let b = FakeRingBackend(log: log); b.pullsStartAtSnapshot = nil
        let (r, _, _) = run(b, ticks: [.tick, .tick])
        #expect(r.outcome.hasPrefix("invalid: a reader was never called") && r.outcome != "ok", "\(r.outcome)")
        #expect(r.stoppedBy == "no pull" && r.samples.isEmpty)
        #expect((r.timings.engineStartToFirstPullSeconds ?? 0) >= RingProbeRunner.firstPullDeadlineSeconds)
        #expect(Array(log.all.suffix(8)) == teardownTail)
    }

    @Test func theRunWaitsUntilBOTHReadersHaveBeenCalledBeforeItSamples() {
        let b = FakeRingBackend(log: EventLog()); b.pullsStartAtSnapshot = 1; b.rightPullsStartAtSnapshot = 4        // the right reader is called three snapshots later
        let (r, _, _) = run(b, ticks: Array(repeating: .tick, count: 8))
        #expect(r.outcome == "ok")
        #expect((r.samples.first?.readers[0].calls ?? 0) > 0 && (r.samples.first?.readers[1].calls ?? 0) > 0, "the first sample must already show both readers called")
        #expect(r.timings.fillAtFirstPull != nil && (r.timings.engineStartToFirstPullSeconds ?? 0) >= 3 * RingProbeRunner.pollIntervalSeconds - 1e-9)
        let never = FakeRingBackend(log: EventLog()); never.pullsStartAtSnapshot = 1; never.rightPullsStartAtSnapshot = 100_000
        #expect(run(never, ticks: [.tick]).0.outcome.hasPrefix("invalid:"), "one reader that is never called is INVALID too")
    }

    @Test func eachFailureUnwindsExactlyWhatWasCreatedInReverse() {
        func attempt(_ configure: (FakeRingBackend) -> Void) -> (RingProbeReport, [String]) {
            let log = EventLog(); let b = FakeRingBackend(log: log); configure(b)
            return (run(b, ticks: [.tick]).0, log.all)
        }
        var (r, l) = attempt { $0.failCreateTap = true }
        #expect(r.outcome == "failed at AudioHardwareCreateProcessTap" && l == ["createTap", "ticker.stop"])
        (r, l) = attempt { $0.failRing = true }
        #expect(r.outcome.hasPrefix("failed at SARingCreate") && l == ["createTap", "createRing", "ticker.stop", "tap.destroy"], "no ring: nothing to finish")
        (r, l) = attempt { $0.failAggregate = true }
        #expect(r.outcome == "failed at AudioHardwareCreateAggregateDevice" && l == ["createTap", "createRing", "createAggregate", "ticker.stop", "tap.destroy", "ring.finish"])
        (r, l) = attempt { $0.failStart = true }
        #expect(r.outcome == "failed at AudioDeviceStart" && l == ["createTap", "createRing", "createAggregate", "createIOProc", "io.start", "ticker.stop", "ioproc.destroy", "aggregate.destroy", "tap.destroy", "ring.finish"])
        (r, l) = attempt { $0.failPrepare = true }
        #expect(r.outcome.hasPrefix("failed at AVAudioEngine: attach") && !l.contains("engine.stop") && !l.contains("detach"), "an engine that was never prepared is not stopped")
        (r, l) = attempt { $0.failStartEngine = true }
        #expect(r.outcome == "failed at AVAudioEngine startAndReturnError" && l.suffix(8) == teardownTail[...])
        (r, l) = attempt { $0.format = TapFormat(sampleRate: 48_000, formatID: "lpcm", formatFlags: 0x29, bytesPerPacket: 4, framesPerPacket: 1, bytesPerFrame: 4, channelsPerFrame: 2, bitsPerChannel: 32) }
        #expect(r.outcome.hasPrefix("failed at tap format: the ring needs interleaved Float32 stereo") && !l.contains("createRing"), "a non-interleaved tap is refused before the ring exists")
        (r, l) = attempt { $0.refusal = "no" }
        #expect(r.outcome == "refused: no" && l == ["ticker.stop"])
    }

    @Test func aFailedDestroyIsRecordedAndMakesTeardownUnclean() {
        let b = FakeRingBackend(log: EventLog()); b.destroyStatus = -50
        let (r, _, _) = run(b, ticks: Array(repeating: .tick, count: 6))
        #expect(r.outcome == "ok" && !r.teardownClean && r.notes.contains { $0.contains("non-zero status") })
        #expect(r.teardownOrder.count == 8, "a failed destroy does not skip the next step")
    }

    @Test func theReportHoldsNoUIDNoDeviceNameKeyAndNoPath() throws {
        let b = FakeRingBackend(log: EventLog())
        let (r, _, _) = run(b, ticks: Array(repeating: .tick, count: 6))
        let data = try r.jsonData()
        let json = String(decoding: data, as: UTF8.self)
        for text in [json, r.markdown()] {
            #expect(!text.contains("/Users/") && !text.contains("/private/") && !text.contains("/var/") && !text.contains("/tmp"))
            #expect(!text.contains("SENTINEL"), "the tap's UID value must never reach a report")
        }
        func keys(_ o: Any) -> [String] {
            if let d = o as? [String: Any] { return d.keys.map { $0 } + d.values.flatMap(keys) }
            if let a = o as? [Any] { return a.flatMap(keys) }
            return []
        }
        let all = Set(keys(try JSONSerialization.jsonObject(with: data)))
        #expect(all.isDisjoint(with: ["uid", "UID", "deviceName", "deviceUID", "productName", "path", "directory", "manufacturer"]))
        #expect(try RingProbeReport.decode(data) == r, "the JSON round-trips losslessly")
        #expect(r.markdown().contains("In this plain mode NOTHING ends a starvation"), "the plain mode still says that nothing re-primes")
        #expect(!r.markdown().contains("## 8. Recovery"), "no recovery section in a plain report")
    }

    @Test func underrunsAreExplainedAsExpectedAndALateEngineStartIsCalledOut() {
        let quiet = FakeRingBackend(log: EventLog())
        #expect(!run(quiet, ticks: Array(repeating: .tick, count: 6)).0.notes.contains { $0.contains("underrun block") })
        let starved = FakeRingBackend(log: EventLog()); starved.underrunBlocks = 12; starved.fill = -5000
        let notes = run(starved, ticks: Array(repeating: .tick, count: 6)).0.notes
        #expect(notes.contains { $0.contains("12 underrun block(s)") && $0.contains("EXPECTED in this count-only spike") && $0.contains("stays starved") })
        let lapped = FakeRingBackend(log: EventLog()); lapped.fill = 20_000                // beyond the 16,384-frame window of the default ring
        #expect(run(lapped, ticks: Array(repeating: .tick, count: 6)).0.notes.contains { $0.contains("already exceeded the serve window") })
    }
}

@Suite struct RingProbeArgumentsTests {
    private func parse(_ a: String...) -> RingProbeArguments.Parsed { RingProbeArguments.parse(["app"] + a) }

    @Test func nothingIsRequestedWithoutARingProbeSwitch() {
        #expect(parse() == .notRequested && parse("--tap-probe", "10") == .notRequested && parse("--simulate", "--gain=1") == .notRequested)
    }

    @Test func theTwoModesParseWithASpaceOrAnEqualsSign() {
        #expect(parse("--ring-probe", "120") == .request(RingProbeRequest(seconds: 120, simulate: false, simulatedProducerPPM: 0, simulatedUnderrunAtSeconds: nil, simulatedUnderrunStallSeconds: 0)))
        #expect(parse("--ring-probe=60") == parse("--ring-probe", "60"))
        guard case .request(let sim) = parse("--ring-probe-simulate", "5", "--ring-sim-underrun=2,0.5", "--ring-sim-ppm=-250") else { Issue.record("not a request"); return }
        #expect(sim.simulate && sim.seconds == 5 && sim.simulatedUnderrunAtSeconds == 2 && sim.simulatedUnderrunStallSeconds == 0.5 && sim.simulatedProducerPPM == -250)
        #expect(parse("--ring-probe-simulate=7", "--results-dir=/x") == .request(RingProbeRequest(seconds: 7, simulate: true, simulatedProducerPPM: 0, simulatedUnderrunAtSeconds: nil, simulatedUnderrunStallSeconds: 0)))
    }

    @Test func badValuesAreRefusedWithAReason() {
        for args in [["--ring-probe"], ["--ring-probe", "abc"], ["--ring-probe", "0"], ["--ring-probe", "-5"], ["--ring-probe", "601"], ["--ring-probe", "nan"],
                     ["--ring-probe", "10", "--ring-probe-simulate", "10"], ["--ring-probe", "10", "--ring-sim-ppm=5"], ["--ring-probe", "10", "--ring-sim-underrun=1,1"],
                     ["--ring-sim-ppm=5"], ["--ring-probe-simulate", "10", "--ring-sim-underrun=1"], ["--ring-probe-simulate", "10", "--ring-sim-underrun=-1,1"],
                     ["--ring-probe-simulate", "10", "--ring-sim-ppm=1e9"]] {
            guard case .invalid(let why) = RingProbeArguments.parse(["app"] + args) else { Issue.record("accepted: \(args)"); continue }
            #expect(!why.isEmpty)
        }
    }

    @Test func thereIsNoGainOptionAndNamingOneIsRefusedNotIgnored() {
        for g in ["--gain=1", "--output-gain=0.5", "--ring-probe-gain=1", "--volume=1", "--Output-Volume", "--mixer-gain"] {
            guard case .invalid(let why) = parse("--ring-probe", "10", g) else { Issue.record("accepted \(g)"); continue }
            #expect(why.contains("no gain or volume option"), "\(g): \(why)")
            guard case .invalid = parse("--ring-probe-simulate", "10", g) else { Issue.record("accepted \(g) in simulate"); continue }
        }
        // and the request type has no field a gain could travel in
        let names = Mirror(reflecting: RingProbeRequest(seconds: 1, simulate: false, simulatedProducerPPM: 0, simulatedUnderrunAtSeconds: nil, simulatedUnderrunStallSeconds: 0)).children.compactMap(\.label)
        #expect(!names.contains { $0.lowercased().contains("gain") || $0.lowercased().contains("volume") })
    }
}
