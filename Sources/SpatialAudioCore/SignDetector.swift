import Foundation

/// Yaw / pitch / roll values (units are the context's: degrees unless stated).
public struct AngleTriple: Codable, Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double

    public init(yaw: Double = 0, pitch: Double = 0, roll: Double = 0) {
        self.yaw = yaw; self.pitch = pitch; self.roll = roll
    }

    public subscript(axis: RotationAxis) -> Double {
        get {
            switch axis { case .yaw: yaw; case .pitch: pitch; case .roll: roll }
        }
        set {
            switch axis { case .yaw: yaw = newValue; case .pitch: pitch = newValue; case .roll: roll = newValue }
        }
    }
}

/// ALL THRESHOLDS ARE PROPOSALS, UNTUNED. They are printed in every report so they can be tightened or
/// loosened from real data.
///
/// Why these values: a deliberate "toward the shoulder" turn should be several times larger than the yaw
/// floor, and a chin-up or ear-tilt several times larger than the pitch/roll floor, while the floors sit
/// well above expected Vision jitter and drift between the reference and hold windows. The noise-multiple
/// term makes the floor adapt when the data is noisy (e.g. a dim room). Rest-pose offsets (raw pitch was
/// −11.7° at rest in the first manual session) cancel because the test uses hold − reference differences.
public struct SignDetectionConfig: Codable, Equatable, Sendable {
    /// Minimum |hold − reference| of the instructed axis, degrees.
    public var minMovementDegrees = AngleTriple(yaw: 15, pitch: 10, roll: 10)
    /// The movement must also exceed this many robust standard deviations of the reference window.
    public var noiseMultiple = 5.0
    /// The hold must be steady: its robust spread must not exceed this fraction of the movement.
    public var maxHoldSpreadRatio = 0.4
    /// No other axis may move more than this fraction of the instructed axis (catches axis mix-ups).
    public var maxLeakageRatio = 0.6
    public var minReferenceSamples = 10
    public var minHoldSamples = 15
    /// Minimum fraction of hold-window frames in which a face was found.
    public var minFacePresentFraction = 0.6
    /// How many repetitions must be individually usable (and agree) for a result.
    public var requiredValidRepetitions = 2
    /// Informational only: note when the smaller repetition is below this fraction of the larger.
    public var magnitudeAgreementRatio = 0.5

    public init() {}
}

/// Raw Vision samples for one repetition of one move.
public struct RepetitionEvidence: Equatable, Sendable {
    /// Samples (faces found) from the steady window of the phase right before the hold.
    public var reference: [VisionFaceAngles]
    /// All frames (face or not) in the reference window.
    public var referenceFrames: Int
    /// Samples from the steady window of the hold.
    public var hold: [VisionFaceAngles]
    public var holdFrames: Int
    /// Fraction of the face-bearing frames (reference + hold) that were horizontally mirrored; nil if none.
    public var mirroredFraction: Double?

    public init(reference: [VisionFaceAngles], referenceFrames: Int, hold: [VisionFaceAngles],
                holdFrames: Int, mirroredFraction: Double?) {
        self.reference = reference; self.referenceFrames = referenceFrames
        self.hold = hold; self.holdFrames = holdFrames; self.mirroredFraction = mirroredFraction
    }

    public init(referenceFrames: [SelfTestFrame], holdFrames: [SelfTestFrame]) {
        let ref = referenceFrames.filter { !$0.isWatchdogTick && $0.angles != nil }
        let hold = holdFrames.filter { !$0.isWatchdogTick && $0.angles != nil }
        let faces = ref + hold
        self.init(reference: ref.compactMap(\.angles), referenceFrames: referenceFrames.count,
                  hold: hold.compactMap(\.angles), holdFrames: holdFrames.count,
                  mirroredFraction: faces.isEmpty ? nil : Double(faces.filter(\.frameMirrored).count) / Double(faces.count))
    }
}

public struct RepetitionResult: Codable, Equatable, Sendable {
    public var usable: Bool
    /// hold median − reference median, RAW Vision degrees, all three axes (shows leakage).
    public var deltaDegrees: AngleTriple
    public var intendedDeltaDegrees: Double
    /// Robust spread of the instructed axis in the reference window / inside the hold.
    public var referenceNoiseDegrees: Double
    public var holdSpreadDegrees: Double
    /// max(axis floor, noiseMultiple × reference noise).
    public var requiredMovementDegrees: Double
    /// Largest other-axis |Δ| ÷ |intended Δ| (capped at 999).
    public var leakageRatio: Double
    public var referenceSamples: Int
    public var holdSamples: Int
    public var holdFrames: Int
    public var problems: [String]
}

public enum SignOutcome: String, Codable, Sendable {
    case determined, inconclusive
}

public struct AxisSignResult: Codable, Equatable, Sendable {
    public var axis: RotationAxis
    public var outcome: SignOutcome
    /// Sign (+1 / −1) of the RAW Vision change during the instructed move; nil if inconclusive.
    public var rawVisionSign: Int?
    /// Whether the invert flag must be ON, relative to the documented default mapping
    /// (`HeadAngleMapping()` with all invert flags off, including its mirror compensation). nil if inconclusive.
    public var invertNeeded: Bool?
    /// Mirror state of the frames used (nil if inconclusive).
    public var framesMirrored: Bool?
    public var repetitions: [RepetitionResult]
    /// Why the result is inconclusive, or notes about a determined one.
    public var reasons: [String]
}

public enum SignDetector {
    private static let deg = 180 / Double.pi

    public static func analyze(axis: RotationAxis, evidence: [RepetitionEvidence],
                               config: SignDetectionConfig = SignDetectionConfig()) -> AxisSignResult {
        let reps = evidence.map { analyzeRepetition(axis: axis, evidence: $0, config: config) }
        var reasons: [String] = []

        func inconclusive() -> AxisSignResult {
            AxisSignResult(axis: axis, outcome: .inconclusive, rawVisionSign: nil, invertNeeded: nil,
                           framesMirrored: nil, repetitions: reps, reasons: reasons)
        }

        let usable = reps.indices.filter { reps[$0].usable }
        if usable.count < config.requiredValidRepetitions {
            reasons.append("only \(usable.count) of \(reps.count) repetitions usable (need \(config.requiredValidRepetitions))")
            for i in reps.indices where !reps[i].usable {
                for p in reps[i].problems { reasons.append("repetition \(i + 1): \(p)") }
            }
            return inconclusive()
        }

        // Sign agreement between repetitions.
        let signs = Set(usable.map { reps[$0].intendedDeltaDegrees > 0 ? 1 : -1 })
        if signs.count > 1 {
            let list = usable.map { String(format: "%+.1f°", reps[$0].intendedDeltaDegrees) }.joined(separator: ", ")
            reasons.append("repetitions disagree on the direction of the change (\(list))")
            return inconclusive()
        }

        // Mirroring must be constant and known, otherwise the mirror compensation cannot be trusted.
        let fractions = usable.compactMap { evidence[$0].mirroredFraction }
        if fractions.contains(where: { $0 > 0.05 && $0 < 0.95 }) {
            reasons.append("frame mirroring changed within a repetition")
            return inconclusive()
        }
        let mirrorFlags = Set(fractions.map { $0 >= 0.5 })
        if mirrorFlags.count != 1 {
            reasons.append("frame mirroring differs between repetitions")
            return inconclusive()
        }
        let mirrored = mirrorFlags.first!

        // Direction: derive the invert flag through the REAL mapping so it cannot disagree with it.
        let deltas = usable.map { reps[$0].intendedDeltaDegrees }
        let delta = RobustStats.median(deltas)!
        var probe = AngleTriple()
        probe[axis] = delta
        let mapped = HeadAngleMapping().euler(
            from: VisionFaceAngles(yaw: probe.yaw / deg, pitch: probe.pitch / deg, roll: probe.roll / deg),
            frameMirrored: mirrored)
        let mappedValue = mapped.value(for: axis)

        let mags = deltas.map(abs)
        if let lo = mags.min(), let hi = mags.max(), hi > 0, lo / hi < config.magnitudeAgreementRatio {
            reasons.append(String(format: "note: repetition magnitudes differ by more than %.0fx (%.1f° vs %.1f°); the direction still agrees",
                                  1 / config.magnitudeAgreementRatio, lo, hi))
        }
        return AxisSignResult(axis: axis, outcome: .determined, rawVisionSign: delta > 0 ? 1 : -1,
                              invertNeeded: mappedValue < 0, framesMirrored: mirrored,
                              repetitions: reps, reasons: reasons)
    }

    static func analyzeRepetition(axis: RotationAxis, evidence e: RepetitionEvidence,
                                  config c: SignDetectionConfig) -> RepetitionResult {
        var problems: [String] = []
        let faceFraction = e.holdFrames > 0 ? Double(e.hold.count) / Double(e.holdFrames) : 0

        if e.reference.count < c.minReferenceSamples {
            problems.append("too few reference samples (\(e.reference.count), need \(c.minReferenceSamples))")
        }
        if e.hold.count < c.minHoldSamples {
            problems.append("too few hold samples (\(e.hold.count), need \(c.minHoldSamples))")
        }
        if e.holdFrames > 0, e.hold.count >= c.minHoldSamples, faceFraction < c.minFacePresentFraction {
            problems.append(String(format: "face found in only %.0f%% of hold frames (need %.0f%%)",
                                   faceFraction * 100, c.minFacePresentFraction * 100))
        }
        guard e.reference.count >= c.minReferenceSamples, e.hold.count >= c.minHoldSamples else {
            return RepetitionResult(usable: false, deltaDegrees: AngleTriple(), intendedDeltaDegrees: 0,
                                    referenceNoiseDegrees: 0, holdSpreadDegrees: 0,
                                    requiredMovementDegrees: c.minMovementDegrees[axis], leakageRatio: 999,
                                    referenceSamples: e.reference.count, holdSamples: e.hold.count,
                                    holdFrames: e.holdFrames, problems: problems)
        }

        func values(_ xs: [VisionFaceAngles], _ a: RotationAxis) -> [Double] {
            xs.map { $0.value(for: a) * deg }
        }
        var delta = AngleTriple()
        for a in RotationAxis.allCases {
            delta[a] = RobustStats.median(values(e.hold, a))! - RobustStats.median(values(e.reference, a))!
        }
        let intended = delta[axis]
        let noise = RobustStats.sigma(values(e.reference, axis)) ?? 0
        let spread = RobustStats.sigma(values(e.hold, axis)) ?? 0
        let required = max(c.minMovementDegrees[axis], c.noiseMultiple * noise)
        let others = RotationAxis.allCases.filter { $0 != axis }
        let leakage = abs(intended) > 1e-9
            ? min(999, others.map { abs(delta[$0]) / abs(intended) }.max() ?? 0) : 999

        if abs(intended) < required {
            problems.append(String(format: "movement too small: %.1f° < required %.1f° (floor %.0f°, %.0f× noise %.1f°)",
                                   abs(intended), required, c.minMovementDegrees[axis], c.noiseMultiple, noise))
        } else {
            if spread > c.maxHoldSpreadRatio * abs(intended) {
                problems.append(String(format: "hold not steady: spread %.1f° vs movement %.1f° (limit %.0f%%)",
                                       spread, abs(intended), c.maxHoldSpreadRatio * 100))
            }
            if leakage > c.maxLeakageRatio {
                let worst = others.max { abs(delta[$0]) < abs(delta[$1]) }!
                problems.append(String(format: "wrong axis dominates: %@ changed %.1f° vs %.1f° on %@ (limit %.1f×)",
                                       worst.rawValue, abs(delta[worst]), abs(intended), axis.rawValue, c.maxLeakageRatio))
            }
        }
        return RepetitionResult(usable: problems.isEmpty, deltaDegrees: delta, intendedDeltaDegrees: intended,
                                referenceNoiseDegrees: noise, holdSpreadDegrees: spread,
                                requiredMovementDegrees: required, leakageRatio: leakage,
                                referenceSamples: e.reference.count, holdSamples: e.hold.count,
                                holdFrames: e.holdFrames, problems: problems)
    }
}

extension VisionFaceAngles {
    func value(for axis: RotationAxis) -> Double {
        switch axis {
        case .yaw: yaw
        case .pitch: pitch
        case .roll: roll
        }
    }
}

extension EulerAngles {
    func value(for axis: RotationAxis) -> Double {
        switch axis {
        case .yaw: yaw
        case .pitch: pitch
        case .roll: roll
        }
    }
}
