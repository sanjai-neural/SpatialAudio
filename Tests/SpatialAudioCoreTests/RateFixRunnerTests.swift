import Testing
import Foundation
@testable import SpatialAudioCore

// Step 6b-3b (a2): the device-bound mode inside the runner (the rate-equality guard, the first-sample clock, the rate-fix section), and the new switch. Against the recording fake
// backend, ticker and clock of RingProbeRunnerTests: no hardware, no real clock. Nothing here says what a real device-bound tap reports.

private func runFake(_ backend: FakeRingBackend, seconds: Double = 5, ticks: Int = 10) -> (RingProbeReport, FakeClockBox) {
    let clock = FakeClockBox()
    let ticker = FakeTicker(log: backend.log, script: Array(repeating: .tick, count: ticks))
    let env = RingProbeEnvironment(createdAt: "2026-11-19T00:00:00Z", macOSVersion: "test", hardwareModel: "test", ownPID: 1, requestedSeconds: seconds)
    return (RingProbeRunner.run(backend: backend, ticker: ticker, environment: env, clock: clock.clock), clock)
}

@Suite struct RateFixRunnerTests {
    @Test func aDeviceBoundRunWithEqualRatesRunsToTheEndAndCarriesTheRateFixSection() throws {
        let log = EventLog()
        let b = FakeRingBackend(log: log); b.tapMode = .deviceBound            // tap 48 kHz, output 48 kHz (the fake's defaults)
        let (r, _) = runFake(b)
        #expect(r.outcome == "ok" && r.stoppedBy == "timeout" && r.tapMode == .deviceBound)
        let fix = try #require(r.rateFix)
        #expect(fix.stage == .s0 && fix.verdict == .proceedToS1 && fix.criteriaVersion == RateFixCriteria.version)
        #expect(log.all.contains("createRing") && log.all.contains("engine.start"))
        #expect(r.calls.contains { $0.name.hasPrefix("rate-equality guard") && $0.status == 0 })
    }

    @Test func aRateMismatchStopsTheRunBeforeTheRingExistsRecordsTheFormatAndTearsDownWhatWasBuilt() throws {
        let log = EventLog()
        let b = FakeRingBackend(log: log); b.tapMode = .deviceBound
        b.outputFacts = RingOutputFacts(transportType: "fake", nominalSampleRate: 44_100, actualSampleRate: 44_100, bufferFrameSize: 512)   // the tap stays 48 kHz
        let (r, _) = runFake(b)
        #expect(r.outcome.hasPrefix("failed at tap rate"), "\(r.outcome)")
        #expect(r.tapFormat == b.format, "the format the tap reported is in the report, so the refusal can be read")
        #expect(!log.all.contains("createRing") && !log.all.contains("createAggregate") && !log.all.contains("engine.start") && !log.all.contains("engine.prepare"))
        #expect(log.all.contains("tap.destroy"), "the tap that was created is destroyed")
        let guardCall = try #require(r.calls.first { $0.name.hasPrefix("rate-equality guard") })
        #expect(guardCall.status == -1 && (guardCall.note ?? "").contains("48000.0") && (guardCall.note ?? "").contains("44100.0"))
        #expect(r.notes.contains { $0.contains("Stopped before the ring was created") })
        let fix = try #require(r.rateFix)
        #expect(fix.stage == .s0 && fix.verdict == .noGo, "a refusal at the guard still carries the S0 verdict")
        #expect(r.samples.isEmpty && r.teardownClean)
    }

    @Test func anUnknownOutputRateAlsoStopsTheDeviceBoundRun() {
        let b = FakeRingBackend(log: EventLog()); b.tapMode = .deviceBound
        b.outputFacts = RingOutputFacts(transportType: "fake", nominalSampleRate: nil)
        let (r, _) = runFake(b)
        #expect(r.outcome.hasPrefix("failed at tap rate") && r.outcome.contains("unknown") && r.rateFix?.verdict == .noGo)
    }

    @Test func theGlobalModeNeverHadTheGuardAndStillRunsWith48kHzOnA44kHzOutput() {
        let log = EventLog()
        let b = FakeRingBackend(log: log)       // tapMode stays .globalMixdown: the Bluetooth case of every earlier real run
        b.outputFacts = RingOutputFacts(transportType: "fake", nominalSampleRate: 44_100, actualSampleRate: 44_100, bufferFrameSize: 512)
        let (r, _) = runFake(b)
        #expect(r.outcome == "ok" && r.tapMode == .globalMixdown)
        #expect(r.rateFix == nil, "no rate-fix section in the global mode")
        #expect(!r.calls.contains { $0.name.hasPrefix("rate-equality guard") })
        #expect(log.all.contains("engine.start"))
    }

    @Test func theFirstSamplesRunClockTimeIsRecordedAfterTheWaitsAndBeforeTheSampling() throws {
        let b = FakeRingBackend(log: EventLog()); b.tapMode = .deviceBound
        let (r, clock) = runFake(b)
        let t = try #require(r.timings.firstSampleRunClockSeconds)
        // three sleeps of 0.005 s happened before the first sample (two refused primes, one first-pull poll); the teardown sleeps come later
        #expect(abs(t - 0.015) < 1e-9, "got \(t)")
        #expect(t <= clock.now)
        #expect(r.timings.engineStartToFirstPullSeconds != nil)
    }

    @Test func theFirstSampleClockIsRecordedInTheGlobalModeToo() {
        let (r, _) = runFake(FakeRingBackend(log: EventLog()))
        #expect(r.timings.firstSampleRunClockSeconds != nil)
    }

    @Test func aRunThatNeverSampledHasNoFirstSampleClock() {
        let b = FakeRingBackend(log: EventLog()); b.failStartEngine = true
        let (r, _) = runFake(b)
        #expect(r.timings.firstSampleRunClockSeconds == nil)
    }

    @Test func theDeviceBoundReportHoldsNoUIDNoDeviceNameKeyAndNoPath() throws {
        let b = FakeRingBackend(log: EventLog()); b.tapMode = .deviceBound
        let (r, _) = runFake(b)
        let json = String(decoding: try r.jsonData(), as: UTF8.self), md = r.markdown()
        for text in [json, md] {
            #expect(!text.contains("SENTINEL-UID") && !text.contains("/Users") && !text.lowercased().contains("\"uid\""))
        }
        #expect(json.contains("\"rateFix\"") && json.contains("\"tapMode\" : \"deviceBound\""))
    }

    @Test func theRateFixSectionRoundTripsThroughJSONAndPrintsInTheMarkdown() throws {
        let b = FakeRingBackend(log: EventLog()); b.tapMode = .deviceBound
        let (r, _) = runFake(b)
        let back = try RingProbeReport.decode(r.jsonData())
        #expect(back.rateFix == r.rateFix && back.tapMode == .deviceBound && back.timings.firstSampleRunClockSeconds == r.timings.firstSampleRunClockSeconds)
        let md = r.markdown()
        #expect(md.contains("## 9. Rate-fix check") && md.contains("**Verdict: proceedToS1**") && md.contains("- Tap mode: device-bound"))
        #expect(md.hasPrefix("# Ring probe report (Step 6b-2, device-bound tap of Step 6b-3b)"))
        let global = runFake(FakeRingBackend(log: EventLog())).0.markdown()
        #expect(!global.contains("## 9.") && !global.contains("device-bound") && global.contains("- Tap mode: global stereo mixdown"))
    }

    @Test func anOldReportWithoutTheNewKeysStillDecodes() throws {
        let b = FakeRingBackend(log: EventLog())
        let (r, _) = runFake(b)
        var obj = try #require(JSONSerialization.jsonObject(with: r.jsonData()) as? [String: Any])
        obj.removeValue(forKey: "tapMode"); obj.removeValue(forKey: "rateFix")
        var timings = try #require(obj["timings"] as? [String: Any]); timings.removeValue(forKey: "firstSampleRunClockSeconds"); obj["timings"] = timings
        let old = try RingProbeReport.decode(JSONSerialization.data(withJSONObject: obj))
        #expect(old.tapMode == nil && old.rateFix == nil && old.timings.firstSampleRunClockSeconds == nil)
    }

    @Test func theDefaultBackendTapModeIsTheGlobalMixdown() {
        final class Minimal: RingProbeBackend {
            // only what the extension default needs to be visible: the rest is the FakeRingBackend's job
            let source = "x", composition = "x", hostTicksPerSecond = 1.0, ringConstants = RingProbeConstants(capacityFrames: 2, primeCallbacks: 1), injectedFaults: String? = nil
            func preflight() -> String? { nil }; func outputDeviceFacts() -> RingOutputFacts { RingOutputFacts() }
            func translateOwnPID() -> (object: UInt32, status: Int32) { (0, 0) }
            func createTap(excludingProcessObjects: [UInt32]) -> (tap: UInt32, status: Int32) { (0, 0) }
            func readTapUID(_ tap: UInt32) -> (uid: String?, status: Int32) { (nil, 0) }
            func readTapFormat(_ tap: UInt32) -> (format: TapFormat?, status: Int32) { (nil, 0) }
            func createRing() -> Bool { false }
            func createAggregate(tapUID: String) -> (device: UInt32, status: Int32) { (0, 0) }
            func createIOProc(on device: UInt32) -> Int32 { 0 }
            func start(_ device: UInt32) -> Int32 { 0 }
            func prepareEngine(tapFormat: TapFormat) -> (ok: Bool, detail: String?) { (false, nil) }
            func engineFacts() -> RingEngineFacts? { nil }
            func engineOutputGain() -> Double? { nil }
            func prime(callbacks: UInt32) -> Bool { false }
            func startEngine() -> (ok: Bool, detail: String?) { (false, nil) }
            func snapshot() -> RingProbeRawSample? { nil }
            func configurationChangeCount() -> Int { 0 }
            var isEngineRunning: Bool { false }
            func pauseEngine() {}; func stopEngine() {}; func detachSourceNodes() {}
            func stop(_ device: UInt32) -> Int32 { 0 }
            func destroyIOProc(on device: UInt32) -> Int32 { 0 }
            func destroyAggregate(_ device: UInt32) -> Int32 { 0 }
            func destroyTap(_ tap: UInt32) -> Int32 { 0 }
            func listDevices() -> (ids: [UInt32], status: Int32) { ([], 0) }
            func listTaps() -> (ids: [UInt32], status: Int32) { ([], 0) }
            func finishRing() -> RingDisposition { RingDisposition(freed: false, reason: "x") }
        }
        #expect(Minimal().tapMode == .globalMixdown)
    }
}

@Suite struct RingProbeDeviceTapArgumentsTests {
    private func parse(_ a: String...) -> RingProbeArguments.Parsed { RingProbeArguments.parse(["app"] + a) }
    private func request(_ a: [String]) -> RingProbeRequest? {
        if case .request(let r) = RingProbeArguments.parse(["app"] + a) { return r } else { return nil }
    }

    @Test func theSwitchModifiesEachOfTheFourProbeFlagsInEitherOrder() {
        for (flag, sim, rec) in [("--ring-probe", false, false), ("--ring-probe-simulate", true, false), ("--ring-probe-recovery", false, true), ("--ring-probe-recovery-simulate", true, true)] {
            for args in [[flag, "5", "--ring-probe-device-tap"], ["--ring-probe-device-tap", flag, "5"], [flag + "=5", "--ring-probe-device-tap"]] {
                let r = request(args)
                #expect(r?.deviceTap == true && r?.seconds == 5 && r?.simulate == sim && r?.recovery == rec, "\(args)")
            }
        }
    }

    @Test func withoutTheSwitchTheRequestIsTheGlobalOneAsBefore() {
        #expect(request(["--ring-probe", "120"])?.deviceTap == false)
        #expect(parse("--ring-probe", "120") == .request(RingProbeRequest(seconds: 120, simulate: false, simulatedProducerPPM: 0, simulatedUnderrunAtSeconds: nil, simulatedUnderrunStallSeconds: 0)))
    }

    @Test func theSwitchAloneOrWithOnlySimulatorOptionsIsRefusedNotIgnored() {
        for args in [["--ring-probe-device-tap"], ["--ring-probe-device-tap", "5"], ["--ring-probe-device-tap", "--ring-sim-ppm=5"], ["--ring-sim-ppm=5", "--ring-probe-device-tap"]] {
            guard case .invalid(let why) = RingProbeArguments.parse(["app"] + args) else { Issue.record("accepted \(args)"); continue }
            #expect(!why.isEmpty, "\(args)")
        }
        if case .invalid(let why) = parse("--ring-probe-device-tap") { #expect(why.contains("--ring-probe-device-tap needs one of")) } else { Issue.record("accepted") }
    }

    @Test func aRepeatedSwitchOrAValueOnItIsRefused() {
        for args in [["--ring-probe", "5", "--ring-probe-device-tap", "--ring-probe-device-tap"], ["--ring-probe", "5", "--ring-probe-device-tap=1"]] {
            guard case .invalid = RingProbeArguments.parse(["app"] + args) else { Issue.record("accepted \(args)"); continue }
        }
    }

    @Test func theSwitchDoesNotWeakenTheNoGainRule() {
        for g in ["--gain=1", "--output-volume=1"] {
            guard case .invalid(let why) = parse("--ring-probe", "5", "--ring-probe-device-tap", g) else { Issue.record("accepted \(g)"); continue }
            #expect(why.contains("no gain or volume option"))
        }
    }

    @Test func theDeviceTapFileStemHasItsOwnPrefixAndKeepsTheSimulatedSuffix() {
        let d = Date(timeIntervalSince1970: 0), utc = TimeZone(identifier: "UTC")!
        #expect(RingProbeReport.fileStem(date: d, timeZone: utc, simulated: false, recovery: false, deviceTap: true) == "ringdevicetap-19700101-000000")
        #expect(RingProbeReport.fileStem(date: d, timeZone: utc, simulated: true, recovery: true, deviceTap: true) == "ringdevicetap-19700101-000000-SIMULATED")
        #expect(RingProbeReport.fileStem(date: d, timeZone: utc, simulated: false, recovery: true) == "ringrecovery-19700101-000000")
        #expect(RingProbeReport.fileStem(date: d, timeZone: utc, simulated: false) == "ringprobe-19700101-000000")
    }
}
