import Foundation
import Observation
import SpatialAudioCore
import SpatialAudioTracking

/// View model only: owns the tracker and republishes snapshots to the UI.
/// No CV or DSP logic lives here (that is in SpatialAudioTracking / SpatialAudioCore).
@MainActor @Observable
final class HeadTrackingModel {
    static let shared = HeadTrackingModel()

    enum Status: Equatable {
        case idle, starting, running
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var snapshot: TrackingSnapshot?
    private(set) var deviceName: String?
    private(set) var mapping = HeadAngleMapping()
    private(set) var recenterMessage: String?
    /// Programmatic evidence from the last stop (nil until a stop + check has run).
    private(set) var releaseReport: CameraReleaseReport?
    private(set) var releaseCheckPending = false
    /// Where the current sign mapping came from, for display.
    private(set) var mappingNote = "documented defaults (UNVERIFIED on hardware)"

    let isSimulated: Bool
    @ObservationIgnored let selfTest = SelfTestController()
    @ObservationIgnored let trackerConfig = HeadTrackerConfig()
    @ObservationIgnored private let tracker: HeadTracker
    @ObservationIgnored private let provider: HeadPoseProvider
    @ObservationIgnored private let simulatedProvider: SimulatedHeadPoseProvider?
    @ObservationIgnored private var activityToken: NSObjectProtocol?

    private init() {
        let options = LaunchOptions.current
        isSimulated = options.simulate
        if options.simulate {
            let sim = SimulatedHeadPoseProvider(user: SimulatedUser(conventions: options.conventions, framesMirrored: options.mirrored))
            simulatedProvider = sim
            provider = sim
        } else {
            simulatedProvider = nil
            provider = CameraHeadPoseProvider()
        }
        tracker = HeadTracker(provider: provider, config: trackerConfig)
        tracker.setSnapshotHandler { snap in
            let arrival = HeadTracker.monotonicSeconds()         // stamp on the capture queue, before the main-actor hop
            Task { @MainActor in HeadTrackingModel.shared.receive(snap, arrival: arrival) }
        }
        // Signs the user confirmed in an earlier self-test (never loaded for simulated runs).
        if !options.simulate, let saved = MappingStore.load() {
            mapping = saved.mapping
            tracker.setMapping(saved.mapping)
            mappingNote = "saved from a self-test on \(saved.cameraName) (\(saved.savedAt))"
        }
        selfTest.attach(model: self)
    }

    // MARK: camera control

    func start() {
        Task { _ = await startAndWait() }
    }

    /// Starts the tracker and waits for the result. Returns false (and sets `status = .failed`) on error.
    func startAndWait() async -> Bool {
        guard status == .idle || status.isFailed else { return status == .running }
        status = .starting
        snapshot = nil
        releaseReport = nil
        do {
            try await tracker.start()
            beginTrackingActivity()
            deviceName = tracker.sourceDescription
            status = .running
            return true
        } catch {
            status = .failed(Self.describe(error))
            return false
        }
    }

    /// Synchronous stop (also used when the app quits). Releases the camera before returning.
    func stop() {
        tracker.stop()
        endTrackingActivity()
        status = .idle
        deviceName = nil
        snapshot = nil
    }

    /// Stops, waits `settle`, then reads back the capture session's state. This is PROGRAMMATIC evidence
    /// only; whether the green camera light is off is a visual check.
    @discardableResult
    func stopAndVerifyRelease(settle: Duration = .seconds(1.2)) async -> CameraReleaseReport? {
        stop()
        releaseCheckPending = true
        try? await Task.sleep(for: settle)
        let report = provider.releaseReport()
        releaseReport = report
        releaseCheckPending = false
        return report
    }

    /// Without this, macOS App-Naps an app whose window is hidden or behind others: timers get coalesced and work is
    /// delayed. Measured on the simulated source: 26 fps with 130 ms stalls instead of 30 fps, which also distorted the
    /// self-test's frame-rate, watchdog and loss-test results. `.latencyCritical` is documented for capture-style work;
    /// the "allowing idle system sleep" variant does not stop the Mac from sleeping.
    private func beginTrackingActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Head tracking needs regular frame and timer delivery")
    }

    private func endTrackingActivity() {
        if let token = activityToken { ProcessInfo.processInfo.endActivity(token); activityToken = nil }
    }

    func recenter() {
        recenterMessage = tracker.recenter() ? "Recentered." : "Recenter only works while state is LOCKED."
    }

    // MARK: sign mapping

    func setInvert(yaw: Bool? = nil, pitch: Bool? = nil, roll: Bool? = nil) {
        var m = mapping
        if let yaw { m.invertYaw = yaw }
        if let pitch { m.invertPitch = pitch }
        if let roll { m.invertRoll = roll }
        changeMapping(to: m, note: "manual override")
        recenterMessage = "Signs changed: filter and calibration were reset. Look at the screen and press Recenter."
    }

    /// Applies the signs the user confirmed after a self-test and remembers them for the next launch.
    func applyDetectedMapping(_ m: HeadAngleMapping, cameraName: String, framesMirrored: Bool, timestamp: String) {
        changeMapping(to: m, note: "saved from a self-test on \(cameraName) (\(timestamp))")
        MappingStore.save(SavedMapping(mapping: m, cameraName: cameraName, framesMirrored: framesMirrored, savedAt: timestamp))
        recenterMessage = "Signs applied and saved. Start the camera, look at the screen, press Recenter, then check: turn LEFT → arrow points left and yaw is positive."
    }

    func resetToDocumentedDefaults() {
        MappingStore.clear()
        changeMapping(to: HeadAngleMapping(), note: "documented defaults (UNVERIFIED on hardware)")
        recenterMessage = "Signs reset to the documented defaults. Press Recenter."
    }

    private func changeMapping(to m: HeadAngleMapping, note: String) {
        mapping = m
        mappingNote = note
        tracker.setMapping(m)
    }

    // MARK: frames

    func beginSimulatedScript(at monotonic: Double) { simulatedProvider?.beginScript(at: monotonic) }

    var releaseReportForSelfTest: CameraReleaseReport? { provider.releaseReport() }

    var statusText: String {
        switch status {
        case .idle: "idle (camera off)"
        case .starting: "starting…"
        case .running: "running"
        case .failed(let m): "FAILED: \(m)"
        }
    }

    private func receive(_ s: TrackingSnapshot, arrival: Double) {
        guard status == .running else { return }   // ignore frames that arrive after stop
        snapshot = s
        selfTest.ingest(s, arrival: arrival)
    }

    private static func describe(_ error: Error) -> String {
        switch error as? HeadPoseProviderError {
        case .cameraAccessDenied:
            return "Camera access denied. Allow it in System Settings > Privacy & Security > Camera, then start again."
        case .cameraAccessRestricted: return "Camera access is restricted on this Mac."
        case .noCameraFound: return "No camera found."
        case .alreadyRunning: return "Already running."
        case .cannotConfigureSession(let why): return "Camera setup failed: \(why)"
        case nil: return error.localizedDescription
        }
    }
}

extension HeadTrackingModel.Status {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}
