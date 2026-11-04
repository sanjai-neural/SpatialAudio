/// Neutral-pose calibration ("recenter").
///
/// `raw` is the head orientation as estimated in the camera frame. The neutral pose is
/// the raw orientation the user holds while looking at the screen. The calibrated
/// orientation is the head orientation in the frame defined by that neutral pose:
/// `calibrated = neutral⁻¹ * raw`, so `neutral * calibrated == raw` and neutral maps to identity.
public struct Calibration: Equatable, Sendable {
    public private(set) var neutral: Quaternion

    public init(neutral: Quaternion = .identity) {
        self.neutral = neutral.normalized()
    }

    public mutating func setNeutral(_ q: Quaternion) {
        neutral = q.normalized()
    }

    /// Set neutral from the mean of several samples. Returns false (and changes nothing) if `samples` is empty.
    @discardableResult
    public mutating func setNeutral(averaging samples: [Quaternion]) -> Bool {
        guard let mean = Quaternion.average(samples) else { return false }
        neutral = mean
        return true
    }

    public mutating func reset() { neutral = .identity }

    public func apply(_ raw: Quaternion) -> Quaternion {
        (neutral.conjugate * raw.normalized()).normalized()
    }
}
