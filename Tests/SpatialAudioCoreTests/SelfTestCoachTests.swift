import Testing
import Foundation
@testable import SpatialAudioCore

private let d2r = Double.pi / 180
private func angles(_ yaw: Double, _ pitch: Double = 0, _ roll: Double = 0) -> VisionFaceAngles {
    VisionFaceAngles(yaw: yaw * d2r, pitch: pitch * d2r, roll: roll * d2r)
}
private func steady(_ yaw: Double, _ pitch: Double = 0, _ roll: Double = 0, n: Int = 10) -> [VisionFaceAngles] {
    Array(repeating: angles(yaw, pitch, roll), count: n)
}

@Suite struct HoldCoachTests {
    let c = CoachConfig()
    let reference = steady(0)

    func yaw(_ recent: [VisionFaceAngles]) -> CoachFeedback {
        SelfTestCoach.hold(axis: .yaw, target: 30, reference: reference, recent: recent, config: c)
    }

    @Test func targetsAreTheCoachedMoveSizes() {
        #expect(SelfTestMove.turnLeft.targetDegrees == 30 && SelfTestMove.lookUp.targetDegrees == 20 && SelfTestMove.tiltRightEar.targetDegrees == 20)
    }

    @Test func tooSmallGoodAndTooFarFollowTheTargetBands() {
        #expect(yaw(steady(10)).verdict == .tooSmall)                        // 10° of 30°
        #expect(yaw(steady(20)).verdict == .tooSmall)                        // 0.67 of target: just under the good band
        #expect(yaw(steady(21)).verdict == .good)                            // 0.70
        #expect(yaw(steady(30)).verdict == .good)
        #expect(yaw(steady(45)).verdict == .good)                            // 1.50: still good
        #expect(yaw(steady(46)).verdict == .tooFar)
        #expect(yaw(steady(60)).verdict == .tooFar)                          // the real runs turned 53-63°
        #expect(yaw(steady(-30)).verdict == .good)                           // direction is not judged (the test must not know it)
    }

    @Test func anotherAxisMovingIsCalledOutOnceTheMainMoveIsUnderway() {
        let leaky = yaw(steady(30, 20, 0))                                   // pitch 20° vs yaw 30°: ratio 0.67 > 0.5, and 20° > 15°
        #expect(leaky.verdict == .otherAxisMoving && leaky.worstOtherAxis == .pitch)
        #expect(leaky.message.contains("nodding") && leaky.message.contains("just turning it"))
        #expect(yaw(steady(30, 14, 0)).verdict == .good)                     // ratio 0.47 and 14° < 15°: below both warnings
        // Step 2e: the ABSOLUTE limit speaks even before the move is underway (it used to say "a bit more" here) ...
        #expect(yaw(steady(8, 20, 0)).verdict == .otherAxisMoving)
        // ... while a small leak before the move is underway is still not a warning (the ratio rule needs a move to compare with).
        #expect(yaw(steady(8, 12, 0)).verdict == .tooSmall)
        // and it outranks "too far": fix the axis problem first
        #expect(yaw(steady(60, 50, 0)).verdict == .otherAxisMoving)
    }

    @Test func rollLeakageIsReportedToo() {
        let r = SelfTestCoach.hold(axis: .yaw, target: 30, reference: reference, recent: steady(30, 0, 25), config: c)
        #expect(r.verdict == .otherAxisMoving && r.worstOtherAxis == .roll)
    }

    @Test func deviationsAreAbsoluteMediansRelativeToTheReference() throws {
        let ref = steady(5, -10, 2)
        let r = SelfTestCoach.hold(axis: .pitch, target: 20, reference: ref, recent: steady(7, -30, 3), config: c)
        let d = try #require(r.deviationDegrees)
        #expect(abs(d.yaw - 2) < 1e-9 && abs(d.pitch - 20) < 1e-9 && abs(d.roll - 1) < 1e-9)
        #expect(r.verdict == .good && r.instructedAxis == .pitch && r.targetDegrees == 20)
    }

    @Test func aSingleOutlierDoesNotMoveTheLiveValueBecauseItIsAMedian() {
        var recent = steady(30, n: 9)
        recent.append(angles(120))
        #expect(yaw(recent).verdict == .good)
    }

    @Test func tooFewSamplesOrNoReferenceMeansWeCannotSeeYou() {
        #expect(yaw(steady(30, n: 3)).verdict == .noFace)
        #expect(yaw([]).verdict == .noFace)
        #expect(SelfTestCoach.hold(axis: .yaw, target: 30, reference: [], recent: steady(30), config: c).verdict == .noFace)
    }
}

@Suite struct OtherAxisLimitTests {
    let c = CoachConfig()

    func feedback(_ axis: RotationAxis, target: Double = 30, reference: [VisionFaceAngles] = steady(0),
                  recent: [VisionFaceAngles], config: CoachConfig = CoachConfig()) -> CoachFeedback {
        SelfTestCoach.hold(axis: axis, target: target, reference: reference, recent: recent, config: config)
    }

    @Test func theLimitIsAPlaceholderOfFifteenDegrees() {
        #expect(c.otherAxisLimitDegrees == 15)
    }

    @Test func aWrongAxisOverTheLimitIsFlaggedBeforeTheInstructedAxisHasMovedAtAll() {
        let f = feedback(.yaw, recent: steady(0, 16, 0))                     // nothing turned yet, but the head is nodding 16°
        #expect(f.verdict == .otherAxisMoving && f.worstOtherAxis == .pitch && f.flaggedAxes == [.pitch])
        let roll = feedback(.roll, target: 20, recent: steady(18, 0, 0))                     // tilting not started, head turning 18°
        #expect(roll.verdict == .otherAxisMoving && roll.worstOtherAxis == .yaw && roll.flaggedAxes == [.yaw])
    }

    @Test func theLimitIsStrictlyGreaterThanAndTheInstructedAxisIsNeverItsOwnWrongAxis() throws {
        // 15° goes through degrees -> radians -> degrees and may come back as 14.999999999999998, so the boundary is tested
        // against the deviation the coach itself computed: a limit EXACTLY equal to it does not flag, the next value down does.
        let recent = steady(0, 15, 0)
        let measured = try #require(feedback(.yaw, recent: recent).deviationDegrees).pitch
        #expect(abs(measured - 15) < 1e-9)
        var atLimit = CoachConfig(); atLimit.otherAxisLimitDegrees = measured
        #expect(feedback(.yaw, recent: recent, config: atLimit).verdict == .tooSmall)                 // exactly at the limit: not over
        atLimit.otherAxisLimitDegrees = measured.nextDown
        #expect(feedback(.yaw, recent: recent, config: atLimit).verdict == .otherAxisMoving)         // a hair over: flagged
        #expect(feedback(.yaw, recent: steady(0, 15.1, 0)).verdict == .otherAxisMoving)
        #expect(feedback(.yaw, recent: steady(80, 0, 0)).flaggedAxes.isEmpty)           // 80° of the instructed axis is "too far", not a leak
    }

    @Test func theRealRollRunWouldHaveBeenCalledOut() throws {
        // The 14:58 real report, roll holds: raw yaw -60.2° and pitch +27.2° against a reference of yaw -2.4°, pitch +0.4°,
        // roll +1.8°, while roll moved to -1.9° (3.7° of tilt). The old rule stayed silent ("A bit more: 4° so far").
        let f = feedback(.roll, target: 20, reference: steady(-2.4, 0.4, 1.8), recent: steady(-60.2, 27.2, -1.9))
        #expect(f.verdict == .otherAxisMoving && f.worstOtherAxis == .yaw)
        #expect(f.flaggedAxes == [.yaw, .pitch])
        #expect(f.message.contains("turning your head (58°)") && f.message.contains("instead of just tilting it"))
        #expect(f.message.contains("right ear toward your right shoulder"))
        let d = try #require(f.deviationDegrees)
        #expect(abs(d.yaw - 57.8) < 1e-9 && abs(d.pitch - 26.8) < 1e-9 && abs(d.roll - 3.7) < 1e-9)
    }

    @Test func theWrongMotionIsNamedForAllSixAxisPairs() {
        let cases: [(RotationAxis, RotationAxis, String, String)] = [
            (.roll, .yaw, "turning your head", "just tilting it"),
            (.roll, .pitch, "nodding", "just tilting it"),
            (.yaw, .pitch, "nodding", "just turning it"),
            (.yaw, .roll, "tilting your head sideways", "just turning it"),
            (.pitch, .yaw, "turning your head", "just tipping it back"),
            (.pitch, .roll, "tilting your head sideways", "just tipping it back"),
        ]
        for (instructed, wrong, doing, instead) in cases {
            let recent = steady(wrong == .yaw ? 20 : 0, wrong == .pitch ? 20 : 0, wrong == .roll ? 20 : 0)
            let f = feedback(instructed, target: 20, recent: recent)
            #expect(f.verdict == .otherAxisMoving && f.worstOtherAxis == wrong, "\(instructed)/\(wrong)")
            #expect(f.message.contains("You are \(doing) (20°)") && f.message.contains("instead of \(instead)"), "\(instructed)/\(wrong): \(f.message)")
        }
    }

    @Test func onlyTheAxesOverTheirLimitAreFlaggedAndTheWorstIsNamed() {
        let one = feedback(.roll, target: 20, recent: steady(20, 10, 0))
        #expect(one.flaggedAxes == [.yaw] && one.worstOtherAxis == .yaw)
        let two = feedback(.roll, target: 20, recent: steady(20, 18, 0))
        #expect(two.flaggedAxes == [.yaw, .pitch] && two.worstOtherAxis == .yaw)
        let swapped = feedback(.roll, target: 20, recent: steady(17, 25, 0))
        #expect(swapped.flaggedAxes == [.yaw, .pitch] && swapped.worstOtherAxis == .pitch && swapped.message.contains("nodding"))
    }

    @Test func theRatioRuleStillWorksBelowTheAbsoluteLimit() {
        // yaw 20° of 30° is underway (≥ 15°); pitch 11° is more than half of 20° but under 15°.
        let f = feedback(.yaw, recent: steady(20, 11, 0))
        #expect(f.verdict == .otherAxisMoving && f.flaggedAxes == [.pitch])
        #expect(feedback(.yaw, recent: steady(20, 10, 0)).verdict == .tooSmall)         // exactly half: not more than half
        // not underway yet: the ratio rule is silent
        #expect(feedback(.yaw, recent: steady(10, 6, 0)).verdict == .tooSmall)
    }

    @Test func theLimitComesFromTheConfiguration() {
        var wide = CoachConfig(); wide.otherAxisLimitDegrees = 40
        #expect(feedback(.yaw, recent: steady(0, 30, 0), config: wide).verdict == .tooSmall)
        #expect(feedback(.yaw, recent: steady(0, 30, 0)).verdict == .otherAxisMoving)
        var tight = CoachConfig(); tight.otherAxisLimitDegrees = 5
        #expect(feedback(.yaw, recent: steady(0, 6, 0), config: tight).verdict == .otherAxisMoving)
    }

    @Test func otherVerdictsFlagNothing() {
        for recent in [steady(30), steady(10), steady(60), steady(30, 14, 0)] {
            let f = feedback(.yaw, recent: recent)
            #expect(f.verdict != .otherAxisMoving && f.flaggedAxes.isEmpty, "\(f.verdict)")
        }
        #expect(feedback(.yaw, recent: steady(30, n: 2)).flaggedAxes.isEmpty)           // no face
    }

    @Test func aCleanTiltIsGoodAndASingleOutlierDoesNotTriggerTheWarning() {
        #expect(feedback(.roll, target: 20, recent: steady(3, 2, 20)).verdict == .good)
        var recent = steady(0, 0, 20, n: 9)
        recent.append(angles(90, 90, 20))                                              // one wild frame: the median ignores it
        #expect(feedback(.roll, target: 20, recent: recent).verdict == .good)
    }
}

@Suite struct RestCoachTests {
    let c = CoachConfig()

    @Test func aStillHeadAtTheStartingPoseIsSteady() {
        #expect(SelfTestCoach.rest(reference: steady(1, -11, -3), recent: steady(2, -11, -3), config: c).verdict == .steady)
    }

    @Test func aHeadThatIsStillMovingIsToldToHoldStill() {
        // A head in motion sweeps through intermediate angles: a drift of 14° over the last half second, or a ±8° swing.
        let drift = (0..<15).map { angles(Double($0)) }
        let swing = (0..<15).map { angles(8 * sin(Double($0) * 0.9)) }
        #expect(SelfTestCoach.rest(reference: steady(0), recent: drift, config: c).verdict == .stillMoving)
        #expect(SelfTestCoach.rest(reference: steady(0), recent: swing, config: c).verdict == .stillMoving)
        // Normal tracking jitter of a quiet head is not "moving".
        let jitter = (0..<15).map { angles(0.6 * sin(Double($0) * 2.1)) }
        #expect(SelfTestCoach.rest(reference: steady(0), recent: jitter, config: c).verdict == .steady)
    }

    @Test func aHeadThatIsStillButNotBackAtTheCentreIsToldSo() {
        let r = SelfTestCoach.rest(reference: steady(0), recent: steady(14), config: c)
        #expect(r.verdict == .notCentered && r.message.contains("14"))
    }

    @Test func withoutAReferenceOnlyStillnessIsJudged() {
        #expect(SelfTestCoach.rest(reference: [], recent: steady(40), config: c).verdict == .steady)
        #expect(SelfTestCoach.rest(reference: [], recent: [], config: c).verdict == .noFace)
    }
}

@Suite struct SessionCoachTests {
    let dt = 1.0 / 30
    let script = SelfTestScript.standard.withoutLockGates

    func add(_ s: inout SelfTestSession, from a: Double, to b: Double, yaw: Double, pitch: Double = 0, roll: Double = 0) {
        var t = a
        while t < b - 1e-9 {
            s.record(SelfTestFrame(arrival: t, captureTime: t, angles: angles(yaw, pitch, roll), frameMirrored: false, state: .locked,
                                   pose: .identity, qualityOverall: 1, deliveryLatency: 0, visionDuration: 0, totalLatency: 0))
            t += dt
        }
    }

    @Test func noFeedbackWhereNoneIsNeeded() {
        let s = SelfTestSession(script: script, lighting: .normalLight, startTime: 0)
        #expect(SelfTestCoach.feedback(session: s, now: 1) == nil)             // get ready
        #expect(SelfTestCoach.feedback(session: s, now: script.starts[script.firstIndex(of: .cover)!] + 1) == nil)
        #expect(SelfTestCoach.feedback(session: s, now: 1000) == nil)
    }

    @Test func duringAHoldTheReferenceIsTheBaselineAndTheLiveValueTheLastFewFrames() throws {
        var s = SelfTestSession(script: script, lighting: .normalLight, startTime: 0)
        add(&s, from: 3, to: 5, yaw: 2)                                        // baseline phase (3-5 s): looking ahead at yaw 2°
        let hold1 = script.starts[2]                                          // 5 s: first "turn left" hold
        add(&s, from: hold1, to: hold1 + 0.2, yaw: 12)                        // started moving
        let early = try #require(SelfTestCoach.feedback(session: s, now: hold1 + 0.2))
        #expect(early.verdict == .tooSmall && early.instructedAxis == .yaw && early.targetDegrees == 30)
        add(&s, from: hold1 + 0.2, to: hold1 + 1.5, yaw: 33)                  // 31° from the baseline
        let later = try #require(SelfTestCoach.feedback(session: s, now: hold1 + 1.5))
        #expect(later.verdict == .good)
        add(&s, from: hold1 + 1.5, to: hold1 + 2.5, yaw: 66)                  // overshoot
        #expect(try #require(SelfTestCoach.feedback(session: s, now: hold1 + 2.5)).verdict == .tooFar)
    }

    @Test func theLossTurnIsCoachedTowardTwentyFiveDegreesOfYaw() throws {
        var s = SelfTestSession(script: script, lighting: .normalLight, startTime: 0)
        let turn = script.firstIndex(of: .lossTurn)!
        let lastRest = turn - 1
        add(&s, from: script.starts[lastRest], to: script.starts[turn], yaw: 0)
        add(&s, from: script.starts[turn], to: script.starts[turn] + 1.5, yaw: 58)           // the 08:12 run held about 59°
        let f = try #require(SelfTestCoach.feedback(session: s, now: script.starts[turn] + 1.5))
        #expect(f.verdict == .tooFar && f.targetDegrees == 25)
    }

    @Test func aRollHoldThatIsReallyATurnAndANodIsCalledOutThroughTheSession() throws {
        // Numbers modelled on the 14:58 real report's roll holds (see docs/STATUS.md, Step 2e findings).
        var s = SelfTestSession(script: script, lighting: .normalLight, startTime: 0)
        let hold = try #require(script.phases.firstIndex { $0.move == .tiltRightEar && $0.repetition == 1 })
        add(&s, from: script.starts[hold - 1], to: script.starts[hold], yaw: -2.4, pitch: 0.4, roll: 1.8)        // the rest before: the reference
        add(&s, from: script.starts[hold], to: script.starts[hold] + 1.5, yaw: -60.2, pitch: 27.2, roll: -1.9)
        let f = try #require(SelfTestCoach.feedback(session: s, now: script.starts[hold] + 1.5))
        #expect(f.verdict == .otherAxisMoving && f.instructedAxis == .roll && f.targetDegrees == 20)
        #expect(f.worstOtherAxis == .yaw && f.flaggedAxes == [.yaw, .pitch])
        #expect(f.message.contains("turning your head") && f.message.contains("just tilting it"))
    }

    @Test func restPhasesAreCoachedForStillnessAgainstTheBaseline() throws {
        var s = SelfTestSession(script: script, lighting: .normalLight, startTime: 0)
        add(&s, from: 3, to: 5, yaw: 0)
        let rest1 = script.firstIndex(of: .rest)!
        add(&s, from: script.starts[rest1], to: script.starts[rest1] + 1.2, yaw: 0)
        #expect(try #require(SelfTestCoach.feedback(session: s, now: script.starts[rest1] + 1.2)).verdict == .steady)
        add(&s, from: script.starts[rest1] + 1.2, to: script.starts[rest1] + 1.9, yaw: 20)
        #expect(try #require(SelfTestCoach.feedback(session: s, now: script.starts[rest1] + 1.9)).verdict == .notCentered)
    }
}
