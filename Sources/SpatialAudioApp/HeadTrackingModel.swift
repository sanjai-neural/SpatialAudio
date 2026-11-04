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

    @ObservationIgnored private let tracker: HeadTracker

    private init() {
        tracker = HeadTracker(provider: CameraHeadPoseProvider())
        tracker.setSnapshotHandler { snap in
            Task { @MainActor in HeadTrackingModel.shared.receive(snap) }
        }
    }

    func start() {
        guard status == .idle || status.isFailed else { return }
        status = .starting
        snapshot = nil
        Task {
            do {
                try await tracker.start()
                deviceName = tracker.sourceDescription
                status = .running
            } catch {
                status = .failed(Self.describe(error))
            }
        }
    }

    func stop() {
        tracker.stop()
        status = .idle
        deviceName = nil
        snapshot = nil
    }

    func recenter() {
        recenterMessage = tracker.recenter() ? "Recentered." : "Recenter only works while state is LOCKED."
    }

    func setInvert(yaw: Bool? = nil, pitch: Bool? = nil, roll: Bool? = nil) {
        if let yaw { mapping.invertYaw = yaw }
        if let pitch { mapping.invertPitch = pitch }
        if let roll { mapping.invertRoll = roll }
        tracker.setMapping(mapping)
    }

    private func receive(_ s: TrackingSnapshot) {
        guard status == .running else { return }   // ignore frames that arrive after stop
        snapshot = s
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
