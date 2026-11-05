import Foundation

// Step 2e: what the report records. The 14:58 real run (docs/STATUS.md, "Step 2e findings") showed that per-window angle
// statistics are not enough to tell what the head and the tracker were doing: the face-box height per phase, the tracker
// state per hold and the time course inside a window were all missing. Everything here is numbers only; there is no
// image, no video frame and no field that could hold one.

/// min / median / max of a series of finite values.
public struct MinMedianMax: Codable, Equatable, Sendable {
    public var min: Double
    public var median: Double
    public var max: Double

    /// nil when `xs` holds no finite value.
    public init?(_ xs: [Double]) {
        let v = xs.filter(\.isFinite)
        guard let lo = v.min(), let hi = v.max(), let mid = RobustStats.median(v) else { return nil }
        min = lo; median = mid; max = hi
    }
}

/// Seconds the tracker spent in each state.
public struct PhaseStateSeconds: Codable, Equatable, Sendable {
    public var locked = 0.0
    public var holding = 0.0
    public var decaying = 0.0
    public var staticState = 0.0

    public init() {}

    public var total: Double { locked + holding + decaying + staticState }

    mutating func add(_ state: TrackingState, _ seconds: Double) {
        switch state {
        case .locked: locked += seconds
        case .holding: holding += seconds
        case .decaying: decaying += seconds
        case .static: staticState += seconds
        }
    }
}

/// Whole-phase statistics of one phase of the run (not only its analysis window). The per-frame series below holds the raw
/// material, so any other window can be recomputed from it.
public struct PhaseRecord: Codable, Equatable, Sendable {
    public var index: Int
    public var kind: SelfTestPhase.Kind
    /// Short label, e.g. "hold: turn LEFT #1".
    public var name: String
    public var move: SelfTestMove?
    public var repetition: Int?
    /// Seconds since the run started (the phases behind the lock gate are shifted by the time waited).
    public var startSeconds: Double
    public var endSeconds: Double
    /// Quality over the phase's camera frames: min, median, mean, the shares below the gate's loss and recovery thresholds
    /// (strictly below) and which component limited it. nil when the phase has no camera frame.
    public var quality: QualityWindowSummary?
    /// The component that was the weakest in the most frames ("none" = all components were 1); ties go to the first name
    /// in alphabetical order.
    public var dominantLimiting: String?
    /// Face-box height (fraction of the frame height) over the frames that had a face. nil when none had.
    public var boxHeight: MinMedianMax?
    public var framesWithBox: Int
    /// Tracker state over time. See `SelfTestRecorder.stateSeconds` for how a frame's state is turned into seconds.
    public var stateSeconds: PhaseStateSeconds
}

/// One row per frame of the whole run (camera frames and watchdog ticks), stored column by column so the JSON stays small.
/// Precision: `secondsFromRunStart` 0.001 s, angles 0.01°, box height 0.0001, quality 0.001. Entries are nil where there was no
/// face (and no box). `state` indexes `stateLegend`; `phase` indexes the script's phases.
public struct FrameSeries: Codable, Equatable, Sendable {
    public static let legend = ["locked", "holding", "decaying", "static"]

    public var stateLegend: [String]
    public var secondsFromRunStart: [Double]
    public var phase: [Int]
    /// RAW Vision angles in degrees, before any sign mapping.
    public var rawYawDegrees: [Double?]
    public var rawPitchDegrees: [Double?]
    public var rawRollDegrees: [Double?]
    public var boxHeight: [Double?]
    public var quality: [Double]
    public var state: [Int]
    /// True for ticks synthesized because no camera frame arrived.
    public var watchdogTick: [Bool]

    public var count: Int { secondsFromRunStart.count }

    static func stateCode(_ s: TrackingState) -> Int {
        switch s { case .locked: 0; case .holding: 1; case .decaying: 2; case .static: 3 }
    }
}

public enum SelfTestRecorder {
    /// Seconds per tracker state inside the window [a, b]. `frames` must be sorted by arrival. A frame's state is taken to
    /// hold from its own arrival until the next frame's arrival (the last one until `b`); before the first frame the first
    /// frame's state is used. So the result always adds up to `b - a`. Watchdog ticks count like any other frame: they are
    /// how the state advances while the camera delivers nothing. The assumption: the state does not change between two
    /// frames (frames arrive about every 33 ms; the tracker itself also moves between frames only when a tick arrives).
    public static func stateSeconds(frames: [SelfTestFrame], from a: Double, to b: Double) -> PhaseStateSeconds {
        var out = PhaseStateSeconds()
        guard b > a, !frames.isEmpty else { return out }
        for k in frames.indices {
            let start = k == 0 ? -Double.infinity : frames[k].arrival
            let end = k + 1 < frames.count ? frames[k + 1].arrival : Double.infinity
            let lo = max(start, a), hi = min(end, b)
            if hi > lo { out.add(frames[k].state, hi - lo) }
        }
        return out
    }

    static func name(of p: SelfTestPhase) -> String {
        switch p.kind {
        case .getReady: "get ready"
        case .baseline: "baseline"
        case .hold: "hold: \(p.move?.label ?? "?") #\(p.repetition ?? 0)"
        case .rest: "rest"
        case .lossTurn: "loss test: turn"
        case .cover: "loss test: cover"
        case .uncover: "loss test: uncover"
        }
    }

    /// Frames of the whole run in arrival order, each with the index of its phase.
    static func timeline(_ session: SelfTestSession) -> [(phase: Int, frame: SelfTestFrame)] {
        session.framesByPhase.enumerated()
            .flatMap { i, fs in fs.map { (phase: i, frame: $0) } }
            .sorted { ($0.frame.arrival, $0.phase) < ($1.frame.arrival, $1.phase) }
    }

    /// One record for every phase that started (a phase behind a lock gate that never opened did not).
    public static func phaseRecords(_ session: SelfTestSession, gate: QualityGateConfig) -> [PhaseRecord] {
        let all = timeline(session).map(\.frame)
        var out: [PhaseRecord] = []
        for (i, p) in session.script.phases.enumerated() {
            guard session.effectiveStart(of: i) != nil else { continue }
            let a = session.absoluteStart(of: i), b = session.absoluteEnd(of: i)
            let frames = session.framesByPhase[i]
            let quality = QualityAnalyzer.summarize(name: name(of: p), frames: frames, gate: gate)
            let heights = frames.compactMap { $0.faceBox?.height }
            out.append(PhaseRecord(
                index: i, kind: p.kind, name: name(of: p), move: p.move, repetition: p.repetition,
                startSeconds: a - session.startTime, endSeconds: b - session.startTime,
                quality: quality,
                dominantLimiting: quality?.limitingFractions.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first?.key,
                boxHeight: MinMedianMax(heights), framesWithBox: heights.count,
                stateSeconds: stateSeconds(frames: all, from: a, to: b)))
        }
        return out
    }

    public static func frameSeries(_ session: SelfTestSession) -> FrameSeries {
        // JSON can not hold NaN / infinity: a non-finite value is stored as "no value" (null), never as a made-up number.
        func r(_ x: Double, _ scale: Double) -> Double { x.isFinite ? (x * scale).rounded() / scale : 0 }
        func rn(_ x: Double?, _ scale: Double) -> Double? { x.flatMap { $0.isFinite ? ($0 * scale).rounded() / scale : nil } }
        let rows = timeline(session)
        let toDeg = 180 / Double.pi
        return FrameSeries(
            stateLegend: FrameSeries.legend,
            secondsFromRunStart: rows.map { r($0.frame.arrival - session.startTime, 1000) },
            phase: rows.map(\.phase),
            rawYawDegrees: rows.map { rn($0.frame.angles.map { $0.yaw * toDeg }, 100) },
            rawPitchDegrees: rows.map { rn($0.frame.angles.map { $0.pitch * toDeg }, 100) },
            rawRollDegrees: rows.map { rn($0.frame.angles.map { $0.roll * toDeg }, 100) },
            boxHeight: rows.map { rn($0.frame.faceBox?.height, 10_000) },
            quality: rows.map { r($0.frame.qualityOverall, 1000) },
            state: rows.map { FrameSeries.stateCode($0.frame.state) },
            watchdogTick: rows.map(\.frame.isWatchdogTick))
    }
}
