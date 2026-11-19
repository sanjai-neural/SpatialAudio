import Testing
import Foundation
@testable import SpatialAudioCore

// Step 6b-3b (a2): the pure verdict of the device-bound-tap spike. The criteria are "pre-registered GUESS, fixed before the run"; these tests pin them. Every number below is a
// number the evaluator is SUPPOSED to treat that way, taken from the approved plan (G0 to G3); none is a measurement of a device-bound tap, and nothing here says what a real
// device-bound tap does. No hardware, no clock.

let tapAt44100 = TapFormat(sampleRate: 44_100, formatID: "lpcm", formatFlags: 0x9, bytesPerPacket: 8, framesPerPacket: 1, bytesPerFrame: 8, channelsPerFrame: 2, bitsPerChannel: 32)
let tapAt48000 = TapFormat(sampleRate: 48_000, formatID: "lpcm", formatFlags: 0x9, bytesPerPacket: 8, framesPerPacket: 1, bytesPerFrame: 8, channelsPerFrame: 2, bitsPerChannel: 32)

/// A reader that passes everything.
func cleanReader(_ framesPerCall: Double = 512, slope: Double? = 5, jumps: UInt64? = 0) -> RateFixReaderInput {
    RateFixReaderInput(intervalMin: framesPerCall, intervalMedian: framesPerCall, intervalMax: framesPerCall, fillSlopePPM: slope, underrunsAfterFirstSample: 0, overrunBlocks: 0,
                       phaseMismatches: 0, validTimestampShare: 1, jumps: jumps)
}

/// An input that passes everything for `stage` (S2 by default: recovery mode, 0 re-primes).
func cleanInput(_ stage: RateFixStage = .s2, tap: TapFormat = tapAt44100, output: Double? = 44_100, buffer: UInt32? = 512) -> RateFixInput {
    RateFixInput(stage: stage, tapFormat: tap, outputNominalRate: output, bufferFrameSize: buffer, rePrimes: stage == .s2 ? 0 : nil,
                 readers: [cleanReader(jumps: stage == .s2 ? 0 : nil), cleanReader(jumps: stage == .s2 ? 0 : nil)])
}

@Suite struct RateEqualityGuardTests {
    @Test func equalRatesPassAndDifferentRatesFailWithBothRatesInTheReason() {
        #expect(RateEqualityGuard.check(tapRate: 44_100, outputNominalRate: 44_100) == .init(passes: true, reason: nil))
        let r = RateEqualityGuard.check(tapRate: 48_000, outputNominalRate: 44_100)
        #expect(!r.passes && (r.reason ?? "").contains("48000.0") && (r.reason ?? "").contains("44100.0"))
    }

    @Test func theToleranceIsHalfAHzAndOnlyThat() {
        #expect(RateEqualityGuard.check(tapRate: 44_100.4999, outputNominalRate: 44_100).passes)
        #expect(!RateEqualityGuard.check(tapRate: 44_100.5, outputNominalRate: 44_100).passes, "exactly 0.5 Hz apart is not equal")
        #expect(!RateEqualityGuard.check(tapRate: 44_101, outputNominalRate: 44_100).passes)
        #expect(!RateEqualityGuard.check(tapRate: 44_103, outputNominalRate: 44_100).passes)
    }

    @Test func aTapBelowTheOutputRateFailsToo() {
        #expect(!RateEqualityGuard.check(tapRate: 44_099, outputNominalRate: 44_100).passes)
        #expect(!RateEqualityGuard.check(tapRate: 44_000, outputNominalRate: 44_100).passes)
    }

    @Test func anUnknownOrNonsenseOutputRateIsRefusedAsUnknownAndNeverPasses() {
        for bad in [nil, 0.0, -44_100.0, Double.nan, Double.infinity] as [Double?] {
            let r = RateEqualityGuard.check(tapRate: 44_100, outputNominalRate: bad)
            #expect(!r.passes && r.reason == "the output device's nominal rate is unknown", "\(String(describing: bad)): \(String(describing: r.reason))")
        }
        let t = RateEqualityGuard.check(tapRate: 0, outputNominalRate: 44_100)
        #expect(!t.passes && (t.reason ?? "").contains("tap's rate"))
    }
}

@Suite struct RateFixStageTests {
    @Test func theFourRegisteredRunsAreRecognisedByModeAndSeconds() {
        #expect(RateFixStage.classify(recovery: false, requestedSeconds: 5) == .s0)
        #expect(RateFixStage.classify(recovery: false, requestedSeconds: 180) == .s1)
        #expect(RateFixStage.classify(recovery: true, requestedSeconds: 600) == .s2)
        #expect(RateFixStage.classify(recovery: false, requestedSeconds: 120) == .s3)
    }

    @Test func anythingElseIsUnclassified() {
        for (rec, secs) in [(true, 5.0), (true, 180.0), (true, 120.0), (false, 600.0), (false, 300.0), (false, 181.0), (false, 179.0), (false, 1.0), (true, 601.0), (false, 60.0)] {
            #expect(RateFixStage.classify(recovery: rec, requestedSeconds: secs) == .unclassified, "recovery \(rec), \(secs) s")
        }
    }
}

@Suite struct RateFixEvaluatorS0Tests {
    @Test func s0PassesWhenTheTapIsFloatStereoAtTheOutputRate() {
        let r = RateFixEvaluator.evaluate(cleanInput(.s0))
        #expect(r.verdict == .proceedToS1 && r.stage == .s0)
        #expect(r.criteria.first { $0.id == "G0" }?.status == .pass)
        #expect(r.criteria.filter { $0.id != "G0" }.allSatisfy { $0.status == .notEvaluated }, "S0 judges G0 only")
    }

    @Test func s0IsANoGoForArmAWhenTheRateDiffersAndTheTextNamesTheNextStepAsSanjaisCall() {
        let r = RateFixEvaluator.evaluate(RateFixInput(stage: .s0, outcome: "failed at tap rate: x", stoppedBy: "never started", tapFormat: tapAt48000, outputNominalRate: 44_100))
        #expect(r.verdict == .noGo)
        #expect(r.verdictText.contains("arm B") && r.verdictText.contains("Sanjai's go"))
    }

    @Test func s0IsANoGoWhenTheTapWasNeverCreatedOrTheOutputRateIsUnknown() {
        #expect(RateFixEvaluator.evaluate(RateFixInput(stage: .s0, outcome: "failed at create tap", stoppedBy: "never started", tapFormat: nil, outputNominalRate: 44_100)).verdict == .noGo)
        #expect(RateFixEvaluator.evaluate(RateFixInput(stage: .s0, tapFormat: tapAt44100, outputNominalRate: nil)).verdict == .noGo)
    }

    @Test func s0NeedsFloat32InterleavedStereo() {
        let notFloat = TapFormat(sampleRate: 44_100, formatID: "lpcm", formatFlags: 0xC, bytesPerPacket: 8, framesPerPacket: 1, bytesPerFrame: 8, channelsPerFrame: 2, bitsPerChannel: 32)
        let planar = TapFormat(sampleRate: 44_100, formatID: "lpcm", formatFlags: 0x29, bytesPerPacket: 4, framesPerPacket: 1, bytesPerFrame: 4, channelsPerFrame: 2, bitsPerChannel: 32)
        let mono = TapFormat(sampleRate: 44_100, formatID: "lpcm", formatFlags: 0x9, bytesPerPacket: 4, framesPerPacket: 1, bytesPerFrame: 4, channelsPerFrame: 1, bitsPerChannel: 32)
        for f in [notFloat, planar, mono] {
            #expect(RateFixEvaluator.evaluate(RateFixInput(stage: .s0, tapFormat: f, outputNominalRate: 44_100)).verdict == .noGo, "\(f.sampleFormatDescription) \(f.channelsPerFrame) ch")
        }
    }

    @Test func s0WhoseRunDidNotFinishIsIncompleteNotAProceed() {
        let r = RateFixEvaluator.evaluate(RateFixInput(stage: .s0, outcome: "failed at AudioDeviceStart", stoppedBy: "never started", tapFormat: tapAt44100, outputNominalRate: 44_100))
        #expect(r.verdict == .incomplete)
    }

    @Test func aRunOnA48kHzOutputSaysItCannotTellTheTwoTapsApartAndA441OutputDoesNotSayIt() {
        let on48 = RateFixEvaluator.evaluate(cleanInput(.s0, tap: tapAt48000, output: 48_000))
        #expect(on48.verdict == .proceedToS1 && on48.informational.contains { $0.contains("cannot tell the device-bound tap from the global one") })
        #expect(!RateFixEvaluator.evaluate(cleanInput(.s0)).informational.contains { $0.contains("cannot tell") })
    }
}

@Suite struct RateFixEvaluatorG1Tests {
    private func s1(_ l: RateFixReaderInput, _ r: RateFixReaderInput, buffer: UInt32 = 512) -> RateFixReport {
        var i = cleanInput(.s1, buffer: buffer); i.readers = [l, r]; return RateFixEvaluator.evaluate(i)
    }
    private func reader(min: Double, med: Double, max: Double) -> RateFixReaderInput {
        var r = cleanReader(); r.intervalMin = min; r.intervalMedian = med; r.intervalMax = max; return r
    }

    @Test func exactlyTheDeviceBufferEveryIntervalPassesG1() {
        let r = s1(cleanReader(), cleanReader())
        #expect(r.criteria.first { $0.id == "G1" }?.status == .pass && r.verdict == .continueToS2)
    }

    @Test func oneCallOfOneFrameMoreInAnIntervalFailsG1() {
        // 86 calls, one asks 513: the mean is 512.0116, outside the 0.005 tolerance.
        let r = s1(reader(min: 512, med: 512, max: 512 + 1.0 / 86), cleanReader())
        #expect(r.criteria.first { $0.id == "G1" }?.status == .fail && r.verdict == .noGo)
    }

    @Test func theMinimumAndTheMaximumAreBothChecked() {
        #expect(s1(reader(min: 511.5, med: 512, max: 512), cleanReader()).verdict == .noGo, "min alone out of tolerance")
        #expect(s1(reader(min: 512, med: 512, max: 512.5), cleanReader()).verdict == .noGo, "max alone out of tolerance")
    }

    @Test func bothReadersAreCheckedEachOnItsOwn() {
        #expect(s1(reader(min: 558, med: 558, max: 558), cleanReader()).verdict == .noGo, "left alone at 558 (the old signature)")
        #expect(s1(cleanReader(), reader(min: 558, med: 558, max: 558)).verdict == .noGo, "right alone at 558")
    }

    @Test func theExpectedValueFollowsTheDeviceBufferSize() {
        let r = s1(cleanReader(256), cleanReader(256), buffer: 256)
        #expect(r.criteria.first { $0.id == "G1" }?.status == .pass, "256-frame buffer, 256 asked")
        #expect(s1(cleanReader(512), cleanReader(512), buffer: 256).verdict == .noGo, "256-frame buffer, 512 asked")
    }

    @Test func aMissingPerIntervalSummaryIsNotAPassAndS1CannotContinueOnIt() {
        var l = cleanReader(); l.intervalMin = nil
        let r = s1(l, cleanReader())
        #expect(r.criteria.first { $0.id == "G1" }?.status == .notEvaluated)
        #expect(r.verdict == .incomplete)
    }

    @Test func g1IsNotEvaluatedWhenG0DidNotPass() {
        let r = RateFixEvaluator.evaluate(cleanInput(.s2, tap: tapAt48000, output: 44_100))
        #expect(r.criteria.first { $0.id == "G1" }?.status == .notEvaluated && r.verdict == .noGo)
    }
}

@Suite struct RateFixEvaluatorG2Tests {
    private func s2(left: Double?, right: Double?) -> RateFixReport {
        var i = cleanInput(.s2); i.readers[0].fillSlopePPM = left; i.readers[1].fillSlopePPM = right; return RateFixEvaluator.evaluate(i)
    }

    @Test func aSmallDrainIsAGo() {
        #expect(s2(left: 20, right: -30).verdict == .go)
        #expect(s2(left: -100, right: 100).verdict == .go, "exactly 100 ppm is still a go")
    }

    @Test func justAbove100IsGrayAndExactly300IsStillGray() {
        #expect(s2(left: 100.01, right: 0).verdict == .gray)
        #expect(s2(left: 200, right: 0).verdict == .gray)
        #expect(s2(left: 0, right: -300).verdict == .gray, "exactly 300 ppm is gray, not a no-go")
    }

    @Test func aboveThreeHundredIsANoGoWhateverTheSign() {
        #expect(s2(left: 301, right: 0).verdict == .noGo)
        #expect(s2(left: -1294, right: -1290).verdict == .noGo, "the measured rounding signature, a NEGATIVE slope")
        #expect(s2(left: -1294, right: -1290).verdictText.contains("G2"))
    }

    @Test func theWorseOfTheTwoReadersDecidesInEitherOrder() {
        #expect(s2(left: 5, right: 1294).verdict == .noGo, "right alone")
        #expect(s2(left: 1294, right: 5).verdict == .noGo, "left alone")
        #expect(s2(left: 5, right: 250).verdict == .gray && s2(left: 250, right: 5).verdict == .gray)
    }

    @Test func g2IsNotEvaluatedWhenReprimesSplitTheRunAndTheVerdictIsStillNoGoByG3a() {
        var i = cleanInput(.s2); i.rePrimes = 2; i.readers[0].fillSlopePPM = 200; i.readers[1].fillSlopePPM = 200
        let r = RateFixEvaluator.evaluate(i)
        #expect(r.criteria.first { $0.id == "G2" }?.status == .notEvaluated)
        #expect(r.verdict == .noGo && r.verdictText.contains("G3a"))
    }

    @Test func aMissingSlopeIsNotAGo() {
        let r = s2(left: nil, right: 5)
        #expect(r.criteria.first { $0.id == "G2" }?.status == .notEvaluated && r.verdict == .inconclusive)
    }

    @Test func s3DoesNotJudgeTheSlopeAtAll() {
        var i = cleanInput(.s3); i.readers[0].fillSlopePPM = 5000; i.readers[1].fillSlopePPM = -5000
        let r = RateFixEvaluator.evaluate(i)
        #expect(r.criteria.first { $0.id == "G2" }?.status == .notEvaluated && r.verdict == .controlOK)
    }

    @Test func theSlopeJudgementItselfIsNotEvaluatedInS3EvenForAHugeSlopeButIsJudgedInS2() {
        // Added after the first mutation run (E08 survived: the S3 line of `judgeSlope` is redundant at the report level, because `evaluate` replaces the S3 G2 row with
        // "not part of S3"). The contract of the function itself is tested here.
        var i = cleanInput(.s3); i.readers[0].fillSlopePPM = 5000; i.readers[1].fillSlopePPM = -5000
        let s3 = RateFixEvaluator.judgeSlope(i, stage: .s3)
        #expect(s3.worstPPM == nil && (s3.reason ?? "").contains("S3"))
        #expect(RateFixEvaluator.judgeSlope(i, stage: .s2).worstPPM == 5000)
        #expect(RateFixEvaluator.judgeSlope(i, stage: .s1).worstPPM == 5000)
    }

    @Test func s1UsesOnlyTheNoGoThreshold() {
        func s1(_ v: Double) -> RateFixVerdictKind { var i = cleanInput(.s1); i.readers[0].fillSlopePPM = v; return RateFixEvaluator.evaluate(i).verdict }
        #expect(s1(250) == .continueToS2 && s1(300) == .continueToS2 && s1(-250) == .continueToS2)
        #expect(s1(301) == .noGo && s1(-1300) == .noGo && s1(1294) == .noGo)
    }
}

@Suite struct RateFixEvaluatorG3Tests {
    private func s2(_ edit: (inout RateFixInput) -> Void) -> RateFixReport { var i = cleanInput(.s2); edit(&i); return RateFixEvaluator.evaluate(i) }

    @Test func aCleanS2RunIsAGoAndEveryCriterionPassed() {
        let r = s2 { _ in }
        #expect(r.verdict == .go && r.criteria.allSatisfy { $0.status == .pass }, "\(r.criteria.map { "\($0.id):\($0.status.rawValue)" })")
    }

    @Test func oneReprimeIsANoGo() {
        let r = s2 { $0.rePrimes = 1 }
        #expect(r.verdict == .noGo && r.criteria.first { $0.id == "G3a" }?.status == .fail)
    }

    @Test func eachOtherG3FailureMakesItInconclusiveNotAGoAndNotANoGo() {
        let cases: [(String, (inout RateFixInput) -> Void)] = [
            ("jumps left", { $0.readers[0].jumps = 1 }), ("jumps right", { $0.readers[1].jumps = 1 }),
            ("overrun blocks left", { $0.readers[0].overrunBlocks = 1 }), ("overrun blocks right", { $0.readers[1].overrunBlocks = 1 }),
            ("underrun left", { $0.readers[0].underrunsAfterFirstSample = 1 }), ("underrun right", { $0.readers[1].underrunsAfterFirstSample = 1 }),
            ("phase left", { $0.readers[0].phaseMismatches = 1 }), ("phase right", { $0.readers[1].phaseMismatches = 1 }),
            ("valid share 0.9 left", { $0.readers[0].validTimestampShare = 0.9 }), ("valid share 0.9 right", { $0.readers[1].validTimestampShare = 0.9 }),
            ("valid share missing", { $0.readers[0].validTimestampShare = nil }),
        ]
        for (name, edit) in cases {
            let r = s2(edit)
            #expect(r.verdict == .inconclusive, "\(name): \(r.verdict)")
        }
    }

    @Test func s2WithoutARecoverySectionCannotBeAGo() {
        let r = s2 { $0.rePrimes = nil }
        #expect(r.criteria.first { $0.id == "G3a" }?.status == .notEvaluated && r.verdict == .inconclusive)
    }

    @Test func aG1FailureIsANoGoEvenWhenTheSlopeIsGray() {
        var i = cleanInput(.s2); i.readers[0].fillSlopePPM = 200; i.readers[0].intervalMax = 513
        #expect(RateFixEvaluator.evaluate(i).verdict == .noGo)
    }

    @Test func aGrayRunWithAnotherG3FailureIsStillGray() {
        var i = cleanInput(.s2); i.readers[0].fillSlopePPM = 200; i.readers[1].phaseMismatches = 1
        #expect(RateFixEvaluator.evaluate(i).verdict == .gray)
    }
}

@Suite struct RateFixEvaluatorStageRulesTests {
    @Test func s1IsNeverAGoItContinuesOrFailsFast() {
        #expect(RateFixEvaluator.evaluate(cleanInput(.s1)).verdict == .continueToS2)
        var starved = cleanInput(.s1); starved.readers[1].underrunsAfterFirstSample = 1
        let r = RateFixEvaluator.evaluate(starved)
        #expect(r.verdict == .noGo && r.verdictText.contains("G3c"))
        var left = cleanInput(.s1); left.readers[0].underrunsAfterFirstSample = 3
        #expect(RateFixEvaluator.evaluate(left).verdict == .noGo)
    }

    @Test func s1DoesNotFailOnPhaseMismatchesOrJumpsButListsThemAsNotPartOfS1() {
        var i = cleanInput(.s1); i.readers[0].phaseMismatches = 1
        let r = RateFixEvaluator.evaluate(i)
        #expect(r.verdict == .continueToS2)
        #expect(r.criteria.first { $0.id == "G3d" }?.status == .notEvaluated)
    }

    @Test func s3IsAControlThatNeedsG0G1AndTheEventItems() {
        #expect(RateFixEvaluator.evaluate(cleanInput(.s3, tap: tapAt48000, output: 48_000)).verdict == .controlOK)
        let cases: [(String, (inout RateFixInput) -> Void)] = [
            ("underrun", { $0.readers[1].underrunsAfterFirstSample = 1 }), ("overrun block", { $0.readers[0].overrunBlocks = 1 }),
            ("phase", { $0.readers[0].phaseMismatches = 2 }), ("valid share", { $0.readers[1].validTimestampShare = 0.99 }),
            ("g1", { $0.readers[0].intervalMax = 513 }),
        ]
        for (name, edit) in cases {
            var i = cleanInput(.s3, tap: tapAt48000, output: 48_000); edit(&i)
            #expect(RateFixEvaluator.evaluate(i).verdict == .controlFailed, "\(name)")
        }
    }

    @Test func aG0FailureIsANoGoInEveryStageEvenWhenTheRunDidNotFinish() {
        for stage in [RateFixStage.s1, .s2, .s3] {
            var i = cleanInput(stage, tap: tapAt48000, output: 44_100); i.outcome = "failed at tap rate: x"; i.stoppedBy = "never started"
            #expect(RateFixEvaluator.evaluate(i).verdict == .noGo, "\(stage)")
        }
    }

    @Test func aRunThatDidNotCompleteHasNoVerdictInS1ToS3() {
        for stage in [RateFixStage.s1, .s2, .s3] {
            var signal = cleanInput(stage); signal.stoppedBy = "signal"
            var interrupted = cleanInput(stage); interrupted.outcome = "interrupted"; interrupted.stoppedBy = "configurationChange"
            var failed = cleanInput(stage); failed.outcome = "failed at snapshot"
            for i in [signal, interrupted, failed] { #expect(RateFixEvaluator.evaluate(i).verdict == .incomplete, "\(stage) \(i.outcome) \(i.stoppedBy)") }
        }
    }

    @Test func anUnclassifiedRunGetsNoVerdictButTheNumbersAreStillComputed() {
        let r = RateFixEvaluator.evaluate(cleanInput(.unclassified))
        #expect(r.verdict == .unclassified && r.criteria.count == 8 && r.criteria.first { $0.id == "G0" }?.status == .pass)
        #expect(r.verdictText.contains("no verdict"))
    }

    @Test func aSimulatedReportsVerdictSaysSoInItsFirstWords() {
        var i = cleanInput(.s2); i.simulated = true
        let r = RateFixEvaluator.evaluate(i)
        #expect(r.verdict == .go && r.simulated && r.verdictText.hasPrefix("SIMULATED (fabricated data, decides nothing): "))
        #expect(!RateFixEvaluator.evaluate(cleanInput(.s2)).verdictText.contains("SIMULATED"))
    }

    @Test func theCriteriaVersionAndTheRegistrationLabelAreInEveryReport() {
        let r = RateFixEvaluator.evaluate(cleanInput(.s2))
        #expect(r.criteriaVersion == "6b-3b-prereg-1" && r.criteriaVersion == RateFixCriteria.version)
        #expect(r.registration == "pre-registered GUESS, fixed before the run")
    }

    @Test func thePreRegisteredNumbersAreTheApprovedOnes() {
        #expect(RateFixCriteria.goSlopePPM == 100 && RateFixCriteria.noGoSlopePPM == 300 && RateFixCriteria.framesPerCallToleranceFrames == 0.005)
        #expect(RateEqualityGuard.toleranceHz == 0.5 && RateFixCriteria.globalTapMeasuredRateHz == 48_000)
    }

    @Test func theStartUpNotesDecideNothing() {
        var i = cleanInput(.s2); i.fillAtFirstPull = [13_266, 13_266]; i.engineStartToFirstPullSeconds = 0.008; i.eventsAtFirstSample = true
        let r = RateFixEvaluator.evaluate(i)
        #expect(r.verdict == .go, "the start-up notes do not change the verdict")
        #expect(r.informational.contains { $0.contains("13266, 13266") && $0.contains("standing latency") })
        #expect(r.informational.contains { $0.contains("FIRST sample") })
        #expect(!RateFixEvaluator.evaluate(cleanInput(.s2)).informational.contains { $0.contains("FIRST sample") })
    }

    @Test func theMarkdownCarriesTheVerdictTheCriteriaTableAndTheRegistrationLabel() {
        let lines = RateFixEvaluator.evaluate(cleanInput(.s2)).markdownLines()
        let text = lines.joined(separator: "\n")
        #expect(text.contains("## 9. Rate-fix check") && text.contains("pre-registered GUESS, fixed before the run") && text.contains("6b-3b-prereg-1"))
        #expect(text.contains("**Verdict: go**"))
        #expect(text.contains("| G0 |") && text.contains("| G2 |") && text.contains("| G3e |"))
    }
}

// MARK: - From a report to the input

/// A series of `seconds + 1` samples one measured second apart.
func syntheticSamples(seconds: Int, framesPerCall: UInt64 = 512, callsPerSecond: UInt64 = 86, fill: (Int) -> Int64 = { _ in 2048 },
                      underruns: (Int) -> UInt64 = { _ in 0 }, overrunBlocks: UInt64 = 0, phaseMismatchesRight: UInt64 = 0, validTimestamps: Bool = true,
                      outputRate: Double = 44_100) -> [RingProbeSample] {
    (0...seconds).map { i in
        var l = RingReaderCounters()
        l.calls = 1 + callsPerSecond * UInt64(i); l.framesRequested = l.calls * framesPerCall; l.servedBlocks = l.calls
        if validTimestamps { l.phaseValidCalls = l.calls } else { l.phaseInvalidCalls = l.calls }
        l.fill = fill(i); l.underrunBlocks = underruns(i); l.overrunBlocks = overrunBlocks
        var r = l
        r.phaseMismatches = phaseMismatchesRight
        var p = RingProducerCounters(); p.w = Int64(i) * 44_100; p.commits = UInt64(i) * 86; p.capacity = 32_768; p.maxCommit = 16_384
        return RingProbeSample(index: i, hostTicks: UInt64(1_000_000_000 + i * 1_000_000_000), elapsedSeconds: Double(i), gapSeconds: i == 0 ? nil : 1, continuousElapsedSeconds: nil,
                               producer: p, readers: [l, r], outputNominalRate: outputRate, outputActualRate: outputRate, defaultOutputChanged: false)
    }
}

func syntheticReport(source: String = "fake", requestedSeconds: Double, tap: TapFormat? = tapAt44100, outputRate: Double? = 44_100, buffer: UInt32? = 512,
                     samples: [RingProbeSample], recovery: RingRecoveryReport? = nil, outcome: String = "ok", stoppedBy: String = "timeout",
                     firstSampleRunClock: Double? = nil) -> RingProbeReport {
    var timings = RingTimings()
    timings.fillAtFirstPull = [2048, 2048]; timings.firstSampleRunClockSeconds = firstSampleRunClock
    var r = RingProbeReport(
        createdAt: "t", source: source, macOSVersion: "t", hardwareModel: "t", composition: "c", ownPID: 1, ownProcessObjectBefore: nil, ownProcessObjectAfterEngineStart: nil,
        excludedProcessObjects: [], requestedSeconds: requestedSeconds, elapsedSeconds: samples.last?.elapsedSeconds ?? 0, stoppedBy: stoppedBy, outcome: outcome, flags: [], tapFormat: tap,
        hostTicksPerSecond: 1e9, constants: nil, outputGain: RingGainRecord(), timings: timings,
        outputDevice: RingOutputFacts(transportType: "blue", nominalSampleRate: outputRate, actualSampleRate: outputRate, bufferFrameSize: buffer), engine: nil,
        configurationChanges: 0, calls: [], lists: TapProbeLists(settlePolls: 0, settleSeconds: nil), teardownOrder: [], teardownClean: true, ring: nil,
        summary: tap.map { RingProbeAnalyzer.summarize(samples: samples, tapRate: $0.sampleRate) }, samples: samples, injectedFaults: nil, notes: [])
    r.recovery = recovery
    return r
}

func syntheticRecovery(left: RingReaderRecovery = RingReaderRecovery(name: "left"), right: RingReaderRecovery = RingReaderRecovery(name: "right"),
                       rePrimes: [RePrimeRecord] = []) -> RingRecoveryReport {
    RingRecoveryReport(config: RePrimeConfig(), start: nil, rePrimes: rePrimes, suppressedByMinimumInterval: 0, suppressedByStormLimit: 0, gaveUp: nil, readers: [left, right], standingFillAtEnd: 2048)
}

@Suite struct RateFixInputFromReportTests {
    @Test func aCleanReportBecomesAPassingInputOfTheRightStage() {
        let report = syntheticReport(requestedSeconds: 180, samples: syntheticSamples(seconds: 20))
        let i = RateFixInput(report: report)
        #expect(i.stage == .s1 && !i.simulated && i.outcome == "ok" && i.stoppedBy == "timeout")
        #expect(i.tapFormat == tapAt44100 && i.outputNominalRate == 44_100 && i.bufferFrameSize == 512 && i.outputTransport == "blue" && i.rePrimes == nil)
        #expect(i.readers.count == 2 && i.readers.allSatisfy { $0.intervalMin == 512 && $0.intervalMax == 512 && $0.underrunsAfterFirstSample == 0 && $0.validTimestampShare == 1 })
        #expect(i.readers.allSatisfy { abs($0.fillSlopePPM ?? .nan) < 1e-9 && $0.jumps == nil })
        #expect(RateFixEvaluator.evaluate(i).verdict == .continueToS2)
    }

    @Test func theFillSlopeIsInPPMOfTheTapRateNotFramesPerSecond() {
        // 62 frames per second down at a 44.1 kHz tap = -1405.9 ppm.
        let report = syntheticReport(requestedSeconds: 180, samples: syntheticSamples(seconds: 30, fill: { 4000 - 62 * Int64($0) }))
        let slope = RateFixInput(report: report).readers[0].fillSlopePPM ?? .nan
        #expect(abs(slope - (-62.0 / 44_100 * 1e6)) < 0.5, "got \(slope)")
        #expect(RateFixEvaluator.evaluate(RateFixInput(report: report)).verdict == .noGo)
    }

    @Test func underrunsAreCountedAfterTheFirstSampleOnly() {
        let flat = RateFixInput(report: syntheticReport(requestedSeconds: 180, samples: syntheticSamples(seconds: 10, underruns: { _ in 5 })))
        #expect(flat.readers.allSatisfy { $0.underrunsAfterFirstSample == 0 }, "5 at sample 0 and 5 at the end: none after the first sample")
        let rising = RateFixInput(report: syntheticReport(requestedSeconds: 180, samples: syntheticSamples(seconds: 10, underruns: { 5 + UInt64($0 > 4 ? 4 : 0) })))
        #expect(rising.readers.allSatisfy { $0.underrunsAfterFirstSample == 4 })
    }

    @Test func jumpsAreTheSumOfOverrunDivergenceAndRefusedForEachReader() {
        let left = RingReaderRecovery(name: "left", overrunJumps: 1)
        let right = RingReaderRecovery(name: "right", divergenceJumps: 2, refusedJumps: 4)
        let report = syntheticReport(requestedSeconds: 600, samples: syntheticSamples(seconds: 10), recovery: syntheticRecovery(left: left, right: right))
        #expect(RateFixInput(report: report).readers.map(\.jumps) == [1, 6])
        let overrunOnly = syntheticReport(requestedSeconds: 600, samples: syntheticSamples(seconds: 10), recovery: syntheticRecovery(left: RingReaderRecovery(name: "l", overrunJumps: 7)))
        #expect(RateFixInput(report: overrunOnly).readers.map(\.jumps) == [7, 0])
        let divergenceOnly = syntheticReport(requestedSeconds: 600, samples: syntheticSamples(seconds: 10), recovery: syntheticRecovery(left: RingReaderRecovery(name: "l", divergenceJumps: 3)))
        #expect(RateFixInput(report: divergenceOnly).readers.map(\.jumps) == [3, 0])
        let refusedOnly = syntheticReport(requestedSeconds: 600, samples: syntheticSamples(seconds: 10), recovery: syntheticRecovery(left: RingReaderRecovery(name: "l", refusedJumps: 5)))
        #expect(RateFixInput(report: refusedOnly).readers.map(\.jumps) == [5, 0])
    }

    @Test func theStageNeedsARecoverySectionForS2() {
        let plain = syntheticReport(requestedSeconds: 600, samples: syntheticSamples(seconds: 5))
        let recovery = syntheticReport(requestedSeconds: 600, samples: syntheticSamples(seconds: 5), recovery: syntheticRecovery())
        #expect(RateFixInput(report: plain).stage == .unclassified && RateFixInput(report: recovery).stage == .s2)
        #expect(RateFixInput(report: recovery).rePrimes == 0)
        let recovery120 = syntheticReport(requestedSeconds: 120, samples: syntheticSamples(seconds: 5), recovery: syntheticRecovery())
        #expect(RateFixInput(report: recovery120).stage == .unclassified, "S3 is plain")
    }

    @Test func aSimulatedSourceIsPassedOn() {
        #expect(RateFixInput(report: syntheticReport(source: "simulated", requestedSeconds: 5, samples: syntheticSamples(seconds: 3))).simulated)
        #expect(!RateFixInput(report: syntheticReport(source: "coreAudioTap", requestedSeconds: 5, samples: syntheticSamples(seconds: 3))).simulated)
    }

    @Test func aStartUpEventInTheFirstSampleIsNoted() {
        #expect(!RateFixInput(report: syntheticReport(requestedSeconds: 180, samples: syntheticSamples(seconds: 5))).eventsAtFirstSample)
        #expect(RateFixInput(report: syntheticReport(requestedSeconds: 180, samples: syntheticSamples(seconds: 5, overrunBlocks: 1))).eventsAtFirstSample)
        #expect(RateFixInput(report: syntheticReport(requestedSeconds: 180, samples: syntheticSamples(seconds: 5, phaseMismatchesRight: 1))).eventsAtFirstSample)
    }

    @Test func aReportWithoutATapFormatOrSeriesGivesAnInputThatNeverPassesAnything() {
        let report = syntheticReport(requestedSeconds: 5, tap: nil, samples: [], outcome: "failed at create tap", stoppedBy: "never started")
        let r = RateFixEvaluator.evaluate(RateFixInput(report: report))
        #expect(r.verdict == .noGo && r.criteria.first { $0.id == "G0" }?.status == .notEvaluated)
    }

    @Test func aWholeS2ReportEndToEndIsAGoOnlyWhenEverythingIsClean() {
        let clean = syntheticReport(requestedSeconds: 600, samples: syntheticSamples(seconds: 60), recovery: syntheticRecovery())
        #expect(RateFixEvaluator.evaluate(RateFixInput(report: clean)).verdict == .go)
        let invalidTimestamps = syntheticReport(requestedSeconds: 600, samples: syntheticSamples(seconds: 60, validTimestamps: false), recovery: syntheticRecovery())
        #expect(RateFixEvaluator.evaluate(RateFixInput(report: invalidTimestamps)).verdict == .inconclusive)
    }
}
