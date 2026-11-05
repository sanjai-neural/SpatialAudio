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

    /// How far to move, in degrees (the coached target; the detector only needs the floors in `SignDetectionConfig`).
    /// Smaller than the first version (which gave no target and produced 37-63 degree turns with 25-57 degrees of
    /// cross-axis leakage in the two real reports): a moderate, single-axis move is what the detector can judge.
    public var targetDegrees: Double {
        switch self {
        case .turnLeft: 30
        case .lookUp: 20
        case .tiltRightEar: 20
        }
    }
}

/// The loss test's cover cue waits until the tracker has been LOCKED continuously for `minimumLockedSeconds`; if that does
/// not happen within `maximumWaitSeconds` the loss test is marked INVALID instead of being run on a tracker that was
/// already losing the face before the cover (the 08:12 real report started in `decaying`).
public struct LockGate: Equatable, Sendable {
    public var minimumLockedSeconds = 1.0
    public var maximumWaitSeconds = 10.0
    public init(minimumLockedSeconds: Double = 1.0, maximumWaitSeconds: Double = 10.0) {
        self.minimumLockedSeconds = minimumLockedSeconds; self.maximumWaitSeconds = maximumWaitSeconds
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
    /// If set, this phase does not start until the tracker has been locked long enough (see `LockGate`).
    public var lockGate: LockGate? = nil
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

    /// The same script without any lock gate: fixed timing only. For tests of the timing and for sources (the simulated
    /// user) that follow the nominal times.
    public var withoutLockGates: SelfTestScript {
        SelfTestScript(phases: phases.map { var p = $0; p.lockGate = nil; return p })
    }

    /// The statistics window length: total duration of the phases flagged `inStatsWindow`.
    public var statsWindowSeconds: Double { phases.filter(\.inStatsWindow).reduce(0) { $0 + $1.duration } }

    /// getReady 3 s, baseline 2 s, then for each move twice (hold 3 s + rest 2 s), then the loss test
    /// (turn 3 s, cover 5 s, uncover 4 s). The 12 hold/rest phases are exactly the 30 s statistics window.
    public static let standard: SelfTestScript = {
        var phases: [SelfTestPhase] = []
        func add(_ kind: SelfTestPhase.Kind, move: SelfTestMove? = nil, rep: Int? = nil,
                 title: String, instruction: String, duration: Double,
                 window: ClosedRange<Double>? = nil, stats: Bool = false, cue: SelfTestCue, gate: LockGate? = nil) {
            phases.append(SelfTestPhase(id: phases.count, kind: kind, move: move, repetition: rep, title: title,
                                        instruction: instruction, duration: duration, analysisWindow: window,
                                        inStatsWindow: stats, cue: cue, lockGate: gate))
        }

        add(.getReady, title: "GET READY",
            instruction: "Sit the way you normally do, facing the screen. The test starts when the countdown ends.",
            duration: 3, cue: .begin)
        add(.baseline, title: "LOOK STRAIGHT AHEAD",
            instruction: "Look at the middle of the screen and stay completely still.",
            duration: 2, window: 0.5...2.0, cue: .rest)

        let moves = SelfTestMove.allCases
        for (mi, move) in moves.enumerated() {
            for rep in 1...2 {
                let how: String
                switch move {
                case .turnLeft:
                    how = "Turn your head toward YOUR left shoulder (the side of your left hand), about 30°, and keep it there."
                case .lookUp:
                    how = "Tilt your head back so your chin goes up, about 20°. Moving only your eyes does not count."
                case .tiltRightEar:
                    how = "Tilt your head so YOUR right ear moves down toward YOUR right shoulder, about 20°. Your face still points at the screen."
                }
                add(.hold, move: move, rep: rep,
                    title: "\(move.label.uppercased()) — HOLD  (\(rep) of 2)",
                    instruction: how + " Move ONLY this one way and keep the rest of your head still. Hold until the next sound.",
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
            instruction: "Turn your head about 25° toward YOUR left shoulder (a quarter of the way, not more) and hold it still. The camera test starts only after tracking has been steady for a second; keep still, even when you hear a sound.",
            duration: 3, cue: .hold)
        add(.cover, title: "COVER THE CAMERA NOW",
            instruction: "Cover the camera lens with your hand. Keep your head turned and still.",
            duration: 5, cue: .cover, gate: LockGate())
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
    /// The weakest quality component for this frame: "none" (all components 1), "no face", "size", "edge", "center jump",
    /// "scale jump", "angular speed", "frame rate", "vision confidence", or "no frames" for watchdog ticks. "n/a" if unknown.
    public var limiting: String
    /// Vision angles after the sign mapping, before filtering and calibration, in degrees; nil when no face.
    public var mappedDegrees: AngleTriple?
    /// The face bounding box (normalized image coordinates, numbers only); nil when no face.
    public var faceBox: NormalizedRect?

    public init(arrival: Double, captureTime: Double, angles: VisionFaceAngles?, frameMirrored: Bool,
                videoRotationAngle: Double? = nil, state: TrackingState, pose: Quaternion,
                qualityOverall: Double, isWatchdogTick: Bool = false,
                deliveryLatency: Double, visionDuration: Double, totalLatency: Double,
                limiting: String = "n/a", mappedDegrees: AngleTriple? = nil, faceBox: NormalizedRect? = nil) {
        self.arrival = arrival; self.captureTime = captureTime; self.angles = angles
        self.frameMirrored = frameMirrored; self.videoRotationAngle = videoRotationAngle
        self.state = state; self.pose = pose; self.qualityOverall = qualityOverall
        self.isWatchdogTick = isWatchdogTick; self.deliveryLatency = deliveryLatency
        self.visionDuration = visionDuration; self.totalLatency = totalLatency
        self.limiting = limiting; self.mappedDegrees = mappedDegrees; self.faceBox = faceBox
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
    /// True while the phase before a gated phase has run its time but the tracker is not yet locked long enough.
    public var isWaitingForLock = false
    /// Seconds the tracker has been continuously LOCKED right now (0 if it is not locked).
    public var lockedSeconds = 0.0
    public var lockSecondsNeeded = 0.0
    /// Seconds spent waiting so far / allowed.
    public var waitedSeconds = 0.0
    public var waitSecondsAllowed = 0.0
}

/// Plays a `SelfTestScript` against a monotonic clock and files each incoming frame under the phase
/// it arrived in. Everything is derived from the timestamps passed in, so it is deterministic and
/// testable; it never reads a clock itself.
///
/// Lock gate: a phase with a `LockGate` (the cover cue) does not start at its nominal time unless the tracker has been
/// LOCKED continuously for the required time (judged from the frames that were recorded, which also have to be arriving).
/// Until then the previous phase just continues and the session reports `isWaitingForLock`. When the gate opens, the gated
/// phase and every later phase are shifted by the time waited. If it does not open within the maximum wait, the run ends
/// at once and `lossGateFailed` is set: the loss test is then reported INVALID instead of being run on a tracker that was
/// not locked.
public struct SelfTestSession: Sendable {
    public let script: SelfTestScript
    public let lighting: LightingTag
    /// Monotonic seconds at which phase 0 begins.
    public let startTime: Double
    public private(set) var framesByPhase: [[SelfTestFrame]]
    public private(set) var announcedPhases = 0
    public private(set) var isFinished = false
    public private(set) var wasAborted = false
    /// Index of the gated phase, if any.
    public let gateIndex: Int?
    /// Seconds the gated phase (and all later phases) were delayed. Valid once `gateOpened`.
    public private(set) var gateShift = 0.0
    public private(set) var gateOpened = false
    public private(set) var lossGateFailed = false

    private var lockedSince: Double?
    private var lastFrameArrival: Double?
    /// A recorded frame older than this no longer counts as "tracking right now".
    static let staleFrameSeconds = 0.25

    public init(script: SelfTestScript = .standard, lighting: LightingTag, startTime: Double) {
        self.script = script
        self.lighting = lighting
        self.startTime = startTime
        self.framesByPhase = Array(repeating: [], count: script.phases.count)
        self.gateIndex = script.phases.firstIndex { $0.lockGate != nil }
    }

    // MARK: timeline

    /// Seconds from the session start at which phase `i` starts; nil if it has not started yet (behind a closed gate).
    public func effectiveStart(of i: Int) -> Double? {
        guard let g = gateIndex, i >= g else { return script.starts[i] }
        return gateOpened ? script.starts[i] + gateShift : nil
    }

    public var totalDuration: Double { script.totalDuration + (gateOpened ? gateShift : 0) }

    func phaseIndex(atElapsed e: Double) -> Int? {
        guard e.isFinite, e >= 0 else { return nil }
        guard let g = gateIndex, e >= script.starts[g] else { return script.index(atElapsed: e) }
        if lossGateFailed { return nil }
        if !gateOpened || e < script.starts[g] + gateShift { return g - 1 }     // still in the phase before the gate
        return script.index(atElapsed: e - gateShift)
    }

    private func lockedFor(_ now: Double) -> Double {
        guard let since = lockedSince, let last = lastFrameArrival, now - last <= Self.staleFrameSeconds else { return 0 }
        return max(0, now - since)
    }

    public func status(at now: Double) -> SelfTestStatus? {
        let e = now - startTime
        guard let i = phaseIndex(atElapsed: e) else { return nil }
        let p = script.phases[i]
        let start = effectiveStart(of: i) ?? script.starts[i]
        let el = e - start
        var s = SelfTestStatus(phaseIndex: i, phaseCount: script.phases.count, phase: p, phaseElapsed: el,
                               secondsRemainingInPhase: max(0, p.duration - el),
                               phaseProgress: min(1, max(0, el / p.duration)),
                               overallProgress: min(1, max(0, e / totalDuration)))
        if let g = gateIndex, i == g - 1, !gateOpened, e >= script.starts[g], let gate = script.phases[g].lockGate {
            s.isWaitingForLock = true
            s.lockedSeconds = lockedFor(now)
            s.lockSecondsNeeded = gate.minimumLockedSeconds
            s.waitedSeconds = e - script.starts[g]
            s.waitSecondsAllowed = gate.maximumWaitSeconds
        }
        return s
    }

    /// Emits each phase-start event (in order, exactly once) and `.finished` once the script has run out (or once the lock
    /// gate gave up).
    public mutating func advance(to now: Double) -> [SelfTestEvent] {
        guard !wasAborted, !isFinished else { return [] }
        var events: [SelfTestEvent] = []
        let e = now - startTime

        if let g = gateIndex, !gateOpened, e >= script.starts[g], let gate = script.phases[g].lockGate {
            let waited = e - script.starts[g]
            if lockedFor(now) >= gate.minimumLockedSeconds {
                gateOpened = true
                gateShift = max(0, waited)
            } else if waited >= gate.maximumWaitSeconds {
                lossGateFailed = true
                isFinished = true
                return [.finished]
            }
        }

        while announcedPhases < script.phases.count, let s = effectiveStart(of: announcedPhases), e >= s {
            events.append(.phaseStarted(index: announcedPhases))
            announcedPhases += 1
        }
        if announcedPhases == script.phases.count, e >= totalDuration {
            isFinished = true
            events.append(.finished)
        }
        return events
    }

    /// Files the frame under the phase containing its arrival time. Frames before the start or after
    /// the end of the script, and frames after an abort, are ignored. Also tracks how long the tracker has been locked.
    public mutating func record(_ frame: SelfTestFrame) {
        guard !wasAborted else { return }
        lastFrameArrival = frame.arrival
        if frame.state == .locked, !frame.isWatchdogTick {
            if lockedSince == nil { lockedSince = frame.arrival }
        } else {
            lockedSince = nil
        }
        guard let i = phaseIndex(atElapsed: frame.arrival - startTime) else { return }
        framesByPhase[i].append(frame)
    }

    public mutating func abort() { wasAborted = true }

    /// Frames of phase `i` that arrived between `window.lowerBound` and `window.upperBound` seconds
    /// after that phase started (upper bound exclusive).
    public func frames(inPhase i: Int, window: ClosedRange<Double>) -> [SelfTestFrame] {
        guard framesByPhase.indices.contains(i) else { return [] }
        let t0 = absoluteStart(of: i)
        return framesByPhase[i].filter { $0.arrival - t0 >= window.lowerBound && $0.arrival - t0 < window.upperBound }
    }

    /// Absolute (monotonic) time at which phase `i` starts. For a phase behind a gate that never opened this is the nominal time.
    public func absoluteStart(of i: Int) -> Double { startTime + (effectiveStart(of: i) ?? script.starts[i]) }
    /// Absolute end of phase `i`; the phase before the gate ends when the gate opens (it may have been extended).
    public func absoluteEnd(of i: Int) -> Double {
        if let g = gateIndex, i == g - 1 { return startTime + script.starts[g] + (gateOpened ? gateShift : 0) }
        return absoluteStart(of: i) + script.phases[i].duration
    }
}

extension TrackingState: Codable {}
