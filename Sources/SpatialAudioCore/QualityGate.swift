import Foundation

/// Hysteresis + minimum dwell for the tracking-quality decision "is this frame good enough to follow?".
///
/// Why it exists (Step 2d, from the real 08:12 self-test report): the state machine used one hard threshold
/// (quality >= 0.5). A quality score that hovers around 0.5, for example while the head is turned far or the
/// face is near the frame edge, therefore flips between "locked" and "lost" frame by frame. The real report shows
/// the state sequence decaying, locked, holding, locked, holding, locked, holding, decaying, locked, ... with a
/// hold of 0.07 s instead of 0.5 s. A hard threshold produces that chatter by construction.
///
/// Rules (ALL VALUES UNTUNED PLACEHOLDERS, printed in every report):
/// - While tracking, a frame below `lossBelow` does NOT immediately cause loss: the pose coasts (frozen, not
///   fed to the filter) and loss is declared only once the quality has stayed below `lossBelow` for `lossDwell`.
/// - While lost, recovery needs the quality to stay at or above `recoverAbove` for `recoverDwell`. `recoverAbove`
///   is higher than `lossBelow`, so a score inside the band keeps whatever decision was made last.
/// - Frames that stopped arriving (watchdog) are a definite loss and bypass the dwell (`forceLost`).
public struct QualityGateConfig: Equatable, Sendable, Codable {
    /// Quality below this starts the loss countdown.
    public var lossBelow: Double
    /// Quality must reach this to start the recovery countdown. Keep it above `lossBelow`.
    public var recoverAbove: Double
    /// Seconds the quality must stay below `lossBelow` before loss is declared.
    public var lossDwell: Double
    /// Seconds the quality must stay at or above `recoverAbove` before tracking resumes.
    public var recoverDwell: Double

    public init(lossBelow: Double = 0.40, recoverAbove: Double = 0.60, lossDwell: Double = 0.10, recoverDwell: Double = 0.20) {
        self.lossBelow = lossBelow; self.recoverAbove = recoverAbove
        self.lossDwell = lossDwell; self.recoverDwell = recoverDwell
    }

    /// The behaviour before Step 2d: one threshold, no dwell. Kept so tests can show the chatter the new gate removes.
    public static func singleThreshold(_ threshold: Double = 0.5) -> QualityGateConfig {
        QualityGateConfig(lossBelow: threshold, recoverAbove: threshold, lossDwell: 0, recoverDwell: 0)
    }
}

public enum QualityGateDecision: String, Equatable, Sendable {
    /// Use this frame: it is tracked.
    case good
    /// Quality dipped below the loss threshold but not for long enough: keep the current pose, feed nothing.
    case coast
    /// Not tracking.
    case lost
}

public struct QualityGate: Sendable {
    public var config: QualityGateConfig
    public private(set) var isTracking = false
    private var pendingSince: Double?

    /// A dwell counts as met within a nanosecond, so 3 frames at 30 fps (0.1 s up to floating-point rounding) are not
    /// sometimes 3 frames and sometimes 4 depending on how the timestamps happen to round.
    static let timeTolerance = 1e-9

    public init(config: QualityGateConfig = QualityGateConfig()) { self.config = config }

    public mutating func reset() { isTracking = false; pendingSince = nil }

    /// Frames stopped arriving: lose immediately and require a full recovery dwell afterwards.
    public mutating func forceLost() { isTracking = false; pendingSince = nil }

    /// `quality` in 0...1 (0 when there is no face), `time` in seconds on a monotonic timeline.
    public mutating func update(quality: Double, at time: Double) -> QualityGateDecision {
        let q = quality.isFinite ? quality : 0
        if isTracking {
            if q >= config.lossBelow { pendingSince = nil; return .good }
            let since = pendingSince ?? time
            pendingSince = since
            if time - since >= config.lossDwell - Self.timeTolerance {
                isTracking = false; pendingSince = nil
                return .lost
            }
            return .coast
        }
        if q >= config.recoverAbove {
            let since = pendingSince ?? time
            pendingSince = since
            if time - since >= config.recoverDwell - Self.timeTolerance {
                isTracking = true; pendingSince = nil
                return .good
            }
            return .lost
        }
        pendingSince = nil
        return .lost
    }
}
