import Foundation

/// One-Euro filter parameters (Casiez, Roussel, Vogel, CHI 2012).
/// DEFAULTS ARE UNTUNED PLACEHOLDERS; they must be tuned on real camera data (Step 2).
public struct OneEuroParameters: Equatable, Sendable {
    /// Cutoff (Hz) at zero speed. Lower = smoother but laggier when still.
    public var minCutoff: Double
    /// How strongly speed raises the cutoff. Higher = less lag during fast motion.
    public var beta: Double
    /// Cutoff (Hz) for the speed estimate.
    public var derivativeCutoff: Double
    /// If the gap between samples exceeds this (seconds) the filter restarts from the new sample.
    public var resetGap: Double

    public init(minCutoff: Double = 1.0, beta: Double = 0.5, derivativeCutoff: Double = 1.0, resetGap: Double = 0.5) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
        self.resetGap = resetGap
    }
}

enum OneEuroMath {
    /// Low-pass smoothing factor for a given cutoff (Hz) and timestep (s).
    static func alpha(cutoff: Double, dt: Double) -> Double {
        let c = max(cutoff, 1e-6)
        let tau = 1 / (2 * Double.pi * c)
        return 1 / (1 + tau / dt)
    }
}

/// Scalar One-Euro filter. Timestamps are seconds on any monotonic clock.
public struct OneEuroFilter: Sendable {
    public var parameters: OneEuroParameters
    private var prevRaw: Double?
    private var prevFiltered = 0.0
    private var prevDerivative = 0.0
    private var prevTime = 0.0

    public init(parameters: OneEuroParameters = OneEuroParameters()) {
        self.parameters = parameters
    }

    public mutating func reset() { prevRaw = nil }

    /// Filter one sample. Non-finite input or a non-increasing timestamp returns the previous output.
    public mutating func filter(_ value: Double, at time: Double) -> Double {
        guard value.isFinite, time.isFinite else { return prevRaw == nil ? 0 : prevFiltered }
        guard let raw = prevRaw else {
            start(value, time); return value
        }
        let dt = time - prevTime
        if dt <= 0 { return prevFiltered }
        if dt > parameters.resetGap { start(value, time); return value }

        let derivative = (value - raw) / dt
        let dHat = prevDerivative + OneEuroMath.alpha(cutoff: parameters.derivativeCutoff, dt: dt) * (derivative - prevDerivative)
        let cutoff = parameters.minCutoff + parameters.beta * abs(dHat)
        let a = OneEuroMath.alpha(cutoff: cutoff, dt: dt)
        let filtered = prevFiltered + a * (value - prevFiltered)

        prevRaw = value; prevFiltered = filtered; prevDerivative = dHat; prevTime = time
        return filtered
    }

    private mutating func start(_ value: Double, _ time: Double) {
        prevRaw = value; prevFiltered = value; prevDerivative = 0; prevTime = time
    }
}

/// One-Euro filter on orientation. Works directly on quaternions (no Euler angles):
/// angular speed drives an adaptive cutoff, and the output slerps toward the input.
public struct OneEuroQuaternionFilter: Sendable {
    public var parameters: OneEuroParameters
    private var prevRaw: Quaternion?
    private var prevFiltered = Quaternion.identity
    private var prevSpeed = 0.0   // rad/s, low-passed
    private var prevTime = 0.0

    public init(parameters: OneEuroParameters = OneEuroParameters()) {
        self.parameters = parameters
    }

    public mutating func reset() { prevRaw = nil }

    /// Filter one orientation sample; output is always unit length.
    /// Non-finite input or a non-increasing timestamp returns the previous output.
    public mutating func filter(_ q: Quaternion, at time: Double) -> Quaternion {
        guard q.isFinite, time.isFinite else { return prevRaw == nil ? .identity : prevFiltered }
        let q = q.normalized()
        guard let raw = prevRaw else {
            start(q, time); return q
        }
        let dt = time - prevTime
        if dt <= 0 { return prevFiltered }
        if dt > parameters.resetGap { start(q, time); return q }

        let speed = raw.angle(to: q) / dt
        let sHat = prevSpeed + OneEuroMath.alpha(cutoff: parameters.derivativeCutoff, dt: dt) * (speed - prevSpeed)
        let cutoff = parameters.minCutoff + parameters.beta * sHat
        let a = OneEuroMath.alpha(cutoff: cutoff, dt: dt)
        let filtered = Quaternion.slerp(prevFiltered, q, a)

        prevRaw = q; prevFiltered = filtered; prevSpeed = sHat; prevTime = time
        return filtered
    }

    private mutating func start(_ q: Quaternion, _ time: Double) {
        prevRaw = q; prevFiltered = q; prevSpeed = 0; prevTime = time
    }
}
