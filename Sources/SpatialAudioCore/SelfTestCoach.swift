import Foundation

/// ALL VALUES ARE UNTUNED PROPOSALS. The real self-test reports (07:45, 08:12) showed turns of 37-63 degrees with 25-57 degrees
/// of cross-axis leakage and reference windows that were not still. The coach tells the person, live, how far they are from
/// the target on each axis and whether another axis is moving, so they can correct DURING the hold.
public struct CoachConfig: Equatable, Sendable {
    /// "good" = at least this fraction of the target ...
    public var goodFromFraction = 0.7
    /// ... and at most this fraction (beyond it: too far).
    public var tooFarFraction = 1.5
    /// Another axis moving more than this fraction of the instructed one is flagged. The detector's own limit is 0.6.
    public var otherAxisWarnRatio = 0.5
    /// The leakage warning only applies once the instructed move is at least this fraction of the target.
    public var otherAxisCheckFromFraction = 0.5
    /// Live values are medians of the frames of this many seconds.
    public var recentSeconds = 0.3
    public var minimumRecentSamples = 4
    /// Rest phases: robust spread of the last `restRecentSeconds` above this means "still moving".
    public var restStillSigmaDegrees = 2.5
    public var restRecentSeconds = 0.5
    /// Rest phases: distance from the baseline pose above this means "not back at the centre".
    public var restCenteredDegrees = 8.0
    /// The loss test's turn target (degrees of yaw).
    public var lossTurnTargetDegrees = 25.0

    public init() {}
}

public enum CoachVerdict: String, Equatable, Sendable {
    case noFace, tooSmall, good, tooFar, otherAxisMoving
    case steady, stillMoving, notCentered
}

public struct CoachFeedback: Equatable, Sendable {
    public var verdict: CoachVerdict
    public var message: String
    /// The axis the current phase asks for; nil in rest phases.
    public var instructedAxis: RotationAxis?
    public var targetDegrees: Double?
    /// |current - reference| per axis, degrees; nil when there is no usable face / reference.
    public var deviationDegrees: AngleTriple?
    public var worstOtherAxis: RotationAxis?
}

public enum SelfTestCoach {
    /// Live feedback for the phase running at `now`, or nil for phases that need none (get ready, cover, uncover).
    public static func feedback(session: SelfTestSession, now: Double, config: CoachConfig = CoachConfig()) -> CoachFeedback? {
        guard let status = session.status(at: now) else { return nil }
        let i = status.phaseIndex
        let phase = status.phase

        func faces(inPhase p: Int, since: Double) -> [VisionFaceAngles] {
            session.framesByPhase[p].filter { !$0.isWatchdogTick && $0.arrival >= since && $0.arrival <= now }.compactMap(\.angles)
        }
        func referenceFrames(for p: Int) -> [VisionFaceAngles] {
            guard p > 0, let w = session.script.phases[p - 1].analysisWindow else { return [] }
            return session.frames(inPhase: p - 1, window: w).filter { !$0.isWatchdogTick }.compactMap(\.angles)
        }

        switch phase.kind {
        case .hold:
            guard let move = phase.move else { return nil }
            return hold(axis: move.axis, target: move.targetDegrees, reference: referenceFrames(for: i),
                        recent: faces(inPhase: i, since: now - config.recentSeconds), config: config)
        case .lossTurn:
            return hold(axis: .yaw, target: config.lossTurnTargetDegrees, reference: referenceFrames(for: i),
                        recent: faces(inPhase: i, since: now - config.recentSeconds), config: config)
        case .baseline, .rest:
            var reference: [VisionFaceAngles] = []
            if phase.kind == .rest, let b = session.script.firstIndex(of: .baseline), let w = session.script.phases[b].analysisWindow {
                reference = session.frames(inPhase: b, window: w).filter { !$0.isWatchdogTick }.compactMap(\.angles)
            }
            return rest(reference: reference, recent: faces(inPhase: i, since: now - config.restRecentSeconds), config: config)
        case .getReady, .cover, .uncover:
            return nil
        }
    }

    // MARK: - pure helpers (unit-tested directly)

    private static let deg = 180 / Double.pi

    private static func median(_ xs: [VisionFaceAngles], _ a: RotationAxis) -> Double? {
        RobustStats.median(xs.map { $0.value(for: a) * deg })
    }

    static func hold(axis: RotationAxis, target: Double, reference: [VisionFaceAngles], recent: [VisionFaceAngles],
                     config c: CoachConfig) -> CoachFeedback {
        func fb(_ v: CoachVerdict, _ msg: String, dev: AngleTriple? = nil, worst: RotationAxis? = nil) -> CoachFeedback {
            CoachFeedback(verdict: v, message: msg, instructedAxis: axis, targetDegrees: target, deviationDegrees: dev, worstOtherAxis: worst)
        }
        guard recent.count >= c.minimumRecentSamples else { return fb(.noFace, "I can't see your face — look toward the camera.") }
        guard !reference.isEmpty else { return fb(.noFace, "No starting position recorded yet.") }
        var dev = AngleTriple()
        for a in RotationAxis.allCases {
            guard let r = median(reference, a), let n = median(recent, a) else { return fb(.noFace, "I can't see your face — look toward the camera.") }
            dev[a] = abs(n - r)
        }
        let d = dev[axis]
        let others = RotationAxis.allCases.filter { $0 != axis }
        let worst = others.max { dev[$0] < dev[$1] }!
        let ratio = d > 1e-9 ? dev[worst] / d : (dev[worst] > 1 ? 999 : 0)

        if d >= c.otherAxisCheckFromFraction * target, ratio > c.otherAxisWarnRatio {
            return fb(.otherAxisMoving, String(format: "%@ is moving too (%.0f°). Move ONLY %@ and keep the rest of your head still.",
                                               worst.rawValue.capitalized, dev[worst], axis.rawValue), dev: dev, worst: worst)
        }
        if d > c.tooFarFraction * target {
            return fb(.tooFar, String(format: "Too far (%.0f°, aim for about %.0f°) — come back a little.", d, target), dev: dev, worst: worst)
        }
        if d >= c.goodFromFraction * target {
            return fb(.good, String(format: "Good — %.0f° (target about %.0f°). Hold it here, keep still.", d, target), dev: dev, worst: worst)
        }
        return fb(.tooSmall, String(format: "A bit more: %.0f° so far, aim for about %.0f°.", d, target), dev: dev, worst: worst)
    }

    static func rest(reference: [VisionFaceAngles], recent: [VisionFaceAngles], config c: CoachConfig) -> CoachFeedback {
        func fb(_ v: CoachVerdict, _ msg: String, dev: AngleTriple? = nil) -> CoachFeedback {
            CoachFeedback(verdict: v, message: msg, instructedAxis: nil, targetDegrees: nil, deviationDegrees: dev, worstOtherAxis: nil)
        }
        guard recent.count >= c.minimumRecentSamples else { return fb(.noFace, "I can't see your face — look toward the camera.") }
        var worstSigma = 0.0
        var dev: AngleTriple?
        for a in RotationAxis.allCases {
            worstSigma = max(worstSigma, RobustStats.sigma(recent.map { $0.value(for: a) * deg }) ?? 0)
        }
        if !reference.isEmpty {
            var d = AngleTriple()
            for a in RotationAxis.allCases {
                if let r = median(reference, a), let n = median(recent, a) { d[a] = abs(n - r) }
            }
            dev = d
        }
        if worstSigma > c.restStillSigmaDegrees {
            return fb(.stillMoving, String(format: "Still moving (±%.1f°). Hold completely still.", worstSigma), dev: dev)
        }
        if let d = dev, max(d.yaw, d.pitch, d.roll) > c.restCenteredDegrees {
            return fb(.notCentered, String(format: "Not back at the centre (%.0f° off). Look straight at the screen.", max(d.yaw, d.pitch, d.roll)), dev: dev)
        }
        return fb(.steady, "Steady — keep still.", dev: dev)
    }
}
