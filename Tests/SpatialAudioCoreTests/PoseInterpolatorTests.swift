import Testing
import Foundation
@testable import SpatialAudioCore

@Suite struct PoseInterpolatorTests {
    let block = 512.0 / 48_000        // one nominal audio block, about 10.7 ms

    @Test func staysNeutralUntilATargetArrives() {
        var i = PoseInterpolator()
        for _ in 0..<50 { i.advance(by: block) }
        #expect(i.current == .identity && i.target == .identity)
    }

    @Test func approachesTheTargetMonotonicallyWithoutOvershoot() {
        var i = PoseInterpolator()
        let target = eulerQ(60, 20, -15)
        i.setTarget(target)
        var previous = angleDeg(i.current, target)
        for step in 0..<200 {
            i.advance(by: block)
            let remaining = angleDeg(i.current, target)
            if previous > 1e-6 {
                #expect(remaining < previous, "step \(step) did not get closer")  // strictly closer, so never past it
            } else {
                #expect(remaining <= 1e-6, "step \(step) left the converged state")   // below the floating-point floor
            }
            previous = remaining
        }
        #expect(previous <= 1e-6)
    }

    @Test func everyStepIsExactlyTheConfiguredFractionOfTheRemainingAngle() {
        var i = PoseInterpolator()
        i.setTarget(yawQ(80))
        let alpha = 1 - exp(-block / i.config.timeConstant)
        for _ in 0..<20 {
            let before = angleDeg(i.current, i.target)
            i.advance(by: block)
            let after = angleDeg(i.current, i.target)
            if before > 4 {
                #expect(abs(after - before * (1 - alpha)) < 1e-9)                 // true slerp: exact fraction
            } else {
                // Quaternion.slerp falls back to normalized lerp below about 3.6 degrees, which is not exactly
                // constant-speed; the fraction is then right to within a tiny relative error, never overshooting.
                #expect(abs(after - before * (1 - alpha)) <= 1e-3 * before + 1e-9)
            }
        }
    }

    @Test func theTimeConstantIsTheTimeToCoverSixtyThreePercent() {
        var i = PoseInterpolator(config: .init(timeConstant: 0.050))
        i.setTarget(yawQ(40))
        i.advance(by: 0.050)
        #expect(abs(angleDeg(i.current, i.target) - 40 * exp(-1)) < 1e-9)
    }

    @Test func splittingTheTimeStepDoesNotChangeTheResult() {
        var whole = PoseInterpolator(), halves = PoseInterpolator(), irregular = PoseInterpolator()
        let target = eulerQ(70, -25, 30)
        whole.setTarget(target); halves.setTarget(target); irregular.setTarget(target)
        whole.advance(by: 0.040)
        halves.advance(by: 0.020); halves.advance(by: 0.020)
        for dt in [0.007, 0.013, 0.004, 0.016] { irregular.advance(by: dt) }
        #expect(angleDeg(whole.current, halves.current) < 1e-7)
        #expect(angleDeg(whole.current, irregular.current) < 1e-7)
    }

    @Test func takesTheShortWayRoundTheCircle() {
        var i = PoseInterpolator()
        i.reset(to: yawQ(-170))
        i.setTarget(yawQ(170))                           // only 20 degrees away through +-180
        i.advance(by: block)
        let yaw = i.current.euler.yawDegrees
        #expect(abs(yaw) > 170, "went the long way round: yaw \(yaw)")
    }

    @Test func aTargetAndItsNegationAreTheSameRotation() {
        var a = PoseInterpolator(), b = PoseInterpolator()
        let q = eulerQ(50, 10, 5)
        a.setTarget(q)
        b.setTarget(Quaternion(w: -q.w, x: -q.x, y: -q.y, z: -q.z))
        for _ in 0..<10 { a.advance(by: block); b.advance(by: block) }
        #expect(angleDeg(a.current, b.current) < 1e-9)
    }

    @Test func badTargetsAreIgnoredAndCountedNeverSnappedToNeutral() {
        var i = PoseInterpolator()
        i.setTarget(yawQ(45))
        i.advance(by: 0.5)                               // settle near +45
        let settled = i.current
        for bad in [Quaternion(w: .nan, x: 0, y: 0, z: 0), Quaternion(w: 0, x: 0, y: 0, z: 0),
                    Quaternion(w: .infinity, x: 0, y: 0, z: 0), Quaternion(w: 1e-9, x: 0, y: 0, z: 0)] {
            i.setTarget(bad)
        }
        #expect(i.rejectedTargets == 4)
        #expect(angleDeg(i.target, yawQ(45)) < 1e-9)
        i.advance(by: block)
        #expect(angleDeg(i.current, settled) < 0.01)     // it kept holding the old target, no jump toward identity
    }

    @Test func anUnnormalizedTargetIsNormalized() {
        var i = PoseInterpolator()
        let q = yawQ(30)
        i.setTarget(Quaternion(w: q.w * 5, x: q.x * 5, y: q.y * 5, z: q.z * 5))
        #expect(abs(i.target.norm - 1) < 1e-12)
        #expect(angleDeg(i.target, q) < 1e-9)
    }

    @Test func nonPositiveOrNonFiniteTimeStepsChangeNothing() {
        var i = PoseInterpolator()
        i.setTarget(yawQ(30))
        for dt in [0.0, -0.01, .nan, .infinity, -.infinity] {
            let before = i.current
            let out = i.advance(by: dt)
            #expect(out == before && i.current == before, "dt \(dt)")
        }
    }

    @Test func aZeroTimeConstantFollowsTheTargetImmediately() {
        var i = PoseInterpolator(config: .init(timeConstant: 0))
        i.setTarget(yawQ(33))
        i.advance(by: 0.001)
        #expect(angleDeg(i.current, yawQ(33)) < 1e-9)
    }

    @Test func resetJumpsBothAndFallsBackToNeutralForGarbage() {
        var i = PoseInterpolator()
        i.reset(to: yawQ(20))
        #expect(angleDeg(i.current, yawQ(20)) < 1e-9 && angleDeg(i.target, yawQ(20)) < 1e-9)
        i.reset(to: Quaternion(w: .nan, x: 0, y: 0, z: 0))
        #expect(i.current == .identity && i.target == .identity)
    }

    @Test func followsAnAbruptNewTargetWithoutAJump() {
        // A turn that starts suddenly: the first block must move only a fraction of the way.
        var i = PoseInterpolator()
        i.setTarget(yawQ(90))
        let first = angleDeg(.identity, i.advance(by: block))
        let alpha = 1 - exp(-block / i.config.timeConstant)
        #expect(abs(first - 90 * alpha) < 1e-9)
        #expect(first < 90 * 0.5)                         // well under half the turn in one block
    }
}
