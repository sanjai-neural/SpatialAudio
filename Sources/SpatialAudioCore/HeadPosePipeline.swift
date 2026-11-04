/// One head-pose measurement from a `HeadPoseProvider` (Step 2).
public struct HeadPoseSample: Equatable, Sendable {
    /// Raw head orientation in the camera frame.
    public var orientation: Quaternion
    /// 0...1. Meaning is defined by the provider; compared against `TrackingStateMachineConfig.minConfidence`.
    public var confidence: Double
    /// Capture time in seconds on a monotonic clock shared with `process(_:now:)`.
    public var timestamp: Double

    public init(orientation: Quaternion, confidence: Double, timestamp: Double) {
        self.orientation = orientation; self.confidence = confidence; self.timestamp = timestamp
    }
}

/// raw sample -> One-Euro filter -> calibration -> tracking state machine.
/// Order matters: filtering happens in raw camera space; calibration is applied after, so
/// "neutral" (what decay returns to) is always the calibrated identity.
public struct HeadPosePipeline: Sendable {
    public var calibration: Calibration
    public private(set) var filter: OneEuroQuaternionFilter
    public private(set) var machine: TrackingStateMachine
    private var lastFilteredRaw: Quaternion?

    public init(filter: OneEuroParameters = OneEuroParameters(),
                machine: TrackingStateMachineConfig = TrackingStateMachineConfig(),
                calibration: Calibration = Calibration()) {
        self.filter = OneEuroQuaternionFilter(parameters: filter)
        self.machine = TrackingStateMachine(config: machine)
        self.calibration = calibration
    }

    /// Feed a sample, or `nil` when no face is available, with the current time.
    /// Low-confidence samples are not fed to the filter.
    @discardableResult
    public mutating func process(_ sample: HeadPoseSample?, now: Double) -> TrackingOutput {
        if let s = sample, s.orientation.isFinite, s.confidence >= machine.config.minConfidence {
            let filtered = filter.filter(s.orientation, at: s.timestamp)
            lastFilteredRaw = filtered
            return machine.update(at: s.timestamp, pose: calibration.apply(filtered), confidence: s.confidence)
        }
        return machine.update(at: now, pose: nil)
    }

    /// Make the current (filtered) head orientation the neutral pose. Only while locked;
    /// returns false otherwise. The output blends smoothly instead of jumping.
    @discardableResult
    public mutating func recenter() -> Bool {
        guard machine.state == .locked, let raw = lastFilteredRaw else { return false }
        calibration.setNeutral(raw)
        machine.beginBlend(at: machine.lastUpdateTime ?? 0)
        return true
    }
}
