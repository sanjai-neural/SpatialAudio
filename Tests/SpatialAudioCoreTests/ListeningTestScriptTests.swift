import Testing
import Foundation
@testable import SpatialAudioCore

@Suite struct ListeningTestScriptTests {
    let frame = 1.0 / 30            // the scripted publisher's step

    @Test func thereAreFiveDistinctTestsWithText() {
        #expect(ListeningTest.allCases.count == 5)
        #expect(Set(ListeningTest.allCases.map(\.id)).count == 5)
        for t in ListeningTest.allCases {
            #expect(!t.title.isEmpty && !t.whatYouShouldHear.isEmpty && t.loopDuration > 0)
        }
    }

    @Test func everyScriptLoops() {
        for test in ListeningTest.allCases {
            for t in stride(from: 0.0, to: test.loopDuration, by: 0.37) {
                let a = test.scene(at: t), b = test.scene(at: t + test.loopDuration), c = test.scene(at: t + 3 * test.loopDuration)
                #expect(angleDeg(a.headPose, b.headPose) < 1e-6 && near(a.sourcePosition, b.sourcePosition, 1e-9), "\(test) t=\(t)")
                #expect(angleDeg(a.headPose, c.headPose) < 1e-6 && near(a.sourcePosition, c.sourcePosition, 1e-9), "\(test) t=\(t)")
            }
            // negative times wrap instead of crashing or going out of range
            let n = test.scene(at: -1.0), w = test.scene(at: test.loopDuration - 1.0)
            #expect(angleDeg(n.headPose, w.headPose) < 1e-6 && near(n.sourcePosition, w.sourcePosition, 1e-9))
        }
        #expect(ListeningTest.headSweepYaw.scene(at: .nan).headPose == .identity)
    }

    @Test func theHeadNeverJumpsBetweenPublishedFrames() {
        // Largest legitimate speed: sweeps 2*pi*A/T = 31 deg/s (yaw) -> 1.05 deg per 1/30 s; holds ease with peak 1.5*45/1 s
        // = 67.5 deg/s -> 2.3 deg per frame. Allow some margin; a jump of the kind the state machine forbids would be far larger.
        for test in ListeningTest.allCases {
            var maxStep = 0.0, t = 0.0
            var prev = test.scene(at: 0).headPose
            while t < 2 * test.loopDuration {
                t += frame
                let q = test.scene(at: t).headPose
                maxStep = max(maxStep, angleDeg(prev, q))
                prev = q
            }
            #expect(maxStep < 2.6, "\(test): largest per-frame step \(maxStep) deg")
        }
    }

    @Test func sweepsStartAtNeutralAndReachTheirAmplitude() {
        func peak(_ test: ListeningTest, _ axis: KeyPath<EulerAngles, Double>) -> Double {
            stride(from: 0.0, to: test.loopDuration, by: 0.01).map { abs(test.scene(at: $0).headPose.euler[keyPath: axis]) * 180 / .pi }.max()!
        }
        for test in [ListeningTest.headSweepYaw, .headSweepPitch, .headSweepRoll, .headHoldsYaw] {
            #expect(angleDeg(test.scene(at: 0).headPose, .identity) < 1e-9, "\(test) starts neutral")
        }
        #expect(abs(peak(.headSweepYaw, \.yaw) - 60) < 0.1)
        #expect(abs(peak(.headSweepPitch, \.pitch) - 40) < 0.1)
        #expect(abs(peak(.headSweepRoll, \.roll) - 40) < 0.1)
        #expect(abs(peak(.headHoldsYaw, \.yaw) - 45) < 0.1)
    }

    @Test func theYawSweepTurnsLeftFirstAndTheToneMovesToTheRight() {
        let q = ListeningTest.headSweepYaw
        #expect(q.scene(at: 3).headPose.euler.yawDegrees > 59)                    // quarter period: head turned LEFT (yaw +)
        #expect(q.scene(at: 9).headPose.euler.yawDegrees < -59)
        #expect(abs(q.expectedDirection(at: 3).azimuthDegrees - 60) < 0.1)        // tone seems 60 degrees to the RIGHT
        #expect(abs(q.expectedDirection(at: 9).azimuthDegrees + 60) < 0.1)        // ... and to the LEFT
        #expect(abs(q.expectedDirection(at: 0).azimuthDegrees) < 1e-9)
        #expect(q.scene(at: 3).caption.contains("LEFT") && q.scene(at: 9).caption.contains("RIGHT"))
        #expect(q.scene(at: 0).caption.contains("straight ahead"))
    }

    @Test func theHoldsTestSitsOnTheRightThenOnTheLeft() {
        let q = ListeningTest.headHoldsYaw
        for t in [3.2, 4.5, 5.9] { #expect(abs(q.expectedDirection(at: t).azimuthDegrees - 45) < 0.5, "t=\(t)") }
        for t in [0.5, 1.9, 7.5, 8.9] { #expect(abs(q.expectedDirection(at: t).azimuthDegrees) < 0.5, "t=\(t)") }
        for t in [10.2, 11.5, 12.9] { #expect(abs(q.expectedDirection(at: t).azimuthDegrees + 45) < 0.5, "t=\(t)") }
    }

    @Test func theSourceSidesTestKeepsTheHeadStillAndMovesTheTone() {
        let q = ListeningTest.sourceSides
        for t in [0.0, 1.5, 2.99] { #expect(abs(q.expectedDirection(at: t).azimuthDegrees + 90) < 1e-9, "left at \(t)") }
        for t in [3.0, 4.5, 5.99] { #expect(abs(q.expectedDirection(at: t).azimuthDegrees - 90) < 1e-9, "right at \(t)") }
        for t in [6.0, 7.5, 8.99] { #expect(abs(q.expectedDirection(at: t).azimuthDegrees) < 1e-9, "ahead at \(t)") }
        for t in stride(from: 0.0, to: 9.0, by: 0.5) { #expect(q.scene(at: t).headPose == .identity) }
        #expect(q.scene(at: 1).caption.contains("hard LEFT"))
        #expect(q.scene(at: 4).caption.contains("hard RIGHT"))
        #expect(q.scene(at: 7).caption.contains("AHEAD"))
    }

    @Test func lookingUpMakesTheToneSeemLowerAndTiltingTheRightEarMakesItRise() {
        let pitch = ListeningTest.headSweepPitch
        #expect(abs(pitch.expectedDirection(at: 3).elevationDegrees + 40) < 0.1)  // head up 40 -> tone 40 below
        #expect(abs(pitch.expectedDirection(at: 9).elevationDegrees - 40) < 0.1)
        #expect(abs(pitch.expectedDirection(at: 3).azimuthDegrees) < 1e-6)
        #expect(pitch.scene(at: 3).caption.contains("UP") && pitch.scene(at: 9).caption.contains("DOWN"))

        let roll = ListeningTest.headSweepRoll
        #expect(roll.expectedDirection(at: 3).elevationDegrees > 25)              // right ear down -> a right-side tone rises
        #expect(roll.expectedDirection(at: 9).elevationDegrees < -25)
        #expect(roll.scene(at: 3).caption.contains("RIGHT ear down") && roll.scene(at: 9).caption.contains("LEFT ear down"))
    }

    @Test func theToneIsAlwaysAFixedTwoMetersFromTheListener() {
        for test in ListeningTest.allCases {
            for t in stride(from: 0.0, to: test.loopDuration, by: 0.5) {
                #expect(abs(test.scene(at: t).sourcePosition.length - ListeningTest.sourceDistance) < 1e-9)
            }
        }
    }

    @Test func headTestsKeepTheToneStillInTheRoom() {
        for test in [ListeningTest.headSweepYaw, .headHoldsYaw, .headSweepPitch, .headSweepRoll] {
            let first = test.scene(at: 0).sourcePosition
            for t in stride(from: 0.0, to: test.loopDuration, by: 0.25) {
                #expect(near(test.scene(at: t).sourcePosition, first, 1e-12), "\(test) moved the tone at \(t)")
            }
        }
    }
}
