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
        let leaky = yaw(steady(30, 20, 0))                                   // pitch 20° vs yaw 30°: ratio 0.67 > 0.5
        #expect(leaky.verdict == .otherAxisMoving && leaky.worstOtherAxis == .pitch)
        #expect(leaky.message.contains("Pitch") && leaky.message.contains("ONLY yaw"))
        #expect(yaw(steady(30, 14, 0)).verdict == .good)                     // ratio 0.47: below the warning
        // before the move is underway the leakage is not meaningful: just ask for more movement
        #expect(yaw(steady(8, 20, 0)).verdict == .tooSmall)
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
