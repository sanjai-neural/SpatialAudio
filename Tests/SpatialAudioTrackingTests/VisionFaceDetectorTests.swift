import Testing
import CoreVideo
import Vision
import SpatialAudioCore
@testable import SpatialAudioTracking

/// These tests exercise our Vision wrapper without a camera. They do NOT prove face-pose quality:
/// no real face image is used. That is verified manually with the camera (see docs/STATUS.md).
@Suite struct VisionFaceDetectorTests {
    @Test func usesRevision3() {
        #expect(VisionFaceDetector.revisionInUse == 3)
        #expect(VNDetectFaceRectanglesRequest.supportedRevisions.contains(3))
    }

    @Test func blankFrameYieldsNoFaceAndNoError() throws {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA, nil, &pb)
        let r = try VisionFaceDetector().detect(in: try #require(pb))
        #expect(r.facesDetected == 0)
        #expect(r.largest == nil)
    }

    // VNFaceObservation's factory (documented in the SDK header) lets us feed known angles through
    // our extraction code.
    @Test func extractsAnglesInRadiansFromObservation() throws {
        let o = VNFaceObservation(requestRevision: 3, boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.5),
                                  roll: 0.2, yaw: -0.3, pitch: 0.1)
        let m = try #require(VisionFaceDetector.measurement(from: o))
        #expect(abs(m.angles.yaw - (-0.3)) < 1e-6)
        #expect(abs(m.angles.pitch - 0.1) < 1e-6)
        #expect(abs(m.angles.roll - 0.2) < 1e-6)
        #expect(abs(m.boundingBoxArea - 0.2) < 1e-6)
        #expect(abs(m.boundingBox.x - 0.2) < 1e-6 && abs(m.boundingBox.height - 0.5) < 1e-6)
        #expect(m.confidence == 1.0)    // header: observations created this way have confidence 1.0
    }

    @Test func missingPitchMeansNoMeasurement() {
        let o = VNFaceObservation(requestRevision: 3, boundingBox: CGRect(x: 0, y: 0, width: 0.3, height: 0.3),
                                  roll: 0.1, yaw: 0.1, pitch: nil)
        #expect(VisionFaceDetector.measurement(from: o) == nil)
    }
}
