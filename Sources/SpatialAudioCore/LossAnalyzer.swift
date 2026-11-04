import Foundation

/// ALL VALUES ARE PROPOSALS, UNTUNED, and are printed in the report.
///
/// Jump threshold: a step is flagged when it exceeds max(`jumpThresholdFloorDegrees`, `jumpSafetyFactor` ×
/// the largest step the designed eased blends could legitimately produce). The state machine's blends use
/// smoothstep, whose peak speed is 1.5× the mean speed, so crossing T degrees in D seconds at F frames/s
/// peaks at about 1.5·T/(D·F) degrees per frame. For a 25° turn and the default 0.25 s reacquire blend at
/// 30 fps that is about 5°/frame; for a 60° turn about 12°/frame, which is why the threshold must scale
/// instead of being a fixed number. During the loss test the head is held still, so anything beyond this
/// bound is a discontinuity, not designed motion.
public struct LossAnalysisConfig: Codable, Equatable, Sendable {
    public var jumpThresholdFloorDegrees = 10.0
    public var jumpSafetyFactor = 1.25
    public var smoothstepPeakFactor = 1.5
    /// If the pose that was held at loss is closer than this to neutral, a "no jump" result proves little.
    public var minMeaningfulTravelDegrees = 10.0
    /// Timing deviations from the configured hold/decay durations beyond this are reported as notes.
    public var timingToleranceSeconds = 0.25
    /// Pose steps across gaps longer than this × the median frame interval are not counted as jumps.
    public var ignoreGapFactor = 2.5
    /// Seconds before the cover cue where the state sequence analysis starts (so it begins in `locked`).
    public var sequenceLeadInSeconds = 1.0
    /// A gap between delivered frames longer than this is reported as a stall (cameras keep delivering frames while
    /// covered, so a long gap is a throttled or overloaded app or a camera frame-rate drop, not part of the test).
    public var frameStallWarningSeconds = 0.15

    public init() {}
}

public enum LossVerdict: String, Codable, Sendable {
    /// Expected sequence seen once and no pose jump above the threshold.
    case pass
    /// A pose jump above the threshold, or a state transition the machine should never make.
    case fail
    /// The expected sequence was not completed (e.g. never reached static or never reacquired).
    case incomplete
}

public struct StateSeconds: Codable, Equatable, Sendable {
    public var lockedBeforeLoss: Double
    public var holding: Double
    public var decaying: Double
    public var staticState: Double
}

public struct LossReport: Codable, Equatable, Sendable {
    public var verdict: LossVerdict
    public var observedSequence: [String]
    public var expectedSequence: [String]
    public var secondsInState: StateSeconds
    /// From the first `holding` frame to the first `static` frame.
    public var timeToStaticSeconds: Double?
    /// From the uncover cue to the first `locked` frame after `static` (includes the human reaction time).
    public var reacquireSecondsAfterUncoverCue: Double?
    public var expectedHoldSeconds: Double
    public var expectedDecaySeconds: Double
    public var maxFrameJumpDegrees: Double
    /// State of the frame at which the largest step ended.
    public var maxJumpState: String?
    public var maxJumpSecondsAfterCoverCue: Double?
    public var jumpThresholdDegrees: Double
    public var jumpFlagged: Bool
    /// Angle between the pose held at loss and neutral (how far the decay had to travel).
    public var heldPoseTravelDegrees: Double?
    /// Angle between neutral and the pose after reacquire (how far the reacquire blend had to travel).
    public var reacquirePoseTravelDegrees: Double?
    public var jumpCheckMeaningful: Bool
    public var framesAnalyzed: Int
    public var ignoredGapPairs: Int
    public var notes: [String]
}

public enum LossAnalyzer {
    public static let expectedSequence: [TrackingState] = [.locked, .holding, .decaying, .static, .locked]

    private static let legalTransitions: Set<String> = [
        "locked>holding", "holding>decaying", "holding>locked", "decaying>static", "decaying>locked", "static>locked",
    ]

    /// All times are absolute monotonic seconds on the same clock as `SelfTestFrame.arrival`.
    public static func analyze(frames: [SelfTestFrame], coverStart: Double, uncoverStart: Double, end: Double,
                               machine: TrackingStateMachineConfig,
                               config: LossAnalysisConfig = LossAnalysisConfig()) -> LossReport {
        let expected = expectedSequence.map(\.rawValue)
        var notes: [String] = []
        let sorted = frames.sorted { $0.arrival < $1.arrival }
        let window = sorted.filter { $0.arrival >= coverStart - config.sequenceLeadInSeconds && $0.arrival < end }

        func empty(_ why: String) -> LossReport {
            LossReport(verdict: .incomplete, observedSequence: [], expectedSequence: expected,
                       secondsInState: StateSeconds(lockedBeforeLoss: 0, holding: 0, decaying: 0, staticState: 0),
                       timeToStaticSeconds: nil, reacquireSecondsAfterUncoverCue: nil,
                       expectedHoldSeconds: machine.holdDuration, expectedDecaySeconds: machine.decayDuration,
                       maxFrameJumpDegrees: 0, maxJumpState: nil, maxJumpSecondsAfterCoverCue: nil,
                       jumpThresholdDegrees: config.jumpThresholdFloorDegrees, jumpFlagged: false,
                       heldPoseTravelDegrees: nil, reacquirePoseTravelDegrees: nil, jumpCheckMeaningful: false,
                       framesAnalyzed: window.count, ignoredGapPairs: 0, notes: [why])
        }
        guard window.count >= 5 else { return empty("too few frames in the loss window (\(window.count))") }

        // --- State runs -------------------------------------------------------------------------------
        struct Run { var state: TrackingState; var start: Double; var firstIndex: Int; var lastIndex: Int }
        var runs: [Run] = []
        for (i, f) in window.enumerated() {
            if let last = runs.last, last.state == f.state { runs[runs.count - 1].lastIndex = i }
            else { runs.append(Run(state: f.state, start: f.arrival, firstIndex: i, lastIndex: i)) }
        }
        func duration(_ r: Int) -> Double { (r + 1 < runs.count ? runs[r + 1].start : end) - runs[r].start }
        let observed = runs.map { $0.state.rawValue }

        var seconds = StateSeconds(lockedBeforeLoss: 0, holding: 0, decaying: 0, staticState: 0)
        var seenLoss = false
        for r in runs.indices {
            switch runs[r].state {
            case .locked: if !seenLoss { seconds.lockedBeforeLoss += duration(r) }
            case .holding: seenLoss = true; seconds.holding += duration(r)
            case .decaying: seenLoss = true; seconds.decaying += duration(r)
            case .static: seenLoss = true; seconds.staticState += duration(r)
            }
        }
        let firstHolding = runs.first { $0.state == .holding }
        let firstStatic = runs.first { $0.state == .static }
        let timeToStatic: Double? = (firstHolding != nil && firstStatic != nil) ? firstStatic!.start - firstHolding!.start : nil
        var reacquire: Double?
        if let s = runs.firstIndex(where: { $0.state == .static }),
           let l = runs[(s + 1)...].first(where: { $0.state == .locked }) {
            reacquire = l.start - uncoverStart
        }

        var illegal: [String] = []
        for r in 1..<max(runs.count, 1) where runs.count > 1 {
            let t = "\(runs[r - 1].state.rawValue)>\(runs[r].state.rawValue)"
            if !legalTransitions.contains(t) { illegal.append(t) }
        }
        if !illegal.isEmpty { notes.append("transitions the state machine should never make: \(illegal.joined(separator: ", "))") }

        // --- Pose continuity --------------------------------------------------------------------------
        let dts = zip(window, window.dropFirst()).map { $1.arrival - $0.arrival }.filter { $0 > 0 }
        let medianDt = RobustStats.median(dts) ?? (1.0 / 30)
        let fps = 1 / medianDt

        let realFrames = window.filter { !$0.isWatchdogTick }
        if let longest = zip(realFrames, realFrames.dropFirst()).map({ $1.arrival - $0.arrival }).max(),
           longest > config.frameStallWarningSeconds {
            notes.append(String(format: "frame delivery stalled for %.0f ms during the loss test (median interval %.0f ms): a throttled app or a camera frame-rate drop can cause false state flapping, so repeat the test before trusting this result", longest * 1000, medianDt * 1000))
        }

        let analysisFrames = sorted.filter { $0.arrival >= coverStart && $0.arrival < end }
        var maxStep = 0.0
        var maxState: TrackingState?
        var maxAt: Double?
        var ignored = 0
        for (a, b) in zip(analysisFrames, analysisFrames.dropFirst()) {
            if b.arrival - a.arrival > config.ignoreGapFactor * medianDt { ignored += 1; continue }
            let step = a.pose.angle(to: b.pose) * 180 / .pi
            if step > maxStep { maxStep = step; maxState = b.state; maxAt = b.arrival - coverStart }
        }

        let identity = Quaternion.identity
        var heldTravel: Double?
        if let h = runs.firstIndex(where: { $0.state == .holding }), h > 0, runs[h - 1].state == .locked {
            heldTravel = window[runs[h - 1].lastIndex].pose.angle(to: identity) * 180 / .pi
        }
        var reacquireTravel: Double?
        if let s = runs.firstIndex(where: { $0.state == .static }),
           let l = runs[(s + 1)...].firstIndex(where: { $0.state == .locked }) {
            reacquireTravel = window[runs[l].lastIndex].pose.angle(to: identity) * 180 / .pi
        }

        func peakStep(travel: Double?, duration: Double) -> Double {
            guard let t = travel else { return 0 }
            return duration > 0 ? config.smoothstepPeakFactor * t / (duration * fps) : t
        }
        let expectedPeak = max(peakStep(travel: reacquireTravel, duration: machine.reacquireBlendDuration),
                               peakStep(travel: heldTravel, duration: machine.decayDuration))
        let threshold = max(config.jumpThresholdFloorDegrees, config.jumpSafetyFactor * expectedPeak)
        let flagged = maxStep > threshold
        let meaningful = (heldTravel ?? 0) >= config.minMeaningfulTravelDegrees
        if !meaningful {
            notes.append(String(format: "jump check is weak: the held pose was only %.1f° from neutral (need ≥ %.0f° for a meaningful test)",
                                heldTravel ?? 0, config.minMeaningfulTravelDegrees))
        }
        if ignored > 0 { notes.append("\(ignored) pose step(s) across frame gaps longer than \(config.ignoreGapFactor)× the median interval were not counted") }

        // --- Timing vs configuration (notes only) -----------------------------------------------------
        if let h = runs.firstIndex(where: { $0.state == .holding }) {
            let d = duration(h)
            if abs(d - machine.holdDuration) > config.timingToleranceSeconds {
                notes.append(String(format: "holding lasted %.2f s, configured %.2f s", d, machine.holdDuration))
            }
        }
        if let d = runs.firstIndex(where: { $0.state == .decaying }) {
            let dd = duration(d)
            if abs(dd - machine.decayDuration) > config.timingToleranceSeconds {
                notes.append(String(format: "decaying lasted %.2f s, configured %.2f s", dd, machine.decayDuration))
            }
        }
        if let r = reacquire, r < 0 { notes.append("the face reappeared before the uncover cue") }

        // --- Verdict ----------------------------------------------------------------------------------
        let verdict: LossVerdict
        if flagged || !illegal.isEmpty { verdict = .fail }
        else if observed == expected { verdict = .pass }
        else {
            verdict = .incomplete
            if observed.last != "locked" { notes.append("tracking never came back to locked after the cover") }
            if !observed.contains("static") { notes.append("static was never reached (cover too short, or only partly covered?)") }
            if observed.filter({ $0 == "holding" }).count > 1 { notes.append("state flapped: holding was entered more than once (partial cover?)") }
        }

        return LossReport(
            verdict: verdict, observedSequence: observed, expectedSequence: expected, secondsInState: seconds,
            timeToStaticSeconds: timeToStatic, reacquireSecondsAfterUncoverCue: reacquire,
            expectedHoldSeconds: machine.holdDuration, expectedDecaySeconds: machine.decayDuration,
            maxFrameJumpDegrees: maxStep, maxJumpState: maxState?.rawValue, maxJumpSecondsAfterCoverCue: maxAt,
            jumpThresholdDegrees: threshold, jumpFlagged: flagged, heldPoseTravelDegrees: heldTravel,
            reacquirePoseTravelDegrees: reacquireTravel, jumpCheckMeaningful: meaningful,
            framesAnalyzed: window.count, ignoredGapPairs: ignored, notes: notes)
    }
}
