import Foundation

// MARK: - Which quality component was limiting, and for what fraction of frames

/// Quality statistics for one group of frames (a phase kind, the statistics window, the loss test). Numbers only.
public struct QualityWindowSummary: Codable, Equatable, Sendable {
    public var name: String
    public var frames: Int
    /// Watchdog ticks (no frames arriving) inside the window; they are not counted in `frames`.
    public var watchdogTicks: Int
    public var meanQuality: Double
    public var minQuality: Double
    /// Fraction of frames below the gate's loss threshold / below its recovery threshold.
    public var fractionBelowLossThreshold: Double
    public var fractionBelowRecoverThreshold: Double
    /// For every frame: which component was the weakest ("none" = all components were 1, "no face", "size", "edge", ...).
    /// Values are fractions of `frames` and sum to 1.
    public var limitingFractions: [String: Double]
    /// The same, counting only frames whose quality was below the recovery threshold (empty when there were none).
    public var limitingFractionsWhenLow: [String: Double]
    /// Median quality (nil in reports written before Step 2e).
    public var medianQuality: Double? = nil
}

public enum QualityAnalyzer {
    public static func summarize(name: String, frames all: [SelfTestFrame], gate: QualityGateConfig) -> QualityWindowSummary? {
        let frames = all.filter { !$0.isWatchdogTick }
        guard !frames.isEmpty else { return nil }
        func fractions(_ xs: [SelfTestFrame]) -> [String: Double] {
            guard !xs.isEmpty else { return [:] }
            var counts: [String: Int] = [:]
            for f in xs { counts[f.limiting, default: 0] += 1 }
            return counts.mapValues { Double($0) / Double(xs.count) }
        }
        let low = frames.filter { $0.qualityOverall < gate.recoverAbove }
        let n = Double(frames.count)
        return QualityWindowSummary(
            name: name, frames: frames.count, watchdogTicks: all.count - frames.count,
            meanQuality: frames.map(\.qualityOverall).reduce(0, +) / n,
            minQuality: frames.map(\.qualityOverall).min() ?? 0,
            fractionBelowLossThreshold: Double(frames.filter { $0.qualityOverall < gate.lossBelow }.count) / n,
            fractionBelowRecoverThreshold: Double(low.count) / n,
            limitingFractions: fractions(frames), limitingFractionsWhenLow: fractions(low),
            medianQuality: RobustStats.median(frames.map(\.qualityOverall)))
    }
}

// MARK: - Evidence around the largest pose step

/// One frame of the window around the largest pose step. Numbers and short strings only.
public struct StepEvidenceFrame: Codable, Equatable, Sendable {
    /// Seconds relative to the frame at which the largest step ended (negative = before).
    public var secondsFromStep: Double
    /// RAW Vision angles, degrees; nil when no face was found.
    public var rawVisionDegrees: AngleTriple?
    /// After the sign mapping, before filtering and calibration, degrees; nil without a face.
    public var mappedDegrees: AngleTriple?
    /// The pipeline OUTPUT pose (filtered, calibrated, state machine) as yaw / pitch / roll degrees.
    public var outputPoseDegrees: AngleTriple
    public var state: String
    public var quality: Double
    public var limiting: String
    /// Face box centre and height in normalized image coordinates; nil without a face.
    public var faceBoxCenterX: Double?
    public var faceBoxCenterY: Double?
    public var faceBoxHeight: Double?
}

/// What the evidence window looks like. This is a description of SHAPE, not a verdict about the person.
public struct StepClassification: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The raw Vision orientation jumped in one frame and came back within a few frames.
        case spike
        /// The raw orientation moved a lot over several frames (consistent with a real, fast head turn).
        case multiFrameMovement
        /// The raw orientation jumped in one frame and stayed there.
        case abruptAndSustained
        /// The face appeared or disappeared at the step, so there is no raw step to compare.
        case faceAppearedOrVanished
        /// The output pose moved although the raw Vision angles hardly did: a filter / blend / calibration effect.
        case outputOnly
        case indeterminate
    }
    public var kind: Kind
    /// Angle between the raw Vision orientations of the two frames forming the step.
    public var rawStepDegrees: Double?
    public var rawStepDegreesPerSecond: Double?
    /// Frames after the step until the raw orientation was back within 30% of the step from where it was before.
    public var framesUntilRawReturned: Int?
    /// Raw orientation change from 5 frames before to 5 frames after the step.
    public var displacementOverTenFramesDegrees: Double?
    /// True if some frame within 2 frames of the step was not in the locked state.
    public var nearStateChange: Bool
    public var explanation: String
}

public struct StepEvidence: Codable, Equatable, Sendable {
    /// Size of the OUTPUT pose step (what the loss test flagged).
    public var stepDegrees: Double
    public var stateAtStep: String
    public var secondsAfterCoverCue: Double
    public var frames: [StepEvidenceFrame]
    public var classification: StepClassification
}

public enum StepEvidenceAnalyzer {
    /// Frames on each side of the step that are stored.
    public static let radius = 15
    /// UNTUNED shape thresholds, printed with the explanation:
    static let returnedFraction = 0.30       // "came back" = within 30% of the step size of the pre-step orientation
    static let maxReturnFrames = 5
    static let multiFrameFraction = 0.50     // a step smaller than half of the 10-frame displacement is part of a longer movement
    static let minRawStepDegrees = 1.0       // below this the raw angles did not really move
    static let outputOnlyFraction = 0.25     // a raw step under this fraction of the OUTPUT step did not cause it (a blend or filter did)

    /// `frames` must be sorted by arrival; `stepIndex` is the frame at which the largest output step ended.
    public static func build(frames: [SelfTestFrame], stepIndex: Int, stepDegrees: Double, coverStart: Double,
                             framesPerSecond: Double) -> StepEvidence? {
        guard frames.indices.contains(stepIndex) else { return nil }
        let lo = max(0, stepIndex - radius), hi = min(frames.count - 1, stepIndex + radius)
        let slice = Array(frames[lo...hi])
        let at = stepIndex - lo
        let t0 = frames[stepIndex].arrival
        let out: [StepEvidenceFrame] = slice.map { f in
            let e = f.pose.euler
            return StepEvidenceFrame(
                secondsFromStep: f.arrival - t0,
                rawVisionDegrees: f.angles.map { AngleTriple(yaw: $0.yaw * 180 / .pi, pitch: $0.pitch * 180 / .pi, roll: $0.roll * 180 / .pi) },
                mappedDegrees: f.mappedDegrees,
                outputPoseDegrees: AngleTriple(yaw: e.yawDegrees, pitch: e.pitchDegrees, roll: e.rollDegrees),
                state: f.state.rawValue, quality: f.qualityOverall, limiting: f.limiting,
                faceBoxCenterX: f.faceBox?.centerX, faceBoxCenterY: f.faceBox?.centerY, faceBoxHeight: f.faceBox?.height)
        }
        return StepEvidence(stepDegrees: stepDegrees, stateAtStep: frames[stepIndex].state.rawValue,
                            secondsAfterCoverCue: t0 - coverStart, frames: out,
                            classification: classify(slice, at: at, framesPerSecond: framesPerSecond))
    }

    /// Pure shape analysis of the raw Vision orientations around frame `at` (the step is between `at - 1` and `at`).
    public static func classify(_ frames: [SelfTestFrame], at: Int, framesPerSecond: Double) -> StepClassification {
        func raw(_ i: Int) -> Quaternion? {
            guard frames.indices.contains(i), let a = frames[i].angles, a.isFinite else { return nil }
            return Quaternion(euler: EulerAngles(yaw: a.yaw, pitch: a.pitch, roll: a.roll))
        }
        func deg(_ a: Quaternion, _ b: Quaternion) -> Double { a.angle(to: b) * 180 / .pi }
        let nearChange = ((at - 2)...(at + 2)).contains { i in frames.indices.contains(i) && frames[i].state != .locked }
        func result(_ kind: StepClassification.Kind, step: Double? = nil, back: Int? = nil, disp: Double? = nil, _ why: String) -> StepClassification {
            StepClassification(kind: kind, rawStepDegrees: step, rawStepDegreesPerSecond: step.map { $0 * framesPerSecond },
                               framesUntilRawReturned: back, displacementOverTenFramesDegrees: disp,
                               nearStateChange: nearChange, explanation: why + (nearChange ? " A state change happens within 2 frames of this step." : ""))
        }

        guard at >= 1, let before = raw(at - 1), let after = raw(at) else {
            return result(.faceAppearedOrVanished, "There is no Vision face on one side of the step, so the raw angles can not be compared.")
        }
        let step = deg(before, after)
        let outputStep = frames[at - 1].pose.angle(to: frames[at].pose) * 180 / .pi
        if step < max(minRawStepDegrees, outputOnlyFraction * outputStep) {
            return result(.outputOnly, step: step,
                          "The raw Vision angles moved only \(fmt(step))° across the step while the output pose moved \(fmt(outputStep))°: the filter, calibration or a state blend produced it, not the camera.")
        }
        for k in 1...maxReturnFrames {
            if let later = raw(at + k), deg(before, later) < returnedFraction * step {
                return result(.spike, step: step, back: k,
                              "The raw Vision orientation jumped \(fmt(step))° in one frame (\(fmt(step * framesPerSecond))°/s) and was back within \(Int(returnedFraction * 100))% of that \(k) frame(s) later: shaped like a single-frame outlier.")
            }
        }
        var displacement: Double?
        if let far0 = raw(at - 5), let far1 = raw(at + 4) { displacement = deg(far0, far1) }
        if let d = displacement, step < multiFrameFraction * d {
            return result(.multiFrameMovement, step: step, disp: d,
                          "The largest one-frame raw step was \(fmt(step))°, less than half of the \(fmt(d))° the raw orientation moved over 10 frames: a movement spread over several frames, consistent with a real fast turn.")
        }
        let stays = (1...3).allSatisfy { k in raw(at + k).map { deg(before, $0) >= returnedFraction * step } ?? false }
        if stays {
            return result(.abruptAndSustained, step: step, disp: displacement,
                          "The raw Vision orientation jumped \(fmt(step))° in one frame (\(fmt(step * framesPerSecond))°/s) and stayed there for the next frames: either a very fast real movement or a tracking mode switch; the data alone does not say which.")
        }
        return result(.indeterminate, step: step, disp: displacement, "The window does not fit any of the described shapes (missing frames after the step, or an irregular pattern).")
    }

    private static func fmt(_ x: Double) -> String { String(format: "%.1f", x) }
}
