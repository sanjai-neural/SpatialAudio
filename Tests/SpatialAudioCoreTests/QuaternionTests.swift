import Testing
import Foundation
@testable import SpatialAudioCore

@Suite struct QuaternionTests {
    @Test func identityRotatesNothing() {
        let v = Vector3(0.3, -1.2, 2)
        #expect(near(Quaternion.identity.rotate(v), v))
    }

    // Pins the sign conventions documented in EulerAngles.
    @Test func positiveYawTurnsLeft() {
        #expect(near(yawQ(90).rotate(.forward), Vector3(-1, 0, 0)))
    }

    @Test func positivePitchLooksUp() {
        #expect(near(pitchQ(90).rotate(.forward), Vector3(0, 1, 0)))
    }

    @Test func positiveRollTiltsRightEarDown() {
        let roll = Quaternion(axis: .forward, angle: 90 * deg)
        #expect(near(roll.rotate(.right), Vector3(0, -1, 0)))
        // forward axis itself is unchanged
        #expect(near(roll.rotate(.forward), .forward))
    }

    @Test func productComposesRotations() {
        let a = eulerQ(30, 20, 10), b = eulerQ(-50, 5, 40)
        let v = Vector3(1, 2, 3)
        #expect(near((a * b).rotate(v), a.rotate(b.rotate(v))))
    }

    @Test func inverseUndoesRotation() {
        let q = eulerQ(70, -25, 15)
        let v = Vector3(0.5, 0.2, -1)
        #expect(near(q.inverse().rotate(q.rotate(v)), v))
        #expect(angleDeg(q * q.inverse(), .identity) < 1e-6)
    }

    @Test func rotationPreservesLength() {
        let v = Vector3(3, -4, 12)
        #expect(abs(eulerQ(123, 40, -77).rotate(v).length - v.length) < 1e-9)
    }

    @Test func eulerRoundTrip() {
        for y in stride(from: -170.0, through: 170, by: 40) {
            for p in stride(from: -80.0, through: 80, by: 32) {
                for r in stride(from: -170.0, through: 170, by: 55) {
                    let e = eulerQ(y, p, r).euler
                    #expect(abs(e.yawDegrees - y) < 1e-6, "yaw \(y),\(p),\(r)")
                    #expect(abs(e.pitchDegrees - p) < 1e-6, "pitch \(y),\(p),\(r)")
                    #expect(abs(e.rollDegrees - r) < 1e-6, "roll \(y),\(p),\(r)")
                }
            }
        }
    }

    @Test func eulerAtGimbalLockStillRepresentsSameRotation() {
        for p in [90.0, -90.0] {
            let q = eulerQ(35, p, 20)
            let e = q.euler
            #expect(e.yaw.isFinite && e.pitch.isFinite && e.roll.isFinite)
            #expect(angleDeg(Quaternion(euler: e), q) < 1e-3)
        }
    }

    @Test func slerpEndpointsAndMidpoint() {
        let a = yawQ(0), b = yawQ(90)
        #expect(angleDeg(Quaternion.slerp(a, b, 0), a) < 1e-9)
        #expect(angleDeg(Quaternion.slerp(a, b, 1), b) < 1e-9)
        #expect(angleDeg(Quaternion.slerp(a, b, 0.5), yawQ(45)) < 1e-9)
    }

    @Test func slerpTakesShortestPathForNegatedQuaternion() {
        let a = yawQ(10)
        let b = yawQ(50)
        let bNeg = Quaternion(w: -b.w, x: -b.x, y: -b.y, z: -b.z)  // same rotation
        #expect(angleDeg(Quaternion.slerp(a, bNeg, 0.5), yawQ(30)) < 1e-9)
    }

    @Test func slerpHasConstantAngularSpeed() {
        let a = eulerQ(0, 0, 0), b = eulerQ(80, 30, -20)
        let total = angleDeg(a, b)
        for t in [0.1, 0.3, 0.7, 0.9] {
            #expect(abs(angleDeg(a, Quaternion.slerp(a, b, t)) - total * t) < 1e-6)
        }
    }

    @Test func angleBetweenYaws() {
        #expect(abs(angleDeg(yawQ(30), yawQ(80)) - 50) < 1e-9)
        // negated quaternion is the same rotation
        let q = yawQ(30)
        #expect(angleDeg(q, Quaternion(w: -q.w, x: -q.x, y: -q.y, z: -q.z)) < 1e-9)
    }

    @Test func degenerateInputsNormalizeToIdentity() {
        #expect(Quaternion(w: 0, x: 0, y: 0, z: 0).normalized() == .identity)
        #expect(Quaternion(w: .nan, x: 0, y: 0, z: 0).normalized() == .identity)
        #expect(Quaternion(axis: .zero, angle: 1) == .identity)
    }

    @Test func averageOfNearbySamples() {
        let m = Quaternion.average([yawQ(10), yawQ(20), yawQ(30)])!
        #expect(angleDeg(m, yawQ(20)) < 0.01)
        // sign-flipped sample must not cancel the others
        let q = yawQ(20)
        let flipped = Quaternion(w: -q.w, x: -q.x, y: -q.y, z: -q.z)
        #expect(angleDeg(Quaternion.average([yawQ(20), flipped])!, yawQ(20)) < 1e-9)
        #expect(Quaternion.average([]) == nil)
    }
}
