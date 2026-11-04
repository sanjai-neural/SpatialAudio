import Testing
@testable import SpatialAudioCore

@Suite struct TrackingQualityTests {
    let dt = 1.0 / 30
    let goodBox = NormalizedRect(x: 0.3, y: 0.25, width: 0.3, height: 0.45)

    func face(box: NormalizedRect? = nil, yaw: Double = 0, conf: Double = 1) -> FaceMeasurement {
        FaceMeasurement(angles: VisionFaceAngles(yaw: yaw * deg, pitch: 0, roll: 0),
                        confidence: conf, boundingBox: box ?? goodBox)
    }

    /// Feeds `count` identical good frames and returns the last breakdown.
    @discardableResult
    func warm(_ e: inout TrackingQualityEstimator, frames count: Int = 10, from t0: Double = 0) -> QualityBreakdown {
        var q = QualityBreakdown.absent(reason: "")
        for i in 0..<count { q = e.update(time: t0 + Double(i) * dt, face: face()) }
        return q
    }

    @Test func goodFrameScoresOneWithNoLimitingFactor() {
        var e = TrackingQualityEstimator()
        let q = warm(&e)
        #expect(q.overall == 1 && q.limiting == "none" && q.facePresent)
        #expect(abs(q.framesPerSecond - 30) < 0.01)
    }

    @Test func noFaceScoresZero() {
        var e = TrackingQualityEstimator()
        let q = e.update(time: 0, face: nil)
        #expect(q.overall == 0 && !q.facePresent && q.limiting == "no face")
    }

    @Test func smallFaceIsPenalizedLinearly() {
        var e = TrackingQualityEstimator()
        let tiny = e.update(time: 0, face: face(box: NormalizedRect(x: 0.4, y: 0.4, width: 0.04, height: 0.05)))
        #expect(tiny.size == 0 && tiny.overall == 0 && tiny.limiting == "size")
        var e2 = TrackingQualityEstimator()
        let mid = e2.update(time: 0, face: face(box: NormalizedRect(x: 0.4, y: 0.4, width: 0.1, height: 0.15)))
        #expect(abs(mid.size - 0.5) < 1e-9)         // ramp 0.10 -> 0.20 at 0.15
    }

    @Test func faceCroppedAtFrameEdgeIsPenalized() {
        var e = TrackingQualityEstimator()
        let cropped = e.update(time: 0, face: face(box: NormalizedRect(x: 0.0, y: 0.25, width: 0.3, height: 0.45)))
        #expect(cropped.edge == 0 && cropped.limiting == "edge")
        var e2 = TrackingQualityEstimator()
        let near = e2.update(time: 0, face: face(box: NormalizedRect(x: 0.015, y: 0.25, width: 0.3, height: 0.45)))
        #expect(abs(near.edge - 0.5) < 1e-9)
    }

    @Test func implausibleBoxJumpIsPenalizedThenAcceptedIfItPersists() {
        var e = TrackingQualityEstimator()
        warm(&e)
        let jumped = NormalizedRect(x: 0.3 + 0.7 * 0.45, y: 0.25, width: 0.3, height: 0.45)   // 0.7 face sizes
        let q1 = e.update(time: 10 * dt, face: face(box: jumped))
        #expect(abs(q1.centerStability - 0.5) < 1e-9 && q1.limiting == "center jump")
        let q2 = e.update(time: 11 * dt, face: face(box: jumped))          // stayed there: now consistent
        #expect(q2.centerStability == 1 && q2.overall == 1)
    }

    @Test func suddenScaleChangeIsPenalized() {
        var e = TrackingQualityEstimator()
        warm(&e)
        let grown = NormalizedRect(x: 0.3, y: 0.25, width: 0.3, height: 0.45 * 1.35)
        let q = e.update(time: 10 * dt, face: face(box: grown))
        #expect(abs(q.scaleStability - 0.5) < 1e-9)
    }

    @Test func implausibleAngularSpeedIsPenalized() {
        var e = TrackingQualityEstimator()
        warm(&e)
        let q = e.update(time: 10 * dt, face: face(yaw: 45))               // 45° in 1/30 s = 1350°/s
        #expect(abs(q.angularStability - 0.5) < 1e-6 && q.limiting == "angular speed")
        var e2 = TrackingQualityEstimator()
        warm(&e2)
        #expect(e2.update(time: 10 * dt, face: face(yaw: 20)).angularStability == 1)   // 600°/s is fine
    }

    @Test func lowFrameRateIsPenalized() {
        var e = TrackingQualityEstimator()
        var q = QualityBreakdown.absent(reason: "")
        for i in 0..<30 { q = e.update(time: Double(i) * 0.1, face: face()) }      // 10 fps
        #expect(abs(q.frameRate - (10.0 - 8) / (20.0 - 8)) < 1e-6 && q.limiting == "frame rate")
    }

    @Test func lowVisionConfidenceIsPenalizedButTypicalValuesAreNot() {
        var e = TrackingQualityEstimator()
        #expect(e.update(time: 0, face: face(conf: 0.88)).visionConfidence == 1)     // value seen in the manual test
        var e2 = TrackingQualityEstimator()
        let q = e2.update(time: 0, face: face(conf: 0.45))
        #expect(abs(q.visionConfidence - 0.5) < 1e-9 && q.limiting == "vision confidence")
    }

    @Test func longGapResetsContinuityAndFrameRate() {
        var e = TrackingQualityEstimator()
        warm(&e)
        // 2 s later the face is somewhere else: not a "jump", just a new acquisition.
        let far = NormalizedRect(x: 0.6, y: 0.25, width: 0.3, height: 0.45)
        let q = e.update(time: 2.0, face: face(box: far, yaw: 80))
        #expect(q.centerStability == 1 && q.angularStability == 1 && q.overall == 1)
    }

    @Test func faceLossResetsContinuity() {
        var e = TrackingQualityEstimator()
        warm(&e)
        _ = e.update(time: 10 * dt, face: nil)
        let far = NormalizedRect(x: 0.55, y: 0.25, width: 0.3, height: 0.45)
        #expect(e.update(time: 11 * dt, face: face(box: far)).overall == 1)
    }

    @Test func noteGapResetsLikeALongGap() {
        var e = TrackingQualityEstimator()
        warm(&e)
        e.noteGap()
        #expect(e.framesPerSecond == 0)
        let far = NormalizedRect(x: 0.55, y: 0.25, width: 0.3, height: 0.45)
        #expect(e.update(time: 10 * dt, face: face(box: far, yaw: 60)).overall == 1)
    }

    @Test func overallIsTheWeakestComponent() {
        var e = TrackingQualityEstimator()
        // size 0.5 (h = 0.15) and vision confidence 0.5 together: overall is the min, 0.5.
        let q = e.update(time: 0, face: face(box: NormalizedRect(x: 0.4, y: 0.4, width: 0.1, height: 0.15), conf: 0.45))
        #expect(abs(q.overall - 0.5) < 1e-9)
    }

    @Test func rampWorksForEitherOrdering() {
        #expect(abs(TrackingQualityEstimator.ramp(0.15, zero: 0.1, full: 0.2) - 0.5) < 1e-9)
        #expect(abs(TrackingQualityEstimator.ramp(0.7, zero: 1.0, full: 0.4) - 0.5) < 1e-9)
        #expect(TrackingQualityEstimator.ramp(5, zero: 1.0, full: 0.4) == 0)
        #expect(TrackingQualityEstimator.ramp(-5, zero: 1.0, full: 0.4) == 1)
        #expect(TrackingQualityEstimator.ramp(.nan, zero: 0, full: 1) == 0)
    }

    @Test func nonFiniteAnglesCountAsNoFace() {
        var e = TrackingQualityEstimator()
        let bad = FaceMeasurement(angles: VisionFaceAngles(yaw: .nan, pitch: 0, roll: 0), confidence: 1, boundingBox: goodBox)
        #expect(e.update(time: 0, face: bad).overall == 0)
    }

    @Test func normalizedRectGeometry() {
        let r = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.5)
        #expect(abs(r.area - 0.15) < 1e-12 && abs(r.centerX - 0.25) < 1e-12 && abs(r.centerY - 0.45) < 1e-12)
        #expect(r.size == 0.5 && abs(r.edgeMargin - 0.1) < 1e-12)
        #expect(NormalizedRect(x: 0.8, y: 0.1, width: 0.3, height: 0.2).edgeMargin < 0)     // sticks out
    }
}
