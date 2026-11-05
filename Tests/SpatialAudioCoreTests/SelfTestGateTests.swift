import Testing
import Foundation
@testable import SpatialAudioCore

/// Step 2d, item 4: the loss test's cover cue waits until tracking has been LOCKED for a second, and the run is INVALID
/// (not "FAIL") when that never happens. The real 08:12 run started the loss window in `decaying`.
@Suite struct SelfTestGateTests {
    let dt = 1.0 / 30
    let script = SelfTestScript.standard
    var cover: Int { script.firstIndex(of: .cover)! }
    var uncover: Int { script.firstIndex(of: .uncover)! }
    var nominal: Double { script.starts[cover] }             // 38 s: the nominal cover cue

    func frame(_ t: Double, _ state: TrackingState = .locked, watchdog: Bool = false) -> SelfTestFrame {
        SelfTestFrame(arrival: t, captureTime: t, angles: watchdog ? nil : VisionFaceAngles(yaw: 0.4, pitch: 0, roll: 0), frameMirrored: false,
                      state: state, pose: yawQ(25), qualityOverall: 1, isWatchdogTick: watchdog,
                      deliveryLatency: 0.06, visionDuration: 0.018, totalLatency: 0.08)
    }

    /// Records frames every 1/30 s in [a, b) with the given state.
    func feed(_ s: inout SelfTestSession, from a: Double, to b: Double, _ state: TrackingState = .locked, watchdog: Bool = false) {
        var t = a
        while t < b - 1e-9 { s.record(frame(t, state, watchdog: watchdog)); t += dt }
    }

    @Test func theGatedPhaseIsTheCoverPhaseOnly() {
        #expect(script.phases.filter { $0.lockGate != nil }.map(\.kind) == [.cover])
        #expect(script.phases[cover].lockGate == LockGate(minimumLockedSeconds: 1.0, maximumWaitSeconds: 10.0))
        #expect(script.withoutLockGates.phases.allSatisfy { $0.lockGate == nil })
    }

    @Test func aTrackerThatIsAlreadyLockedDoesNotDelayTheCoverCue() {
        var s = SelfTestSession(lighting: .normalLight, startTime: 0)
        feed(&s, from: 0, to: nominal)
        _ = s.advance(to: nominal - 0.001)
        #expect(!s.gateOpened)
        let events = s.advance(to: nominal)
        #expect(events == [.phaseStarted(index: cover)] && s.gateOpened && s.gateShift == 0)
        #expect(s.absoluteStart(of: cover) == nominal && s.totalDuration == script.totalDuration)
    }

    @Test func theCoverCueWaitsUntilTheTrackerHasBeenLockedForOneSecond() throws {
        var s = SelfTestSession(lighting: .normalLight, startTime: 0)
        feed(&s, from: 0, to: nominal + 0.5, .decaying)                       // tracking lost around the nominal cue
        _ = s.advance(to: nominal)
        #expect(!s.gateOpened)
        let waiting = try #require(s.status(at: nominal + 0.4))
        #expect(waiting.isWaitingForLock && waiting.phase.kind == .lossTurn && waiting.lockSecondsNeeded == 1.0)
        #expect(abs(waiting.waitedSeconds - 0.4) < 1e-9 && waiting.lockedSeconds == 0)

        feed(&s, from: nominal + 0.5, to: nominal + 1.45)                     // locked again, but only for 0.95 s
        #expect(s.advance(to: nominal + 1.45).isEmpty && !s.gateOpened)
        let mid = try #require(s.status(at: nominal + 1.45))
        #expect(mid.isWaitingForLock && mid.lockedSeconds > 0.9 && mid.lockedSeconds < 1.0)

        feed(&s, from: nominal + 1.45, to: nominal + 1.6)
        let events = s.advance(to: nominal + 1.6)
        #expect(events == [.phaseStarted(index: cover)])
        #expect(abs(s.gateShift - 1.6) < 1e-9)
        // Everything from the cover on is shifted by the wait; the turn phase was extended to the moment the gate opened.
        #expect(abs(s.absoluteStart(of: cover) - (nominal + 1.6)) < 1e-9)
        #expect(abs(s.absoluteEnd(of: cover - 1) - (nominal + 1.6)) < 1e-9)
        #expect(abs(s.absoluteStart(of: uncover) - (nominal + 1.6 + 5)) < 1e-9)
        #expect(abs(s.totalDuration - (script.totalDuration + 1.6)) < 1e-9)
        #expect(s.advance(to: script.totalDuration + 1.6 - 0.01).count == 1)  // the uncover phase start, nothing else yet
        #expect(s.advance(to: script.totalDuration + 1.6) == [.finished])
    }

    @Test func aTrackerThatNeverLocksEndsTheRunWithoutEverGivingTheCoverCue() {
        var s = SelfTestSession(lighting: .normalLight, startTime: 0)
        feed(&s, from: 0, to: nominal + 12, .decaying)
        _ = s.advance(to: nominal)
        #expect(s.advance(to: nominal + 9.99).isEmpty && !s.isFinished)
        let events = s.advance(to: nominal + 10)
        #expect(events == [.finished] && s.isFinished && s.lossGateFailed)
        #expect(s.announcedPhases == cover)                                   // the cover phase was never announced
        #expect(s.advance(to: nominal + 60).isEmpty)
        #expect(s.status(at: nominal + 11) == nil)
    }

    @Test func staleFramesAndWatchdogTicksDoNotCountAsLocked() {
        var s = SelfTestSession(lighting: .normalLight, startTime: 0)
        feed(&s, from: 0, to: nominal + 0.5)                                  // locked ... then the frames stop
        _ = s.advance(to: nominal + 1.2)
        #expect(!s.gateOpened)                                                // last frame is 0.7 s old: not "tracking right now"

        var t = SelfTestSession(lighting: .normalLight, startTime: 0)
        feed(&t, from: 0, to: nominal - 0.5, .holding)
        feed(&t, from: nominal - 0.5, to: nominal + 2, .locked, watchdog: true)   // watchdog ticks are not tracking
        _ = t.advance(to: nominal + 2)
        #expect(!t.gateOpened)
    }

    @Test func aDipBackOutOfLockedRestartsTheLockedClock() {
        var s = SelfTestSession(lighting: .normalLight, startTime: 0)
        feed(&s, from: 0, to: nominal + 0.8)                                  // locked
        s.record(frame(nominal + 0.8, .holding))                              // one frame of loss
        feed(&s, from: nominal + 0.8 + dt, to: nominal + 1.7)                 // locked again from here
        _ = s.advance(to: nominal + 1.7)
        #expect(!s.gateOpened)                                                // only about 0.87 s since the dip
        feed(&s, from: nominal + 1.7, to: nominal + 2.0)
        #expect(s.advance(to: nominal + 2.0) == [.phaseStarted(index: cover)])
    }

    @Test func framesAreFiledByTheShiftedTimeline() {
        var s = SelfTestSession(lighting: .normalLight, startTime: 0)
        feed(&s, from: 0, to: nominal + 0.5, .decaying)
        _ = s.advance(to: nominal)
        feed(&s, from: nominal + 0.5, to: nominal + 1.7)
        _ = s.advance(to: nominal + 1.7)                                      // gate opens, shift 1.7
        let waitingFrame = nominal + 1.0, inCover = nominal + 1.7 + 0.1, inUncover = nominal + 1.7 + 5.1, afterEnd = nominal + 1.7 + 9.5
        for t in [waitingFrame, inCover, inUncover, afterEnd] { s.record(frame(t)) }
        #expect(s.framesByPhase[cover - 1].contains { $0.arrival == waitingFrame })      // while waiting: filed under the turn phase
        #expect(s.framesByPhase[cover].map(\.arrival) == [inCover])                       // 0.1 s into the SHIFTED cover phase
        #expect(s.framesByPhase[uncover].map(\.arrival) == [inUncover])
        #expect(!s.framesByPhase.contains { $0.contains { $0.arrival == afterEnd } })    // after the end of the run: ignored
    }

    @Test func anUngatedScriptKeepsItsFixedTiming() {
        var s = SelfTestSession(script: script.withoutLockGates, lighting: .normalLight, startTime: 0)
        #expect(s.gateIndex == nil && !s.lossGateFailed)
        let events = s.advance(to: 1000)
        #expect(events.last == .finished && s.totalDuration == 47)
    }

    @Test func aGateThatNeverOpenedMakesTheAnalyzerReportAnInvalidLossTestWithItsReason() {
        var s = SelfTestSession(lighting: .normalLight, startTime: 100)
        var t = 100.0
        while t < 100 + nominal + 12 { s.record(frame(t, .holding)); _ = s.advance(to: t); t += dt }
        #expect(s.lossGateFailed)
        let report = SelfTestAnalyzer.analyze(s, context: testContext())
        #expect(report.loss.verdict == .invalid)
        #expect(report.loss.invalidReason?.contains("never given") == true && report.loss.invalidReason?.contains("LOCKED") == true)
        #expect(report.greenLight == .notAnswered)
    }
}
