import Testing
import Foundation
@testable import SpatialAudioCore

// Step 3a-2: the blind listening test's pure logic (trial plan, geometry truth, the runner on VIRTUAL time, scoring, the two flags, the report).
// No audio, no clock, no sleeps: every time below is a number handed to the runner. The simulated listener is FABRICATED and decides nothing.
// Known values (SplitMix64 outputs, the shuffled orders, the binomial tails) come from an independent Python implementation, not from this code.

private let SL = BlindCondition.staticLeft, SR = BlindCondition.staticRight, SA = BlindCondition.staticAhead
private let HL = BlindCondition.headLeft45, HR = BlindCondition.headRight45

private func abbreviate(_ plan: [BlindCondition]) -> [String] {
    plan.map { c in
        switch c { case .staticLeft: "SL"; case .staticRight: "SR"; case .staticAhead: "SA"; case .headLeft45: "HL"; case .headRight45: "HR" }
    }
}

/// Records for scoring tests: `(condition, answer, how many times)`; truth comes from the geometry like in a real run.
private func recs(_ rows: [(BlindCondition, BlindAnswer, Int)]) -> [BlindTrialRecord] {
    var out: [BlindTrialRecord] = []
    for (c, a, n) in rows {
        for _ in 0..<n {
            out.append(BlindTrialRecord(number: out.count + 1, condition: c, truth: BlindScenes.truth(for: c), answer: a,
                                        reactionSeconds: a == .notAnswered ? nil : 1.5))
        }
    }
    return out
}

@Suite("BlindListening: plan and geometry")
struct BlindListeningPlanTests {
    @Test func splitMixKnownValues() {
        var a = SplitMix64(seed: 0)
        #expect([a.next(), a.next(), a.next()] == [0xe220a8397b1dcdaf, 0x6e789e6aa1b965f4, 0x06c45d188009454f])
        var b = SplitMix64(seed: 12345)
        #expect([b.next(), b.next()] == [0x22118258a9d111a0, 0x346edce5f713f8ed])
    }

    @Test func planHasFourOfEachAndTwentyTotal() {
        for seed in [0, 1, 42, 99] as [UInt64] {
            let plan = BlindTrialPlan.make(seed: seed)
            #expect(plan.count == 20)
            for c in BlindCondition.allCases { #expect(plan.filter { $0 == c }.count == 4, "seed \(seed) \(c)") }
        }
    }

    @Test func planIsDeterministicAndSeedDependent() {
        #expect(BlindTrialPlan.make(seed: 5) == BlindTrialPlan.make(seed: 5))
        #expect(BlindTrialPlan.make(seed: 1) != BlindTrialPlan.make(seed: 2))
        #expect(BlindTrialPlan.make(seed: 0) != BlindTrialPlan.make(seed: 3))
    }

    @Test func planMatchesIndependentOracle() {
        #expect(abbreviate(BlindTrialPlan.make(seed: 42)) == ["HR", "SL", "SA", "SA", "HR", "HR", "SR", "SR", "HR", "SR", "SA", "SL", "HL", "SA", "HL", "SL", "SR", "SL", "HL", "HL"])
        #expect(abbreviate(BlindTrialPlan.make(seed: 7)) == ["SR", "SL", "SL", "HL", "HR", "HR", "SA", "SR", "HL", "SL", "SA", "SR", "HR", "HL", "HR", "SA", "SA", "SL", "HL", "SR"])
        // seed 4: the first shuffle has a run of three, so this one pins the redraw.
        #expect(abbreviate(BlindTrialPlan.make(seed: 4)) == ["SR", "SA", "HL", "HR", "HR", "SR", "SR", "SL", "SA", "HR", "SA", "HL", "HL", "SL", "SR", "SA", "SL", "HL", "HR", "SL"])
    }

    @Test func noConditionThreeTimesInARow() {
        for seed in 0..<200 as Range<UInt64> {
            #expect(BlindTrialPlan.longestRun(BlindTrialPlan.make(seed: seed)) <= 2, "seed \(seed)")
        }
        #expect(BlindTrialPlan.longestRun([SL, SL, SL, SR]) == 3)
        #expect(BlindTrialPlan.longestRun([]) == 0)
    }

    @Test func truthsComeFromGeometryAndMatchHandDerivedValues() {
        #expect(BlindScenes.truth(for: .staticLeft) == .leftEar)
        #expect(BlindScenes.truth(for: .staticRight) == .rightEar)
        #expect(BlindScenes.truth(for: .staticAhead) == .middle)
        // Head turned LEFT, tone fixed ahead: the tone is at the listener's RIGHT. Head turned RIGHT: LEFT.
        #expect(BlindScenes.truth(for: .headLeft45) == .rightEar)
        #expect(BlindScenes.truth(for: .headRight45) == .leftEar)
    }

    @Test func scenesUseTheProjectConventions() {
        let left = BlindScenes.scene(for: .headLeft45, headProgress: 1)
        #expect(abs(left.headPose.euler.yawDegrees - 45) < 1e-9)          // yaw + = turn left
        #expect((left.sourcePosition - Vector3(0, 0, -2)).length < 1e-9)  // ahead = -Z, 2 m
        let right = BlindScenes.scene(for: .headRight45, headProgress: 1)
        #expect(abs(right.headPose.euler.yawDegrees + 45) < 1e-9)
        #expect((BlindScenes.scene(for: .staticLeft, headProgress: 1).sourcePosition - Vector3(-2, 0, 0)).length < 1e-9)  // +X is right
        #expect((BlindScenes.scene(for: .staticRight, headProgress: 0).sourcePosition - Vector3(2, 0, 0)).length < 1e-9)
        #expect(BlindScenes.scene(for: .headLeft45, headProgress: 0).headPose.angle(to: .identity) < 1e-12)
        #expect(BlindScenes.scene(for: .staticLeft, headProgress: 1).headPose.angle(to: .identity) < 1e-12)
        // the ease is monotonic and ends exactly at the target
        var last = -1.0
        for i in 0...10 {
            let y = BlindScenes.scene(for: .headLeft45, headProgress: Double(i) / 10).headPose.euler.yawDegrees
            #expect(y >= last - 1e-12); last = y
        }
    }
}

@Suite("BlindListening: runner")
struct BlindListeningRunnerTests {
    private func runner(_ plan: [BlindCondition] = [SL, HL, SA]) -> BlindRunner { BlindRunner(plan: plan) }

    @Test func timelineOfOneTrial() throws {
        var r = runner()
        let c = r.config
        r.advance(to: 0)
        var f = r.frame
        #expect(!f.inTrial && f.gain == 0 && !f.answerEnabled && f.completedTrials == 0 && f.totalTrials == 3 && !f.finished)
        r.advance(to: c.firstGapSeconds - 0.01)
        #expect(!r.frame.inTrial)
        r.advance(to: c.firstGapSeconds)                                  // onset
        f = r.frame
        #expect(f.inTrial && f.gain == 0 && !f.answerEnabled)
        r.advance(to: c.firstGapSeconds + c.fadeSeconds / 2)
        #expect(abs(r.frame.gain - 0.5) < 1e-9)
        r.advance(to: c.firstGapSeconds + c.fadeSeconds)
        #expect(r.frame.gain == 1)
        // the window opens at onset + answerEnableSeconds, not before
        let early = r.answer(.leftEar, at: c.firstGapSeconds + c.answerEnableSeconds - 0.01)
        #expect(early == false)
        #expect(r.results == nil)
        let onTime = r.answer(.leftEar, at: c.firstGapSeconds + c.answerEnableSeconds)
        #expect(onTime == true)
        let tAnswer = c.firstGapSeconds + c.answerEnableSeconds
        f = r.frame
        #expect(!f.inTrial && f.completedTrials == 1)
        #expect(abs(f.gain - 1) < 1e-9)                                   // the fade-out starts now
        r.advance(to: tAnswer + c.fadeSeconds / 2)
        #expect(abs(r.frame.gain - 0.5) < 1e-9)
        // still the old scene (static left) until sceneSwitchSeconds, then the next trial's start scene, with the tone silent
        #expect((r.frame.sourcePosition - Vector3(-2, 0, 0)).length < 1e-9)
        r.advance(to: tAnswer + c.sceneSwitchSeconds + 0.001)
        #expect(r.frame.gain == 0)
        #expect(r.frame.headPose.angle(to: .identity) < 1e-12)
        #expect((r.frame.sourcePosition - Vector3(0, 0, -2)).length < 1e-9)   // trial 2 (head left) has its tone ahead
        // the next onset comes gapSeconds after the answer
        r.advance(to: tAnswer + c.gapSeconds - 0.01)
        #expect(!r.frame.inTrial)
        r.advance(to: tAnswer + c.gapSeconds)
        #expect(r.frame.inTrial)
    }

    @Test func recordsReactionTimeFromOnset() throws {
        var r = runner([SR])
        r.advance(to: 2.0)
        let accepted = r.answer(.rightEar, at: 2.0 + 2.5)
        #expect(accepted)
        let res = try #require(r.results)
        #expect(res.records.count == 1 && res.completed)
        let rec = res.records[0]
        #expect(rec.number == 1 && rec.condition == .staticRight && rec.truth == .rightEar && rec.answer == .rightEar)
        #expect(abs((rec.reactionSeconds ?? -1) - 2.5) < 1e-12)
    }

    @Test func timeoutIsNotAnsweredNotAnAnswer() throws {
        var r = runner([SL, SR])
        let onset = r.config.firstGapSeconds
        r.advance(to: onset + r.config.timeoutSeconds - 0.01)
        #expect(r.frame.inTrial && r.frame.completedTrials == 0)
        r.advance(to: onset + r.config.timeoutSeconds)
        #expect(!r.frame.inTrial && r.frame.completedTrials == 1)
        // a late answer after the timeout lands on the NEXT gap and is rejected
        let late = r.answer(.leftEar, at: onset + r.config.timeoutSeconds + 0.5)
        #expect(late == false)
        r.advance(to: 1000)
        let res = try #require(r.results)
        #expect(res.records.map(\.answer) == [.notAnswered, .notAnswered])
        #expect(res.records.allSatisfy { $0.reactionSeconds == nil })
    }

    @Test func rejectsEarlyDoubleAndInvalidAnswers() throws {
        var r = runner([SL, SR])
        r.advance(to: 1.0)
        let inGap = r.answer(.leftEar, at: 1.0)                            // silent gap: no trial open
        r.advance(to: 2.0)
        let tooEarly = r.answer(.leftEar, at: 2.0 + 0.5)                   // answer window not open
        let notAButton = r.answer(.notAnswered, at: 2.0 + 2.0)             // not a button
        let good = r.answer(.cantTell, at: 2.0 + 2.0)
        let second = r.answer(.leftEar, at: 2.0 + 2.0)                     // second press in the same moment: the trial is closed
        #expect(inGap == false && tooEarly == false && notAButton == false && good == true && second == false)
        r.abort(at: 2.0 + 2.1)
        let res = try #require(r.results)
        #expect(res.records.count == 1 && res.records[0].answer == .cantTell)
        #expect(res.completed == false && res.plannedTrials == 2)
    }

    @Test func clockNeverRunsBackwards() {
        var r = runner([SL])
        r.advance(to: 5)
        let f = r.frame
        r.advance(to: 1)
        #expect(r.frame == f)
        r.advance(to: .nan)
        #expect(r.frame == f)
    }

    @Test func resultsAreHiddenUntilTheRunIsOver() throws {
        var r = runner([SL])
        #expect(r.results == nil)
        r.advance(to: 2.0)
        _ = r.answer(.leftEar, at: 2.0 + r.config.answerEnableSeconds)
        #expect(r.isFinished)
        #expect(r.results != nil)
        #expect(r.frame.finished && r.frame.completedTrials == 1)
        // the tone fades out after the last answer, then stays silent
        r.advance(to: 2.0 + r.config.answerEnableSeconds + 5)
        #expect(r.frame.gain == 0)
    }

    @Test func emptyPlanIsFinishedImmediately() {
        let r = BlindRunner(plan: [])
        #expect(r.isFinished && r.results?.records.isEmpty == true && r.frame.gain == 0)
    }

    @Test func frameCarriesNoTruthOrCondition() {
        // BlindFrame is everything the UI and the audio side can read while a trial runs. If a field is ever added, this test must be changed ON PURPOSE.
        let labels = Set(Mirror(reflecting: BlindRunner(plan: [SL]).frame).children.compactMap(\.label))
        #expect(labels == ["headPose", "sourcePosition", "gain", "answerEnabled", "completedTrials", "totalTrials", "inTrial", "finished"])
        #expect(!labels.contains("truth") && !labels.contains("expected") && !labels.contains("condition"))
    }

    @Test func sceneChangesOnlyWhileSilentAndHeadMovesSmoothly() {
        // Whole simulated run at 1/120 s steps: a source jump or a pose jump must never happen while the tone is audible (gain > 0).
        var runner = BlindRunner(plan: BlindTrialPlan.make(seed: 3))
        var l = SimulatedBlindListener(.perfect)
        var t = 0.0
        var previous = runner.frame
        var decided = -1
        var enabledAt: Double?
        var worstAudibleStepDegrees = 0.0
        var sourceMovesWhileAudible = 0, sourceMoves = 0
        while !runner.isFinished && t < 2000 {
            runner.advance(to: t)
            let f = runner.frame
            if f.inTrial, f.completedTrials != decided { decided = f.completedTrials; enabledAt = nil }
            if f.inTrial, f.answerEnabled {
                if enabledAt == nil { enabledAt = t }
                if t - enabledAt! >= 1.0, let a = l.answer(for: runner.plan[f.completedTrials]) { runner.answer(a, at: t) }
            }
            let g = runner.frame
            if (g.sourcePosition - previous.sourcePosition).length > 1e-9 {
                sourceMoves += 1
                if g.gain > 0 || previous.gain > 0 { sourceMovesWhileAudible += 1 }
            }
            if g.gain > 0 || previous.gain > 0 { worstAudibleStepDegrees = max(worstAudibleStepDegrees, g.headPose.angle(to: previous.headPose) * 180 / .pi) }
            previous = g
            t += 1.0 / 120
        }
        #expect(runner.isFinished)
        #expect(sourceMoves > 0)                                  // the check is not vacuous: static trials do move the source between trials
        #expect(sourceMovesWhileAudible == 0)
        #expect(worstAudibleStepDegrees < 1.0)                    // smoothstep peak 67.5 deg/s = 0.56 deg per 1/120 s
    }
}

@Suite("BlindListening: scoring")
struct BlindListeningScoringTests {
    @Test func countsAndConfusionOrientation() {
        let s = BlindScoring.score(recs([(SL, .leftEar, 3), (SL, .rightEar, 1), (SR, .middle, 2), (HL, .rightEar, 4), (SA, .cantTell, 1), (SA, .notAnswered, 1), (SA, .middle, 2)]))
        #expect(s.trials == 14)
        // rows = conditions in allCases order (SL, SR, SA, HL, HR), columns = left, right, middle, can't tell, not answered
        #expect(s.confusion[0] == [3, 1, 0, 0, 0])
        #expect(s.confusion[1] == [0, 0, 2, 0, 0])
        #expect(s.confusion[2] == [0, 0, 2, 1, 1])
        #expect(s.confusion[3] == [0, 4, 0, 0, 0])
        #expect(s.confusion[4] == [0, 0, 0, 0, 0])
        #expect(s.confusion.reduce(0) { $0 + $1.reduce(0, +) } == 14)
        #expect(s.perCondition[0] == BlindConditionScore(condition: .staticLeft, trials: 4, definite: 4, correct: 3))
        #expect(s.perCondition[1] == BlindConditionScore(condition: .staticRight, trials: 2, definite: 2, correct: 0))
        #expect(s.perCondition[2] == BlindConditionScore(condition: .staticAhead, trials: 4, definite: 2, correct: 2))
        #expect(s.perCondition[3] == BlindConditionScore(condition: .headLeft45, trials: 4, definite: 4, correct: 4))
    }

    @Test func cantTellAndNotAnsweredAreAbstentionsNotAnswers() {
        // 3 right, 1 wrong, 2 can't tell, 2 not answered: accuracy is 3 of the 4 definite answers, not 3 of 8.
        let s = BlindScoring.score(recs([(SL, .leftEar, 3), (SL, .rightEar, 1), (SR, .cantTell, 2), (SA, .notAnswered, 2)]))
        #expect(s.answeredDefinite == 4 && s.correct == 3)
        #expect(s.accuracyOfDefinite == 0.75)
        // "can't tell" is never correct, even for a middle tone
        let m = BlindScoring.score(recs([(SA, .cantTell, 4)]))
        #expect(m.correct == 0 && m.answeredDefinite == 0 && m.accuracyOfDefinite == nil && m.chanceUpperTail == nil)
        // notAnswered must not be definite either (separately from can't tell)
        let n = BlindScoring.score(recs([(SL, .leftEar, 1), (SL, .notAnswered, 1)]))
        #expect(n.answeredDefinite == 1 && n.accuracyOfDefinite == 1)
    }

    @Test func wrongAnswersAreWrong() {
        let s = BlindScoring.score(recs([(SL, .rightEar, 2), (SR, .leftEar, 2), (SA, .leftEar, 1), (HL, .leftEar, 1)]))
        #expect(s.correct == 0 && s.answeredDefinite == 6 && s.accuracyOfDefinite == 0)
    }

    @Test func binomialTailMatchesIndependentValues() {
        #expect(abs(BlindScoring.binomialUpperTail(n: 3, k: 2, p: 1.0 / 3) - 0.25925925925925924) < 1e-12)
        #expect(abs(BlindScoring.binomialUpperTail(n: 8, k: 6, p: 1.0 / 3) - 0.01966163694558756) < 1e-12)
        #expect(abs(BlindScoring.binomialUpperTail(n: 20, k: 12, p: 1.0 / 3) - 0.012973296825300329) < 1e-12)
        #expect(abs(BlindScoring.binomialUpperTail(n: 5, k: 5, p: 1.0 / 3) - 0.004115226337448558) < 1e-12)
        #expect(BlindScoring.binomialUpperTail(n: 5, k: 0, p: 1.0 / 3) == 1)
        #expect(BlindScoring.binomialUpperTail(n: 5, k: 6, p: 1.0 / 3) == 0)
        let s = BlindScoring.score(recs([(SL, .leftEar, 6), (SR, .rightEar, 2)]))
        #expect(abs((s.chanceUpperTail ?? -1) - 1.0 / 6561) < 1e-15)       // 8 of 8 by chance: (1/3)^8
    }

    // MARK: channel-swap flag (static LEFT / RIGHT trials only)

    @Test func swapFlagNeedsSixDefiniteAnswers() {
        // 5 definite, all opposite: not enough to say anything
        let five = BlindScoring.score(recs([(SL, .rightEar, 3), (SR, .leftEar, 2)]))
        #expect(five.channelSwap == BlindFlag(status: .notAssessable, definiteAnswers: 5, oppositeEarAnswers: 5))
        // 6 definite, all opposite: suspected
        let six = BlindScoring.score(recs([(SL, .rightEar, 3), (SR, .leftEar, 3)]))
        #expect(six.channelSwap == BlindFlag(status: .suspected, definiteAnswers: 6, oppositeEarAnswers: 6))
    }

    @Test func swapFlagFractionBoundaryIsInclusive() {
        // 6 of 8 = exactly 0.75: suspected. 5 of 8: not.
        let at = BlindScoring.score(recs([(SL, .rightEar, 3), (SR, .leftEar, 3), (SL, .leftEar, 1), (SR, .rightEar, 1)]))
        #expect(at.channelSwap.status == .suspected && at.channelSwap.definiteAnswers == 8 && at.channelSwap.oppositeEarAnswers == 6)
        let below = BlindScoring.score(recs([(SL, .rightEar, 3), (SR, .leftEar, 2), (SL, .leftEar, 2), (SR, .rightEar, 1)]))
        #expect(below.channelSwap.status == .notSuspected && below.channelSwap.oppositeEarAnswers == 5)
    }

    @Test func swapFlagIgnoresCantTellAndMiddleCountsAsDefinite() {
        // 5 opposite + 1 can't tell: still only 5 definite -> not assessable
        let a = BlindScoring.score(recs([(SL, .rightEar, 3), (SR, .leftEar, 2), (SR, .cantTell, 1)]))
        #expect(a.channelSwap.status == .notAssessable && a.channelSwap.definiteAnswers == 5)
        // "middle" for a side tone is a definite (wrong, not opposite) answer: 5 opposite of 6 definite = 0.83
        let b = BlindScoring.score(recs([(SL, .rightEar, 3), (SR, .leftEar, 2), (SR, .middle, 1)]))
        #expect(b.channelSwap == BlindFlag(status: .suspected, definiteAnswers: 6, oppositeEarAnswers: 5))
    }

    @Test func swapFlagUsesStaticSideTrialsOnly() {
        // static answers: 2 right, 2 opposite (4 definite: not assessable); head-hold answers all opposite must not leak in
        let s = BlindScoring.score(recs([(SL, .leftEar, 1), (SR, .rightEar, 1), (SL, .rightEar, 1), (SR, .leftEar, 1), (HL, .leftEar, 4), (HR, .rightEar, 4)]))
        #expect(s.channelSwap == BlindFlag(status: .notAssessable, definiteAnswers: 4, oppositeEarAnswers: 2))
        // static-ahead trials never count either
        let t = BlindScoring.score(recs([(SA, .leftEar, 8), (SL, .leftEar, 3), (SR, .rightEar, 3)]))
        #expect(t.channelSwap.definiteAnswers == 6 && t.channelSwap.oppositeEarAnswers == 0 && t.channelSwap.status == .notSuspected)
    }

    @Test func swapFlagMeansTheOppositeEarNotTheSame() {
        let correct = BlindScoring.score(recs([(SL, .leftEar, 4), (SR, .rightEar, 4)]))
        #expect(correct.channelSwap == BlindFlag(status: .notSuspected, definiteAnswers: 8, oppositeEarAnswers: 0))
        let swapped = BlindScoring.score(recs([(SL, .rightEar, 4), (SR, .leftEar, 4)]))
        #expect(swapped.channelSwap == BlindFlag(status: .suspected, definiteAnswers: 8, oppositeEarAnswers: 8))
    }

    // MARK: head-turn-reversed flag

    @Test func headFlagNeedsStaticAnswersMostlyRight() {
        // ears right (static all correct), head answers all opposite: SUSPECTED
        let rev = BlindScoring.score(recs([(SL, .leftEar, 4), (SR, .rightEar, 4), (HL, .leftEar, 4), (HR, .rightEar, 4)]))
        #expect(rev.channelSwap.status == .notSuspected)
        #expect(rev.headTurnReversed == BlindFlag(status: .suspected, definiteAnswers: 8, oppositeEarAnswers: 8))
        // ears swapped AND head answers opposite: can't be told apart -> head flag NOT assessable (the swap flag speaks)
        let swapped = BlindScoring.score(recs([(SL, .rightEar, 4), (SR, .leftEar, 4), (HL, .leftEar, 4), (HR, .rightEar, 4)]))
        #expect(swapped.channelSwap.status == .suspected)
        #expect(swapped.headTurnReversed.status == .notAssessable)
        // everything right: not suspected
        let ok = BlindScoring.score(recs([(SL, .leftEar, 4), (SR, .rightEar, 4), (HL, .rightEar, 4), (HR, .leftEar, 4)]))
        #expect(ok.headTurnReversed == BlindFlag(status: .notSuspected, definiteAnswers: 8, oppositeEarAnswers: 0))
        // too few static definite answers to know the ears are right: not assessable
        let thin = BlindScoring.score(recs([(SL, .leftEar, 2), (SR, .cantTell, 6), (HL, .leftEar, 4), (HR, .rightEar, 4)]))
        #expect(thin.headTurnReversed.status == .notAssessable)
        // too few head answers
        let fewHead = BlindScoring.score(recs([(SL, .leftEar, 4), (SR, .rightEar, 4), (HL, .leftEar, 3), (HR, .cantTell, 5)]))
        #expect(fewHead.headTurnReversed.status == .notAssessable && fewHead.headTurnReversed.definiteAnswers == 3)
    }
}

@Suite("BlindListening: report and simulated listener")
struct BlindListeningReportTests {
    private func report(seed: UInt64 = 11, listener: SimulatedBlindListener.Behavior = .perfect, end: BlindEndAnswers = BlindEndAnswers()) -> BlindListeningReport {
        let results = BlindSimulation.run(seed: seed, listener: SimulatedBlindListener(listener))
        let params = BlindParameters.current(runner: BlindRunnerConfig(), outputVolume: 0.2)
        let run = BlindRunFacts(pumpTicks: 1000, pumpMeanPeriodMilliseconds: 10.7, pumpMaxPeriodMilliseconds: 14.2, thermalStateStart: "nominal", thermalStateEnd: "fair",
                                lowPowerModeStart: false, lowPowerModeEnd: false, durationSeconds: 123.4)
        let dev = ListeningDeviceFacts(transportType: "blue", transportName: "kAudioDeviceTransportTypeBluetooth", nominalSampleRate: 44100, bufferFrameSize: 512, outputChannels: 2)
        return BlindListeningReport.make(seed: seed, results: results, parameters: params, endAnswers: end, device: dev, run: run,
                                         startedAt: "2026-11-10T10:00:00+01:00", endedAt: "2026-11-10T10:03:00+01:00", simulatedListener: SimulatedBlindListener(listener).name)
    }

    @Test func jsonRoundTripAndScoreConsistency() throws {
        let r = report(end: BlindEndAnswers(clicksOrCrackling: .no, soundLocation: .outside, airPodsSpatialAudio: .notUsed))
        let back = try BlindListeningReport.decode(json: try r.jsonData())
        #expect(back == r)
        #expect(BlindScoring.score(back.trials) == back.score)
        #expect(back.seed == 11 && back.schemaVersion == 1 && back.trials.count == 20 && back.completed)
        #expect(back.endAnswers.clicksOrCrackling == .no && back.endAnswers.soundLocation == .outside && back.endAnswers.airPodsSpatialAudio == .notUsed)
        // a seed above 2^53 survives too
        var big = r; big.seed = UInt64.max - 5
        #expect(try BlindListeningReport.decode(json: try big.jsonData()).seed == UInt64.max - 5)
    }

    @Test func unansweredEndQuestionsAreRecordedAsNotAnswered() throws {
        let r = report()
        #expect(r.endAnswers == BlindEndAnswers())
        let text = String(decoding: try r.jsonData(), as: UTF8.self)
        #expect(text.contains("\"clicksOrCrackling\" : \"notAnswered\""))
        #expect(r.markdown().contains("Clicks or crackling heard: not answered"))
        #expect(r.markdown().contains("Sound location: not answered\n"))
        #expect(r.markdown().contains("AirPods Spatial Audio: not answered\n"))
        let answered = report(end: BlindEndAnswers(clicksOrCrackling: .yes, soundLocation: .inside, airPodsSpatialAudio: .on)).markdown()
        #expect(answered.contains("Clicks or crackling heard: yes."))
        #expect(answered.contains("Sound location: inside the head\n"))
        #expect(answered.contains("AirPods Spatial Audio: on\n"))
    }

    @Test func reportsHoldNoNamesPathsOrIdentifiers() throws {
        let r = report()
        // The markdown's own prose says "no UID, no device name", so only the JSON is checked for those words; both are checked for a path.
        let json = String(decoding: try r.jsonData(), as: UTF8.self)
        for banned in ["/Users", "UID", "uid\"", "deviceName", "\"name\""] { #expect(!json.contains(banned), "json: \(banned)") }
        #expect(!r.markdown().contains("/Users"))
    }

    @Test func markdownStatesChanceFlagsAndTruthOnlyInTheResults() {
        let md = report(listener: .swappedChannels).markdown()
        #expect(md.contains("SIMULATED LISTENER"))
        #expect(md.contains("1 in 3"))
        #expect(md.contains("UNTUNED"))
        #expect(md.contains("Channel-swap flag"))
        #expect(md.contains("SUSPECTED"))
        #expect(md.contains("IMPLEMENTED-UNVERIFIED"))
        #expect(md.contains("Not recorded by design: headphone make or model"))
        #expect(md.contains("| 1 |"))
    }

    @Test func fileStemHasSimulatedSuffix() {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 10; c.hour = 9; c.minute = 5; c.second = 7
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let d = cal.date(from: c)!
        #expect(BlindListeningReport.fileStem(date: d, timeZone: TimeZone(identifier: "UTC")!, simulated: false) == "listening-20261110-090507")
        #expect(BlindListeningReport.fileStem(date: d, timeZone: TimeZone(identifier: "UTC")!, simulated: true) == "listening-20261110-090507-SIMULATED")
    }

    @Test func simulatedListenersBehaveAsDescribed() {
        let perfect = report(listener: .perfect).score
        #expect(perfect.correct == 20 && perfect.answeredDefinite == 20 && perfect.channelSwap.status == .notSuspected && perfect.headTurnReversed.status == .notSuspected)

        let swapped = report(listener: .swappedChannels).score
        #expect(swapped.channelSwap.status == .suspected && swapped.headTurnReversed.status == .notAssessable)
        #expect(swapped.correct == 4)                              // only the four static-ahead (middle) trials are right

        let reversed = report(listener: .reversedHeadTurn).score
        #expect(reversed.channelSwap.status == .notSuspected && reversed.headTurnReversed.status == .suspected)

        let abstain = report(listener: .abstain).score
        #expect(abstain.answeredDefinite == 0 && abstain.chanceUpperTail == nil && abstain.channelSwap.status == .notAssessable)
        #expect(abstain.confusion.allSatisfy { $0 == [0, 0, 0, 4, 0] })

        let silent = BlindSimulation.run(seed: 11, listener: SimulatedBlindListener(.silent))
        #expect(silent.completed && silent.records.count == 20 && silent.records.allSatisfy { $0.answer == .notAnswered && $0.reactionSeconds == nil })

        let g1 = BlindSimulation.run(seed: 11, listener: SimulatedBlindListener(.guessing(seed: 9)))
        let g2 = BlindSimulation.run(seed: 11, listener: SimulatedBlindListener(.guessing(seed: 9)))
        #expect(g1 == g2 && g1.records.count == 20)
    }

    @Test func simulatedRunReactionTimesAreTheScriptedOnes() {
        let res = BlindSimulation.run(seed: 2, listener: SimulatedBlindListener(.perfect))
        let cfg = BlindRunnerConfig()
        for r in res.records {
            let rt = r.reactionSeconds ?? -1
            // the listener presses `reactionSeconds` (1 s) after the window opens (1.2 s), on a 1/30 s grid
            #expect(rt >= cfg.answerEnableSeconds + 1.0 - 1e-9 && rt < cfg.answerEnableSeconds + 1.0 + 0.1)
        }
        #expect(res.records.map(\.number) == Array(1...20))
    }
}
