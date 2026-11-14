import Foundation
import SpatialAudioCore

/// Which audio modes are running right now, for the exclusion rule in Core (`ListeningModeExclusion`). One place, so the three models cannot disagree.
@MainActor
enum ListeningModes {
    static func active() -> Set<ListeningMode> {
        var s = Set<ListeningMode>()
        if AudioTestModel.shared.isRunning { s.insert(.scripted) }
        if BlindListeningModel.shared.isRunning { s.insert(.blind) }
        if TrackedListeningModel.shared.isActive { s.insert(.cameraTracked) }
        return s
    }

    /// nil = may start.
    static func conflict(requested: ListeningMode) -> String? {
        let head = HeadTrackingModel.shared
        let cameraBusy = requested == .cameraTracked && (head.status != .idle || head.selfTest.isBusy)
        return ListeningModeExclusion.conflict(requested: requested, active: active(), cameraBusy: cameraBusy)
    }
}
