import Foundation

/// Deterministic synthetic "person" that follows a `SelfTestScript` and produces the RAW Vision angles a
/// camera would report, under configurable Vision sign conventions. It exists so the self-test logic can
/// be exercised without a camera (unit tests, and a clearly labeled SIMULATED mode in the app).
///
/// IT IS NOT EVIDENCE ABOUT REAL HARDWARE. Its numbers are made up (target angles, noise, offsets) and
/// the default `conventions` are the documented-header assumptions, not measured behavior.
public struct SimulatedUser: Sendable {
    /// Sign of the RAW Vision value per unit of OUR-convention movement.
    /// Documented assumption: turning left → Vision yaw +, looking up → Vision pitch − (Vision pitch is
    /// "positive = nodding down"), tilting right ear down → Vision roll +.
    public struct Conventions: Equatable, Sendable {
        public var yawPerLeft = 1.0
        public var pitchPerUp = -1.0
        public var rollPerRightEar = 1.0
        public init(yawPerLeft: Double = 1, pitchPerUp: Double = -1, rollPerRightEar: Double = 1) {
            self.yawPerLeft = yawPerLeft; self.pitchPerUp = pitchPerUp; self.rollPerRightEar = rollPerRightEar
        }
    }

    public var script: SelfTestScript
    public var conventions: Conventions
    /// Raw Vision angles at rest (degrees). The pitch default mirrors the −11.7° seen in the first manual session.
    public var restRawOffsetsDegrees: AngleTriple
    /// Peak movement per move in OUR convention (degrees).
    public var moveTargetsDegrees: AngleTriple
    /// Head turn held during the loss test (degrees, +yaw = left).
    public var lossTurnYawDegrees: Double
    public var noiseSigmaDegrees: Double
    public var rampSeconds: Double
    /// Time for the hand to cover / uncover the lens after the cue.
    public var coverReactionSeconds: Double
    public var uncoverReactionSeconds: Double
    /// If true, the delivered image is horizontally mirrored: Vision yaw and roll flip sign.
    public var framesMirrored: Bool
    public var seed: UInt64

    public init(script: SelfTestScript = .standard,
                conventions: Conventions = Conventions(),
                restRawOffsetsDegrees: AngleTriple = AngleTriple(yaw: 1.5, pitch: -11.7, roll: -3.5),
                moveTargetsDegrees: AngleTriple = AngleTriple(yaw: 45, pitch: 25, roll: 25),
                lossTurnYawDegrees: Double = 25, noiseSigmaDegrees: Double = 0.8, rampSeconds: Double = 0.7,
                coverReactionSeconds: Double = 0.4, uncoverReactionSeconds: Double = 0.4,
                framesMirrored: Bool = false, seed: UInt64 = 1) {
        self.script = script; self.conventions = conventions; self.restRawOffsetsDegrees = restRawOffsetsDegrees
        self.moveTargetsDegrees = moveTargetsDegrees; self.lossTurnYawDegrees = lossTurnYawDegrees
        self.noiseSigmaDegrees = noiseSigmaDegrees; self.rampSeconds = rampSeconds
        self.coverReactionSeconds = coverReactionSeconds; self.uncoverReactionSeconds = uncoverReactionSeconds
        self.framesMirrored = framesMirrored; self.seed = seed
    }

    /// Head angles in OUR convention (degrees) the person is aiming for during phase `i`.
    func target(ofPhase i: Int) -> AngleTriple {
        guard script.phases.indices.contains(i) else { return AngleTriple() }
        let p = script.phases[i]
        switch p.kind {
        case .hold:
            var t = AngleTriple()
            if let m = p.move { t[m.axis] = moveTargetsDegrees[m.axis] }
            return t
        case .lossTurn, .cover, .uncover:
            return AngleTriple(yaw: lossTurnYawDegrees)
        case .getReady, .baseline, .rest:
            return AngleTriple()
        }
    }

    /// The person's head angles in OUR convention (degrees), smoothly moving between phase targets.
    public func headAnglesDegrees(atElapsed t: Double) -> AngleTriple {
        guard t > 0 else { return AngleTriple() }
        let i = script.index(atElapsed: t) ?? (script.phases.count - 1)
        let prev = i > 0 ? target(ofPhase: i - 1) : AngleTriple()
        let cur = target(ofPhase: i)
        let into = min(max((t - script.starts[i]) / max(rampSeconds, 1e-6), 0), 1)
        let s = into * into * (3 - 2 * into)
        var out = AngleTriple()
        for a in RotationAxis.allCases { out[a] = prev[a] + (cur[a] - prev[a]) * s }
        return out
    }

    /// Is the lens covered (no face visible) at this time?
    public func isCovered(atElapsed t: Double) -> Bool {
        guard let c = script.firstIndex(of: .cover), let u = script.firstIndex(of: .uncover) else { return false }
        return t >= script.starts[c] + coverReactionSeconds && t < script.starts[u] + uncoverReactionSeconds
    }

    /// RAW Vision angles for frame number `frameIndex` at `elapsed` seconds; nil when the lens is covered.
    public func rawAngles(frameIndex: Int, atElapsed t: Double) -> VisionFaceAngles? {
        if isCovered(atElapsed: t) { return nil }
        let head = headAnglesDegrees(atElapsed: t)
        let rest = restRawOffsetsDegrees
        var yaw = conventions.yawPerLeft * head.yaw + rest.yaw
        let pitch = conventions.pitchPerUp * head.pitch + rest.pitch
        var roll = conventions.rollPerRightEar * head.roll + rest.roll
        if framesMirrored { yaw = -yaw; roll = -roll }
        let n = noise(frameIndex)
        let d = Double.pi / 180
        return VisionFaceAngles(yaw: (yaw + n.0) * d, pitch: (pitch + n.1) * d, roll: (roll + n.2) * d)
    }

    /// Stateless approximately-Gaussian noise (sum of 4 uniforms) so any frame can be regenerated.
    private func noise(_ frame: Int) -> (Double, Double, Double) {
        func uniform(_ k: UInt64) -> Double {
            var z = (seed &+ k &* 0x9E3779B97F4A7C15) &+ 0x9E3779B97F4A7C15
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z = z ^ (z >> 31)
            return Double(z >> 11) / Double(1 << 53)
        }
        func gauss(_ axis: UInt64) -> Double {
            let base = UInt64(truncatingIfNeeded: frame) &* 16 &+ axis &* 4
            let s = uniform(base) + uniform(base + 1) + uniform(base + 2) + uniform(base + 3)
            return (s - 2) * 1.7320508 * noiseSigmaDegrees      // Irwin–Hall(4): mean 2, variance 1/3 → σ 1
        }
        return (gauss(0), gauss(1), gauss(2))
    }
}
