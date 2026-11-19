import CoreAudio
import SpatialAudioCore

// Step 6b-3c-0: the mapping from the probe's mute option to Core Audio's `CATapMuteBehavior` (CATapDescription.h: unmuted 0, muted 1, mutedWhenTapped 2). A pure function, tested; what each behaviour DOES to the target's
// audio when the tap goes away is not stated by the headers and is what the mute experiments measure.
@available(macOS 14.2, *)
extension RingProbeMuteBehavior {
    public var coreAudioValue: CATapMuteBehavior {
        switch self {
        case .unmuted: return .unmuted
        case .muted: return .muted
        case .mutedWhenTapped: return .mutedWhenTapped
        }
    }
}
