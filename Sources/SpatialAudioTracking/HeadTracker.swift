import Foundation
import SpatialAudioCore

/// Everything the HUD (and later the audio engine) needs about one processed frame or watchdog tick.
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
    /// Vision's own confidence (weak signal; display only).
    public var confidence: Double?
    /// Our quality signal; `quality.overall` is what gates the state machine.
    public var quality: QualityBreakdown
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
    public var framesPerSecond: Double
    /// True for snapshots produced by the watchdog because frames stopped arriving.
    public var isWatchdogTick: Bool
    /// Seconds since the last real frame (0 for frame snapshots).
    public var frameAge: Double
}

public struct HeadTrackerConfig: Sendable {
    public var filter = OneEuroParameters()
    public var machine = TrackingStateMachineConfig()
    public var quality = TrackingQualityConfig()
    /// UNTUNED. No frame for this long (monotonic clock) counts as face loss.
    public var frameTimeout = 0.25
    /// How often the watchdog checks (seconds).
    public var watchdogInterval = 0.05

    public init() {}
}

/// detections -> angle mapping -> quality gate -> `HeadPosePipeline` -> snapshots, plus a watchdog that
/// treats "no frame for `frameTimeout`" as face loss. Contains no AVFoundation or Vision code, so it is
/// fully testable with a fake provider and a fake clock.
public final class HeadTracker: @unchecked Sendable {
    /// Monotonic seconds that do not advance while the Mac sleeps (`CLOCK_UPTIME_RAW`). Used only for
    /// frame-age/watchdog decisions, independent of camera timestamps.
    public static let monotonicSeconds: @Sendable () -> Double = {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    private let provider: HeadPoseProvider
    private let config: HeadTrackerConfig
    private let clock: @Sendable () -> Double
    private let watchdogQueue = DispatchQueue(label: "spatialaudio.tracker.watchdog", qos: .userInitiated)

    private let lock = NSLock()
    private var pipeline: HeadPosePipeline
    private var estimator: TrackingQualityEstimator
    private var mapping: HeadAngleMapping
    private var snapshotHandler: (@Sendable (TrackingSnapshot) -> Void)?
    private var lastFrameMono: Double?       // monotonic time when the last real frame arrived
    private var lastCaptureTime: Double?     // that frame's capture timestamp (pipeline timeline)
    private var watchdogTimer: DispatchSourceTimer?

    public init(provider: HeadPoseProvider,
                mapping: HeadAngleMapping = HeadAngleMapping(),
                config: HeadTrackerConfig = HeadTrackerConfig(),
                clock: @escaping @Sendable () -> Double = HeadTracker.monotonicSeconds) {
        self.provider = provider
        self.mapping = mapping
        self.config = config
        self.clock = clock
        self.pipeline = HeadPosePipeline(filter: config.filter, machine: config.machine)
        self.estimator = TrackingQualityEstimator(config: config.quality)
    }

    deinit { watchdogTimer?.cancel() }

    public var sourceDescription: String? { provider.sourceDescription }

    /// Called on the provider's or watchdog's queue for every snapshot. Keep it fast.
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
        startWatchdog()
    }

    public func stop() {
        stopWatchdog()
        provider.stop()
    }

    // MARK: - Frames

    /// Process one detection. Internal entry point (also used directly by tests).
    @discardableResult
    func ingest(_ d: HeadPoseDetection) -> TrackingSnapshot {
        lock.lock()
        let map = mapping
        var mappedEuler: EulerAngles?
        var sample: HeadPoseSample?

        let quality = estimator.update(time: d.captureTime, face: d.face)
        if let face = d.face {
            let e = map.euler(from: face.angles, frameMirrored: d.frameMirrored)
            mappedEuler = e
            // Our quality (not Vision's confidence) is what the state machine gates on. Samples
            // below its threshold count as lost and never reach the filter.
            sample = HeadPoseSample(orientation: Quaternion(euler: e), confidence: quality.overall,
                                    timestamp: d.captureTime)
        }
        let out = pipeline.process(sample, now: d.captureTime)
        lastFrameMono = clock()
        lastCaptureTime = d.captureTime
        let handler = snapshotHandler
        lock.unlock()

        let snap = TrackingSnapshot(
            captureTime: d.captureTime, state: out.state, pose: out.pose, euler: out.pose.euler,
            visionAngles: d.face?.angles, mappedRawEuler: mappedEuler, confidence: d.face?.confidence,
            quality: quality, facesDetected: d.facesDetected, frameMirrored: d.frameMirrored,
            videoRotationAngle: d.videoRotationAngle, detectorError: d.detectorError,
            deliveryLatency: d.receivedAt - d.captureTime,
            visionDuration: d.detectedAt - d.receivedAt,
            captureToPoseLatency: provider.currentTime() - d.captureTime,
            framesPerSecond: quality.framesPerSecond, isWatchdogTick: false, frameAge: 0)
        handler?(snap)
        return snap
    }

    // MARK: - Watchdog

    /// If no real frame arrived for `frameTimeout`, feed a "lost" tick into the pipeline so the pose
    /// holds, decays to neutral and goes static even though the camera has gone quiet. Does nothing
    /// before the first frame. Called by the timer; internal so tests can drive it with a fake clock.
    func watchdogTick() {
        lock.lock()
        guard let lastMono = lastFrameMono, let lastCapture = lastCaptureTime else { lock.unlock(); return }
        let age = clock() - lastMono
        guard age > config.frameTimeout else { lock.unlock(); return }

        estimator.noteGap()
        // Advance the pipeline timeline by the monotonic time elapsed since the last real frame, so
        // hold/decay timing does not depend on camera timestamps (which stop with the frames).
        let out = pipeline.process(nil, now: lastCapture + age)
        let handler = snapshotHandler
        lock.unlock()

        handler?(TrackingSnapshot(
            captureTime: lastCapture + age, state: out.state, pose: out.pose, euler: out.pose.euler,
            visionAngles: nil, mappedRawEuler: nil, confidence: nil,
            quality: .absent(reason: "no frames"), facesDetected: 0, frameMirrored: false,
            videoRotationAngle: nil, detectorError: nil, deliveryLatency: 0, visionDuration: 0,
            captureToPoseLatency: 0, framesPerSecond: 0, isWatchdogTick: true, frameAge: age))
    }

    // MARK: - Private (synchronous so locks are never held across a suspension point)

    /// Fresh filter/state each run; keeps the user's calibration.
    private func resetForStart() {
        lock.lock(); defer { lock.unlock() }
        pipeline = HeadPosePipeline(filter: config.filter, machine: config.machine, calibration: pipeline.calibration)
        estimator = TrackingQualityEstimator(config: config.quality)
        lastFrameMono = nil; lastCaptureTime = nil
    }

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + config.watchdogInterval, repeating: config.watchdogInterval)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        lock.lock(); watchdogTimer = timer; lock.unlock()
        timer.resume()
    }

    private func stopWatchdog() {
        lock.lock(); let t = watchdogTimer; watchdogTimer = nil; lock.unlock()
        t?.cancel()
    }
}
