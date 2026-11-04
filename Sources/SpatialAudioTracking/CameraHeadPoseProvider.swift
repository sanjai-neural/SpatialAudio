import AVFoundation
import CoreMedia
import SpatialAudioCore

/// Head-pose source backed by the built-in camera (AVFoundation capture + Vision).
///
/// Privacy: frames are handled in memory inside the capture callback and discarded; nothing is
/// written to disk and there is no network code. `stop()` stops the session and removes the
/// input/output so the camera is released.
///
/// Mirroring: this class never sets `isVideoMirrored` (on macOS `automaticallyAdjustsVideoMirroring`
/// is unavailable and setting `videoMirrored` can throw an Objective-C exception). It reports the
/// connection's actual value on every frame so `HeadAngleMapping` can compensate.
public final class CameraHeadPoseProvider: NSObject, HeadPoseProvider, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let sessionQueue = DispatchQueue(label: "spatialaudio.camera.session")
    private let videoQueue = DispatchQueue(label: "spatialaudio.camera.video")   // serial, per AVFoundation requirement
    private let detector = VisionFaceDetector()

    private let lock = NSLock()
    private var session: AVCaptureSession?
    private var clock: CMClock = CMClockGetHostTimeClock()
    private var handler: (@Sendable (HeadPoseDetection) -> Void)?
    private var deviceName: String?

    // Release evidence (all guarded by `lock`).
    private struct StopRecord { var wasRunning: Bool; var isRunning: Bool; var inputs: Int; var outputs: Int; var uptime: Double }
    private var stopRecord: StopRecord?
    private weak var lastStoppedSession: AVCaptureSession?
    private var stopObserver: NSObjectProtocol?
    private var stopNotificationCount = 0
    private var stopCompleted = false
    private var callbacksAfterStop = 0

    public override init() { super.init() }
    deinit {
        stop()
        if let o = stopObserver { NotificationCenter.default.removeObserver(o) }
    }

    private static func uptimeSeconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000 }

    private func noteStopNotification() {
        lock.lock(); stopNotificationCount += 1; lock.unlock()
    }

    public func currentTime() -> Double {
        lock.lock(); let c = clock; lock.unlock()
        return CMClockGetTime(c).seconds
    }

    public var sourceDescription: String? {
        lock.lock(); defer { lock.unlock() }
        return deviceName
    }

    public func start(handler: @escaping @Sendable (HeadPoseDetection) -> Void) async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            if await !AVCaptureDevice.requestAccess(for: .video) { throw HeadPoseProviderError.cameraAccessDenied }
        case .denied: throw HeadPoseProviderError.cameraAccessDenied
        case .restricted: throw HeadPoseProviderError.cameraAccessRestricted
        @unknown default: throw HeadPoseProviderError.cameraAccessDenied
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do { try self.configureAndStart(handler: handler); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    public func stop() {
        sessionQueue.sync {
            lock.lock()
            let s = session
            session = nil
            handler = nil
            deviceName = nil
            lock.unlock()
            guard let s else { return }
            let wasRunning = s.isRunning
            // Stop the callbacks first, then release the hardware.
            for case let out as AVCaptureVideoDataOutput in s.outputs { out.setSampleBufferDelegate(nil, queue: nil) }
            s.stopRunning()                       // "blocks until the session object has completely stopped"
            let isRunningAfter = s.isRunning
            s.beginConfiguration()
            s.inputs.forEach { s.removeInput($0) }
            s.outputs.forEach { s.removeOutput($0) }
            s.commitConfiguration()
            let inputs = s.inputs.count, outputs = s.outputs.count
            lock.lock()
            stopRecord = StopRecord(wasRunning: wasRunning, isRunning: isRunningAfter, inputs: inputs,
                                    outputs: outputs, uptime: Self.uptimeSeconds())
            lastStoppedSession = s
            callbacksAfterStop = 0
            stopCompleted = true
            lock.unlock()
        }
    }

    /// Evidence that OUR capture session stopped and released its input/output. It cannot prove the
    /// physical green camera light is off; that stays a visual check. Re-reads the session's state if the
    /// session object still exists, so calling this a moment after `stop()` also catches late changes.
    public func releaseReport() -> CameraReleaseReport? {
        lock.lock(); defer { lock.unlock() }
        guard let r = stopRecord else { return nil }
        let alive = lastStoppedSession
        return CameraReleaseReport(
            wasRunningBeforeStop: r.wasRunning,
            isRunningAfterStop: alive?.isRunning ?? r.isRunning,
            inputsAfterStop: alive?.inputs.count ?? r.inputs,
            outputsAfterStop: alive?.outputs.count ?? r.outputs,
            stopNotificationsObserved: stopNotificationCount,
            callbacksAfterStop: callbacksAfterStop,
            sessionObjectDeallocated: alive == nil,
            secondsSinceStop: Self.uptimeSeconds() - r.uptime)
    }

    // MARK: - Private (sessionQueue)

    private func configureAndStart(handler: @escaping @Sendable (HeadPoseDetection) -> Void) throws {
        lock.lock(); let already = session != nil; lock.unlock()
        if already { throw HeadPoseProviderError.alreadyRunning }
        guard let device = Self.pickCamera() else { throw HeadPoseProviderError.noCameraFound }

        let s = AVCaptureSession()
        s.beginConfiguration()
        if s.canSetSessionPreset(.vga640x480) { s.sessionPreset = .vga640x480 }   // enough for face pose; cheaper than HD
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) }
        catch { throw HeadPoseProviderError.cannotConfigureSession("input: \(error.localizedDescription)") }
        guard s.canAddInput(input) else { throw HeadPoseProviderError.cannotConfigureSession("cannot add camera input") }
        s.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true   // never queue frames: stale poses are worse than dropped ones
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard s.canAddOutput(output) else { throw HeadPoseProviderError.cannotConfigureSession("cannot add video output") }
        s.addOutput(output)
        s.commitConfiguration()

        lock.lock()
        clock = s.synchronizationClock ?? CMClockGetHostTimeClock()
        self.handler = handler
        deviceName = device.localizedName
        session = s
        // Fresh release evidence for this run.
        stopRecord = nil; lastStoppedSession = nil; stopCompleted = false; callbacksAfterStop = 0; stopNotificationCount = 0
        if let o = stopObserver { NotificationCenter.default.removeObserver(o) }
        stopObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.didStopRunningNotification, object: s, queue: nil
        ) { [weak self] _ in self?.noteStopNotification() }
        lock.unlock()

        s.startRunning()
    }

    /// Prefer a built-in camera; skip iPhone Continuity Cameras, which can otherwise appear as the default.
    private static func pickCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified)
        return discovery.devices.first { !$0.isContinuityCamera } ?? discovery.devices.first
    }

    // MARK: - Frame callback (videoQueue)

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        let receivedAt = currentTime()
        lock.lock()
        let h = handler
        if h == nil && stopCompleted { callbacksAfterStop += 1 }     // a frame arrived after stop() returned
        lock.unlock()
        guard let h, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var face: FaceMeasurement?
        var count = 0
        var errorText: String?
        do {
            let r = try detector.detect(in: pixelBuffer)
            face = r.largest; count = r.facesDetected
        } catch {
            errorText = error.localizedDescription
        }
        h(HeadPoseDetection(
            captureTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds,
            receivedAt: receivedAt,
            detectedAt: currentTime(),
            face: face,
            facesDetected: count,
            frameMirrored: connection.isVideoMirrored,
            videoRotationAngle: Double(connection.videoRotationAngle),
            detectorError: errorText))
    }
}
