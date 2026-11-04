import SpatialAudioCore

/// Result of processing one camera frame. All times are seconds on the provider's clock
/// (`HeadPoseProvider.currentTime()`), which for the camera is the capture session's
/// synchronization clock, the same timebase as the sample timestamps.
public struct HeadPoseDetection: Equatable, Sendable {
    /// Sample presentation timestamp of the frame. Any delay before this stamp (exposure, sensor
    /// readout, ISP) is NOT included and is not measured.
    public var captureTime: Double
    /// When our frame callback started running.
    public var receivedAt: Double
    /// When face detection finished.
    public var detectedAt: Double
    /// Pose of the largest face, or nil if there is no face or its angles were unavailable.
    public var face: FaceMeasurement?
    /// Number of faces Vision returned (may be >0 while `face` is nil if angles were missing).
    public var facesDetected: Int
    /// Whether the frame was horizontally mirrored by the capture connection.
    public var frameMirrored: Bool
    /// `AVCaptureConnection.videoRotationAngle` of the delivering connection, if known.
    public var videoRotationAngle: Double?
    /// Non-nil if the Vision request failed for this frame.
    public var detectorError: String?

    public init(captureTime: Double, receivedAt: Double, detectedAt: Double, face: FaceMeasurement?,
                facesDetected: Int, frameMirrored: Bool, videoRotationAngle: Double? = nil,
                detectorError: String? = nil) {
        self.captureTime = captureTime; self.receivedAt = receivedAt; self.detectedAt = detectedAt
        self.face = face; self.facesDetected = facesDetected; self.frameMirrored = frameMirrored
        self.videoRotationAngle = videoRotationAngle; self.detectorError = detectorError
    }
}

public enum HeadPoseProviderError: Error, Equatable, Sendable {
    case cameraAccessDenied
    case cameraAccessRestricted
    case noCameraFound
    case cannotConfigureSession(String)
    case alreadyRunning
}

/// Source of head-pose detections. The camera implementation lives in this module; tests use fakes.
public protocol HeadPoseProvider: AnyObject, Sendable {
    /// Current time in seconds on the same clock as `HeadPoseDetection` timestamps.
    func currentTime() -> Double
    /// Human-readable description of the active source (e.g. camera name), if running.
    var sourceDescription: String? { get }
    /// Start delivering detections to `handler` (called on a provider-owned serial queue).
    /// Throws if permission is missing or the source cannot start.
    func start(handler: @escaping @Sendable (HeadPoseDetection) -> Void) async throws
    /// Stop delivery and release the underlying hardware. Blocks until released. Idempotent.
    func stop()
}
