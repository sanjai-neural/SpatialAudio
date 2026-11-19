import Testing
import Foundation
@testable import SpatialAudioCore

// Step 6b-3b (a2): the per-epoch fill slope. Synthetic series with KNOWN lines, so every expected number is arithmetic on what the test built. No hardware, no clock.

private func sample(_ t: Double, left: Int64, right: Int64, underruns: (UInt64, UInt64) = (0, 0)) -> RingProbeSample {
    var l = RingReaderCounters(); l.fill = left; l.underrunBlocks = underruns.0
    var r = RingReaderCounters(); r.fill = right; r.underrunBlocks = underruns.1
    return RingProbeSample(index: 0, hostTicks: 0, elapsedSeconds: t, gapSeconds: nil, continuousElapsedSeconds: nil, producer: RingProducerCounters(), readers: [l, r],
                           outputNominalRate: nil, outputActualRate: nil, defaultOutputChanged: false)
}

/// The two-epoch series used by most tests (sample time, seconds): epoch 0 is t = 0...9 on the lines left 4000 - 62 t and right 4000 - 40 t; the engine is stopped from t = 10
/// (stop issued at exactly 10.0) until t = 11.0 (a junk fill of 99,999 is sampled at t = 10); epoch 1 is t = 11...20 on the lines left 5000 - 55 (t - 11), right 5000 - 10 (t - 11).
private func twoEpochSeries() -> [RingProbeSample] {
    var out: [RingProbeSample] = []
    for t in 0...9 { out.append(sample(Double(t), left: 4000 - 62 * Int64(t), right: 4000 - 40 * Int64(t), underruns: (UInt64(t > 6 ? 3 : 0), 0))) }
    out.append(sample(10, left: 99_999, right: 99_999))
    for t in 11...20 { out.append(sample(Double(t), left: 5000 - 55 * Int64(t - 11), right: 5000 - 10 * Int64(t - 11), underruns: (UInt64(t >= 15 ? 7 : 4), 0))) }
    return out
}

/// The run clock reads t0 = 100 when sample 0 is taken: a stop at sample time 10 is run time 110, the restart at sample time 11 is run time 111.
private let cut = RingEpochSlopes.Cut(stopIssuedAtSeconds: 110, restartedAtSeconds: 111)

@Suite struct RingEpochSlopesTests {
    @Test func twoEpochsGetTheirOwnLineSlopesInFramesPerSecondAndPPMOfTheTapRate() throws {
        let e = RingEpochSlopes.compute(samples: twoEpochSeries(), cuts: [cut], firstSampleRunClockSeconds: 100, tapRate: 48_000)
        #expect(e.count == 2)
        let a = try #require(e.first), b = try #require(e.last)
        #expect(a.index == 0 && a.sampleCount == 10 && a.startSeconds == 0 && a.endSeconds == 9)
        #expect(abs((a.slopeFramesPerSecond[0] ?? .nan) + 62) < 1e-9 && abs((a.slopeFramesPerSecond[1] ?? .nan) + 40) < 1e-9)
        #expect(abs((a.slopePPM[0] ?? .nan) - (-62.0 / 48_000 * 1e6)) < 1e-6 && abs((a.slopePPM[1] ?? .nan) - (-40.0 / 48_000 * 1e6)) < 1e-6)
        #expect(b.index == 1 && b.sampleCount == 10 && b.startSeconds == 11 && b.endSeconds == 20)
        #expect(abs((b.slopeFramesPerSecond[0] ?? .nan) + 55) < 1e-9 && abs((b.slopeFramesPerSecond[1] ?? .nan) + 10) < 1e-9)
        #expect(a.fillFirst == [4000, 4000] && a.fillLast == [4000 - 62 * 9, 4000 - 40 * 9] && b.fillFirst == [5000, 5000])
    }

    @Test func theTwoReadersKeepTheirOwnSlopes() throws {
        let a = try #require(RingEpochSlopes.compute(samples: twoEpochSeries(), cuts: [cut], firstSampleRunClockSeconds: 100, tapRate: 48_000).first)
        #expect(a.slopeFramesPerSecond[0] != a.slopeFramesPerSecond[1])
    }

    @Test func theSamplesWhileTheEngineWasStoppedBelongToNoEpochAndTheStopBoundaryIsExclusive() throws {
        let e = RingEpochSlopes.compute(samples: twoEpochSeries(), cuts: [cut], firstSampleRunClockSeconds: 100, tapRate: 48_000)
        // The junk sample at t = 10 sits exactly on the stop boundary and before the restart: in neither epoch (a slope through it would be nowhere near -62).
        #expect(e[0].endSeconds == 9 && e[1].startSeconds == 11 && e[0].sampleCount + e[1].sampleCount == 20)
        #expect(abs((e[0].slopeFramesPerSecond[0] ?? .nan) + 62) < 1e-9)
    }

    @Test func theRunClockIsConvertedBySubtractingTheFirstSamplesRunClockTime() {
        // Offset 100: the stop (run 110) is sample time 10 and the restart (run 111) is 11. With offset 90 they are 20 and 21: epoch 0 then holds the 20 samples before 20 and the
        // series ends before epoch 1 starts. With the opposite sign (boundaries at 210 / 211) epoch 0 would hold all 21 samples.
        let right = RingEpochSlopes.compute(samples: twoEpochSeries(), cuts: [cut], firstSampleRunClockSeconds: 100, tapRate: 48_000)
        #expect(right.map(\.sampleCount) == [10, 10])
        let shifted = RingEpochSlopes.compute(samples: twoEpochSeries(), cuts: [cut], firstSampleRunClockSeconds: 90, tapRate: 48_000)
        #expect(shifted.map(\.sampleCount) == [20])
    }

    @Test func underrunsAreTheCountInsideTheEpochNotTheCumulativeTotal() throws {
        let e = RingEpochSlopes.compute(samples: twoEpochSeries(), cuts: [cut], firstSampleRunClockSeconds: 100, tapRate: 48_000)
        #expect(e[0].underruns == [3, 0], "0 at the start of epoch 0, 3 at its end")
        #expect(e[1].underruns == [3, 0], "4 at the start of epoch 1, 7 at its end: 3 inside it (the cumulative total would be 7)")
    }

    @Test func noCutsMeansTheWholeSeriesIsOneEpoch() throws {
        let series = (0...30).map { sample(Double($0), left: 3000 - 5 * Int64($0), right: 3000) }
        let e = RingEpochSlopes.compute(samples: series, cuts: [], firstSampleRunClockSeconds: nil, tapRate: 44_100)
        #expect(e.count == 1 && e[0].sampleCount == 31)
        #expect(abs((e[0].slopeFramesPerSecond[0] ?? .nan) + 5) < 1e-9 && abs(e[0].slopeFramesPerSecond[1] ?? .nan) < 1e-9)
    }

    @Test func aFirstEpochStartsAtSampleZeroNotAtTheFirstRestart() throws {
        let e = RingEpochSlopes.compute(samples: twoEpochSeries(), cuts: [cut], firstSampleRunClockSeconds: 100, tapRate: 48_000)
        #expect(e[0].startSeconds == 0 && e[0].sampleCount == 10)
    }

    @Test func cutsWithoutAKnownOffsetGiveNoEpochsNeverAGuessedOffset() {
        #expect(RingEpochSlopes.compute(samples: twoEpochSeries(), cuts: [cut], firstSampleRunClockSeconds: nil, tapRate: 48_000).isEmpty)
    }

    @Test func anEpochWithFewerThanThreeSamplesHasNoSlopeButStillAppears() throws {
        // epoch 0: t = 0, 1 (two samples) | stop at 2, restart at 3 | epoch 1: t = 3...8
        var s = [sample(0, left: 4000, right: 4000), sample(1, left: 3940, right: 3940), sample(2, left: 9, right: 9)]
        for t in 3...8 { s.append(sample(Double(t), left: 4000 - 60 * Int64(t - 3), right: 4000)) }
        let e = RingEpochSlopes.compute(samples: s, cuts: [.init(stopIssuedAtSeconds: 102, restartedAtSeconds: 103)], firstSampleRunClockSeconds: 100, tapRate: 48_000)
        #expect(e.count == 2 && e[0].sampleCount == 2 && e[0].slopeFramesPerSecond == [nil, nil] && e[0].slopePPM == [nil, nil])
        #expect(e[1].sampleCount == 6 && abs((e[1].slopeFramesPerSecond[0] ?? .nan) + 60) < 1e-9)
        // exactly three samples is enough
        let three = RingEpochSlopes.compute(samples: (0...2).map { sample(Double($0), left: 100 - 7 * Int64($0), right: 100) }, cuts: [], firstSampleRunClockSeconds: nil, tapRate: 48_000)
        #expect(abs((three[0].slopeFramesPerSecond[0] ?? .nan) + 7) < 1e-9)
    }

    @Test func anEpochWithNoSampleIsLeftOutAndAnEmptySeriesGivesNothing() {
        #expect(RingEpochSlopes.compute(samples: [], cuts: [], firstSampleRunClockSeconds: nil, tapRate: 48_000).isEmpty)
        let s = (0...4).map { sample(Double($0), left: 100, right: 100) }
        // the second cut's whole interval [restart 1.2 s.. stop 1.3 s) holds no sample
        let e = RingEpochSlopes.compute(samples: s, cuts: [.init(stopIssuedAtSeconds: 1.1, restartedAtSeconds: 1.2), .init(stopIssuedAtSeconds: 1.3, restartedAtSeconds: 1.4)],
                                        firstSampleRunClockSeconds: 0, tapRate: 48_000)
        #expect(e.map(\.index) == [0, 2], "epochs 0 and 2 hold samples; epoch 1 does not")
    }

    @Test func aNonPositiveTapRateGivesNoPPMButStillTheFramesPerSecond() throws {
        let e = RingEpochSlopes.compute(samples: (0...5).map { sample(Double($0), left: 100 - 2 * Int64($0), right: 100) }, cuts: [], firstSampleRunClockSeconds: nil, tapRate: 0)
        #expect(abs((e[0].slopeFramesPerSecond[0] ?? .nan) + 2) < 1e-9 && e[0].slopePPM == [nil, nil])
    }

    @Test func theReportOverloadUsesOnlySucceededReprimesAndItsOwnTapRate() throws {
        func record(_ stop: Double, _ restart: Double?, ok: Bool) -> RePrimeRecord {
            RePrimeRecord(index: 1, reason: .underruns, triggeredAtSeconds: stop, secondsSincePreviousRestart: nil, underrunsBefore: 0, needsReprimeAtTrigger: false, divergedAtTrigger: [],
                          stopIssuedAtSeconds: stop, restartedAtSeconds: restart, engineStoppedSeconds: nil, primeAttempts: 1, fillAtRestart: nil, underrunsAfter: nil, succeeded: ok, failure: nil)
        }
        let recovery = syntheticRecovery(rePrimes: [record(110, 111, ok: true), record(500, nil, ok: false)])
        var report = syntheticReport(requestedSeconds: 600, tap: tapAt48000, samples: twoEpochSeries(), recovery: recovery, firstSampleRunClock: 100)
        let e = RingEpochSlopes.compute(report: report)
        #expect(e.count == 2, "the failed re-prime (no restart) is not a cut")
        #expect(abs((e[0].slopePPM[0] ?? .nan) - (-62.0 / 48_000 * 1e6)) < 1e-6)
        report.tapFormat = nil
        #expect(RingEpochSlopes.compute(report: report).isEmpty, "no tap format, no rate, no epochs")
        let noOffset = syntheticReport(requestedSeconds: 600, samples: twoEpochSeries(), recovery: recovery, firstSampleRunClock: nil)
        #expect(RingEpochSlopes.compute(report: noOffset).isEmpty)
        let plain = syntheticReport(requestedSeconds: 180, samples: syntheticSamples(seconds: 10))
        #expect(RingEpochSlopes.compute(report: plain).count == 1)
    }

    @Test func theEpochTableIsPrintedInTheMarkdown() {
        let e = RingEpochSlopes.compute(samples: twoEpochSeries(), cuts: [cut], firstSampleRunClockSeconds: 100, tapRate: 48_000)
        var i = cleanInput(.s2); i.rePrimes = 1
        let text = RateFixEvaluator.evaluate(i, epochs: e).markdownLines().joined(separator: "\n")
        #expect(text.contains("Per-epoch fill slope") && text.contains("-62.00 / -40.00") && text.contains("-1291.7 / -833.3"))
        #expect(text.contains("Per-epoch drain: the worst epoch slope is 1292 ppm"))
    }
}
