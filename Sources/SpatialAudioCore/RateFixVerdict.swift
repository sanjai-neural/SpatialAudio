import Foundation

// Step 6b-3b (a2): the pure decision logic of the device-bound-tap spike. IMPLEMENTED-UNVERIFIED: nothing here has seen a real device-bound tap.
//
// The question this file serves (docs/ARCHITECTURE.md "Step 6b-3 plan", docs/STATUS.md "Step 6b-3b"): does a tap bound to the output device's stream arrive at the OUTPUT
// device's rate, so that the engine asks exactly one device buffer per call and the ring no longer drains at +1,294 ppm? The three real Bluetooth runs of 2026-11-18 asked 558
// frames per call (a global tap at 48 kHz, output at 44.1 kHz). Nothing here claims the device-bound tap arrives at 44.1 kHz: the stages S0 to S3 (docs/MANUAL_TEST_STEP6B3B.md)
// measure it, and these functions turn the measured numbers into the verdict that was FIXED BEFORE THE RUN.
//
// The thresholds below are "pre-registered GUESS, fixed before the run" (approved by Sanjai on 2026-11-19 as written in the plan). If one is ever changed, `RateFixCriteria.version`
// must change with it and docs/STATUS.md must record what changed and why; a verdict is only comparable within one version. The version string is written into every report.
//
// No hardware, no Core Audio and no clock here. The simulated user's data and every SIMULATED report decide nothing: a verdict computed from one says so in its first words.

// MARK: - The two tap modes and the rate-equality guard

/// Which tap the ring probe builds. The default (and every run before 6b-3b) is the global stereo mixdown excluding our own process; `deviceBound` is the 6b-3b (a2) mode.
public enum RingProbeTapMode: String, Codable, Sendable, Equatable {
    case globalMixdown
    case deviceBound
    /// Step 6b-3c-0: a tap on ONE chosen process (the test player), bound to the output device's stream; the target's own audio may be muted (an explicit option, default unmuted).
    case processSpecific
}

/// G0's rate half: the tap's rate must equal the output device's nominal rate. Rates are whole Hz values, so half a Hz of tolerance only absorbs floating-point noise.
public enum RateEqualityGuard {
    public static let toleranceHz = 0.5

    public struct Result: Equatable, Sendable {
        public var passes: Bool
        public var reason: String?
        public init(passes: Bool, reason: String?) { self.passes = passes; self.reason = reason }
    }

    public static func check(tapRate: Double, outputNominalRate: Double?) -> Result {
        guard let output = outputNominalRate, output.isFinite, output > 0 else {
            return Result(passes: false, reason: "the output device's nominal rate is unknown")
        }
        guard tapRate.isFinite, tapRate > 0 else {
            return Result(passes: false, reason: "the tap's rate is not a positive number")
        }
        if abs(tapRate - output) < toleranceHz { return Result(passes: true, reason: nil) }
        return Result(passes: false, reason: "the device-bound tap is \(String(format: "%.1f", tapRate)) Hz but the output device's nominal rate is \(String(format: "%.1f", output)) Hz")
    }
}

// MARK: - The pre-registered criteria

public enum RateFixCriteria {
    /// Bump this with any change below and record the change in docs/STATUS.md.
    public static let version = "6b-3b-prereg-1"
    public static let registration = "pre-registered GUESS, fixed before the run"
    /// G1: tolerance, in frames, on the per-interval mean frames per call. An interval holds at most about 100 calls, so ONE call that differs by one frame moves the mean by more
    /// than 0.01: this tolerance sees any single deviating call and still absorbs floating-point noise.
    public static let framesPerCallToleranceFrames = 0.005
    /// G2: at or below this (ppm of the tap rate) the drain is small enough for a GO: about 4.4 frames/s at 44.1 kHz. Resolution over 600 s is about +/- 19 ppm (one call of 512 frames).
    public static let goSlopePPM = 100.0
    /// G2: above this the drain is a NO-GO: 13x below the measured +1,294 ppm failure signature, 3x the go threshold. Between the two: GRAY (a clock-level term, needs a servo).
    public static let noGoSlopePPM = 300.0
    /// The output rate of every real report so far for the GLOBAL tap (27 reports on disk, 2026-11-07 to 2026-11-18). Used only to say that a run on a 48 kHz output cannot tell the
    /// device-bound tap from the global one. It decides nothing.
    public static let globalTapMeasuredRateHz = 48_000.0
}

/// The four runs of docs/MANUAL_TEST_STEP6B3B.md, recognised from the mode and the requested seconds (no extra switch). Anything else is `unclassified` and gets no verdict.
public enum RateFixStage: String, Codable, Sendable, Equatable {
    case s0, s1, s2, s3, unclassified

    public static func classify(recovery: Bool, requestedSeconds: Double) -> RateFixStage {
        if !recovery && requestedSeconds == 5 { return .s0 }
        if !recovery && requestedSeconds == 180 { return .s1 }
        if recovery && requestedSeconds == 600 { return .s2 }
        if !recovery && requestedSeconds == 120 { return .s3 }
        return .unclassified
    }

    public var title: String {
        switch self {
        case .s0: return "S0 (plain, 5 s: the tap's format and rate)"
        case .s1: return "S1 (plain, 180 s: the fast fail)"
        case .s2: return "S2 (recovery mode, 600 s: the decision)"
        case .s3: return "S3 (plain, 120 s: the speaker control)"
        case .unclassified: return "not a pre-registered run"
        }
    }
}

// MARK: - Input, criteria, verdict

/// One reader's numbers, as the evaluator needs them.
public struct RateFixReaderInput: Equatable, Sendable {
    /// Per ONE-SECOND INTERVAL mean frames per call (min / median / max over the intervals).
    public var intervalMin: Double?
    public var intervalMedian: Double?
    public var intervalMax: Double?
    /// Least-squares fill slope over the whole series, ppm of the tap rate (negative = the reader drains the ring).
    public var fillSlopePPM: Double?
    /// Underrun blocks counted after sample 0 (last sample minus first sample).
    public var underrunsAfterFirstSample: UInt64
    public var overrunBlocks: UInt64
    public var phaseMismatches: UInt64
    public var validTimestampShare: Double?
    /// Overrun + divergence + refused jumps summed over every epoch (the recovery section); nil without it.
    public var jumps: UInt64?

    public init(intervalMin: Double? = nil, intervalMedian: Double? = nil, intervalMax: Double? = nil, fillSlopePPM: Double? = nil, underrunsAfterFirstSample: UInt64 = 0,
                overrunBlocks: UInt64 = 0, phaseMismatches: UInt64 = 0, validTimestampShare: Double? = nil, jumps: UInt64? = nil) {
        self.intervalMin = intervalMin; self.intervalMedian = intervalMedian; self.intervalMax = intervalMax; self.fillSlopePPM = fillSlopePPM
        self.underrunsAfterFirstSample = underrunsAfterFirstSample; self.overrunBlocks = overrunBlocks; self.phaseMismatches = phaseMismatches
        self.validTimestampShare = validTimestampShare; self.jumps = jumps
    }
}

public struct RateFixInput: Equatable, Sendable {
    public var stage: RateFixStage
    public var simulated: Bool
    public var outcome: String
    public var stoppedBy: String
    public var tapFormat: TapFormat?
    public var outputNominalRate: Double?
    public var outputTransport: String?
    public var bufferFrameSize: UInt32?
    /// Re-primes performed after the start sequence; nil when the run was not in recovery mode.
    public var rePrimes: Int?
    /// Exactly two (left, right) or empty when there was no series.
    public var readers: [RateFixReaderInput]
    public var fillAtFirstPull: [Int64]?
    public var engineStartToFirstPullSeconds: Double?
    /// An overrun block or a phase mismatch was already counted in the first sample (a start-up event, not a steady-state one).
    public var eventsAtFirstSample: Bool

    public init(stage: RateFixStage, simulated: Bool = false, outcome: String = "ok", stoppedBy: String = "timeout", tapFormat: TapFormat? = nil, outputNominalRate: Double? = nil,
                outputTransport: String? = nil, bufferFrameSize: UInt32? = nil, rePrimes: Int? = nil, readers: [RateFixReaderInput] = [], fillAtFirstPull: [Int64]? = nil,
                engineStartToFirstPullSeconds: Double? = nil, eventsAtFirstSample: Bool = false) {
        self.stage = stage; self.simulated = simulated; self.outcome = outcome; self.stoppedBy = stoppedBy; self.tapFormat = tapFormat
        self.outputNominalRate = outputNominalRate; self.outputTransport = outputTransport; self.bufferFrameSize = bufferFrameSize; self.rePrimes = rePrimes
        self.readers = readers; self.fillAtFirstPull = fillAtFirstPull; self.engineStartToFirstPullSeconds = engineStartToFirstPullSeconds
        self.eventsAtFirstSample = eventsAtFirstSample
    }

    /// Reads the numbers out of a finished report. The stage is recognised from the mode (a recovery section is present) and the requested seconds.
    public init(report: RingProbeReport) {
        stage = RateFixStage.classify(recovery: report.recovery != nil, requestedSeconds: report.requestedSeconds)
        simulated = report.isSimulated
        outcome = report.outcome
        stoppedBy = report.stoppedBy
        tapFormat = report.tapFormat
        outputNominalRate = report.outputDevice?.nominalSampleRate
        outputTransport = report.outputDevice?.transportType
        bufferFrameSize = report.outputDevice?.bufferFrameSize
        rePrimes = report.recovery?.rePrimesPerformed
        fillAtFirstPull = report.timings.fillAtFirstPull
        engineStartToFirstPullSeconds = report.timings.engineStartToFirstPullSeconds
        let rows = report.samples.filter { $0.readers.count == 2 }
        var inputs: [RateFixReaderInput] = []
        var startEvents = false
        if let summary = report.summary, summary.readers.count == 2, let first = rows.first, let last = rows.last {
            for i in 0..<2 {
                let r = summary.readers[i]
                let m = r.framesPerCallIntervalMeans
                let underruns = last.readers[i].underrunBlocks &- first.readers[i].underrunBlocks
                var jumps: UInt64?
                if let rec = report.recovery, rec.readers.count == 2 {
                    let rr = rec.readers[i]
                    jumps = rr.overrunJumps + rr.divergenceJumps + rr.refusedJumps
                }
                inputs.append(RateFixReaderInput(intervalMin: m?.min, intervalMedian: m?.median, intervalMax: m?.max, fillSlopePPM: r.fillSlopePPM,
                                                 underrunsAfterFirstSample: underruns, overrunBlocks: r.finalCounters.overrunBlocks,
                                                 phaseMismatches: r.finalCounters.phaseMismatches, validTimestampShare: r.validTimestampShare, jumps: jumps))
                if first.readers[i].overrunBlocks > 0 || first.readers[i].phaseMismatches > 0 { startEvents = true }
            }
        }
        readers = inputs
        eventsAtFirstSample = startEvents
    }
}

public struct RateFixCriterion: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case pass, fail, notEvaluated }
    public var id: String
    public var text: String
    public var measured: String
    public var status: Status
    public init(id: String, text: String, measured: String, status: Status) { self.id = id; self.text = text; self.measured = measured; self.status = status }
}

public enum RateFixVerdictKind: String, Codable, Sendable, Equatable {
    /// S0: G0 passed; the next run is S1.
    case proceedToS1
    /// S1: no fast-fail signal; the next run is S2 (S1 cannot resolve 100 ppm, so it is never a go).
    case continueToS2
    case go
    /// S2: G0 and G1 passed and the drain is between the go and the no-go threshold: a clock-level term that needs a servo.
    case gray
    case noGo
    /// S2: no no-go signal, but not every item of G1 to G3 passed (or one could not be evaluated).
    case inconclusive
    case controlOK
    case controlFailed
    /// The run did not complete (not timeout, or an outcome other than ok): no verdict.
    case incomplete
    case unclassified
}

public struct RateFixReport: Codable, Equatable, Sendable {
    public var criteriaVersion: String
    public var registration: String
    public var stage: RateFixStage
    public var verdict: RateFixVerdictKind
    public var verdictText: String
    public var simulated: Bool
    public var criteria: [RateFixCriterion]
    /// Numbers and observations that decide nothing (start-up fill, what a 48 kHz output cannot show, events at the first sample).
    public var informational: [String]
    public var epochs: [RingEpochSlope]

    public func markdownLines() -> [String] {
        var out: [String] = []
        out.append("## 9. Rate-fix check (Step 6b-3b, device-bound tap) - IMPLEMENTED-UNVERIFIED; criteria version \(criteriaVersion): \(registration)")
        out.append("")
        out.append("- Stage: \(stage.title)")
        out.append("- **Verdict: \(verdict.rawValue)** - \(verdictText)")
        out.append("")
        out.append("| id | criterion | measured | status |")
        out.append("|---|---|---|---|")
        for c in criteria { out.append("| \(c.id) | \(c.text) | \(c.measured) | \(c.status.rawValue) |") }
        if !informational.isEmpty {
            out.append("")
            for i in informational { out.append("- \(i)") }
        }
        if !epochs.isEmpty {
            out.append("")
            out.append("Per-epoch fill slope (an epoch is the time between re-primes; the whole run when there was none; a slope needs at least \(RingEpochSlopes.minimumSamples) samples):")
            out.append("")
            out.append("| epoch | from (s) | to (s) | samples | slope L / R (frames/s) | slope L / R (ppm of tap rate) | fill first L / R | fill last L / R | underruns L / R |")
            out.append("|---|---|---|---|---|---|---|---|---|")
            func f(_ v: Double?, _ d: Int) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "-" }
            for e in epochs {
                out.append("| \(e.index) | \(f(e.startSeconds, 1)) | \(f(e.endSeconds, 1)) | \(e.sampleCount) | \(f(e.slopeFramesPerSecond[0], 2)) / \(f(e.slopeFramesPerSecond[1], 2)) | \(f(e.slopePPM[0], 1)) / \(f(e.slopePPM[1], 1)) | \(e.fillFirst[0]) / \(e.fillFirst[1]) | \(e.fillLast[0]) / \(e.fillLast[1]) | \(e.underruns[0]) / \(e.underruns[1]) |")
            }
        }
        return out
    }
}

// MARK: - The evaluator

public enum RateFixEvaluator {
    public static func evaluate(_ input: RateFixInput, epochs: [RingEpochSlope] = []) -> RateFixReport {
        let stage = input.stage
        let g0 = g0Criterion(input)
        let g1 = g1Criterion(input, g0: g0)
        let slope = judgeSlope(input, stage: stage)
        let g2 = g2Criterion(input, stage: stage, slope: slope)
        let g3a = g3aCriterion(input)
        let g3b = g3bCriterion(input)
        let g3c = g3cCriterion(input)
        let g3d = g3dCriterion(input)
        let g3e = g3eCriterion(input)

        // Which items a stage uses; the others are listed as "not part of this stage".
        func part(_ c: RateFixCriterion, _ used: Bool) -> RateFixCriterion {
            used ? c : RateFixCriterion(id: c.id, text: c.text, measured: "not part of \(stage.rawValue.uppercased())", status: .notEvaluated)
        }
        let criteria: [RateFixCriterion]
        switch stage {
        case .s0: criteria = [g0, part(g1, false), part(g2, false), part(g3a, false), part(g3b, false), part(g3c, false), part(g3d, false), part(g3e, false)]
        case .s1: criteria = [g0, g1, g2, part(g3a, false), part(g3b, false), g3c, part(g3d, false), part(g3e, false)]
        case .s3: criteria = [g0, g1, part(g2, false), part(g3a, false), g3b, g3c, g3d, g3e]
        case .s2, .unclassified: criteria = [g0, g1, g2, g3a, g3b, g3c, g3d, g3e]
        }

        var kind: RateFixVerdictKind
        var text: String
        let completed = input.outcome == "ok" && input.stoppedBy == "timeout"
        switch stage {
        case .unclassified:
            kind = .unclassified
            text = "this run is not one of the four pre-registered runs (S0 plain 5 s, S1 plain 180 s, S2 recovery 600 s, S3 plain 120 s), so it gets no verdict; the numbers above are informational."
        case .s0:
            if g0.status != .pass {
                kind = .noGo
                text = "S0: G0 did not pass (\(g0.measured)). The device-bound tap does not arrive in the form the ring needs at the output device's rate; arm B ((e), the mixer at the tap's rate) is the next step only on Sanjai's go."
            } else if input.outcome != "ok" {
                kind = .incomplete
                text = "S0: G0 passed but the run did not finish (outcome: \(input.outcome)); no verdict."
            } else {
                kind = .proceedToS1
                text = "S0: G0 passed (\(g0.measured)). Next: S1 on Bluetooth."
            }
        case .s1, .s2, .s3:
            if g0.status == .fail {
                kind = .noGo
                text = "\(stage.rawValue.uppercased()): G0 did not pass (\(g0.measured))."
            } else if !completed {
                kind = .incomplete
                text = "\(stage.rawValue.uppercased()): the run did not complete (outcome: \(input.outcome); stopped by: \(input.stoppedBy)); no verdict."
            } else if stage == .s1 {
                let used = [g1, g2, g3c]
                if used.contains(where: { $0.status == .fail }) {
                    kind = .noGo
                    text = "S1 fast fail: \(used.filter { $0.status == .fail }.map(\.id).joined(separator: ", ")) did not pass."
                } else if used.contains(where: { $0.status == .notEvaluated }) {
                    kind = .incomplete
                    text = "S1: \(used.filter { $0.status == .notEvaluated }.map(\.id).joined(separator: ", ")) could not be evaluated; not a continue."
                } else {
                    kind = .continueToS2
                    text = "S1: no fast-fail signal. Not a go: 180 s cannot resolve 100 ppm. Next: S2."
                }
            } else if stage == .s3 {
                let used = [g0, g1, g3b, g3c, g3d, g3e]
                if used.allSatisfy({ $0.status == .pass }) {
                    kind = .controlOK
                    text = "S3: the speaker control passed G0, G1 and G3b to G3e."
                } else {
                    kind = .controlFailed
                    text = "S3: the speaker control failed: \(used.filter { $0.status != .pass }.map(\.id).joined(separator: ", ")) did not pass or could not be evaluated."
                }
            } else {
                let worst = slope.worstPPM
                let hardNoGo = g1.status == .fail || (worst.map { $0 > RateFixCriteria.noGoSlopePPM } ?? false) || g3a.status == .fail
                if hardNoGo {
                    kind = .noGo
                    var why: [String] = []
                    if g1.status == .fail { why.append("G1") }
                    if let w = worst, w > RateFixCriteria.noGoSlopePPM { why.append("G2 (\(String(format: "%.0f", w)) ppm > \(String(format: "%.0f", RateFixCriteria.noGoSlopePPM)))") }
                    if g3a.status == .fail { why.append("G3a (re-primes)") }
                    text = "S2 NO-GO: \(why.joined(separator: ", "))."
                } else if let w = worst, w > RateFixCriteria.goSlopePPM {
                    kind = .gray
                    text = "S2 GRAY: the drain is \(String(format: "%.0f", w)) ppm, between \(String(format: "%.0f", RateFixCriteria.goSlopePPM)) and \(String(format: "%.0f", RateFixCriteria.noGoSlopePPM)): a clock-level term that needs a servo."
                } else if [g0, g1, g2, g3a, g3b, g3c, g3d, g3e].allSatisfy({ $0.status == .pass }) {
                    kind = .go
                    text = "S2 GO: G0 to G3 all passed."
                } else {
                    kind = .inconclusive
                    text = "S2: no no-go signal, but not a go: \([g0, g1, g2, g3a, g3b, g3c, g3d, g3e].filter { $0.status != .pass }.map(\.id).joined(separator: ", ")) did not pass or could not be evaluated."
                }
            }
        }
        if input.simulated { text = "SIMULATED (fabricated data, decides nothing): " + text }

        return RateFixReport(criteriaVersion: RateFixCriteria.version, registration: RateFixCriteria.registration, stage: stage, verdict: kind, verdictText: text,
                             simulated: input.simulated, criteria: criteria, informational: informational(input, epochs: epochs), epochs: epochs)
    }

    // MARK: criteria

    static func g0Criterion(_ input: RateFixInput) -> RateFixCriterion {
        let text = "G0: the tap is Float32 interleaved stereo and its rate equals the output device's nominal rate"
        guard let f = input.tapFormat else {
            return RateFixCriterion(id: "G0", text: text, measured: "no tap format (the tap was not created, or its format could not be read)", status: .notEvaluated)
        }
        let formatOK = f.isFloat32 && f.isInterleaved && f.channelsPerFrame == 2
        let rate = RateEqualityGuard.check(tapRate: f.sampleRate, outputNominalRate: input.outputNominalRate)
        let measured = "tap \(f.sampleFormatDescription), \(f.channelsPerFrame) ch, \(String(format: "%.1f", f.sampleRate)) Hz; output nominal \(input.outputNominalRate.map { String(format: "%.1f", $0) } ?? "unknown") Hz\(rate.reason.map { "; " + $0 } ?? "")"
        return RateFixCriterion(id: "G0", text: text, measured: measured, status: formatOK && rate.passes ? .pass : .fail)
    }

    static func g1Criterion(_ input: RateFixInput, g0: RateFixCriterion) -> RateFixCriterion {
        let text = "G1: every one-second interval's mean frames per call is the device buffer x (tap rate / output rate) for both readers (min and max; \(RateFixCriteria.framesPerCallToleranceFrames) frame tolerance)"
        func no(_ why: String) -> RateFixCriterion { RateFixCriterion(id: "G1", text: text, measured: why, status: .notEvaluated) }
        guard g0.status == .pass else { return no("G0 did not pass") }
        guard let buffer = input.bufferFrameSize, let f = input.tapFormat, let output = input.outputNominalRate, input.readers.count == 2 else {
            return no("the device buffer size, the rates or the series are missing")
        }
        let expected = Double(buffer) * f.sampleRate / output
        var parts: [String] = []
        var allOK = true
        for (i, r) in input.readers.enumerated() {
            guard let mn = r.intervalMin, let mx = r.intervalMax else { return no("a reader has no per-interval summary") }
            let ok = abs(mn - expected) <= RateFixCriteria.framesPerCallToleranceFrames && abs(mx - expected) <= RateFixCriteria.framesPerCallToleranceFrames
            if !ok { allOK = false }
            parts.append("\(i == 0 ? "left" : "right") \(String(format: "%.2f", mn)) / \(String(format: "%.2f", r.intervalMedian ?? .nan)) / \(String(format: "%.2f", mx))")
        }
        return RateFixCriterion(id: "G1", text: text, measured: "expected \(String(format: "%.2f", expected)); min / median / max: \(parts.joined(separator: "; "))", status: allOK ? .pass : .fail)
    }

    struct SlopeJudgement: Equatable {
        var worstPPM: Double?
        var reason: String?
    }

    /// The worst (largest absolute) fill slope of the two readers, ppm. Not evaluated in S3 (120 s cannot resolve 100 ppm) and when re-primes split the run (the fill jumps at every
    /// re-prime; see the per-epoch table).
    static func judgeSlope(_ input: RateFixInput, stage: RateFixStage) -> SlopeJudgement {
        if stage == .s3 { return SlopeJudgement(worstPPM: nil, reason: "S3 does not judge the slope: 120 s cannot resolve 100 ppm") }
        if (input.rePrimes ?? 0) > 0 { return SlopeJudgement(worstPPM: nil, reason: "re-primes split the run, so the whole-run slope is not a drain measurement (see the per-epoch table)") }
        guard input.readers.count == 2, let a = input.readers[0].fillSlopePPM, let b = input.readers[1].fillSlopePPM else {
            return SlopeJudgement(worstPPM: nil, reason: "no fill slope (too few samples)")
        }
        return SlopeJudgement(worstPPM: max(abs(a), abs(b)), reason: nil)
    }

    static func g2Criterion(_ input: RateFixInput, stage: RateFixStage, slope: SlopeJudgement) -> RateFixCriterion {
        let text = "G2: the worst |fill slope| of the two readers, ppm of the tap rate (go <= \(Int(RateFixCriteria.goSlopePPM)); gray up to \(Int(RateFixCriteria.noGoSlopePPM)); no-go above)"
        guard let w = slope.worstPPM else { return RateFixCriterion(id: "G2", text: text, measured: slope.reason ?? "not evaluated", status: .notEvaluated) }
        let limit = stage == .s1 ? RateFixCriteria.noGoSlopePPM : RateFixCriteria.goSlopePPM
        return RateFixCriterion(id: "G2", text: text, measured: String(format: "%.1f ppm", w), status: w <= limit ? .pass : .fail)
    }

    static func g3aCriterion(_ input: RateFixInput) -> RateFixCriterion {
        let text = "G3a: no re-prime after the start sequence"
        guard let n = input.rePrimes else { return RateFixCriterion(id: "G3a", text: text, measured: "not a recovery-mode run", status: .notEvaluated) }
        return RateFixCriterion(id: "G3a", text: text, measured: "\(n) re-prime(s)", status: n == 0 ? .pass : .fail)
    }

    static func g3bCriterion(_ input: RateFixInput) -> RateFixCriterion {
        let text = "G3b: no overrun block, no overrun / divergence / refused jump"
        guard input.readers.count == 2 else { return RateFixCriterion(id: "G3b", text: text, measured: "no series", status: .notEvaluated) }
        let blocks = input.readers.map(\.overrunBlocks).reduce(0, +)
        let jumps = input.readers.map { $0.jumps ?? 0 }.reduce(0, +)
        let jumpsKnown = input.readers.allSatisfy { $0.jumps != nil }
        return RateFixCriterion(id: "G3b", text: text, measured: "\(blocks) overrun block(s); \(jumpsKnown ? "\(jumps) jump(s)" : "jump counters only in recovery mode")",
                                status: blocks == 0 && jumps == 0 ? .pass : .fail)
    }

    static func g3cCriterion(_ input: RateFixInput) -> RateFixCriterion {
        let text = "G3c: no underrun block after the first sample (either reader)"
        guard input.readers.count == 2 else { return RateFixCriterion(id: "G3c", text: text, measured: "no series", status: .notEvaluated) }
        let bad = input.readers.contains { $0.underrunsAfterFirstSample > 0 }
        return RateFixCriterion(id: "G3c", text: text, measured: "left \(input.readers[0].underrunsAfterFirstSample), right \(input.readers[1].underrunsAfterFirstSample)", status: bad ? .fail : .pass)
    }

    static func g3dCriterion(_ input: RateFixInput) -> RateFixCriterion {
        let text = "G3d: no phase mismatch (either reader)"
        guard input.readers.count == 2 else { return RateFixCriterion(id: "G3d", text: text, measured: "no series", status: .notEvaluated) }
        let bad = input.readers.contains { $0.phaseMismatches > 0 }
        return RateFixCriterion(id: "G3d", text: text, measured: "left \(input.readers[0].phaseMismatches), right \(input.readers[1].phaseMismatches)", status: bad ? .fail : .pass)
    }

    static func g3eCriterion(_ input: RateFixInput) -> RateFixCriterion {
        let text = "G3e: the valid-timestamp share is 100 % for both readers (the measured baseline)"
        guard input.readers.count == 2 else { return RateFixCriterion(id: "G3e", text: text, measured: "no series", status: .notEvaluated) }
        let ok = input.readers.allSatisfy { ($0.validTimestampShare ?? -1) == 1 }
        func s(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "-" }
        return RateFixCriterion(id: "G3e", text: text, measured: "left \(s(input.readers[0].validTimestampShare)), right \(s(input.readers[1].validTimestampShare))", status: ok ? .pass : .fail)
    }

    // MARK: informational (decides nothing)

    static func informational(_ input: RateFixInput, epochs: [RingEpochSlope]) -> [String] {
        var out: [String] = []
        if let fill = input.fillAtFirstPull {
            out.append("Start-up fill (recorded, not gated): fill at the first pull \(fill.map(String.init).joined(separator: ", ")) frames; engine start to first pull \(input.engineStartToFirstPullSeconds.map { String(format: "%.3f", $0) } ?? "-") s. After a rate fix the fill no longer drains, so this becomes standing latency.")
        }
        if let out48 = input.outputNominalRate, out48 == RateFixCriteria.globalTapMeasuredRateHz {
            out.append("The output device is at \(Int(out48)) Hz, the rate every GLOBAL tap had in the earlier real reports: this run cannot tell the device-bound tap from the global one (it is a control, not a test of the hypothesis).")
        }
        if input.eventsAtFirstSample {
            out.append("An overrun block or a phase mismatch was already counted in the FIRST sample: a start-up event (the engine took long to start), not a steady-state one. It still counts in G3b / G3d as written; repeat the run once and record both.")
        }
        if let t = input.outputTransport { out.append("Output transport: \(t).") }
        let slopes = epochs.flatMap { $0.slopePPM.compactMap { $0 } }.map { abs($0) }
        if (input.rePrimes ?? 0) > 0, let worst = slopes.max() {
            out.append("Per-epoch drain: the worst epoch slope is \(String(format: "%.0f", worst)) ppm. The pre-registered verdict does not use it (any re-prime is a no-go); it says whether the drain is still the +1,294 ppm rounding signature or a smaller term.")
        }
        return out
    }
}
