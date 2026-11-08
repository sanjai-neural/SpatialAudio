import Testing
import Foundation
@testable import SpatialAudioCore

// Step 6b-2. The arithmetic of the ring probe on SYNTHETIC samples: slopes in frames per second and ppm, per-window spread, producer and reader rates, lockstep, flags.
// No clock is read and nothing sleeps: every time in these tests is a number written into a sample.

private let tapRate = 48_000.0

/// One synthetic row. `t` is the MEASURED elapsed time written into the sample, not a nominal second.
private func row(_ i: Int, t: Double, w: Int64 = 0, commits: UInt64 = 0, fill: (Int64, Int64) = (0, 0), calls: (UInt64, UInt64) = (0, 0), frames: (UInt64, UInt64) = (0, 0),
                valid: (UInt64, UInt64) = (0, 0), invalid: (UInt64, UInt64) = (0, 0), nominal: Double? = 48_000, actual: Double? = 48_000, continuous: Double? = nil,
                deviceChanged: Bool = false) -> RingProbeSample {
    var p = RingProducerCounters(); p.w = w; p.commits = commits
    var l = RingReaderCounters(), r = RingReaderCounters()
    l.fill = fill.0; r.fill = fill.1; l.calls = calls.0; r.calls = calls.1; l.framesRequested = frames.0; r.framesRequested = frames.1
    l.phaseValidCalls = valid.0; r.phaseValidCalls = valid.1; l.phaseInvalidCalls = invalid.0; r.phaseInvalidCalls = invalid.1
    return RingProbeSample(index: i, hostTicks: UInt64(t * 1e9), elapsedSeconds: t, gapSeconds: nil, continuousElapsedSeconds: continuous ?? t, producer: p, readers: [l, r],
                           outputNominalRate: nominal, outputActualRate: actual, defaultOutputChanged: deviceChanged)
}

/// Fills in the gaps from the elapsed times, as the runner does.
private func withGaps(_ rows: [RingProbeSample]) -> [RingProbeSample] {
    var out = rows
    for i in 1..<max(out.count, 1) { out[i].gapSeconds = out[i].elapsedSeconds - out[i - 1].elapsedSeconds }
    return out
}

@Suite struct RingProbeAnalyzerTests {
    @Test func theFillSlopeIsAgainstMeasuredSecondsNotTheSampleIndex() {
        // Samples every 0.5 s of MEASURED time: an index-based fit would report twice the slope.
        let rows = (0..<41).map { row($0, t: 0.5 * Double($0), fill: (1000 + Int64(10 * 0.5 * Double($0)), 0)) }
        let s = RingProbeAnalyzer.summarize(samples: rows, tapRate: tapRate)
        #expect(abs((s.readers[0].fillSlopeFramesPerSecond ?? .nan) - 10) < 1e-9)
        #expect(abs((s.readers[0].fillSlopePPM ?? .nan) - 10 / tapRate * 1e6) < 1e-6)
        #expect(s.readers[0].fillStart == 1000 && s.readers[0].fillEnd == 1200 && s.readers[0].fillMin == 1000 && s.readers[0].fillMax == 1200)   // 20 s at 10 frames/s
    }

    @Test func theSlopeIsInFramesPerSecondAndHasTheRightSign() {
        let rows = (0..<31).map { row($0, t: Double($0), fill: (2000 - 5 * Int64($0), 2000 + 7 * Int64($0))) }
        let s = RingProbeAnalyzer.summarize(samples: rows, tapRate: tapRate)
        #expect(abs((s.readers[0].fillSlopeFramesPerSecond ?? .nan) + 5) < 1e-9)         // a reader that runs faster than the producer: the fill falls
        #expect(abs((s.readers[1].fillSlopeFramesPerSecond ?? .nan) - 7) < 1e-9)
        #expect(abs((s.readers[0].fillSlopePPM ?? .nan) + 5 / tapRate * 1e6) < 1e-6)
    }

    @Test func perWindowSlopesFollowMeasuredTimeAndTheSpreadIsTheirRange() {
        // 130 s sampled every 0.5 s: minute 0 slopes +3 frames/s, minute 1 slopes +5, the last 10 s are an incomplete window and are dropped.
        let rows = (0..<261).map { i -> RingProbeSample in
            let t = 0.5 * Double(i)
            let fill = t < 60 ? 3 * t : 180 + 5 * (t - 60)
            return row(i, t: t, fill: (Int64(fill.rounded()), 0))
        }
        let s = RingProbeAnalyzer.summarize(samples: rows, tapRate: tapRate)
        let slopes = s.readers[0].perWindowSlopesFramesPerSecond
        #expect(slopes.count == 2, "two complete minutes, got \(slopes)")
        #expect(abs(slopes[0] - 3) < 0.05 && abs(slopes[1] - 5) < 0.05)
        #expect(abs((s.readers[0].perWindowSpreadPPM ?? .nan) - 2 / tapRate * 1e6) < 1.5)
    }

    @Test func aShortRunHasNoSpreadAndAPartialWindowIsNeverExtrapolated() {
        let rows = (0..<45).map { row($0, t: Double($0), fill: (Int64($0), 0)) }          // 44 s: no complete minute
        let s = RingProbeAnalyzer.summarize(samples: rows, tapRate: tapRate)
        #expect(s.readers[0].perWindowSlopesFramesPerSecond.isEmpty && s.readers[0].perWindowSpreadPPM == nil)
        #expect(s.readers[0].fillSlopeFramesPerSecond != nil)
        let one = RingProbeAnalyzer.summarize(samples: (0..<61).map { row($0, t: Double($0), fill: (Int64($0), 0)) }, tapRate: tapRate)
        #expect(one.readers[0].perWindowSlopesFramesPerSecond.count == 1 && one.readers[0].perWindowSpreadPPM == nil)   // one window: no spread
    }

    @Test func producerAndReaderRatesAreFramesOverMeasuredHostSecondsWithTheirResolution() {
        // Producer 48,005 frames per measured second; reader requests 48,000 in 93.75 calls per second (512 each).
        let rows = (0..<61).map { i -> RingProbeSample in
            let t = Double(i)
            return row(i, t: t, w: Int64(48_005 * i), commits: UInt64(Double(48_005 * i) / 512), fill: (0, 0), calls: (UInt64(93.75 * t), UInt64(93.75 * t)),
                       frames: (UInt64(48_000 * i), UInt64(48_000 * i)))
        }
        let s = RingProbeAnalyzer.summarize(samples: rows, tapRate: tapRate)
        #expect(abs((s.producerFramesPerHostSecond ?? .nan) - 48_005) < 1e-9)
        #expect(abs((s.producerVsTapPPM ?? .nan) - 5 / tapRate * 1e6) < 1e-6)
        #expect(abs((s.readers[0].framesRequestedPerHostSecond ?? .nan) - 48_000) < 1e-9 && abs((s.readers[0].framesRequestedVsTapPPM ?? .nan)) < 1e-9)
        #expect(abs((s.readers[0].callsPerHostSecond ?? .nan) - 93.75) < 0.05)
        #expect(abs((s.meanFramesPerCommit ?? .nan) - 512) < 1)
        // the honest endpoint resolution: two commits over (rate x span)
        #expect(abs((s.producerEndpointResolutionPPM ?? .nan) - 2 * 512 / (tapRate * 60) * 1e6) < 1.5)
        #expect(s.spanSeconds == 60)
    }

    @Test func framesPerCallIsOnlyAvailableAsAnIntervalMeanAndNeverClaimsMoreThanThat() throws {
        var calls: UInt64 = 0, frames: UInt64 = 0
        var rows: [RingProbeSample] = []
        let steps: [(UInt64, UInt64)] = [(0, 0), (94, 48_128), (94, 48_128), (100, 51_200 + 400), (94, 48_128 + 94 * 4)]   // calls and frames added in each second
        for (i, d) in steps.enumerated() { calls += d.0; frames += d.1; rows.append(row(i, t: Double(i), calls: (calls, calls), frames: (frames, frames))) }
        let m = try #require(RingProbeAnalyzer.summarize(samples: rows, tapRate: tapRate).readers[0].framesPerCallIntervalMeans)
        #expect(m.min == 512 && abs(m.max - 516) < 1e-9 && abs(m.median - 514) < 1e-9)           // intervals: 512, 512, 516, 516
        #expect(RingProbeAnalyzer.summarize(samples: rows, tapRate: tapRate).readers[0].meanFramesPerCall == Double(frames) / Double(calls))
        #expect(RingProbeReport.standardAssumptions.contains { $0.contains("frameCount per call is observable only as a mean") })
    }

    @Test func lockstepReportsTheLargestCounterDifferenceAndTheFinalPhaseCounters() {
        var rows = (0..<5).map { row($0, t: Double($0), calls: (UInt64($0) * 94, UInt64($0) * 94), frames: (UInt64($0) * 48_128, UInt64($0) * 48_128)) }
        rows[3].readers[1].calls -= 1; rows[3].readers[1].framesRequested -= 512         // the right reader is one call behind in ONE snapshot (not an atomic cut)
        rows[4].readers[0].phaseMismatches = 7; rows[4].readers[1].phaseSelfChanges = 2; rows[4].readers[1].weakRuleViolations = 9
        let l = RingProbeAnalyzer.summarize(samples: rows, tapRate: tapRate).lockstep
        #expect(l.maxCallsDifference == 1 && l.maxFramesRequestedDifference == 512)
        #expect(l.phaseMismatches == [7, 0] && l.phaseSelfChanges == [0, 2] && l.weakRuleViolations == [0, 9])
    }

    @Test func theValidTimestampShareIsValidOverAllCalls() {
        let rows = [row(0, t: 0), row(1, t: 1, valid: (90, 100), invalid: (10, 0))]
        let s = RingProbeAnalyzer.summarize(samples: rows, tapRate: tapRate)
        #expect(s.readers[0].validTimestampShare == 0.9 && s.readers[1].validTimestampShare == 1.0)
        #expect(s.lockstep.validTimestampShare == [0.9, 1.0])
        #expect(RingProbeAnalyzer.summarize(samples: [row(0, t: 0)], tapRate: tapRate).readers[0].validTimestampShare == nil)      // no call: no share
    }

    @Test func anOutputRateChangeIsFlaggedButMeasurementJitterIsNot() {
        let jitter = (0..<5).map { row($0, t: Double($0), actual: 44_100 + Double($0) * 0.4) }                    // 1.6 Hz of jitter: below 0.1 %
        #expect(RingProbeAnalyzer.summarize(samples: jitter, tapRate: tapRate).outputRate.changesBetweenSamples == 0)
        var rows = (0..<6).map { row($0, t: Double($0), nominal: 44_100, actual: 44_100) }
        rows[3].outputActualRate = 16_000                                                                         // the 6a event: one reading of 16 kHz
        let a = RingProbeAnalyzer.summarize(samples: rows, tapRate: tapRate)
        #expect(a.outputRate.changesBetweenSamples == 2 && a.outputRate.actualMin == 16_000 && a.outputRate.actualMax == 44_100)    // away and back
        #expect(a.flags.contains { $0.contains("output rate changed") })
        var nominal = (0..<4).map { row($0, t: Double($0)) }
        nominal[2].outputNominalRate = 44_100; nominal[3].outputNominalRate = 44_100
        let b = RingProbeAnalyzer.summarize(samples: nominal, tapRate: tapRate)
        #expect(b.outputRate.changesBetweenSamples == 1 && b.outputRate.nominalFirst == 48_000 && b.outputRate.nominalLast == 44_100)
    }

    @Test func aGapLargerThanThreeSecondsIsFlaggedAndOneBelowIsNot() {
        let ok = withGaps([row(0, t: 0), row(1, t: 1), row(2, t: 3.9), row(3, t: 4.9)])                            // a 2.9 s gap
        #expect(!RingProbeAnalyzer.summarize(samples: ok, tapRate: tapRate).flags.contains { $0.contains("gap") })
        let gap = withGaps([row(0, t: 0), row(1, t: 1), row(2, t: 4.5), row(3, t: 5.5)])                           // a 3.5 s gap
        #expect(RingProbeAnalyzer.summarize(samples: gap, tapRate: tapRate).flags.contains { $0.contains("gap of more than 3 s") })
    }

    @Test func aSleepShowsOnlyOnTheClockThatCountsSleepAndIsFlaggedFromTheDifference() {
        // Host time advanced 1 s, the sleep-counting clock advanced 61 s: the Mac slept for 60 s.
        let rows = withGaps([row(0, t: 0, continuous: 0), row(1, t: 1, continuous: 1), row(2, t: 2, continuous: 62), row(3, t: 3, continuous: 63)])
        let f = RingProbeAnalyzer.summarize(samples: rows, tapRate: tapRate).flags
        #expect(f.contains { $0.contains("slept") } && !f.contains { $0.contains("gap of more than") })
    }

    @Test func aDefaultOutputDeviceChangeIsCountedSeparatelyFromARateChange() {
        let rows = (0..<5).map { row($0, t: Double($0), deviceChanged: $0 >= 3) }
        let s = RingProbeAnalyzer.summarize(samples: rows, tapRate: tapRate)
        #expect(s.outputRate.defaultOutputChangedAtSamples == 2 && s.flags.contains { $0.contains("default output device changed") })
    }

    @Test func degenerateInputNeverProducesANonFiniteNumberOrCrashesTheEncoder() throws {
        for rows in [[], [row(0, t: 0)], [row(0, t: 0), row(1, t: 0)], [row(0, t: 5), row(1, t: 5), row(2, t: 5)]] {
            let s = RingProbeAnalyzer.summarize(samples: rows, tapRate: tapRate)
            let data = try JSONEncoder().encode(s)
            #expect(!data.isEmpty)
            #expect(s.readers.allSatisfy { ($0.fillSlopeFramesPerSecond ?? 0).isFinite })
        }
        let bad = RingProbeAnalyzer.summarize(samples: (0..<5).map { row($0, t: Double($0)) }, tapRate: 0)                  // a tap rate of 0: no ppm, no crash
        #expect(bad.producerVsTapPPM == nil && bad.readers[0].fillSlopePPM == nil)
        #expect(RingProbeAnalyzer.summarize(samples: [row(0, t: 0)], tapRate: tapRate).sampleCount == 1)
    }

    @Test func aSampleRowCarriesMeasuredElapsedTimeFromHostTicksOnly() {
        let ticksPerSecond = 24_000_000.0
        func raw(_ ticks: UInt64, _ continuous: Double?) -> RingProbeRawSample {
            RingProbeRawSample(hostTicks: ticks, continuousSeconds: continuous, producer: RingProducerCounters(), readers: [RingReaderCounters(), RingReaderCounters()])
        }
        let first = raw(5_000_000, 100)
        let a = RingProbeSample.make(raw: first, index: 0, first: first, previous: nil, ticksPerSecond: ticksPerSecond)
        #expect(a.elapsedSeconds == 0 && a.gapSeconds == nil && a.continuousElapsedSeconds == 0)
        // the timer asked for one second; the host clock says 1.5 s went by (a late tick): the row must say 1.5
        let b = RingProbeSample.make(raw: raw(5_000_000 + 36_000_000, 101.5), index: 1, first: first, previous: a, ticksPerSecond: ticksPerSecond)
        #expect(b.elapsedSeconds == 1.5 && b.gapSeconds == 1.5 && b.continuousElapsedSeconds == 1.5)
        let c = RingProbeSample.make(raw: raw(5_000_000 + 36_000_000 + 24_000_000 * 4, nil), index: 2, first: first, previous: b, ticksPerSecond: ticksPerSecond)
        #expect(c.elapsedSeconds == 5.5 && c.gapSeconds == 4 && c.continuousElapsedSeconds == nil)
        #expect(RingProbeSample.make(raw: raw(1, nil), index: 1, first: first, previous: a, ticksPerSecond: ticksPerSecond).elapsedSeconds == 0)      // a clock that went backwards: 0, never negative
    }
}
