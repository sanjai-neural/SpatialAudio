import Foundation

// Step 3b: head-tracked listening (the camera drives the renderer). Pure logic only: no audio, no camera.
// IMPLEMENTED-UNVERIFIED for sound until Sanjai has listened.

/// Roll is forced to 0 in the first tracked build (decision by Sanjai; roll stays PLANNED until a pure tilt is measured). This is the tested conversion that
/// does it: yaw and pitch are kept exactly, roll becomes 0. It is NOT the "invert roll" checkbox, which only flips a sign.
public enum RollRemoval {
    public static func removingRoll(from e: EulerAngles) -> EulerAngles {
        EulerAngles(yaw: e.yaw, pitch: e.pitch, roll: 0)
    }

    /// The same pose with its roll angle set to 0 (yaw and pitch unchanged). A non-finite quaternion becomes the identity, like `Quaternion.normalized()`.
    public static func removingRoll(from q: Quaternion) -> Quaternion {
        Quaternion(euler: removingRoll(from: q.euler))
    }
}

/// Which audio modes exist, so that no two can run at once (two engines at once would confuse every test, and the camera mode owns the camera).
public enum ListeningMode: String, CaseIterable, Sendable {
    case scripted        // the scripted listening card (Step 3a)
    case blind           // the blind listening test (Step 3a-2)
    case cameraTracked   // head-tracked listening (Step 3b)
}

public enum ListeningModeExclusion {
    /// nil = `requested` may start. Otherwise the reason, in words for the HUD. `cameraBusy`: the HUD camera or the guided self-test is using the camera.
    public static func conflict(requested: ListeningMode, active: Set<ListeningMode>, cameraBusy: Bool = false) -> String? {
        if let other = active.subtracting([requested]).sorted(by: { $0.rawValue < $1.rawValue }).first {
            switch other {
            case .scripted: return "The scripted audio test is running. Stop it first: two engines at once would confuse the test."
            case .blind: return "The blind listening test is running. Stop it first: two engines at once would confuse the test."
            case .cameraTracked: return "Head-tracked listening is running. Stop it first: two engines at once would confuse the test."
            }
        }
        if requested == .cameraTracked, cameraBusy {
            return "The camera is already in use (the HUD's camera or the guided self-test). Stop it first: this card starts and stops the camera itself."
        }
        return nil
    }
}

/// Volume policy of head-tracked listening. UNTUNED placeholders: there is no loudness measurement and no limiter in this app, so the cap is only a
/// guard against a slider mistake, not a safety guarantee. Set the system volume low as well.
public enum TrackedListeningPolicy {
    public static let defaultVolume = 0.15
    public static let maximumVolume = 0.40

    public static func clampedVolume(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(max(v, 0), maximumVolume)
    }
}
