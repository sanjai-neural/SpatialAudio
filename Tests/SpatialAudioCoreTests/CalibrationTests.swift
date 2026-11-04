import Testing
@testable import SpatialAudioCore

@Suite struct CalibrationTests {
    @Test func defaultCalibrationIsNoOp() {
        let q = eulerQ(30, 10, 5)
        #expect(angleDeg(Calibration().apply(q), q) < 1e-9)
    }

    @Test func neutralMapsToIdentity() {
        let n = eulerQ(30, 20, 10)
        #expect(angleDeg(Calibration(neutral: n).apply(n), .identity) < 1e-9)
    }

    @Test func yawOnlyDifferenceIsSubtracted() {
        let c = Calibration(neutral: yawQ(20))
        #expect(angleDeg(c.apply(yawQ(50)), yawQ(30)) < 1e-9)
        #expect(angleDeg(c.apply(yawQ(-10)), yawQ(-30)) < 1e-9)
    }

    @Test func neutralTimesCalibratedRecoversRaw() {
        // Non-commuting rotations: checks multiplication order, not just yaw arithmetic.
        let neutral = eulerQ(30, 20, 10)
        let raw = eulerQ(50, -10, 25)
        let c = Calibration(neutral: neutral)
        #expect(angleDeg(neutral * c.apply(raw), raw) < 1e-9)
    }

    @Test func setNeutralAveragingSamples() {
        var c = Calibration()
        let ok = c.setNeutral(averaging: [yawQ(8), yawQ(10), yawQ(12)])
        #expect(ok)
        #expect(angleDeg(c.neutral, yawQ(10)) < 0.01)
    }

    @Test func averagingEmptyLeavesNeutralUnchanged() {
        var c = Calibration(neutral: yawQ(5))
        let ok = c.setNeutral(averaging: [])
        #expect(!ok)
        #expect(angleDeg(c.neutral, yawQ(5)) < 1e-9)
    }

    @Test func resetReturnsToIdentity() {
        var c = Calibration(neutral: yawQ(40))
        c.reset()
        #expect(c.neutral == .identity)
    }

    @Test func unnormalizedNeutralIsNormalized() {
        let q = yawQ(30)
        let big = Quaternion(w: q.w * 3, x: q.x * 3, y: q.y * 3, z: q.z * 3)
        #expect(abs(Calibration(neutral: big).neutral.norm - 1) < 1e-12)
    }
}
