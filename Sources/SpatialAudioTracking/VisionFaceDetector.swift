import CoreVideo
import ImageIO
import SpatialAudioCore
import Vision

/// Wraps `VNDetectFaceRectanglesRequest` (revision 3, which reports yaw, pitch and roll
/// continuously) behind a small API. Not thread-safe: use from one serial queue.
///
/// Why Vision's angles and not a custom landmark estimator: the SDK header (VNObservation.h)
/// documents `yaw`, `pitch` and `roll` on `VNFaceObservation` populated by this request.
/// Whether their accuracy/stability is good enough is judged on real camera data, not assumed.
public final class VisionFaceDetector {
    public struct Result: Equatable, Sendable {
        public var facesDetected: Int
        public var largest: FaceMeasurement?
    }

    private let sequenceHandler = VNSequenceRequestHandler()
    private let request: VNDetectFaceRectanglesRequest

    public init() {
        request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3   // pitch + continuous angles (macOS 12+)
    }

    public static var revisionInUse: Int { Int(VNDetectFaceRectanglesRequestRevision3) }

    public func detect(in pixelBuffer: CVPixelBuffer,
                       orientation: CGImagePropertyOrientation = .up) throws -> Result {
        try sequenceHandler.perform([request], on: pixelBuffer, orientation: orientation)
        let observations = request.results ?? []
        let measurements = observations.compactMap(Self.measurement(from:))
        let largest = measurements.max { $0.boundingBoxArea < $1.boundingBoxArea }
        return Result(facesDetected: observations.count, largest: largest)
    }

    /// nil if any of yaw/pitch/roll is unavailable or non-finite.
    static func measurement(from o: VNFaceObservation) -> FaceMeasurement? {
        guard let yaw = o.yaw?.doubleValue, let pitch = o.pitch?.doubleValue, let roll = o.roll?.doubleValue else {
            return nil
        }
        let angles = VisionFaceAngles(yaw: yaw, pitch: pitch, roll: roll)
        guard angles.isFinite else { return nil }
        let box = o.boundingBox
        return FaceMeasurement(angles: angles, confidence: Double(o.confidence),
                               boundingBoxArea: Double(box.width * box.height))
    }
}
