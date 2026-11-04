import Foundation

/// Locked -> Holding -> Decaying -> Static.
public enum TrackingState: String, Sendable {
    /// Face tracked; output follows the (filtered, calibrated) pose.
    case locked
    /// Tracking just lost; output frozen at the last output.
    case holding
    /// Output eases from the held pose back to neutral (identity).
    case decaying
    /// At neutral, no tracking (also the initial state).
    case `static`
}

/// DEFAULTS ARE UNTUNED PLACEHOLDERS (no user testing yet).
public struct TrackingStateMachineConfig: Equatable, Sendable, Codable {
    /// Samples below this confidence count as "lost".
    public var minConfidence: Double
    /// Seconds to freeze the pose after loss before decaying.
    public var holdDuration: Double
    /// Seconds to ease from the held pose to neutral.
    public var decayDuration: Double
    /// Seconds to blend from the previous output to the live pose after (re)acquiring.
    public var reacquireBlendDuration: Double

    public init(minConfidence: Double = 0.5, holdDuration: Double = 0.5,
                decayDuration: Double = 1.5, reacquireBlendDuration: Double = 0.25) {
        self.minConfidence = minConfidence
        self.holdDuration = holdDuration
        self.decayDuration = decayDuration
        self.reacquireBlendDuration = reacquireBlendDuration
    }
}

public struct TrackingOutput: Equatable, Sendable {
    public var state: TrackingState
    /// Calibrated listener orientation (identity = neutral).
    public var pose: Quaternion
}

/// Turns a stream of (possibly missing) poses into a continuous output pose.
/// Invariant: every output starts from the previous output, so the pose never jumps on
/// face loss, on reacquire, or on the first lock (blends are eased, bounded-speed slerps).
///
/// Call `update` regularly (e.g. every video frame, and on a timer while lost) with a
/// monotonic timestamp in seconds. Decay/hold timing advances only through `update`.
public struct TrackingStateMachine: Sendable {
    public var config: TrackingStateMachineConfig
    public private(set) var state: TrackingState = .static
    public private(set) var lastOutput: Quaternion = .identity
    public private(set) var lastUpdateTime: Double?

    private var heldPose: Quaternion = .identity
    private var lossStart: Double = 0
    private var blendFrom: Quaternion?
    private var blendStart: Double = 0

    public init(config: TrackingStateMachineConfig = TrackingStateMachineConfig()) {
        self.config = config
    }

    public mutating func reset() {
        state = .static; lastOutput = .identity; lastUpdateTime = nil; blendFrom = nil
        heldPose = .identity; lossStart = 0; blendStart = 0
    }

    /// Start a smooth blend from the current output to whatever pose arrives next
    /// (used after a recenter so the calibration change does not cause a jump).
    public mutating func beginBlend(at time: Double) {
        guard state == .locked else { return }
        blendFrom = lastOutput
        blendStart = max(time, lastUpdateTime ?? time)
    }

    /// `pose == nil`, non-finite pose, or `confidence < config.minConfidence` counts as lost.
    @discardableResult
    public mutating func update(at time: Double, pose: Quaternion?, confidence: Double = 1) -> TrackingOutput {
        // Clamp so time never runs backwards.
        let t = max(time.isFinite ? time : (lastUpdateTime ?? 0), lastUpdateTime ?? -Double.infinity)
        lastUpdateTime = t

        let out: Quaternion
        if let pose, pose.isFinite, confidence >= config.minConfidence {
            if state != .locked {
                blendFrom = lastOutput
                blendStart = t
            }
            state = .locked
            out = blended(target: pose.normalized(), at: t)
        } else {
            if state == .locked {
                state = .holding
                lossStart = t
                heldPose = lastOutput
                blendFrom = nil
            }
            out = lostOutput(at: t)
        }
        lastOutput = out
        return TrackingOutput(state: state, pose: out)
    }

    // MARK: - Private

    private mutating func blended(target: Quaternion, at t: Double) -> Quaternion {
        guard let from = blendFrom else { return target }
        let d = config.reacquireBlendDuration
        guard d > 0 else { blendFrom = nil; return target }
        let u = (t - blendStart) / d
        if u >= 1 { blendFrom = nil; return target }
        return Quaternion.slerp(from, target, Self.smoothstep(u))
    }

    private mutating func lostOutput(at t: Double) -> Quaternion {
        switch state {
        case .static, .locked:
            return .identity   // .locked cannot occur here; .static stays at neutral
        case .holding, .decaying:
            let elapsed = t - lossStart
            if elapsed < config.holdDuration {
                state = .holding
                return heldPose
            }
            let decayElapsed = elapsed - config.holdDuration
            if config.decayDuration > 0, decayElapsed < config.decayDuration {
                state = .decaying
                return Quaternion.slerp(heldPose, .identity, Self.smoothstep(decayElapsed / config.decayDuration))
            }
            state = .static
            return .identity
        }
    }

    /// Eased 0...1 with zero slope at both ends (no velocity step when a phase starts/ends).
    static func smoothstep(_ u: Double) -> Double {
        let x = min(max(u, 0), 1)
        return x * x * (3 - 2 * x)
    }
}
