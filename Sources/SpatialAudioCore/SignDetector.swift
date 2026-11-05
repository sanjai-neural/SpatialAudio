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
    /// When the movement requirement is set by the noise term and the reference window's robust spread (1.4826 x MAD) is at
    /// least this, the reason given is "the reference was not steady" (the head moved during a phase that asks for stillness)
    /// instead of "movement too small". It changes the wording only: the requirement itself is unchanged.
    public var steadyReferenceSigmaDegrees = 3.0
    /// Sub-window length (samples) used to measure slow drift inside a reference window.
    public var driftSubWindowSamples = 10

    public init() {}
}

extension SignDetectionConfig {
    private enum CodingKeys: String, CodingKey {
        case minMovementDegrees, noiseMultiple, maxHoldSpreadRatio, maxLeakageRatio, minReferenceSamples, minHoldSamples
        case minFacePresentFraction, requiredValidRepetitions, magnitudeAgreementRatio, steadyReferenceSigmaDegrees, driftSubWindowSamples
    }

    /// Tolerant of reports written before Step 2d: a missing key takes the current default.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minMovementDegrees = try c.decodeIfPresent(AngleTriple.self, forKey: .minMovementDegrees) ?? minMovementDegrees
        noiseMultiple = try c.decodeIfPresent(Double.self, forKey: .noiseMultiple) ?? noiseMultiple
        maxHoldSpreadRatio = try c.decodeIfPresent(Double.self, forKey: .maxHoldSpreadRatio) ?? maxHoldSpreadRatio
        maxLeakageRatio = try c.decodeIfPresent(Double.self, forKey: .maxLeakageRatio) ?? maxLeakageRatio
        minReferenceSamples = try c.decodeIfPresent(Int.self, forKey: .minReferenceSamples) ?? minReferenceSamples
        minHoldSamples = try c.decodeIfPresent(Int.self, forKey: .minHoldSamples) ?? minHoldSamples
        minFacePresentFraction = try c.decodeIfPresent(Double.self, forKey: .minFacePresentFraction) ?? minFacePresentFraction
        requiredValidRepetitions = try c.decodeIfPresent(Int.self, forKey: .requiredValidRepetitions) ?? requiredValidRepetitions
        magnitudeAgreementRatio = try c.decodeIfPresent(Double.self, forKey: .magnitudeAgreementRatio) ?? magnitudeAgreementRatio
        steadyReferenceSigmaDegrees = try c.decodeIfPresent(Double.self, forKey: .steadyReferenceSigmaDegrees) ?? steadyReferenceSigmaDegrees
        driftSubWindowSamples = try c.decodeIfPresent(Int.self, forKey: .driftSubWindowSamples) ?? driftSubWindowSamples
    }
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

/// Statistics of one axis over one window of raw Vision samples, in degrees. Shown in the report so a "noise floor" can be
/// read for what it is. `sigmaDegrees` (1.4826 x median absolute deviation) is the figure the decision uses; `rangeDegrees`
/// (max - min) is printed only to show how much larger a range-based estimate would have been; `driftDegrees` is how far
/// the medians of overlapping sub-windows wander, i.e. slow movement inside a window that was supposed to be still.
public struct BaselineStats: Codable, Equatable, Sendable {
    public var samples: Int
    public var medianDegrees: Double
    public var sigmaDegrees: Double
    public var rangeDegrees: Double
    public var p10ToP90Degrees: Double
    public var driftDegrees: Double

    public init?(_ xs: [Double], driftSubWindow: Int = 10) {
        let v = xs.filter(\.isFinite)
        guard let median = RobustStats.median(v), let sigma = RobustStats.sigma(v),
              let lo = v.min(), let hi = v.max(),
              let p10 = RobustStats.percentile(v, 10), let p90 = RobustStats.percentile(v, 90) else { return nil }
        samples = v.count; medianDegrees = median; sigmaDegrees = sigma
        rangeDegrees = hi - lo; p10ToP90Degrees = p90 - p10
        var medians: [Double] = []
        if v.count >= 2 * driftSubWindow, driftSubWindow > 1 {
            var i = 0
            while i + driftSubWindow <= v.count {
                if let m = RobustStats.median(Array(v[i..<(i + driftSubWindow)])) { medians.append(m) }
                i += max(1, driftSubWindow / 2)
            }
        }
        driftDegrees = (medians.max() ?? 0) - (medians.min() ?? 0)
    }
}

public struct AxisBaselines: Codable, Equatable, Sendable {
    public var yaw: BaselineStats?
    public var pitch: BaselineStats?
    public var roll: BaselineStats?
}

public struct RepetitionResult: Codable, Equatable, Sendable {
    public var usable: Bool
    /// Enough movement and a steady hold, whatever the other axes did (only the leakage check may still have failed).
    public var enoughMovement: Bool = false
    /// The cross-axis leakage check failed (the move itself was big and steady enough).
    public var leakageFailed: Bool = false
    /// Robust statistics of the reference window and of the hold window, per axis (nil when there were too few samples).
    public var referenceStats: AxisBaselines? = nil
    public var holdStats: AxisBaselines? = nil
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

extension RepetitionResult {
    private enum CodingKeys: String, CodingKey {
        case usable, enoughMovement, leakageFailed, referenceStats, holdStats, deltaDegrees, intendedDeltaDegrees
        case referenceNoiseDegrees, holdSpreadDegrees, requiredMovementDegrees, leakageRatio
        case referenceSamples, holdSamples, holdFrames, problems
    }

    /// Reports written before Step 2d (schema 1) lack `enoughMovement`, `leakageFailed` and the baseline statistics; they decode
    /// with `usable` as the best available answer and no statistics.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let usable = try c.decode(Bool.self, forKey: .usable)
        self.init(usable: usable,
                  enoughMovement: try c.decodeIfPresent(Bool.self, forKey: .enoughMovement) ?? usable,
                  leakageFailed: try c.decodeIfPresent(Bool.self, forKey: .leakageFailed) ?? false,
                  referenceStats: try c.decodeIfPresent(AxisBaselines.self, forKey: .referenceStats),
                  holdStats: try c.decodeIfPresent(AxisBaselines.self, forKey: .holdStats),
                  deltaDegrees: try c.decode(AngleTriple.self, forKey: .deltaDegrees),
                  intendedDeltaDegrees: try c.decode(Double.self, forKey: .intendedDeltaDegrees),
                  referenceNoiseDegrees: try c.decode(Double.self, forKey: .referenceNoiseDegrees),
                  holdSpreadDegrees: try c.decode(Double.self, forKey: .holdSpreadDegrees),
                  requiredMovementDegrees: try c.decode(Double.self, forKey: .requiredMovementDegrees),
                  leakageRatio: try c.decode(Double.self, forKey: .leakageRatio),
                  referenceSamples: try c.decode(Int.self, forKey: .referenceSamples),
                  holdSamples: try c.decode(Int.self, forKey: .holdSamples),
                  holdFrames: try c.decode(Int.self, forKey: .holdFrames),
                  problems: try c.decode([String].self, forKey: .problems))
    }
}

public enum SignOutcome: String, Codable, Sendable {
    /// At least two repetitions were big, steady, leak-free and agree on the direction.
    case determined
    /// At least two repetitions had enough, steady movement and agree on the direction, but cross-axis leakage failed in
    /// some of them. A hint only: it is NEVER applied automatically and never shown as an answer.
    case likely
    case inconclusive
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
        // Repetitions with enough, steady movement whose ONLY failure is cross-axis leakage (candidates for LIKELY).
        let enough = reps.indices.filter { reps[$0].enoughMovement }
        let required = config.requiredValidRepetitions

        let outcomeIfAgreed: SignOutcome
        let candidates: [Int]
        if usable.count >= required {
            outcomeIfAgreed = .determined; candidates = usable
        } else if enough.count >= required, enough.contains(where: { reps[$0].leakageFailed }) {
            outcomeIfAgreed = .likely; candidates = enough
        } else {
            reasons.append("only \(usable.count) of \(reps.count) repetitions usable (need \(required))")
            for i in reps.indices where !reps[i].usable {
                for p in reps[i].problems { reasons.append("repetition \(i + 1): \(p)") }
            }
            return inconclusive()
        }

        // Sign agreement between repetitions.
        let signs = Set(candidates.map { reps[$0].intendedDeltaDegrees > 0 ? 1 : -1 })
        if signs.count > 1 {
            let list = candidates.map { String(format: "%+.1f°", reps[$0].intendedDeltaDegrees) }.joined(separator: ", ")
            reasons.append("repetitions disagree on the direction of the change (\(list))")
            return inconclusive()
        }

        // Mirroring must be constant and known, otherwise the mirror compensation cannot be trusted.
        let fractions = candidates.compactMap { evidence[$0].mirroredFraction }
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
        let deltas = candidates.map { reps[$0].intendedDeltaDegrees }
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
        if outcomeIfAgreed == .likely {
            let leaky = candidates.filter { reps[$0].leakageFailed }.map { "repetition \($0 + 1): " + (reps[$0].problems.first { $0.hasPrefix("wrong axis") } ?? "cross-axis leakage") }
            reasons.insert("LIKELY, not DETERMINED: the direction agrees in every repetition that had enough movement, but cross-axis leakage failed (" + leaky.joined(separator: "; ") + "). It is NEVER applied automatically; repeat with a smaller, single-axis move.", at: 0)
        }
        return AxisSignResult(axis: axis, outcome: outcomeIfAgreed, rawVisionSign: delta > 0 ? 1 : -1,
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
            return RepetitionResult(usable: false, enoughMovement: false, leakageFailed: false,
                                    referenceStats: nil, holdStats: nil,
                                    deltaDegrees: AngleTriple(), intendedDeltaDegrees: 0,
                                    referenceNoiseDegrees: 0, holdSpreadDegrees: 0,
                                    requiredMovementDegrees: c.minMovementDegrees[axis], leakageRatio: 999,
                                    referenceSamples: e.reference.count, holdSamples: e.hold.count,
                                    holdFrames: e.holdFrames, problems: problems)
        }

        func values(_ xs: [VisionFaceAngles], _ a: RotationAxis) -> [Double] {
            xs.map { $0.value(for: a) * deg }
        }
        func baselines(_ xs: [VisionFaceAngles]) -> AxisBaselines {
            AxisBaselines(yaw: BaselineStats(values(xs, .yaw), driftSubWindow: c.driftSubWindowSamples),
                          pitch: BaselineStats(values(xs, .pitch), driftSubWindow: c.driftSubWindowSamples),
                          roll: BaselineStats(values(xs, .roll), driftSubWindow: c.driftSubWindowSamples))
        }
        var delta = AngleTriple()
        for a in RotationAxis.allCases {
            delta[a] = RobustStats.median(values(e.hold, a))! - RobustStats.median(values(e.reference, a))!
        }
        let intended = delta[axis]
        // The noise figure is a ROBUST spread (1.4826 x median absolute deviation), not a range: a few outlier samples do
        // not inflate it. A large value therefore means that at least half of the window really was spread out.
        let noise = RobustStats.sigma(values(e.reference, axis)) ?? 0
        let spread = RobustStats.sigma(values(e.hold, axis)) ?? 0
        let required = max(c.minMovementDegrees[axis], c.noiseMultiple * noise)
        let others = RotationAxis.allCases.filter { $0 != axis }
        let leakage = abs(intended) > 1e-9
            ? min(999, others.map { abs(delta[$0]) / abs(intended) }.max() ?? 0) : 999

        var moveBigEnough = true, holdSteady = true, leakageFailed = false
        if abs(intended) < required {
            moveBigEnough = false
            let referenceDriven = c.noiseMultiple * noise > c.minMovementDegrees[axis] && noise >= c.steadyReferenceSigmaDegrees
            if referenceDriven {
                let drift = BaselineStats(values(e.reference, axis), driftSubWindow: c.driftSubWindowSamples)?.driftDegrees ?? 0
                problems.append(String(format: "reference window not steady: spread %.1f° (drift %.1f°) while the head should have been still, so %.1f° of movement is not enough (required %.1f° = %.0f× that spread); the head was still moving in the phase before this hold",
                                       noise, drift, abs(intended), required, c.noiseMultiple))
            } else {
                problems.append(String(format: "movement too small: %.1f° < required %.1f° (floor %.0f°, %.0f× noise %.1f°)",
                                       abs(intended), required, c.minMovementDegrees[axis], c.noiseMultiple, noise))
            }
        } else {
            if spread > c.maxHoldSpreadRatio * abs(intended) {
                holdSteady = false
                problems.append(String(format: "hold not steady: spread %.1f° vs movement %.1f° (limit %.0f%%)",
                                       spread, abs(intended), c.maxHoldSpreadRatio * 100))
            }
            if leakage > c.maxLeakageRatio {
                leakageFailed = true
                let worst = others.max { abs(delta[$0]) < abs(delta[$1]) }!
                problems.append(String(format: "wrong axis dominates: %@ changed %.1f° vs %.1f° on %@ (limit %.1f×)",
                                       worst.rawValue, abs(delta[worst]), abs(intended), axis.rawValue, c.maxLeakageRatio))
            }
        }
        let samplesOK = !problems.contains { $0.hasPrefix("too few") || $0.hasPrefix("face found in only") }
        return RepetitionResult(usable: problems.isEmpty,
                                enoughMovement: samplesOK && moveBigEnough && holdSteady,
                                leakageFailed: leakageFailed,
                                referenceStats: baselines(e.reference), holdStats: baselines(e.hold),
                                deltaDegrees: delta, intendedDeltaDegrees: intended,
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
