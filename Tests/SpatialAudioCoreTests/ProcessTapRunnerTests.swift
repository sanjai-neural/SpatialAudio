import Testing
import Foundation
@testable import SpatialAudioCore

// Step 6b-3c-0: the process-specific tap mode inside the runner (the target's translation and refusal, the include list, the mute option in the report, the rate guard and verdict, the injected scenarios, the events) and the
// new switches. Against the recording fake backend, ticker and clock: no hardware, no real clock. Nothing here says what a real muted tap does; the "target" is a fake object.

final class EventBox: @unchecked Sendable {
    private let lock = NSLock(); private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

private func runProcess(_ backend: FakeRingBackend, seconds: Double = 8, ticks: Int = 12, scenario: MuteScenario? = nil, ownPID: Int32 = 1) -> (report: RingProbeReport, events: [String]) {
    let clock = FakeClockBox()
    let ticker = FakeTicker(log: backend.log, script: Array(repeating: .tick, count: ticks))
    let box = EventBox()
    let env = RingProbeEnvironment(createdAt: "2026-11-19T00:00:00Z", macOSVersion: "test", hardwareModel: "test", ownPID: ownPID, requestedSeconds: seconds)
    let r = RingProbeRunner.run(backend: backend, ticker: ticker, environment: env, clock: clock.clock, muteScenario: scenario, onEvent: { box.add($0) })
    return (r, box.all)
}

private func processBackend(mute: RingProbeMuteBehavior = .unmuted, pid: Int32 = 500) -> FakeRingBackend {
    let b = FakeRingBackend(log: EventLog())
    b.tapMode = .processSpecific
    b.processTapSpec = ProcessTapSpec(targetPID: pid, mute: mute)
    return b
}

@Suite struct ProcessTapRunnerTests {
    @Test func theProcessTapIsCreatedFromTheTranslatedTargetOnlyAndNeverFromOurOwnObject() throws {
        let b = processBackend()
        let (r, _) = runProcess(b)
        #expect(r.outcome == "ok" && r.tapMode == .processSpecific)
        #expect(b.processTapIncluded == [30], "only the target's object (30); our own object is 7 and is absent")
        #expect(!b.log.all.contains("createTap"), "the global creation call is never used in this mode")
        let order = b.log.all
        #expect((order.firstIndex(of: "translateTarget") ?? .max) < (order.firstIndex(of: "createProcessTap") ?? 0), "the target is translated before the tap exists")
        #expect(r.calls.contains { $0.name.contains("for the TARGET process") && $0.status == 0 && ($0.note ?? "") == "object 30" })
    }

    @Test func theReportRecordsTheTargetPIDAndTheMuteBehaviourAndDefaultsToUnmuted() {
        let (plain, _) = runProcess(processBackend())
        #expect(plain.targetProcessPID == 500 && plain.muteBehavior == "unmuted")
        #expect(!plain.markdown().contains("WAS MUTED"))
        for m in [RingProbeMuteBehavior.muted, .mutedWhenTapped] {
            let (r, _) = runProcess(processBackend(mute: m))
            #expect(r.muteBehavior == m.rawValue && r.targetProcessPID == 500)
            #expect(r.markdown().contains("THE TARGET PROCESS'S AUDIO WAS MUTED BY THIS RUN (mute behaviour: \(m.rawValue))"))
            #expect(r.markdown().contains("process-specific (a tap on ONE process, PID 500"))
        }
        let global = runProcess(FakeRingBackend(log: EventLog())).report
        #expect(global.targetProcessPID == nil && global.muteBehavior == "unmuted" && global.muteScenario == nil)
    }

    @Test func aTargetThatIsThisProcessIsRefusedBeforeAnyTapExists() {
        let b = processBackend(pid: 1)                                   // the environment's own PID is 1
        let (r, _) = runProcess(b, ownPID: 1)
        #expect(r.outcome.hasPrefix("refused:") && r.outcome.contains("never taps itself"))
        #expect(!b.log.all.contains("createProcessTap") && !b.log.all.contains("createRing") && !b.log.all.contains("engine.start"))
        let byObject = processBackend(); byObject.targetTranslate = (7, 0)       // the fake's own process object is 7
        let (r2, _) = runProcess(byObject)
        #expect(r2.outcome.contains("never taps itself") && !byObject.log.all.contains("createProcessTap"))
    }

    @Test func anUnknownTargetProcessIsRefusedAndNothingIsCreated() {
        let b = processBackend(); b.targetTranslate = (0, 0)
        let (r, _) = runProcess(b)
        #expect(r.outcome.hasPrefix("refused:") && r.outcome.contains("is the player running"))
        #expect(!b.log.all.contains("createProcessTap") && !b.log.all.contains("createRing"))
        let failing = processBackend(); failing.targetTranslate = (0, -1)
        let (r2, _) = runProcess(failing)
        #expect(r2.outcome.hasPrefix("failed at") && !failing.log.all.contains("createProcessTap"))
    }

    @Test func aProcessModeWithoutATargetIsRefused() {
        let b = FakeRingBackend(log: EventLog()); b.tapMode = .processSpecific       // no spec
        let (r, _) = runProcess(b)
        #expect(r.outcome.hasPrefix("refused:") && r.outcome.contains("no target") && !b.log.all.contains("createProcessTap"))
    }

    @Test func theRateEqualityGuardAndTheVerdictApplyToTheProcessTapToo() throws {
        let ok = processBackend()
        let (good, _) = runProcess(ok, seconds: 5)
        let fix = try #require(good.rateFix)
        #expect(good.outcome == "ok" && fix.stage == .s0 && fix.verdict == .proceedToS1 && good.calls.contains { $0.name.hasPrefix("rate-equality guard") && $0.status == 0 })
        let bad = processBackend()
        bad.outputFacts = RingOutputFacts(transportType: "fake", nominalSampleRate: 44_100, actualSampleRate: 44_100, bufferFrameSize: 512)     // the tap stays 48 kHz
        let (r, _) = runProcess(bad, seconds: 5)
        #expect(r.outcome.hasPrefix("failed at tap rate") && r.tapFormat == bad.format && r.rateFix?.verdict == .noGo)
        #expect(!bad.log.all.contains("createRing") && !bad.log.all.contains("engine.start"))
    }

    @Test func theOutputGainIsStillReadBackAndAnythingButZeroRefusesTheEngineStart() {
        let b = processBackend(); b.gainBeforeStart = 0.5
        let (r, _) = runProcess(b)
        #expect(r.outcome.hasPrefix("refused: output gain read back as 0.5") && !b.log.all.contains("engine.start"))
        let (ok, _) = runProcess(processBackend())
        #expect(ok.outputGain.setTo == 0 && ok.outputGain.readBackBeforeStart == 0 && ok.outputGain.readBackAfterStart == 0)
    }

    @Test func theFirstSampleClockIsRecordedInTheProcessMode() {
        #expect(runProcess(processBackend()).report.timings.firstSampleRunClockSeconds != nil)
    }

    @Test func anAnnouncementIsMadeWhenSamplingStartsAndEndsAndAfterTheTeardown() {
        let (_, events) = runProcess(processBackend(mute: .muted))
        #expect(events.first?.hasPrefix("SAMPLING STARTED: the tap lists ONLY process 500; its mute behaviour is muted") == true)
        #expect(events.first?.contains("SILENT") == true)
        #expect(events.contains("SAMPLING ENDED: teardown begins") && events.last == "TEARDOWN COMPLETE: the probe is about to exit")
        let (_, unmutedEvents) = runProcess(processBackend())
        #expect(unmutedEvents.first?.contains("SILENT") == false && unmutedEvents.first?.contains("unmuted") == true)
    }
}

@Suite struct MuteScenarioRunnerTests {
    @Test func destroyTapFiresAtTheFirstSampleAtOrAfterItsTimeAndTheTapIsDestroyedExactlyOnce() throws {
        let b = processBackend(mute: .muted)
        let (r, events) = runProcess(b, scenario: .destroyTap(atSeconds: 3))
        #expect(r.outcome == "ok")
        let sc = try #require(r.muteScenario)
        #expect(sc.kind == "destroy-tap" && sc.requestedAtSeconds == 3 && sc.firedAtElapsedSeconds == 3 && sc.status == 0, "samples are one measured second apart: the sample at 3.0 s is the first at or after 3")
        #expect(b.log.all.filter { $0 == "tap.destroy" }.count == 1, "destroyed by the scenario; the teardown must not destroy it again")
        #expect(b.log.all.filter { $0 == "io.stop" }.count == 1, "the IO is stopped once, by the teardown")
        #expect(r.teardownOrder.contains("tap destroyed (done earlier by the scenario)") && !r.teardownOrder.contains("tap destroyed"))
        #expect(events.contains { $0.hasPrefix("SCENARIO destroy-tap performed at 3.0 s (status 0)") && $0.contains("within 5 s") })
        #expect(r.calls.contains { $0.name == "scenario: AudioHardwareDestroyProcessTap while the IO runs" })
        #expect(r.markdown().contains("Mute scenario: destroy-tap requested at 3.0 s; fired at 3.000 s measured"))
    }

    @Test func aTimeBetweenSamplesFiresAtTheNextSample() throws {
        let (r, _) = runProcess(processBackend(), scenario: .destroyTap(atSeconds: 2.5))
        #expect(try #require(r.muteScenario).firedAtElapsedSeconds == 3)
        let (exact, _) = runProcess(processBackend(), scenario: .stopIO(atSeconds: 2))
        #expect(try #require(exact.muteScenario).firedAtElapsedSeconds == 2, "a time that equals a sample's time fires at that sample, not the next one")
    }

    @Test func stopIOStopsTheIOOnceKeepsTheTapAndTheRunGoesOnToItsEnd() throws {
        let b = processBackend(mute: .mutedWhenTapped)
        let (r, events) = runProcess(b, scenario: .stopIO(atSeconds: 2))
        #expect(r.outcome == "ok" && r.stoppedBy == "timeout")
        let sc = try #require(r.muteScenario)
        #expect(sc.kind == "stop-io" && sc.firedAtElapsedSeconds == 2)
        #expect(b.log.all.filter { $0 == "io.stop" }.count == 1, "stopped by the scenario; the teardown must not stop it again")
        #expect(b.log.all.filter { $0 == "tap.destroy" }.count == 1, "the tap lives until the teardown")
        let order = b.log.all
        #expect((order.firstIndex(of: "io.stop") ?? .max) < (order.firstIndex(of: "tap.destroy") ?? 0))
        #expect(r.teardownOrder.contains("IO stop (done earlier by the scenario)") && r.teardownOrder.contains("tap destroyed"))
        #expect(events.contains { $0.hasPrefix("SCENARIO stop-io performed at 2.0 s") })
        #expect(r.samples.last?.elapsedSeconds == 8, "the run continued to its requested end")
    }

    @Test func aScenarioFiresOnceNotAtEverySampleAfterItsTime() {
        let b = processBackend()
        let (r, events) = runProcess(b, scenario: .stopIO(atSeconds: 1))
        #expect(b.log.all.filter { $0 == "io.stop" }.count == 1 && events.filter { $0.hasPrefix("SCENARIO") }.count == 1)
        #expect(r.samples.count > 5)
    }

    @Test func aScenarioThatNeverComesBeforeTheEndIsRecordedAsNeverFired() throws {
        let (r, events) = runProcess(processBackend(), seconds: 4, scenario: .destroyTap(atSeconds: 100))
        let sc = try #require(r.muteScenario)
        #expect(sc.firedAtElapsedSeconds == nil && sc.status == nil && !events.contains { $0.hasPrefix("SCENARIO") })
        #expect(r.markdown().contains("never (the run ended first)"))
    }

    @Test func aScenarioOutsideTheProcessModeIsRefusedBeforeAnythingExists() {
        for mode in [RingProbeTapMode.globalMixdown, .deviceBound] {
            let b = FakeRingBackend(log: EventLog()); b.tapMode = mode
            let (r, _) = runProcess(b, scenario: .destroyTap(atSeconds: 2))
            #expect(r.outcome == "refused: a mute scenario needs the process-specific tap", "\(mode)")
            #expect(!b.log.all.contains("createTap") && !b.log.all.contains("tap.destroy"))
        }
    }

    @Test func theDeviceBoundAndGlobalModesAreUnchangedAndHaveNoScenarioRecord() {
        let g = runProcess(FakeRingBackend(log: EventLog())).report
        #expect(g.muteScenario == nil && g.outcome == "ok")
    }
}
