import Foundation

public enum RotationAxis: String, Codable, CaseIterable, Sendable {
    case yaw, pitch, roll
}

/// The three guided head moves. Each one is defined in OUR sign convention:
/// turning left = +yaw, looking up = +pitch, tilting the right ear down = +roll.
public enum SelfTestMove: String, Codable, CaseIterable, Sendable {
    case turnLeft, lookUp, tiltRightEar

    public var axis: RotationAxis {
        switch self {
        case .turnLeft: .yaw
        case .lookUp: .pitch
        case .tiltRightEar: .roll
        }
    }

    public var label: String {
        switch self {
        case .turnLeft: "turn LEFT"
        case .lookUp: "look UP"
        case .tiltRightEar: "tilt RIGHT EAR"
        }
    }
}

public enum LightingTag: String, Codable, CaseIterable, Sendable {
    case normalLight = "normal light"
    case dimRoom = "dim room"

    public var fileSlug: String { self == .normalLight ? "normal-light" : "dim-room" }
}

/// Which cue (sound / flash) the UI should play when a phase starts.
public enum SelfTestCue: String, Codable, Sendable {
    case begin, hold, rest, cover, uncover, done
}

public struct SelfTestPhase: Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case getReady, baseline, hold, rest, lossTurn, cover, uncover
    }

    public var id: Int
    public var kind: Kind
    /// For `.hold`: the move being performed.
    public var move: SelfTestMove?
    /// For `.hold`: 1-based repetition.
    public var repetition: Int?
    public var title: String
    public var instruction: String
    public var duration: Double
    /// Seconds after the phase start between which the data is "steady" and used for analysis.
    public var analysisWindow: ClosedRange<Double>?
    /// Frames in this phase count toward the latency / fps statistics window.
    public var inStatsWindow: Bool
    public var cue: SelfTestCue
}

/// The ordered list of guided phases. Pure data; `SelfTestSession` plays it against a clock.
public struct SelfTestScript: Equatable, Sendable {
    public let phases: [SelfTestPhase]
    /// Start offset of each phase from the beginning of the run, in seconds.
    public let starts: [Double]
    public let totalDuration: Double

    public init(phases: [SelfTestPhase]) {
        self.phases = phases
        var s: [Double] = []
        var t = 0.0
        for p in phases { s.append(t); t += p.duration }
        starts = s
        totalDuration = t
    }

    /// Index of the phase that contains `elapsed` seconds since the run start; nil outside the run.
    public func index(atElapsed elapsed: Double) -> Int? {
        guard elapsed.isFinite, elapsed >= 0, elapsed < totalDuration else { return nil }
        var found = 0
        for i in phases.indices where starts[i] <= elapsed { found = i }
        return found
    }

    public func firstIndex(of kind: SelfTestPhase.Kind) -> Int? { phases.firstIndex { $0.kind == kind } }

    /// The statistics window length: total duration of the phases flagged `inStatsWindow`.
    public var statsWindowSeconds: Double { phases.filter(\.inStatsWindow).reduce(0) { $0 + $1.duration } }

    /// getReady 3 s, baseline 2 s, then for each move twice (hold 3 s + rest 2 s), then the loss test
    /// (turn 3 s, cover 5 s, uncover 4 s). The 12 hold/rest phases are exactly the 30 s statistics window.
    public static let standard: SelfTestScript = {
        var phases: [SelfTestPhase] = []
        func add(_ kind: SelfTestPhase.Kind, move: SelfTestMove? = nil, rep: Int? = nil,
                 title: String, instruction: String, duration: Double,
                 window: ClosedRange<Double>? = nil, stats: Bool = false, cue: SelfTestCue) {
            phases.append(SelfTestPhase(id: phases.count, kind: kind, move: move, repetition: rep, title: title,
                                        instruction: instruction, duration: duration, analysisWindow: window,
                                        inStatsWindow: stats, cue: cue))
        }

        add(.getReady, title: "GET READY",
            instruction: "Sit the way you normally do, facing the screen. The test starts when the countdown ends.",
            duration: 3, cue: .begin)
        add(.baseline, title: "LOOK STRAIGHT AHEAD",
            instruction: "Look at the middle of the screen and stay still.",
            duration: 2, window: 0.5...2.0, cue: .rest)

        let moves = SelfTestMove.allCases
        for (mi, move) in moves.enumerated() {
            for rep in 1...2 {
                let how: String
                switch move {
                case .turnLeft:
                    how = "Turn your head toward YOUR left shoulder (the side of your left hand) and keep it there."
                case .lookUp:
                    how = "Tilt your head back so your chin goes up and your face points toward the ceiling. Moving only your eyes does not count."
                case .tiltRightEar:
                    how = "Tilt your head so YOUR right ear moves down toward YOUR right shoulder. Your face still points at the screen."
                }
                add(.hold, move: move, rep: rep,
                    title: "\(move.label.uppercased()) — HOLD  (\(rep) of 2)",
                    instruction: how + " Hold until the next sound.",
                    duration: 3, window: 1.0...3.0, stats: true, cue: .hold)
                let next: String
                if rep == 1 { next = "Next: \(move.label) again." }
                else if mi + 1 < moves.count { next = "Next: \(moves[mi + 1].label)." }
                else { next = "Next: the turn-and-cover test." }
                add(.rest, title: "BACK TO CENTER",
                    instruction: "Look straight at the screen and stay still. \(next)",
                    duration: 2, window: 1.0...2.0, stats: true, cue: .rest)
            }
        }

        add(.lossTurn, title: "TURN LEFT ABOUT 25° AND KEEP STILL",
            instruction: "Turn your head about a quarter of the way toward YOUR left shoulder and hold it still, even when the next sound plays.",
            duration: 3, cue: .hold)
        add(.cover, title: "COVER THE CAMERA NOW",
            instruction: "Cover the camera lens with your hand. Keep your head turned and still.",
            duration: 5, cue: .cover)
        add(.uncover, title: "UNCOVER THE CAMERA",
            instruction: "Take your hand away. Keep your head turned and still.",
            duration: 4, cue: .uncover)
        return SelfTestScript(phases: phases)
    }()
}

/// One processed frame (or watchdog tick) as the self-test sees it. Numbers only: there is no image
/// data anywhere in this type.
public struct SelfTestFrame: Equatable, Sendable {
    /// Monotonic seconds at which the frame reached the app (same clock as the session).
    public var arrival: Double
    /// Camera-clock capture timestamp.
    public var captureTime: Double
    /// RAW Vision angles (before any sign mapping); nil when no face was found.
    public var angles: VisionFaceAngles?
    public var frameMirrored: Bool
    public var videoRotationAngle: Double?
    public var state: TrackingState
    /// Pipeline output pose (calibrated, filtered, state-machine output).
    public var pose: Quaternion
    public var qualityOverall: Double
    /// True for watchdog ticks synthesized because frames stopped.
    public var isWatchdogTick: Bool
    public var deliveryLatency: Double
    public var visionDuration: Double
    public var totalLatency: Double

    public init(arrival: Double, captureTime: Double, angles: VisionFaceAngles?, frameMirrored: Bool,
                videoRotationAngle: Double? = nil, state: TrackingState, pose: Quaternion,
                qualityOverall: Double, isWatchdogTick: Bool = false,
                deliveryLatency: Double, visionDuration: Double, totalLatency: Double) {
        self.arrival = arrival; self.captureTime = captureTime; self.angles = angles
        self.frameMirrored = frameMirrored; self.videoRotationAngle = videoRotationAngle
        self.state = state; self.pose = pose; self.qualityOverall = qualityOverall
        self.isWatchdogTick = isWatchdogTick; self.deliveryLatency = deliveryLatency
        self.visionDuration = visionDuration; self.totalLatency = totalLatency
    }
}

public enum SelfTestEvent: Equatable, Sendable {
    case phaseStarted(index: Int)
    case finished
}

/// What the UI needs to draw the current step.
public struct SelfTestStatus: Equatable, Sendable {
    public var phaseIndex: Int
    public var phaseCount: Int
    public var phase: SelfTestPhase
    public var phaseElapsed: Double
    public var secondsRemainingInPhase: Double
    public var phaseProgress: Double
    public var overallProgress: Double
}

/// Plays a `SelfTestScript` against a monotonic clock and files each incoming frame under the phase
/// it arrived in. Everything is derived from the timestamps passed in, so it is deterministic and
/// testable; it never reads a clock itself.
public struct SelfTestSession: Sendable {
    public let script: SelfTestScript
    public let lighting: LightingTag
    /// Monotonic seconds at which phase 0 begins.
    public let startTime: Double
    public private(set) var framesByPhase: [[SelfTestFrame]]
    public private(set) var announcedPhases = 0
    public private(set) var isFinished = false
    public private(set) var wasAborted = false

    public init(script: SelfTestScript = .standard, lighting: LightingTag, startTime: Double) {
        self.script = script
        self.lighting = lighting
        self.startTime = startTime
        self.framesByPhase = Array(repeating: [], count: script.phases.count)
    }

    public func status(at now: Double) -> SelfTestStatus? {
        let e = now - startTime
        guard let i = script.index(atElapsed: e) else { return nil }
        let p = script.phases[i]
        let el = e - script.starts[i]
        return SelfTestStatus(phaseIndex: i, phaseCount: script.phases.count, phase: p, phaseElapsed: el,
                              secondsRemainingInPhase: max(0, p.duration - el),
                              phaseProgress: min(1, max(0, el / p.duration)),
                              overallProgress: min(1, max(0, e / script.totalDuration)))
    }

    /// Emits each phase-start event (in order, exactly once) and `.finished` once the script has run out.
    public mutating func advance(to now: Double) -> [SelfTestEvent] {
        guard !wasAborted, !isFinished else { return [] }
        var events: [SelfTestEvent] = []
        let e = now - startTime
        while announcedPhases < script.phases.count, e >= script.starts[announcedPhases] {
            events.append(.phaseStarted(index: announcedPhases))
            announcedPhases += 1
        }
        if e >= script.totalDuration {
            isFinished = true
            events.append(.finished)
        }
        return events
    }

    /// Files the frame under the phase containing its arrival time. Frames before the start or after
    /// the end of the script, and frames after an abort, are ignored.
    public mutating func record(_ frame: SelfTestFrame) {
        guard !wasAborted, let i = script.index(atElapsed: frame.arrival - startTime) else { return }
        framesByPhase[i].append(frame)
    }

    public mutating func abort() { wasAborted = true }

    /// Frames of phase `i` that arrived between `window.lowerBound` and `window.upperBound` seconds
    /// after that phase started (upper bound exclusive).
    public func frames(inPhase i: Int, window: ClosedRange<Double>) -> [SelfTestFrame] {
        guard framesByPhase.indices.contains(i) else { return [] }
        let t0 = startTime + script.starts[i]
        return framesByPhase[i].filter { $0.arrival - t0 >= window.lowerBound && $0.arrival - t0 < window.upperBound }
    }

    /// Absolute (monotonic) time at which phase `i` starts.
    public func absoluteStart(of i: Int) -> Double { startTime + script.starts[i] }
    public func absoluteEnd(of i: Int) -> Double { startTime + script.starts[i] + script.phases[i].duration }
}

extension TrackingState: Codable {}
