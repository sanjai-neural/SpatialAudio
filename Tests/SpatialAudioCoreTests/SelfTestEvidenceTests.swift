import Testing
import Foundation
@testable import SpatialAudioCore

private let fps = 30.0
private let dt = 1.0 / 30

/// Frames at 30 fps whose raw Vision yaw (degrees) is given per frame (nil = no face). Pitch and roll stay 0.
/// The output pose follows the raw yaw unless `pose` is given.
private func frames(rawYaw: [Double?], states: [TrackingState]? = nil, pose: [Double]? = nil, limiting: String = "none",
                    quality: Double = 1, start: Double = 0) -> [SelfTestFrame] {
    rawYaw.enumerated().map { i, yaw in
        let t = start + Double(i) * dt
        let poseYaw = pose?[i] ?? yaw ?? 0
        return SelfTestFrame(arrival: t, captureTime: t,
                             angles: yaw.map { VisionFaceAngles(yaw: $0 * deg, pitch: 0, roll: 0) }, frameMirrored: false,
                             state: states?[i] ?? .locked, pose: yawQ(poseYaw), qualityOverall: quality,
                             deliveryLatency: 0.06, visionDuration: 0.018, totalLatency: 0.08,
                             limiting: limiting, mappedDegrees: yaw.map { AngleTriple(yaw: $0, pitch: 0, roll: 0) },
                             faceBox: yaw == nil ? nil : NormalizedRect(x: 0.3, y: 0.25, width: 0.3, height: 0.45))
    }
}

@Suite struct StepEvidenceClassificationTests {
    /// 30 frames of 10°, a change at frame 15 as described by `change`, then more frames.
    func classify(_ raw: [Double?], at: Int = 15, states: [TrackingState]? = nil) -> StepClassification {
        StepEvidenceAnalyzer.classify(frames(rawYaw: raw, states: states), at: at, framesPerSecond: fps)
    }
    func series(before: Double = 10, jumpTo: Double, back: Double? = nil, backAfter: Int = 1, count: Int = 30) -> [Double?] {
        (0..<count).map { i in
            if i < 15 { return before }
            if let back, i >= 15 + backAfter { return back }
            return jumpTo
        }
    }

    @Test func aSingleFrameJumpThatComesBackIsASpike() {
        for backAfter in 1...5 {
            let c = classify(series(jumpTo: 40, back: 10, backAfter: backAfter))
            #expect(c.kind == .spike && c.framesUntilRawReturned == backAfter, "back after \(backAfter): \(c.kind)")
            #expect(abs((c.rawStepDegrees ?? 0) - 30) < 0.01 && abs((c.rawStepDegreesPerSecond ?? 0) - 900) < 0.5)
        }
        let late = classify(series(jumpTo: 40, back: 10, backAfter: 6))              // back only after 6 frames: not a spike by this rule
        #expect(late.kind != .spike)
    }

    @Test func aMovementSpreadOverSeveralFramesIsNotASpikeAndIsDescribedAsMultiFrame() {
        // 40° of yaw over 8 frames (5°/frame, 150°/s): a fast but ordinary head turn.
        let raw: [Double?] = (0..<30).map { i in 10 + 5 * Double(min(max(i - 10, 0), 8)) }
        let c = classify(raw, at: 14)
        #expect(c.kind == .multiFrameMovement && c.framesUntilRawReturned == nil)
        #expect((c.displacementOverTenFramesDegrees ?? 0) > 2 * (c.rawStepDegrees ?? 99))
    }

    @Test func aJumpThatStaysIsAbruptAndSustainedNotCalledAnOutlier() {
        let c = classify(series(jumpTo: 40))
        #expect(c.kind == .abruptAndSustained && c.framesUntilRawReturned == nil)
        #expect(c.explanation.contains("does not say which"))                        // it must not claim to know
    }

    @Test func aFaceThatAppearsOrVanishesAtTheStepHasNoRawStep() {
        var raw = series(jumpTo: 10)
        raw[15] = nil
        let c = classify(raw)
        #expect(c.kind == .faceAppearedOrVanished && c.rawStepDegrees == nil)
    }

    @Test func anOutputStepWithoutARawStepIsAFilterOrBlendEffect() {
        let all = frames(rawYaw: Array(repeating: 10.0, count: 30), pose: (0..<30).map { $0 < 15 ? 0 : 17 })
        let c = StepEvidenceAnalyzer.classify(all, at: 15, framesPerSecond: fps)
        #expect(c.kind == .outputOnly && (c.rawStepDegrees ?? 99) < 1e-6)
    }

    @Test func aSmallRawStepBesideALargeOutputStepIsABlendNotAnOutlierEvenAboveOneDegree() {
        // The healthy simulated run: the biggest output step (5.8°) is the reacquire blend; the raw angles moved 1.4° (noise).
        let raw: [Double?] = (0..<30).map { $0 < 15 ? 10.0 : 11.4 }
        let all = frames(rawYaw: raw, pose: (0..<30).map { $0 < 15 ? 20.0 : 25.8 })
        let c = StepEvidenceAnalyzer.classify(all, at: 15, framesPerSecond: fps)
        #expect(c.kind == .outputOnly && abs((c.rawStepDegrees ?? 0) - 1.4) < 0.01)
        #expect(c.explanation.contains("5.8"))
        // Whereas a raw step that explains the output step is not output-only:
        let real = StepEvidenceAnalyzer.classify(frames(rawYaw: raw.map { $0.map { $0 * 4 } }, pose: (0..<30).map { $0 < 15 ? 40.0 : 45.6 }), at: 15, framesPerSecond: fps)
        #expect(real.kind != .outputOnly)
    }

    @Test func aNearbyStateChangeIsFlaggedSeparately() {
        var states = [TrackingState](repeating: .locked, count: 30)
        states[16] = .holding; states[17] = .holding
        let c = classify(series(jumpTo: 40, back: 10, backAfter: 2), states: states)
        #expect(c.nearStateChange && c.explanation.contains("state change"))
        #expect(!classify(series(jumpTo: 40, back: 10, backAfter: 2)).nearStateChange)
    }

    @Test func tooLittleDataIsIndeterminateNotGuessed() {
        let c = classify(Array(series(jumpTo: 40).prefix(16)))                       // nothing after the step
        #expect(c.kind == .indeterminate || c.kind == .abruptAndSustained)
        #expect(c.kind != .spike)
    }

    @Test func legitimateFastTurnsAreNeverClassifiedAsSpikes() {
        // Sweep many realistic fast turns: 20°-90° over 2-12 frames. None may be reported as a one-frame outlier.
        for total in stride(from: 20.0, through: 90, by: 10) {
            for n in 2...12 {
                let raw: [Double?] = (0..<40).map { i in 10 + total * min(max(Double(i - 12) / Double(n), 0), 1) }
                let worst = (1..<40).max { abs(raw[$0]! - raw[$0 - 1]!) < abs(raw[$1]! - raw[$1 - 1]!) }!
                let c = StepEvidenceAnalyzer.classify(frames(rawYaw: raw), at: worst, framesPerSecond: fps)
                #expect(c.kind != .spike, "\(total)° over \(n) frames was called a spike")
            }
        }
    }
}

@Suite struct StepEvidenceWindowTests {
    @Test func theWindowHoldsRawMappedOutputQualityAndBoxNumbersAroundTheStep() throws {
        let all = frames(rawYaw: (0..<60).map { _ in 12.0 }, limiting: "angular speed", quality: 0.7)
        let ev = try #require(StepEvidenceAnalyzer.build(frames: all, stepIndex: 30, stepDegrees: 17.3, coverStart: 0.5, framesPerSecond: fps))
        #expect(ev.frames.count == 2 * StepEvidenceAnalyzer.radius + 1)
        #expect(abs(ev.stepDegrees - 17.3) < 1e-12 && ev.stateAtStep == "locked")
        let centre = try #require(ev.frames.first { abs($0.secondsFromStep) < 1e-9 })
        #expect(abs((centre.rawVisionDegrees?.yaw ?? 0) - 12) < 1e-6 && abs((centre.mappedDegrees?.yaw ?? 0) - 12) < 1e-9)
        #expect(abs(centre.outputPoseDegrees.yaw - 12) < 1e-6)
        #expect(centre.limiting == "angular speed" && centre.quality == 0.7 && centre.faceBoxHeight == 0.45)
        #expect(ev.frames.first!.secondsFromStep < 0 && ev.frames.last!.secondsFromStep > 0)
        #expect(zip(ev.frames, ev.frames.dropFirst()).allSatisfy { $0.secondsFromStep < $1.secondsFromStep })
    }

    @Test func theWindowIsClippedAtTheEdgesOfTheRun() throws {
        let all = frames(rawYaw: (0..<20).map { _ in 5.0 })
        let ev = try #require(StepEvidenceAnalyzer.build(frames: all, stepIndex: 3, stepDegrees: 1, coverStart: 0, framesPerSecond: fps))
        #expect(ev.frames.count == 3 + 1 + StepEvidenceAnalyzer.radius)      // 3 before, the step, 15 after (the run has 20 frames)
        #expect(StepEvidenceAnalyzer.build(frames: all, stepIndex: 99, stepDegrees: 1, coverStart: 0, framesPerSecond: fps) == nil)
    }

    @Test func theEvidenceCarriesNoImageDataOnlyNumbersAndShortStrings() throws {
        let all = frames(rawYaw: (0..<40).map { $0 == 20 ? nil : 5.0 })
        let ev = try #require(StepEvidenceAnalyzer.build(frames: all, stepIndex: 21, stepDegrees: 4, coverStart: 0, framesPerSecond: fps))
        let json = String(decoding: try JSONEncoder().encode(ev), as: UTF8.self)
        #expect(json.count < 20_000)
        #expect(!json.lowercased().contains("base64") && !json.lowercased().contains("image"))
    }

    @Test func theLossAnalyzerAttachesEvidenceAndFlagsASpikeInTheLockedState() throws {
        // Locked throughout; the raw yaw jumps for one frame at t = 4.0 and comes back (an outlier the filter passed through).
        var raw = [Double?](repeating: 25, count: 360)
        raw[120] = 55
        let state = [TrackingState](repeating: .locked, count: 360)
        let fs = frames(rawYaw: raw, states: state, start: 2)
        let r = LossAnalyzer.analyze(frames: fs, coverStart: 3, uncoverStart: 8, end: 14, machine: TrackingStateMachineConfig())
        #expect(r.jumpFlagged && r.maxJumpState == "locked")
        let ev = try #require(r.stepEvidence)
        #expect(ev.classification.kind == .spike)
        #expect(abs(ev.stepDegrees - r.maxFrameJumpDegrees) < 1e-9)
    }
}

@Suite struct LossInvalidTests {
    func run(states: (Double) -> TrackingState, from: Double = 2, to: Double = 14) -> [SelfTestFrame] {
        var out: [SelfTestFrame] = []
        var t = from
        while t < to {
            out.append(SelfTestFrame(arrival: t, captureTime: t, angles: VisionFaceAngles(yaw: 0.4, pitch: 0, roll: 0), frameMirrored: false,
                                     state: states(t), pose: yawQ(25), qualityOverall: 1, deliveryLatency: 0, visionDuration: 0, totalLatency: 0))
            t += dt
        }
        return out
    }

    @Test func aRunThatDidNotStartLockedIsInvalidNotFail() {
        // The 08:12 real run: the window began in `decaying`, then chattered.
        let fs = run { t in t < 2.4 ? .decaying : (t < 2.7 ? .locked : (t < 2.8 ? .holding : .locked)) }
        let r = LossAnalyzer.analyze(frames: fs, coverStart: 3, uncoverStart: 8, end: 14, machine: TrackingStateMachineConfig())
        #expect(r.verdict == .invalid)
        let why = r.invalidReason ?? ""
        #expect(why.contains("not LOCKED") && why.contains("decaying") && why.contains("holding") && r.notes.first?.hasPrefix("INVALID") == true)
    }

    @Test func aLockedStartIsNotInvalid() {
        let fs = run { t in t < 3.4 ? .locked : .holding }
        let r = LossAnalyzer.analyze(frames: fs, coverStart: 3, uncoverStart: 8, end: 14, machine: TrackingStateMachineConfig())
        #expect(r.verdict != .invalid && r.invalidReason == nil)
    }

    @Test func noFramesBeforeTheCoverCueIsInvalid() {
        let fs = run(states: { _ in .locked }, from: 3.2, to: 14)
        let r = LossAnalyzer.analyze(frames: fs, coverStart: 3, uncoverStart: 8, end: 14, machine: TrackingStateMachineConfig())
        #expect(r.verdict == .invalid && r.invalidReason?.contains("no frames") == true)
    }

    @Test func aKnownReasonFromTheSessionMakesTheRunInvalidEvenIfTheFramesLookFine() {
        let fs = run { _ in .locked }
        let r = LossAnalyzer.analyze(frames: fs, coverStart: 3, uncoverStart: 8, end: 14, machine: TrackingStateMachineConfig(), invalidReason: "gate gave up")
        #expect(r.verdict == .invalid && r.invalidReason == "gate gave up")
    }

    @Test func aSingleNonLockedFrameBeforeTheCueIsEnoughToInvalidateIt() {
        let fs = run { t in abs(t - 2.5) < 0.01 ? .holding : .locked }
        let r = LossAnalyzer.analyze(frames: fs, coverStart: 3, uncoverStart: 8, end: 14, machine: TrackingStateMachineConfig())
        #expect(r.verdict == .invalid)
    }
}

@Suite struct QualityAttributionTests {
    func f(_ q: Double, _ limiting: String, watchdog: Bool = false) -> SelfTestFrame {
        SelfTestFrame(arrival: 0, captureTime: 0, angles: nil, frameMirrored: false, state: .locked, pose: .identity,
                      qualityOverall: q, isWatchdogTick: watchdog, deliveryLatency: 0, visionDuration: 0, totalLatency: 0, limiting: limiting)
    }

    @Test func fractionsOfFramesPerLimitingComponentAddUpAndSplitByLowQuality() throws {
        let frames = [f(1, "none"), f(1, "none"), f(0.7, "angular speed"), f(0.45, "edge"), f(0.3, "edge"), f(0.0, "no face"),
                      f(0.35, "edge"), f(1, "none")]
        let s = try #require(QualityAnalyzer.summarize(name: "x", frames: frames, gate: QualityGateConfig()))   // loss 0.40, recover 0.60
        #expect(s.frames == 8 && abs(s.limitingFractions.values.reduce(0, +) - 1) < 1e-12)
        #expect(abs(s.limitingFractions["none"]! - 3.0 / 8) < 1e-12 && abs(s.limitingFractions["edge"]! - 3.0 / 8) < 1e-12)
        #expect(abs(s.fractionBelowLossThreshold - 3.0 / 8) < 1e-12)              // 0.30, 0.0, 0.35
        #expect(abs(s.fractionBelowRecoverThreshold - 4.0 / 8) < 1e-12)           // + 0.45
        #expect(s.limitingFractionsWhenLow["edge"] == 3.0 / 4 && s.limitingFractionsWhenLow["no face"] == 1.0 / 4)
        #expect(s.minQuality == 0 && abs(s.meanQuality - (3 + 0.7 + 0.45 + 0.3 + 0 + 0.35) / 8) < 1e-12)
    }

    @Test func watchdogTicksAreCountedSeparatelyAndAnEmptyWindowGivesNothing() throws {
        let s = try #require(QualityAnalyzer.summarize(name: "x", frames: [f(1, "none"), f(0, "no frames", watchdog: true)], gate: QualityGateConfig()))
        #expect(s.frames == 1 && s.watchdogTicks == 1 && s.limitingFractions == ["none": 1])
        #expect(QualityAnalyzer.summarize(name: "x", frames: [], gate: QualityGateConfig()) == nil)
        #expect(QualityAnalyzer.summarize(name: "x", frames: [f(0, "no frames", watchdog: true)], gate: QualityGateConfig()) == nil)
        #expect(s.limitingFractionsWhenLow.isEmpty)
    }
}
