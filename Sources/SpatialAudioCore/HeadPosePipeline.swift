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

/// raw sample -> quality gate (hysteresis + dwell) -> One-Euro filter -> calibration -> tracking state machine.
/// Order matters: filtering happens in raw camera space; calibration is applied after, so
/// "neutral" (what decay returns to) is always the calibrated identity.
///
/// The `QualityGate` replaced the old single confidence threshold in Step 2d: samples are only fed to the filter
/// while the gate says `good`; during a short quality dip the pose coasts; a sustained dip is a loss; recovery needs
/// a sustained good stretch. `machine.config.minConfidence` is therefore no longer used by the pipeline.
public struct HeadPosePipeline: Sendable {
    public var calibration: Calibration
    public private(set) var filter: OneEuroQuaternionFilter
    public private(set) var machine: TrackingStateMachine
    public private(set) var gate: QualityGate
    private var lastFilteredRaw: Quaternion?

    public init(filter: OneEuroParameters = OneEuroParameters(),
                machine: TrackingStateMachineConfig = TrackingStateMachineConfig(),
                calibration: Calibration = Calibration(),
                gate: QualityGateConfig = QualityGateConfig()) {
        self.filter = OneEuroQuaternionFilter(parameters: filter)
        self.machine = TrackingStateMachine(config: machine)
        self.calibration = calibration
        self.gate = QualityGate(config: gate)
    }

    /// Feed a sample, or `nil` when no face is available, with the current time. `sample.confidence` is the
    /// per-frame quality in 0...1; no face counts as quality 0.
    @discardableResult
    public mutating func process(_ sample: HeadPoseSample?, now: Double) -> TrackingOutput {
        let usable = sample.flatMap { $0.orientation.isFinite ? $0 : nil }
        let time = usable?.timestamp ?? now
        switch gate.update(quality: usable?.confidence ?? 0, at: time) {
        case .good:
            guard let s = usable else { return machine.update(at: now, pose: nil) }
            let filtered = filter.filter(s.orientation, at: s.timestamp)
            lastFilteredRaw = filtered
            return machine.update(at: s.timestamp, pose: calibration.apply(filtered), confidence: 1)
        case .coast:
            return machine.coast(at: time)
        case .lost:
            return machine.update(at: now, pose: nil)
        }
    }

    /// Frames stopped arriving (the watchdog): a definite loss, no dwell.
    @discardableResult
    public mutating func processFramesStopped(now: Double) -> TrackingOutput {
        gate.forceLost()
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
