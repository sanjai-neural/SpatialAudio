import Testing
@testable import SpatialAudioCore

@Suite struct HeadAngleMappingTests {
    let m = HeadAngleMapping()
    func angles(_ y: Double, _ p: Double, _ r: Double) -> VisionFaceAngles {
        VisionFaceAngles(yaw: y * deg, pitch: p * deg, roll: r * deg)
    }

    @Test func zeroAnglesGiveIdentity() {
        #expect(angleDeg(m.orientation(from: angles(0, 0, 0), frameMirrored: false), .identity) < 1e-9)
    }

    @Test func visionPitchDownBecomesNegativePitch() {
        // Header: Vision positive pitch = nodding down. Ours: positive = up.
        let e = m.euler(from: angles(0, 20, 0), frameMirrored: false)
        #expect(abs(e.pitchDegrees - (-20)) < 1e-9)
        // and the resulting head forward vector points downward
        #expect(m.orientation(from: angles(0, 20, 0), frameMirrored: false).rotate(.forward).y < 0)
    }

    @Test func yawPassesThroughWhenUnmirrored() {
        #expect(abs(m.euler(from: angles(30, 0, 0), frameMirrored: false).yawDegrees - 30) < 1e-9)
    }

    @Test func rollPassesThroughWhenUnmirrored() {
        #expect(abs(m.euler(from: angles(0, 0, 15), frameMirrored: false).rollDegrees - 15) < 1e-9)
    }

    @Test func mirroringFlipsYawAndRollButNotPitch() {
        let a = angles(30, 10, 15)
        let plain = m.euler(from: a, frameMirrored: false)
        let mirrored = m.euler(from: a, frameMirrored: true)
        #expect(abs(mirrored.yaw + plain.yaw) < 1e-12)
        #expect(abs(mirrored.roll + plain.roll) < 1e-12)
        #expect(abs(mirrored.pitch - plain.pitch) < 1e-12)
    }

    @Test func invertFlagsFlipOnlyTheirAxis() {
        let a = angles(30, 10, 15)
        let base = m.euler(from: a, frameMirrored: false)
        let y = HeadAngleMapping(invertYaw: true).euler(from: a, frameMirrored: false)
        let p = HeadAngleMapping(invertPitch: true).euler(from: a, frameMirrored: false)
        let r = HeadAngleMapping(invertRoll: true).euler(from: a, frameMirrored: false)
        #expect(y.yaw == -base.yaw && y.pitch == base.pitch && y.roll == base.roll)
        #expect(p.pitch == -base.pitch && p.yaw == base.yaw && p.roll == base.roll)
        #expect(r.roll == -base.roll && r.yaw == base.yaw && r.pitch == base.pitch)
    }

    @Test func mirrorAndInvertCancel() {
        let a = angles(25, 5, -10)
        let x = HeadAngleMapping(invertYaw: true, invertRoll: true).euler(from: a, frameMirrored: true)
        let y = m.euler(from: a, frameMirrored: false)
        #expect(abs(x.yaw - y.yaw) < 1e-12 && abs(x.roll - y.roll) < 1e-12)
    }

    @Test func resultingQuaternionRoundTripsThroughEuler() {
        let a = angles(40, -15, 20)
        let e = m.orientation(from: a, frameMirrored: false).euler
        #expect(abs(e.yawDegrees - 40) < 1e-6)
        #expect(abs(e.pitchDegrees - 15) < 1e-6)     // pitch negated
        #expect(abs(e.rollDegrees - 20) < 1e-6)
    }

    @Test func nonFiniteAnglesAreDetectable() {
        #expect(!VisionFaceAngles(yaw: .nan, pitch: 0, roll: 0).isFinite)
        #expect(angles(1, 2, 3).isFinite)
    }
}
