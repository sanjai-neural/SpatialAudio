import Foundation
import SpatialAudioCore

/// Everything the HUD (and later the audio engine) needs about one processed frame.
public struct TrackingSnapshot: Equatable, Sendable {
    public var captureTime: Double
    public var state: TrackingState
    /// Calibrated, filtered listener orientation (identity = neutral).
    public var pose: Quaternion
    /// `pose` as Euler angles for display only.
    public var euler: EulerAngles
    /// Raw Vision angles for the frame (nil if no face).
    public var visionAngles: VisionFaceAngles?
    /// Vision angles after sign mapping, before filtering/calibration (display only).
    public var mappedRawEuler: EulerAngles?
    public var confidence: Double?
    public var facesDetected: Int
    public var frameMirrored: Bool
    public var videoRotationAngle: Double?
    public var detectorError: String?
    /// receivedAt - captureTime: camera-to-callback delivery delay after the sample timestamp.
    public var deliveryLatency: Double
    /// detectedAt - receivedAt: time spent in Vision for this frame.
    public var visionDuration: Double
    /// pose-ready time - captureTime. Excludes anything before the sample timestamp.
    public var captureToPoseLatency: Double
    /// Smoothed frame rate from capture timestamps.
    public var framesPerSecond: Double
}

/// detections -> angle mapping -> `HeadPosePipeline` -> snapshots. Contains no AVFoundation or
/// Vision code, so it is fully testable with a fake provider.
public final class HeadTracker: @unchecked Sendable {
    private let provider: HeadPoseProvider
    private let filterParameters: OneEuroParameters
    private let machineConfig: TrackingStateMachineConfig

    private let lock = NSLock()
    private var pipeline: HeadPosePipeline
    private var mapping: HeadAngleMapping
    private var fps = 0.0
    private var lastCaptureTime: Double?
    private var snapshotHandler: (@Sendable (TrackingSnapshot) -> Void)?

    public init(provider: HeadPoseProvider,
                mapping: HeadAngleMapping = HeadAngleMapping(),
                filter: OneEuroParameters = OneEuroParameters(),
                machine: TrackingStateMachineConfig = TrackingStateMachineConfig()) {
        self.provider = provider
        self.mapping = mapping
        self.filterParameters = filter
        self.machineConfig = machine
        self.pipeline = HeadPosePipeline(filter: filter, machine: machine)
    }

    public var sourceDescription: String? { provider.sourceDescription }

    /// Called on the provider's queue for every processed frame. Keep it fast.
    public func setSnapshotHandler(_ handler: (@Sendable (TrackingSnapshot) -> Void)?) {
        lock.lock(); snapshotHandler = handler; lock.unlock()
    }

    public func setMapping(_ m: HeadAngleMapping) {
        lock.lock(); mapping = m; lock.unlock()
    }

    /// Make the current head orientation neutral. False if not currently locked.
    @discardableResult
    public func recenter() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pipeline.recenter()
    }

    public func start() async throws {
        resetForStart()
        try await provider.start { [weak self] detection in _ = self?.ingest(detection) }
    }

    /// Fresh filter/state each run; keeps the user's calibration. (Synchronous so the lock is
    /// never held across a suspension point.)
    private func resetForStart() {
        lock.lock(); defer { lock.unlock() }
        pipeline = HeadPosePipeline(filter: filterParameters, machine: machineConfig, calibration: pipeline.calibration)
        fps = 0; lastCaptureTime = nil
    }

    public func stop() { provider.stop() }

    /// Process one detection. Internal entry point (also used directly by tests).
    @discardableResult
    func ingest(_ d: HeadPoseDetection) -> TrackingSnapshot {
        lock.lock()
        let map = mapping
        var mappedEuler: EulerAngles?
        var sample: HeadPoseSample?
        if let face = d.face {
            let e = map.euler(from: face.angles, frameMirrored: d.frameMirrored)
            mappedEuler = e
            sample = HeadPoseSample(orientation: Quaternion(euler: e), confidence: face.confidence,
                                    timestamp: d.captureTime)
        }
        let out = pipeline.process(sample, now: d.captureTime)

        if let last = lastCaptureTime, d.captureTime > last {
            let instant = 1 / (d.captureTime - last)
            fps = fps == 0 ? instant : fps + 0.1 * (instant - fps)
        }
        lastCaptureTime = d.captureTime
        let currentFPS = fps
        let handler = snapshotHandler
        lock.unlock()

        let snap = TrackingSnapshot(
            captureTime: d.captureTime, state: out.state, pose: out.pose, euler: out.pose.euler,
            visionAngles: d.face?.angles, mappedRawEuler: mappedEuler, confidence: d.face?.confidence,
            facesDetected: d.facesDetected, frameMirrored: d.frameMirrored,
            videoRotationAngle: d.videoRotationAngle, detectorError: d.detectorError,
            deliveryLatency: d.receivedAt - d.captureTime,
            visionDuration: d.detectedAt - d.receivedAt,
            captureToPoseLatency: provider.currentTime() - d.captureTime,
            framesPerSecond: currentFPS)
        handler?(snap)
        return snap
    }
}
