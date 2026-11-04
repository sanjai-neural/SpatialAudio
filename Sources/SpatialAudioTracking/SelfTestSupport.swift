import Foundation
import SpatialAudioCore

extension TrackingSnapshot {
    /// The numbers-only view of this snapshot used by the guided self-test. `arrival` is the monotonic time
    /// at which the snapshot reached the app. No image data is involved.
    public func selfTestFrame(arrival: Double) -> SelfTestFrame {
        SelfTestFrame(arrival: arrival, captureTime: captureTime, angles: visionAngles, frameMirrored: frameMirrored,
                      videoRotationAngle: videoRotationAngle, state: state, pose: pose, qualityOverall: quality.overall,
                      isWatchdogTick: isWatchdogTick, deliveryLatency: deliveryLatency, visionDuration: visionDuration,
                      totalLatency: captureToPoseLatency)
    }
}

/// A head-pose source that plays a `SimulatedUser` in real time. For rehearsing and verifying the self-test
/// flow WITHOUT a camera. Everything it produces is made up: results from it are labeled SIMULATED and must
/// never be used to set real sign defaults. Latencies are deliberately different from any measured value.
public final class SimulatedHeadPoseProvider: HeadPoseProvider, @unchecked Sendable {
    public static let sourceName = "SIMULATED user (no camera)"

    private let user: SimulatedUser
    private let fps: Double
    private let deliveryLatency = 0.050
    private let visionDuration = 0.010
    private let queue = DispatchQueue(label: "spatialaudio.simulated", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var handler: (@Sendable (HeadPoseDetection) -> Void)?
    private var scriptStart: Double?
    private var frameIndex = 0
    private var running = false

    public init(user: SimulatedUser = SimulatedUser(), fps: Double = 30) {
        self.user = user; self.fps = fps
        queue.setSpecific(key: queueKey, value: ())
    }
    deinit { stop() }

    public func currentTime() -> Double { HeadTracker.monotonicSeconds() }

    public var sourceDescription: String? {
        lock.lock(); defer { lock.unlock() }
        return running ? Self.sourceName : nil
    }

    /// Tells the simulated person when the script starts (monotonic seconds, same clock as `currentTime()`).
    /// Before this the person just sits at rest.
    public func beginScript(at monotonic: Double) {
        lock.lock(); scriptStart = monotonic; lock.unlock()
    }

    public func start(handler: @escaping @Sendable (HeadPoseDetection) -> Void) async throws {
        try startTimer(handler: handler)
    }

    public func stop() {
        lock.lock()
        let t = timer
        timer = nil; handler = nil; running = false; scriptStart = nil
        lock.unlock()
        t?.cancel()
        // The protocol promises stop() "blocks until released": wait for a tick that is already running, so no
        // detection can be delivered after stop() returns. (Skipped if stop() is called from the tick itself.)
        if t != nil, DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
    }

    // MARK: private

    private func startTimer(handler: @escaping @Sendable (HeadPoseDetection) -> Void) throws {
        lock.lock()
        if timer != nil { lock.unlock(); throw HeadPoseProviderError.alreadyRunning }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / fps, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t; self.handler = handler; running = true; frameIndex = 0
        lock.unlock()
        t.resume()
    }

    private func tick() {
        let now = currentTime()
        lock.lock()
        let h = handler
        let start = scriptStart
        let index = frameIndex
        frameIndex += 1
        lock.unlock()
        guard let h else { return }

        let latency = deliveryLatency + visionDuration
        let elapsed = start.map { now - $0 } ?? 0
        let raw = user.rawAngles(frameIndex: index, atElapsed: max(0, elapsed - latency))
        let box = NormalizedRect(x: 0.3, y: 0.25, width: 0.3, height: 0.45)
        h(HeadPoseDetection(
            captureTime: now - latency, receivedAt: now - visionDuration, detectedAt: now,
            face: raw.map { FaceMeasurement(angles: $0, confidence: 0.88, boundingBox: box) },
            facesDetected: raw == nil ? 0 : 1, frameMirrored: user.framesMirrored, videoRotationAngle: 0))
    }
}
