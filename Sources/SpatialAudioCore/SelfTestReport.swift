import Foundation

// MARK: - Supporting report types

/// Programmatic evidence that a capture session stopped. It proves OUR session stopped and released its
/// input/output; it cannot prove the physical camera indicator light is off. That remains a visual check.
public struct CameraReleaseReport: Codable, Equatable, Sendable {
    public var wasRunningBeforeStop: Bool
    /// `AVCaptureSession.isRunning` read right after `stopRunning()` returned (it "blocks until the
    /// session object has completely stopped").
    public var isRunningAfterStop: Bool
    public var inputsAfterStop: Int
    public var outputsAfterStop: Int
    /// Number of `AVCaptureSession.didStopRunningNotification` deliveries observed for that session.
    public var stopNotificationsObserved: Int
    /// Sample-buffer callbacks that still arrived after `stop()` returned (should be 0).
    public var callbacksAfterStop: Int
    /// Whether the session object had been deallocated when the report was taken.
    public var sessionObjectDeallocated: Bool
    public var secondsSinceStop: Double

    public var isClean: Bool {
        !isRunningAfterStop && inputsAfterStop == 0 && outputsAfterStop == 0 && callbacksAfterStop == 0
    }

    public init(wasRunningBeforeStop: Bool, isRunningAfterStop: Bool, inputsAfterStop: Int, outputsAfterStop: Int,
                stopNotificationsObserved: Int, callbacksAfterStop: Int, sessionObjectDeallocated: Bool,
                secondsSinceStop: Double) {
        self.wasRunningBeforeStop = wasRunningBeforeStop; self.isRunningAfterStop = isRunningAfterStop
        self.inputsAfterStop = inputsAfterStop; self.outputsAfterStop = outputsAfterStop
        self.stopNotificationsObserved = stopNotificationsObserved; self.callbacksAfterStop = callbacksAfterStop
        self.sessionObjectDeallocated = sessionObjectDeallocated; self.secondsSinceStop = secondsSinceStop
    }
}

/// The user's answer to "is the green camera light off?" (a visual check no code can make).
public enum GreenLightAnswer: String, Codable, Sendable {
    case notAsked = "not asked"
    case off = "user reports OFF"
    case stillOn = "user reports STILL ON"
}

public struct EnvironmentInfo: Codable, Equatable, Sendable {
    public var macOSVersion: String
    public var hardwareModel: String
    public var cameraName: String?
    public var capturePreset: String
    public var visionRevision: Int
    /// Fraction of face-bearing frames that were horizontally mirrored.
    public var framesMirroredFraction: Double?
    public var videoRotationAnglesDegrees: [Double]
}

public struct StatsReport: Codable, Equatable, Sendable {
    /// Total length of the phases that form the statistics window.
    public var windowSeconds: Double
    public var frameCount: Int
    public var facePresentFraction: Double
    public var meanQuality: Double
    /// Mean frame rate from camera capture timestamps.
    public var fpsMean: Double?
    public var frameIntervalMs: SeriesSummary?
    /// receivedAt − capture timestamp.
    public var deliveryMs: SeriesSummary?
    public var visionMs: SeriesSummary?
    /// pose ready − capture timestamp (excludes any delay before the sample timestamp).
    public var totalMs: SeriesSummary?
    public var sufficient: Bool
    public var notes: [String]
}

public enum StatsAnalyzer {
    public static func analyze(frames all: [SelfTestFrame], windowSeconds: Double, minimumFrames: Int,
                               stallWarningMs: Double = 100) -> StatsReport {
        let frames = all.filter { !$0.isWatchdogTick }.sorted { $0.captureTime < $1.captureTime }
        var notes: [String] = []
        let intervals = zip(frames, frames.dropFirst()).map { ($1.captureTime - $0.captureTime) * 1000 }.filter { $0 > 0 }
        let fps: Double? = RobustStats.mean(intervals).map { 1000 / $0 }
        let facePresent = frames.isEmpty ? 0 : Double(frames.filter { $0.angles != nil }.count) / Double(frames.count)
        let sufficient = frames.count >= minimumFrames
        if !sufficient { notes.append("only \(frames.count) frames (need ≥ \(minimumFrames)); statistics are weak") }
        if let worst = intervals.max(), worst > stallWarningMs {
            let nominal = RobustStats.median(intervals) ?? 0
            notes.append(String(format: "frame delivery stalled: the longest gap between frames was %.0f ms (typical %.0f ms). A throttled app (App Nap, heavy load) or a camera frame-rate drop (low light) causes this, and it distorts fps, latency and the loss test", worst, nominal))
        }
        return StatsReport(
            windowSeconds: windowSeconds, frameCount: frames.count, facePresentFraction: facePresent,
            meanQuality: RobustStats.mean(frames.map(\.qualityOverall)) ?? 0, fpsMean: fps,
            frameIntervalMs: SeriesSummary(intervals),
            deliveryMs: SeriesSummary(frames.map { $0.deliveryLatency * 1000 }),
            visionMs: SeriesSummary(frames.map { $0.visionDuration * 1000 }),
            totalMs: SeriesSummary(frames.map { $0.totalLatency * 1000 }),
            sufficient: sufficient, notes: notes)
    }
}

public struct SignDetectionReport: Codable, Equatable, Sendable {
    public var yaw: AxisSignResult
    public var pitch: AxisSignResult
    public var roll: AxisSignResult

    public subscript(axis: RotationAxis) -> AxisSignResult {
        switch axis { case .yaw: yaw; case .pitch: pitch; case .roll: roll }
    }

    public var determinedAxes: [RotationAxis] { RotationAxis.allCases.filter { self[$0].outcome == .determined } }
    public var allDetermined: Bool { determinedAxes.count == 3 }

    /// `base` with the invert flag of every DETERMINED axis set to what the test found. Inconclusive axes
    /// keep `base` untouched (the detector never guesses).
    public func recommendedMapping(over base: HeadAngleMapping) -> HeadAngleMapping {
        var m = base
        if yaw.outcome == .determined { m.invertYaw = yaw.invertNeeded ?? m.invertYaw }
        if pitch.outcome == .determined { m.invertPitch = pitch.invertNeeded ?? m.invertPitch }
        if roll.outcome == .determined { m.invertRoll = roll.invertNeeded ?? m.invertRoll }
        return m
    }
}

public struct SelfTestConfigUsed: Codable, Equatable, Sendable {
    public var signs: SignDetectionConfig
    public var loss: LossAnalysisConfig
    public var machine: TrackingStateMachineConfig
    public var minimumStatsFrames: Int
}

public struct SelfTestAnalysisConfig: Equatable, Sendable {
    public var signs = SignDetectionConfig()
    public var loss = LossAnalysisConfig()
    public var minimumStatsFrames = 150
    public init() {}
}

/// Facts the analyzer cannot derive from frames.
public struct SelfTestContext: Sendable {
    public var createdAt: String
    /// "camera" or "simulated".
    public var inputSource: String
    public var macOSVersion: String
    public var hardwareModel: String
    public var cameraName: String?
    public var capturePreset: String
    public var visionRevision: Int
    public var mappingDuringTest: HeadAngleMapping
    public var machine: TrackingStateMachineConfig

    public init(createdAt: String, inputSource: String, macOSVersion: String, hardwareModel: String,
                cameraName: String?, capturePreset: String, visionRevision: Int,
                mappingDuringTest: HeadAngleMapping, machine: TrackingStateMachineConfig) {
        self.createdAt = createdAt; self.inputSource = inputSource; self.macOSVersion = macOSVersion
        self.hardwareModel = hardwareModel; self.cameraName = cameraName; self.capturePreset = capturePreset
        self.visionRevision = visionRevision; self.mappingDuringTest = mappingDuringTest; self.machine = machine
    }
}

// MARK: - Report

/// Numbers and short strings only. No images or video frames exist in, or are reachable from, this type.
public struct SelfTestReport: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var createdAt: String
    public var inputSource: String
    public var lighting: LightingTag
    public var environment: EnvironmentInfo
    public var mappingDuringTest: HeadAngleMapping
    public var signs: SignDetectionReport
    public var loss: LossReport
    public var stats: StatsReport
    public var cameraRelease: CameraReleaseReport?
    public var greenLight: GreenLightAnswer
    /// Set only if the user confirmed "apply".
    public var appliedMapping: HeadAngleMapping?
    public var config: SelfTestConfigUsed
    public var assumptions: [String]

    public var isSimulated: Bool { inputSource == "simulated" }

    public static let standardAssumptions = [
        "Signs assume each move was performed in the instructed direction; the test cannot see which way you actually moved.",
        "Angles are RAW Vision values (VNFaceObservation yaw/pitch/roll, revision 3) before any sign mapping.",
        "All thresholds are untuned proposals; the values used are listed in this report.",
        "Latency excludes any delay before the camera sample timestamp.",
        "Release check proves the capture session stopped; whether the green camera light is off is a visual check.",
    ]
}

public enum SelfTestAnalyzer {
    public static func analyze(_ session: SelfTestSession, context: SelfTestContext,
                               config: SelfTestAnalysisConfig = SelfTestAnalysisConfig()) -> SelfTestReport {
        let script = session.script

        func evidence(for move: SelfTestMove) -> [RepetitionEvidence] {
            var out: [RepetitionEvidence] = []
            for (i, p) in script.phases.enumerated() where p.kind == .hold && p.move == move {
                guard i > 0, let holdWindow = p.analysisWindow, let refWindow = script.phases[i - 1].analysisWindow else { continue }
                out.append(RepetitionEvidence(referenceFrames: session.frames(inPhase: i - 1, window: refWindow),
                                              holdFrames: session.frames(inPhase: i, window: holdWindow)))
            }
            return out
        }
        let signs = SignDetectionReport(
            yaw: SignDetector.analyze(axis: .yaw, evidence: evidence(for: .turnLeft), config: config.signs),
            pitch: SignDetector.analyze(axis: .pitch, evidence: evidence(for: .lookUp), config: config.signs),
            roll: SignDetector.analyze(axis: .roll, evidence: evidence(for: .tiltRightEar), config: config.signs))

        let loss: LossReport
        if let turn = script.firstIndex(of: .lossTurn), let cover = script.firstIndex(of: .cover),
           let uncover = script.firstIndex(of: .uncover) {
            let frames = (turn...uncover).flatMap { session.framesByPhase[$0] }
            loss = LossAnalyzer.analyze(frames: frames, coverStart: session.absoluteStart(of: cover),
                                        uncoverStart: session.absoluteStart(of: uncover),
                                        end: session.absoluteEnd(of: uncover), machine: context.machine,
                                        config: config.loss)
        } else {
            loss = LossAnalyzer.analyze(frames: [], coverStart: 0, uncoverStart: 0, end: 0,
                                        machine: context.machine, config: config.loss)
        }

        let statFrames = script.phases.indices.filter { script.phases[$0].inStatsWindow }.flatMap { session.framesByPhase[$0] }
        let stats = StatsAnalyzer.analyze(frames: statFrames, windowSeconds: script.statsWindowSeconds,
                                          minimumFrames: config.minimumStatsFrames)

        let allFrames = session.framesByPhase.flatMap { $0 }.filter { !$0.isWatchdogTick && $0.angles != nil }
        let env = EnvironmentInfo(
            macOSVersion: context.macOSVersion, hardwareModel: context.hardwareModel, cameraName: context.cameraName,
            capturePreset: context.capturePreset, visionRevision: context.visionRevision,
            framesMirroredFraction: allFrames.isEmpty ? nil : Double(allFrames.filter(\.frameMirrored).count) / Double(allFrames.count),
            videoRotationAnglesDegrees: Array(Set(allFrames.compactMap(\.videoRotationAngle))).sorted())

        return SelfTestReport(
            createdAt: context.createdAt, inputSource: context.inputSource, lighting: session.lighting,
            environment: env, mappingDuringTest: context.mappingDuringTest, signs: signs, loss: loss, stats: stats,
            cameraRelease: nil, greenLight: .notAsked, appliedMapping: nil,
            config: SelfTestConfigUsed(signs: config.signs, loss: config.loss, machine: context.machine,
                                       minimumStatsFrames: config.minimumStatsFrames),
            assumptions: SelfTestReport.standardAssumptions)
    }
}

// MARK: - File names, JSON, markdown

extension SelfTestReport {
    /// ISO-8601 with the given zone's offset, e.g. 2026-11-04T15:30:12-05:00.
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// e.g. selftest-20261104-153012-normal-light (SIMULATED runs get a -SIMULATED suffix).
    public static func fileStem(date: Date, timeZone: TimeZone = .current, lighting: LightingTag, simulated: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "selftest-\(f.string(from: date))-\(lighting.fileSlug)" + (simulated ? "-SIMULATED" : "")
    }

    public func jsonData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> SelfTestReport {
        try JSONDecoder().decode(SelfTestReport.self, from: data)
    }
}

extension SelfTestReport {
    /// Human-readable report (also what "Copy report" puts on the clipboard).
    public func markdown() -> String {
        func f1(_ x: Double) -> String { String(format: "%.1f", x) }
        func sd(_ x: Double) -> String { String(format: "%+.1f°", x) }
        func ms(_ s: SeriesSummary?) -> String {
            guard let s else { return "—" }
            return String(format: "%.0f | %.0f | %.0f", s.mean, s.p95, s.max)
        }
        var L: [String] = []
        L.append("# SpatialAudio self-test report")
        L.append("")
        if isSimulated {
            L.append("> **SIMULATED INPUT** — produced by the built-in simulated user, NOT camera data. Do not use these numbers as hardware results.")
            L.append("")
        }
        L.append("- **Date:** \(createdAt)")
        L.append("- **Lighting:** \(lighting.rawValue)")
        L.append("- **Input:** \(inputSource)\(environment.cameraName.map { " (\($0))" } ?? ""), capture preset \(environment.capturePreset), Vision request revision \(environment.visionRevision)")
        L.append("- **Machine:** \(environment.hardwareModel), macOS \(environment.macOSVersion)")
        L.append("- **Frames mirrored (observed):** \(environment.framesMirroredFraction.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"); **rotation angle(s):** \(environment.videoRotationAnglesDegrees.isEmpty ? "n/a" : environment.videoRotationAnglesDegrees.map { String(format: "%.0f°", $0) }.joined(separator: ", "))")
        L.append("- **Invert flags in effect during the test:** yaw=\(mappingDuringTest.invertYaw ? "ON" : "off") pitch=\(mappingDuringTest.invertPitch ? "ON" : "off") roll=\(mappingDuringTest.invertRoll ? "ON" : "off")")
        L.append("")
        L.append("## 1. Sign detection")
        L.append("Target convention: turn LEFT = +yaw, look UP = +pitch, tilt RIGHT ear down = +roll. Raw Vision angles, degrees.")
        L.append("")
        L.append("| Axis | Result | Raw Vision sign during move | Invert needed* | Repetition Δ (leakage ratio) | Reasons / notes |")
        L.append("|---|---|---|---|---|---|")
        for axis in RotationAxis.allCases {
            let r = signs[axis]
            let reps = r.repetitions.enumerated().map { (i, x) in
                x.referenceSamples == 0 && x.holdSamples == 0 ? "rep\(i + 1): no data"
                    : "rep\(i + 1): \(sd(x.intendedDeltaDegrees)) (\(String(format: "%.2f", x.leakageRatio)))\(x.usable ? "" : " ✗")"
            }.joined(separator: "; ")
            L.append("| \(axis.rawValue) | \(r.outcome == .determined ? "DETERMINED" : "INCONCLUSIVE") | \(r.rawVisionSign.map { $0 > 0 ? "+" : "−" } ?? "—") | \(r.invertNeeded.map { $0 ? "YES" : "no" } ?? "—") | \(reps) | \(r.reasons.isEmpty ? "—" : r.reasons.joined(separator: " / ")) |")
        }
        L.append("")
        L.append("\\* relative to the documented default mapping (all invert flags off, including its mirror compensation).")
        if let applied = appliedMapping {
            L.append("")
            L.append("**Applied by the user:** invert yaw=\(applied.invertYaw ? "ON" : "off") pitch=\(applied.invertPitch ? "ON" : "off") roll=\(applied.invertRoll ? "ON" : "off")")
        }
        L.append("")
        L.append("## 2. Loss test (turn ~25° left, cover camera, uncover)")
        L.append("- **Verdict:** \(loss.verdict.rawValue.uppercased())")
        L.append("- **Observed state sequence:** \(loss.observedSequence.joined(separator: " → ")) (expected \(loss.expectedSequence.joined(separator: " → ")))")
        L.append(String(format: "- **Time in state:** locked-before-loss %.2f s, holding %.2f s (configured %.2f), decaying %.2f s (configured %.2f), static %.2f s",
                        loss.secondsInState.lockedBeforeLoss, loss.secondsInState.holding, loss.expectedHoldSeconds,
                        loss.secondsInState.decaying, loss.expectedDecaySeconds, loss.secondsInState.staticState))
        L.append("- **Holding → static:** \(loss.timeToStaticSeconds.map { String(format: "%.2f s", $0) } ?? "n/a"); **reacquire after uncover cue:** \(loss.reacquireSecondsAfterUncoverCue.map { String(format: "%.2f s (includes your reaction time)", $0) } ?? "n/a")")
        L.append(String(format: "- **Largest frame-to-frame pose step:** %.2f° (threshold %.1f°) → %@%@",
                        loss.maxFrameJumpDegrees, loss.jumpThresholdDegrees, loss.jumpFlagged ? "**FLAGGED**" : "ok",
                        loss.maxJumpState.map { " (in state \($0), \(String(format: "%.2f", loss.maxJumpSecondsAfterCoverCue ?? 0)) s after the cover cue)" } ?? ""))
        L.append("- **Held pose distance from neutral:** \(loss.heldPoseTravelDegrees.map { String(format: "%.1f°", $0) } ?? "n/a")\(loss.jumpCheckMeaningful ? "" : " — jump check is WEAK")")
        for n in loss.notes { L.append("- note: \(n)") }
        L.append("")
        L.append("## 3. Statistics (\(String(format: "%.0f", stats.windowSeconds)) s window, \(lighting.rawValue))")
        L.append("- **Frames:** \(stats.frameCount); **face found in:** \(String(format: "%.0f%%", stats.facePresentFraction * 100)); **mean quality:** \(String(format: "%.2f", stats.meanQuality))")
        L.append("- **Mean frame rate:** \(stats.fpsMean.map { String(format: "%.1f fps", $0) } ?? "n/a")")
        L.append("")
        L.append("| Metric (ms) | mean | p95 | max |")
        L.append("|---|---|---|---|")
        L.append("| Frame interval | \(ms(stats.frameIntervalMs)) |")
        L.append("| Delivery (sample timestamp → callback) | \(ms(stats.deliveryMs)) |")
        L.append("| Vision | \(ms(stats.visionMs)) |")
        L.append("| Total (sample timestamp → pose ready) | \(ms(stats.totalMs)) |")
        for n in stats.notes { L.append("- note: \(n)") }
        L.append("")
        L.append("## 4. Camera release")
        if let r = cameraRelease {
            L.append("- **Programmatic:** \(r.isClean ? "CLEAN" : "NOT CLEAN") — isRunning after stop=\(r.isRunningAfterStop), inputs=\(r.inputsAfterStop), outputs=\(r.outputsAfterStop), callbacks after stop=\(r.callbacksAfterStop), (informational: stop notifications seen=\(r.stopNotificationsObserved), session object deallocated=\(r.sessionObjectDeallocated); both depend on the run loop and timing) — checked \(f1(r.secondsSinceStop)) s after stop")
        } else if isSimulated {
            L.append("- **Programmatic:** n/a — simulated input has no camera hardware")
        } else {
            L.append("- **Programmatic:** not available (the camera was not stopped and read back)")
        }
        L.append("- **Green light (visual, user-reported):** \(greenLight.rawValue)")
        L.append("")
        L.append("## Thresholds used (all untuned)")
        let s = config.signs
        L.append("- Sign detection: min movement yaw \(f1(s.minMovementDegrees.yaw))° / pitch \(f1(s.minMovementDegrees.pitch))° / roll \(f1(s.minMovementDegrees.roll))° and ≥ \(f1(s.noiseMultiple))× reference noise; hold spread ≤ \(String(format: "%.0f%%", s.maxHoldSpreadRatio * 100)) of the movement; other-axis leakage ≤ \(String(format: "%.2f", s.maxLeakageRatio)); ≥ \(s.requiredValidRepetitions) usable agreeing repetitions; ≥ \(s.minReferenceSamples)/\(s.minHoldSamples) reference/hold samples; face in ≥ \(String(format: "%.0f%%", s.minFacePresentFraction * 100)) of hold frames")
        let lo = config.loss
        L.append("- Loss test: jump threshold = max(\(f1(lo.jumpThresholdFloorDegrees))°, \(String(format: "%.2f", lo.jumpSafetyFactor))× the largest step the eased blend could produce); meaningful if held pose ≥ \(f1(lo.minMeaningfulTravelDegrees))° from neutral")
        L.append(String(format: "- State machine: min confidence %.2f, hold %.2f s, decay %.2f s, reacquire blend %.2f s", config.machine.minConfidence, config.machine.holdDuration, config.machine.decayDuration, config.machine.reacquireBlendDuration))
        L.append("")
        L.append("## Assumptions and limits")
        for a in assumptions { L.append("- \(a)") }
        L.append("")
        return L.joined(separator: "\n")
    }
}
