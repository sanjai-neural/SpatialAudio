import Foundation

/// Per-audio-block smoothing of the head pose between camera updates.
///
/// The tracker publishes a pose about 30 times a second; the renderer asks for one every audio block (about 10 ms).
/// Applying each published pose as a step would move the soundstage in 33 ms jumps, so each block moves the output
/// part of the way from where it is toward the latest published pose:
///
///     current = slerp(current, latest, 1 - exp(-dt / timeConstant))
///
/// Properties (all unit-tested): never overshoots, never jumps (a step is always a fraction of the remaining angle),
/// takes the shortest path, is independent of how `dt` is chopped (two steps of dt/2 equal one step of dt toward a fixed
/// target), and ignores non-finite or zero-length targets instead of snapping to neutral.
///
/// Real-time note: this is a plain value type (no classes, arrays or closures), so it is allowed on the render thread
/// by the rule in docs/ARCHITECTURE.md. In Step 3a it is called from the pose pump, not from an audio callback.
public struct PoseInterpolator: Sendable {
    public struct Config: Equatable, Sendable {
        /// Seconds for the output to cover 63% of the distance to a fixed target. UNTUNED placeholder: small enough
        /// not to add noticeable lag at head-turn speeds, large enough to hide the 33 ms steps.
        public var timeConstant: Double = 0.020

        public init(timeConstant: Double = 0.020) { self.timeConstant = timeConstant }
    }

    public var config: Config
    /// The pose to hand to the renderer.
    public private(set) var current: Quaternion = .identity
    /// The latest accepted target (what `current` is heading for).
    public private(set) var target: Quaternion = .identity
    /// How many targets were ignored for being non-finite or (near) zero length.
    public private(set) var rejectedTargets = 0

    public init(config: Config = Config()) { self.config = config }

    /// Accepts a new target. A bad quaternion is counted and ignored (the old target stays).
    public mutating func setTarget(_ q: Quaternion) {
        guard q.isFinite, q.norm > 1e-6 else { rejectedTargets += 1; return }
        target = q.normalized()
    }

    /// Moves `current` toward `target` for `dt` seconds and returns it. A non-positive or non-finite `dt` changes nothing.
    @discardableResult
    public mutating func advance(by dt: Double) -> Quaternion {
        guard dt.isFinite, dt > 0 else { return current }
        let alpha = config.timeConstant > 0 ? 1 - exp(-dt / config.timeConstant) : 1
        current = Quaternion.slerp(current, target, alpha)
        return current
    }

    /// Jump `current` and `target` to `q` (use only when nothing is audible, e.g. before starting).
    public mutating func reset(to q: Quaternion = .identity) {
        let n = q.isFinite && q.norm > 1e-6 ? q.normalized() : .identity
        current = n; target = n
    }
}
