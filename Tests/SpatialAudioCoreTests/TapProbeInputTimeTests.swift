import Testing
import Foundation
@testable import SpatialAudioCore

// Step 6a3. The input-timestamp estimator, its resolution figures, the validity handling and the report text. Pure logic on synthetic records with
// exact arithmetic (1,000,000 host ticks per second, so one tick is one microsecond); no Core Audio and no clock. The records are SIMULATED stamps: they
// check the arithmetic, and say nothing about what a real tap's stamps look like.

private let ticksPerSecond = 1_000_000.0
private let base: Int64 = 1_000_000_000

/// A callback every `every` ticks (10_000 = 10 ms) carrying `frames` frames. `now` / `input` are offsets in ticks from the nominal time of callback k.
/// `flags(k)` can mark the input host / sample time invalid; an invalid field is stored as 0, as the C callback does.
private func series(count: Int, every: Int64 = 10_000, frames: UInt32 = 480, now: (Int) -> Int64 = { _ in 0 }, input: (Int) -> Int64 = { _ in -3_000 },
                    flags: (Int) -> UInt32 = { _ in 0 }, sample: (Int) -> Double = { Double($0) * 480 }) -> [TapProbeRecord] {
    (0..<count).map { k in
        let f = flags(k)
        let hostBad = f & TapProbeFlag.inputHostTimeInvalid != 0, sampleBad = f & TapProbeFlag.inputSampleTimeInvalid != 0
        return TapProbeRecord(hostTime: UInt64(base + Int64(k) * every + now(k)), sumSquares: 0.01, frames: frames, samples: 960, peak: 0.1, flags: f,
                              inputHostTime: hostBad ? 0 : UInt64(base + Int64(k) * every + input(k)), inputSampleTime: sampleBad ? 0 : sample(k))
    }
}

private func summarize(_ r: [TapProbeRecord], declared: Double? = 48_000) -> TapProbeStats {
    TapProbeAggregator.summarize(records: r, dropped: 0, hostTicksPerSecond: ticksPerSecond, declaredRate: declared)
}

/// `count` points one second apart at `rate` frames per second, with `jitter` frames added to even points and subtracted from odd ones.
private func alternatingPoints(count: Int, rate: Double, jitter: Double) -> [(t: Double, f: Double)] {
    var out: [(t: Double, f: Double)] = []
    for k in 0..<count {
        let t = Double(k)
        let sign: Double = k % 2 == 0 ? 1 : -1
        out.append((t: t, f: rate * t + sign * jitter))
    }
    return out
}

/// `count` points one second apart on a straight line of `rate` frames per second.
private func linePoints(count: Int, rate: Double) -> [(t: Double, f: Double)] {
    (0..<count).map { k -> (t: Double, f: Double) in (t: Double(k), f: rate * Double(k)) }
}

// MARK: - The estimator on its own (hand-computable numbers)

@Suite struct TapOffsetEstimatorTests {
    @Test func aHandComputedSeriesGivesTheHandComputedFit() throws {
        // t = 0...4 s at 1000 Hz declared; offsets 0, 1, 0, 1, 0 frames. Mean offset 0.4, slope 0, residuals -0.4 0.6 -0.4 0.6 -0.4:
        // SSE 1.2, SD sqrt(1.2 / 3), standard error of the slope SD / sqrt(Sxx = 10) = 0.2 frames/s = 200 ppm, peak-to-peak 1.0.
        let pts: [(t: Double, f: Double)] = [(0, 0), (1, 1001), (2, 2000), (3, 3001), (4, 4000)]
        let fit = try #require(TapOffsetEstimator.fit(points: pts, declaredRate: 1000, windowSeconds: 10))
        #expect(fit.callbacks == 5 && fit.spanSeconds == 4)
        #expect(abs(fit.driftPPM) < 1e-9 && abs(fit.fittedOffsetChangeFrames) < 1e-9)
        #expect(abs(fit.driftStdErrPPM - 200) < 1e-6)
        #expect(abs(fit.residualSDFrames - 0.4.squareRoot()) < 1e-12 && abs(fit.residualPeakToPeakFrames - 1.0) < 1e-12)
        #expect(abs(fit.resolutionPPM - 250) < 1e-9)          // 1 frame / (1000 Hz x 4 s) = 250 ppm
        #expect(abs(fit.windowResolutionPPM - 100) < 1e-9)    // 1 frame / (1000 Hz x 10 s) = 100 ppm
        #expect(fit.windowSeconds == 10)
    }

    @Test func aStraightLineAtADifferentRateGivesThatRateInPPMAndNoScatter() throws {
        let fast = linePoints(count: 10, rate: 1000.2)                                    // +200 ppm
        let slow = linePoints(count: 10, rate: 999.9)                                     // -100 ppm
        let a = try #require(TapOffsetEstimator.fit(points: fast, declaredRate: 1000, windowSeconds: 10))
        let b = try #require(TapOffsetEstimator.fit(points: slow, declaredRate: 1000, windowSeconds: 10))
        #expect(abs(a.driftPPM - 200) < 1e-6 && abs(b.driftPPM + 100) < 1e-6)
        #expect(abs(a.fittedOffsetChangeFrames - 0.2 * 9) < 1e-9 && abs(b.fittedOffsetChangeFrames + 0.1 * 9) < 1e-9)
        #expect(a.residualPeakToPeakFrames < 1e-9 && a.residualSDFrames < 1e-9 && a.resolutionPPM < 1e-6 && a.driftStdErrPPM < 1e-6)
    }

    @Test func thePeakToPeakIsTheWholeJitterAndTheFloorScalesInverselyWithTimeAndRate() throws {
        // +-12 frames alternating (24 peak-to-peak) over 100 s at 48 kHz: 24 / (48000 x 100) = 5 ppm; one 10 s window: 50 ppm.
        let pts = alternatingPoints(count: 101, rate: 48_000, jitter: 12)
        let fit = try #require(TapOffsetEstimator.fit(points: pts, declaredRate: 48_000, windowSeconds: 10))
        #expect(abs(fit.residualPeakToPeakFrames - 24) < 0.1)
        #expect(abs(fit.resolutionPPM - 5) < 0.01 && abs(fit.windowResolutionPPM - 50) < 0.1)
        let longer = alternatingPoints(count: 201, rate: 48_000, jitter: 12)
        let fit2 = try #require(TapOffsetEstimator.fit(points: longer, declaredRate: 48_000, windowSeconds: 10))
        #expect(abs(fit2.resolutionPPM - 2.5) < 0.01)                                    // twice the time, half the floor
    }

    @Test func movingTheOriginOfTheFramesOrOfTheTimeDoesNotChangeTheFit() throws {
        // Documented property: the fit is of offsets about their own line, so a constant added to every frame count (or to every stamp time) changes
        // no field. (This is why which callback the aggregator uses as origin for the input series cannot change the whole-run figures.)
        let pts = alternatingPoints(count: 41, rate: 48_000, jitter: 7)
        let a = try #require(TapOffsetEstimator.fit(points: pts, declaredRate: 48_000, windowSeconds: 10))
        let framesShifted = pts.map { (t: $0.t, f: $0.f + 12_345) }
        let b = try #require(TapOffsetEstimator.fit(points: framesShifted, declaredRate: 48_000, windowSeconds: 10))
        #expect(abs(a.driftPPM - b.driftPPM) < 1e-6 && abs(a.driftStdErrPPM - b.driftStdErrPPM) < 1e-6)
        #expect(abs(a.residualSDFrames - b.residualSDFrames) < 1e-6 && abs(a.residualPeakToPeakFrames - b.residualPeakToPeakFrames) < 1e-6)
        #expect(abs(a.resolutionPPM - b.resolutionPPM) < 1e-9 && abs(a.fittedOffsetChangeFrames - b.fittedOffsetChangeFrames) < 1e-6)
        // the same for the TIME origin: a series that does not start at t = 0 has the same span and floor (found by the mutation run: every earlier test started at 0)
        let timeShifted = pts.map { (t: $0.t + 1000, f: $0.f) }
        let c = try #require(TapOffsetEstimator.fit(points: timeShifted, declaredRate: 48_000, windowSeconds: 10))
        #expect(c.spanSeconds == 40 && a.spanSeconds == 40)
        #expect(abs(a.driftPPM - c.driftPPM) < 1e-6 && abs(a.residualPeakToPeakFrames - c.residualPeakToPeakFrames) < 1e-6)
        #expect(abs(a.resolutionPPM - c.resolutionPPM) < 1e-9 && abs(a.fittedOffsetChangeFrames - c.fittedOffsetChangeFrames) < 1e-6)
    }

    @Test func tooFewPointsNoSpreadOrAnUnusableRateGiveNoFit() {
        let ok: [(t: Double, f: Double)] = [(0, 0), (1, 1000), (2, 2000)]
        #expect(TapOffsetEstimator.fit(points: ok, declaredRate: 1000, windowSeconds: 10) != nil)
        #expect(TapOffsetEstimator.fit(points: Array(ok.prefix(2)), declaredRate: 1000, windowSeconds: 10) == nil)
        #expect(TapOffsetEstimator.fit(points: [(1, 0), (1, 1), (1, 2)], declaredRate: 1000, windowSeconds: 10) == nil)
        #expect(TapOffsetEstimator.fit(points: ok, declaredRate: 0, windowSeconds: 10) == nil)
        #expect(TapOffsetEstimator.fit(points: ok, declaredRate: -1, windowSeconds: 10) == nil)
        #expect(TapOffsetEstimator.fit(points: ok, declaredRate: .nan, windowSeconds: 10) == nil)
        #expect(TapOffsetEstimator.fit(points: ok, declaredRate: .infinity, windowSeconds: 10) == nil)
        #expect(TapOffsetEstimator.fit(points: ok, declaredRate: 1000, windowSeconds: 0) == nil)
    }
}

// MARK: - Through the aggregator: the two estimators on the same callbacks

@Suite struct TapInputEstimatorTests {
    @Test func identicalStampsGiveIdenticalEstimatorsAndWindows() throws {
        let st = summarize(series(count: 2500, input: { _ in 0 }))
        let t = try #require(st.inputTime)
        #expect(t.inNowFit != nil && t.inNowFit == t.inputFit)
        #expect(st.windows.count == 3)
        for w in st.windows {
            #expect(w.inputCallbacks == w.callbacks && w.inputSpanSeconds == w.spanSeconds && w.inputImpliedFramesPerSecond == w.impliedFramesPerSecond)
            #expect(w.inputImpliedVsDeclaredPPM == w.impliedVsDeclaredPPM && w.inputCumulativeFrameOffset == w.cumulativeFrameOffset)
        }
    }

    @Test func aConstantLatencyCancelsOutOfTheRateAndIsReportedInMilliseconds() throws {
        let st = summarize(series(count: 2500, input: { _ in -3_000 }))
        let t = try #require(st.inputTime), a = try #require(t.inNowFit), b = try #require(t.inputFit)
        #expect(abs(a.driftPPM - b.driftPPM) < 1e-9 && abs(a.residualPeakToPeakFrames - b.residualPeakToPeakFrames) < 1e-9)
        let lag = try #require(t.nowMinusInputHostMs)
        #expect(abs(lag.min - 3) < 1e-9 && abs(lag.median - 3) < 1e-9 && abs(lag.max - 3) < 1e-9)
        // the cumulative offset origin is each estimator's own first callback, so a constant latency leaves it at zero
        for w in st.windows {
            let off = try #require(w.inputCumulativeFrameOffset)
            #expect(abs(off) < 1e-6)
        }
    }

    @Test func jitterThatIsOnlyInInNowShowsOnlyInTheInNowEstimator() throws {
        // inNow is 4 ms late on every odd callback; the input stamps are exact. 4 ms x 48 kHz = 192 frames peak-to-peak.
        let st = summarize(series(count: 2000, now: { $0 % 2 == 0 ? 0 : 4_000 }, input: { _ in -3_000 }))
        let t = try #require(st.inputTime), a = try #require(t.inNowFit), b = try #require(t.inputFit)
        #expect(abs(a.residualPeakToPeakFrames - 192) < 1.0)
        #expect(b.residualPeakToPeakFrames < 1e-6)
        // spans are ~20 s: 192 / (48000 x ~20) = ~200 ppm over the run, ~400 ppm in a 10 s window
        #expect(abs(a.resolutionPPM - 200) < 3 && abs(a.windowResolutionPPM - 400) < 3 && b.resolutionPPM < 1e-3)
        let lag = try #require(t.nowMinusInputHostMs)
        #expect(abs(lag.min - 3) < 1e-9 && abs(lag.max - 7) < 1e-9)                              // 3 ms, and 3 + 4 ms on the late callbacks
        let off0 = try #require(st.windows[0].inputCumulativeFrameOffset)
        #expect(abs(off0) < 1e-6)
    }

    @Test func anInputClockThatRunsFastShowsInTheInputEstimatorOnly() throws {
        // input stamps 9999 us apart instead of 10000: 480 frames per 9.999 ms = +100.01 ppm. inNow stays exact.
        let st = summarize(series(count: 2500, input: { -Int64($0) }))
        let t = try #require(st.inputTime), a = try #require(t.inNowFit), b = try #require(t.inputFit)
        #expect(abs(a.driftPPM) < 1e-6)
        #expect(abs(b.driftPPM - 100.010001) < 0.001)
        for w in st.windows {
            let nowPPM = try #require(w.impliedVsDeclaredPPM), inPPM = try #require(w.inputImpliedVsDeclaredPPM)
            #expect(abs(nowPPM) < 1e-6 && abs(inPPM - 100.010001) < 0.001, "window \(w.startSecond): \(nowPPM) \(inPPM)")
        }
        #expect(b.fittedOffsetChangeFrames > 0)
    }

    @Test func callbacksWithAnInvalidInputHostTimeAreLeftOutOfTheInputEstimatorButTheirFramesStillCount() throws {
        // every 5th callback (including the very first) has no valid input host time. Exact cadence everywhere, so if the frames of the skipped
        // callbacks were not counted the input rate would come out wrong.
        let invalid: (Int) -> UInt32 = { $0 % 5 == 0 ? TapProbeFlag.inputHostTimeInvalid : 0 }
        let st = summarize(series(count: 2500, flags: invalid))
        let t = try #require(st.inputTime), b = try #require(t.inputFit)
        #expect(t.hostTimeUsable == 2000 && b.callbacks == 2000 && st.callbackCount == 2500)
        #expect(st.windows.map(\.inputCallbacks) == [800, 800, 400])
        #expect(st.windows.map(\.callbacks) == [1000, 1000, 500])                                     // inNow's membership is unchanged
        #expect(abs(b.driftPPM) < 1e-6 && b.residualPeakToPeakFrames < 1e-6)
        for w in st.windows {
            let ppm = try #require(w.inputImpliedVsDeclaredPPM), off = try #require(w.inputCumulativeFrameOffset)
            #expect(abs(ppm) < 1e-6 && abs(off) < 1e-6)
        }
    }

    @Test func aWindowWithoutAnyUsableInputIsEmptyAndTheOthersAreNot() throws {
        let invalid: (Int) -> UInt32 = { (1000..<2000).contains($0) ? TapProbeFlag.inputHostTimeInvalid : 0 }
        let st = summarize(series(count: 2500, flags: invalid))
        let w = st.windows
        #expect(w[1].inputCallbacks == 0 && w[1].inputSpanSeconds == nil && w[1].inputImpliedFramesPerSecond == nil)
        #expect(w[1].inputImpliedVsDeclaredPPM == nil && w[1].inputCumulativeFrameOffset == nil && w[1].impliedFramesPerSecond != nil)
        #expect(w[0].inputImpliedFramesPerSecond != nil && w[2].inputImpliedFramesPerSecond != nil)
        // window 2's offset still counts the frames of the skipped window: no phantom offset
        let off2 = try #require(w[2].inputCumulativeFrameOffset)
        #expect(abs(off2) < 1e-6)
    }

    @Test func aVaryingBlockSizeGivesAFlatOffsetWhenTheStampsFollowTheFramesExactly() throws {
        // declared 1,000,000 frames/s and 1 tick = 1 us: a callback's stamp is base + (frames delivered before it), so the offset is exactly 0 for BOTH
        // estimators whatever the block sizes are. A fit that counted a callback's own frames into its offset would show the block-size pattern.
        var recs: [TapProbeRecord] = []
        var delivered: UInt64 = 0
        for k in 0..<400 {
            let frames: UInt32 = k % 2 == 0 ? 480 : 512
            recs.append(TapProbeRecord(hostTime: UInt64(base) + delivered, sumSquares: 0, frames: frames, samples: 0, peak: 0, flags: 0,
                                       inputHostTime: UInt64(base) + delivered - 300, inputSampleTime: Double(delivered)))
            delivered += UInt64(frames)
        }
        let st = summarize(recs, declared: 1_000_000)
        let t = try #require(st.inputTime), a = try #require(t.inNowFit), b = try #require(t.inputFit)
        #expect(a.residualPeakToPeakFrames < 1e-6 && b.residualPeakToPeakFrames < 1e-6 && abs(a.driftPPM) < 1e-6 && abs(b.driftPPM) < 1e-6)
        #expect(t.sampleTimeStepMismatches == 0)
    }

    @Test func aWindowsLastCallbackWithoutInputIsNotUsedForTheInputOffsetOrRate() throws {
        // the last callback of each window (k = 999, 1999) has no valid input host time: the input figures must come from the last USABLE one (k = 998, 1998)
        let invalid: (Int) -> UInt32 = { $0 % 1000 == 999 ? TapProbeFlag.inputHostTimeInvalid : 0 }
        let st = summarize(series(count: 2500, flags: invalid))
        for w in st.windows.prefix(2) {
            let off = try #require(w.inputCumulativeFrameOffset), ppm = try #require(w.inputImpliedVsDeclaredPPM)
            #expect(abs(off) < 1e-6 && abs(ppm) < 1e-6 && w.inputCallbacks == w.callbacks - 1)
        }
    }

    @Test func theWindowLengthReachesTheWindowFloor() throws {
        let recs = series(count: 2000, now: { $0 % 2 == 0 ? 0 : 4_000 })
        let st = TapProbeAggregator.summarize(records: recs, dropped: 0, hostTicksPerSecond: ticksPerSecond, declaredRate: 48_000, windowSeconds: 5)
        let fit = try #require(st.inputTime?.inNowFit)
        #expect(fit.windowSeconds == 5 && abs(fit.windowResolutionPPM - 192.0 / (48_000 * 5) * 1e6) < 3)
        #expect(st.windows.count == 4 && st.windows.first?.callbacks == 500)
    }

    @Test func aWindowWithOneUsableInputCallbackHasSpanZeroAndNoRate() throws {
        let invalid: (Int) -> UInt32 = { ($0 % 1000) == 500 ? 0 : TapProbeFlag.inputHostTimeInvalid }       // exactly one usable callback per window
        let st = summarize(series(count: 2500, flags: invalid))
        let w = st.windows[0]
        #expect(w.inputCallbacks == 1 && w.inputSpanSeconds == 0 && w.inputImpliedFramesPerSecond == nil && w.inputImpliedVsDeclaredPPM == nil)
        #expect(w.inputCumulativeFrameOffset != nil)
    }

    @Test func noUsableInputAtAllLeavesTheInputSideEmptyAndInNowIntact() throws {
        let all = TapProbeFlag.noInputTime | TapProbeFlag.inputHostTimeInvalid | TapProbeFlag.inputSampleTimeInvalid
        let st = summarize(series(count: 2500, flags: { _ in all }))
        let t = try #require(st.inputTime)
        #expect(t.inputFit == nil && t.inNowFit != nil && t.nowMinusInputHostMs == nil)
        #expect(t.callbacks == 2500 && t.hostTimeUsable == 0 && t.sampleTimeUsable == 0 && t.noInputTime == 2500 && t.sampleTimeSteps == 0)
        #expect(st.windows.allSatisfy { $0.inputCallbacks == 0 && $0.inputCumulativeFrameOffset == nil && $0.impliedFramesPerSecond != nil })
        #expect(st.flagCounts["no input timestamp"] == 2500 && st.flagCounts["input host time not valid"] == 2500 && st.flagCounts["input sample time not valid"] == 2500)
    }

    @Test func aRecordWithoutInputFieldsAtAllIsNotUsable() throws {
        // Step 6a2-style records (flags 0, input fields 0): a zero host time is the "not stamped" convention, so nothing is used from them.
        let old = (0..<30).map { k in TapProbeRecord(hostTime: UInt64(base) + UInt64(k) * 10_000, sumSquares: 0, frames: 480, samples: 0, peak: 0, flags: 0) }
        let t = try #require(summarize(old).inputTime)
        #expect(t.hostTimeUsable == 0 && t.inputFit == nil && t.nowMinusInputHostMs == nil && t.inNowFit != nil)
    }

    @Test func anInputStampEarlierThanTheOriginIsSkipped() throws {
        let st = summarize(series(count: 100, input: { $0 == 3 ? -500_000 : -3_000 }))                // callback 3's input time is 0.5 s before the origin
        let t = try #require(st.inputTime), b = try #require(t.inputFit)
        #expect(t.hostTimeUsable == 100 && b.callbacks == 99)
        #expect(st.windows[0].inputCallbacks == 99)
    }

    @Test func withoutADeclaredRateThereIsNoFitAndTheContinuityStillCounts() throws {
        let st = summarize(series(count: 100), declared: nil)
        let t = try #require(st.inputTime)
        #expect(t.inNowFit == nil && t.inputFit == nil && t.sampleTimeSteps == 99 && t.hostTimeUsable == 100)
        #expect(st.windows.allSatisfy { $0.inputImpliedVsDeclaredPPM == nil && $0.inputCumulativeFrameOffset == nil && $0.inputImpliedFramesPerSecond != nil })
    }

    @Test func noRecordsGiveNoInputStats() {
        #expect(summarize([]).inputTime == nil)
    }
}

// MARK: - Validity comes from the flags, field by field

@Suite struct TapInputValidityTests {
    @Test func eachFieldIsUsableOnlyWhenItsOwnFlagIsClearEvenIfTheValueIsNonZero() throws {
        // Records the C callback never produces (it stores 0 for an invalid field) but the type can hold: the FLAG decides, not the value.
        let good = series(count: 1)[0]
        #expect(good.inputHostTime != 0 && good.inputHostTimeUsable && good.inputSampleTimeUsable)
        var hostFlagged = good; hostFlagged.flags = TapProbeFlag.inputHostTimeInvalid
        #expect(hostFlagged.inputHostTime != 0 && !hostFlagged.inputHostTimeUsable && hostFlagged.inputSampleTimeUsable)
        var sampleFlagged = good; sampleFlagged.flags = TapProbeFlag.inputSampleTimeInvalid
        #expect(sampleFlagged.inputHostTimeUsable && !sampleFlagged.inputSampleTimeUsable)
        var bothFlagged = good; bothFlagged.flags = TapProbeFlag.inputHostTimeInvalid | TapProbeFlag.inputSampleTimeInvalid
        #expect(!bothFlagged.inputHostTimeUsable && !bothFlagged.inputSampleTimeUsable)
    }

    @Test func theCountsKeepTheThreeFlagsApart() throws {
        // callbacks 0-3: host time invalid only; 4-5: no inInputTime pointer (all three bits); 6-9: fully valid
        let all = TapProbeFlag.noInputTime | TapProbeFlag.inputHostTimeInvalid | TapProbeFlag.inputSampleTimeInvalid
        let flags: (Int) -> UInt32 = { $0 < 4 ? TapProbeFlag.inputHostTimeInvalid : ($0 < 6 ? all : 0) }
        let t = try #require(summarize(series(count: 10, flags: flags)).inputTime)
        #expect(t.noInputTime == 2 && t.hostTimeUsable == 4 && t.sampleTimeUsable == 8)
        // a callback with only the sample time flagged still counts as host-usable
        let t2 = try #require(summarize(series(count: 10, flags: { $0 == 3 ? TapProbeFlag.inputSampleTimeInvalid : 0 })).inputTime)
        #expect(t2.hostTimeUsable == 10 && t2.sampleTimeUsable == 9 && t2.noInputTime == 0)
    }
}

// MARK: - Sample-time continuity and the latency figure

@Suite struct TapInputContinuityTests {
    @Test func aContinuousSampleClockHasNoMismatch() throws {
        let t = try #require(summarize(series(count: 50)).inputTime)
        #expect(t.sampleTimeSteps == 49 && t.sampleTimeStepMismatches == 0 && t.sampleTimeSurplusFrames == 0 && t.sampleTimeMaxMismatchFrames == 0)
    }

    @Test func aGapAndAnOverlapAreCountedWithTheirSignAndSize() throws {
        // callback 10's sample time is 512 frames too late (frames were skipped), callback 20's is 480 early (a repeat of the previous block)
        let sample: (Int) -> Double = { k in Double(k) * 480 + (k >= 10 ? 512 : 0) - (k >= 20 ? 992 : 0) }
        let t = try #require(summarize(series(count: 50, sample: sample)).inputTime)
        // steps: 9 -> 10 advances 992 instead of 480 (+512); 19 -> 20 advances 480 - 992 = -512 instead of 480 (-992)
        #expect(t.sampleTimeSteps == 49 && t.sampleTimeStepMismatches == 2)
        #expect(abs(t.sampleTimeSurplusFrames - (512 - 992)) < 1e-9 && abs(t.sampleTimeMaxMismatchFrames - 992) < 1e-9)
    }

    @Test func theExpectedAdvanceIsTheEarlierCallbacksFramesNotTheLaterOnes() throws {
        // frames alternate 480 / 512; sample time advances by exactly the earlier callback's frames: no mismatch. Comparing with the later callback's frames would flag every pair.
        var recs = series(count: 20)
        var sample = 0.0
        for k in 0..<recs.count {
            recs[k].frames = k % 2 == 0 ? 480 : 512
            recs[k].inputSampleTime = sample
            sample += Double(recs[k].frames)
        }
        let t = try #require(summarize(recs).inputTime)
        #expect(t.sampleTimeSteps == 19 && t.sampleTimeStepMismatches == 0 && t.sampleTimeSurplusFrames == 0)
    }

    @Test func aDifferenceOfLessThanHalfAFrameIsNotAMismatchButMoreIs() throws {
        let t1 = try #require(summarize(series(count: 10, sample: { Double($0) * 480 + ($0 >= 5 ? 0.4 : 0) })).inputTime)
        let t2 = try #require(summarize(series(count: 10, sample: { Double($0) * 480 + ($0 >= 5 ? 0.6 : 0) })).inputTime)
        #expect(t1.sampleTimeStepMismatches == 0 && t2.sampleTimeStepMismatches == 1)
    }

    @Test func aSampleTimeOfZeroOnTheFirstCallbackIsUsedBecauseTheFlagDecides() throws {
        let t = try #require(summarize(series(count: 3)).inputTime)                                   // sample times 0, 480, 960
        #expect(t.sampleTimeUsable == 3 && t.sampleTimeSteps == 2)
    }

    @Test func aCallbackWithAnInvalidSampleTimeBreaksTheAdjacentPairsOnBothSides() throws {
        let t = try #require(summarize(series(count: 10, flags: { $0 == 4 ? TapProbeFlag.inputSampleTimeInvalid : 0 })).inputTime)
        #expect(t.sampleTimeUsable == 9 && t.sampleTimeSteps == 7 && t.sampleTimeStepMismatches == 0)      // 9 adjacent pairs, minus (3,4) and (4,5)
    }

    @Test func aNonFiniteSampleTimeIsNotUsedEvenWithTheValidFlag() throws {
        let t = try #require(summarize(series(count: 10, sample: { $0 == 4 ? .nan : Double($0) * 480 })).inputTime)
        #expect(t.sampleTimeUsable == 9 && t.sampleTimeSteps == 7)
    }

    @Test func theLatencyFigureHasTheSignOfInNowMinusInputAndSkipsRecordsWithoutBothStamps() throws {
        let recs = series(count: 6, input: { k in k < 3 ? -2_000 : 5_000 }, flags: { $0 == 5 ? TapProbeFlag.inputHostTimeInvalid : 0 })
        let lag = try #require(summarize(recs).inputTime?.nowMinusInputHostMs)
        // callbacks 0-2: inNow - input = +2 ms; 3-4: -5 ms; 5: no valid input, left out
        #expect(abs(lag.min + 5) < 1e-9 && abs(lag.max - 2) < 1e-9 && abs(lag.median - 2) < 1e-9)
        var noNow = recs; noNow[0].hostTime = 0
        let lag2 = try #require(summarize(noNow).inputTime?.nowMinusInputHostMs)
        #expect(abs(lag2.min + 5) < 1e-9 && abs(lag2.max - 2) < 1e-9)
        let none = TapProbeAggregator.summarize(records: recs, dropped: 0, hostTicksPerSecond: 0, declaredRate: 48_000)
        #expect(none.inputTime?.nowMinusInputHostMs == nil)
    }
}

// MARK: - The report

@Suite struct TapInputReportTests {
    func report(_ records: [TapProbeRecord]) -> TapProbeReport {
        let b = FakeBackend(); b.records = records; b.hostTicksPerSecond = ticksPerSecond
        let t = FakeTime()
        return TapProbeRunner.run(backend: b, environment: TapProbeEnvironment(createdAt: "2026-11-07T12:00:00Z", macOSVersion: "27.2", hardwareModel: "Mac16,12", ownPID: 9, requestedSeconds: 25),
                                  clock: TapProbeClock(now: { t.t }, sleep: { t.t += $0 })) { _ in .timeout }
    }

    @Test func theSchemaIsThreeAndTheNewFieldsRoundTrip() throws {
        let r = report(series(count: 2500, now: { $0 % 2 == 0 ? 0 : 4_000 }))
        #expect(r.schemaVersion == 3)
        let back = try TapProbeReport.decode(r.jsonData())
        #expect(back == r && back.stats?.inputTime?.inputFit != nil && back.stats?.windows.first?.inputCallbacks == 1000)
        #expect(!String(decoding: try r.jsonData(), as: UTF8.self).contains("NaN"))
    }

    @Test func aSchemaTwoJSONWithoutTheNewKeysStillDecodes() throws {
        let r = report(series(count: 2500))
        var obj = try #require(JSONSerialization.jsonObject(with: try r.jsonData()) as? [String: Any])
        obj["schemaVersion"] = 2
        var stats = try #require(obj["stats"] as? [String: Any])
        stats["inputTime"] = nil
        stats["windows"] = (try #require(stats["windows"] as? [[String: Any]])).map { w -> [String: Any] in
            w.filter { !$0.key.hasPrefix("input") }
        }
        obj["stats"] = stats
        let old = try JSONSerialization.data(withJSONObject: obj)
        let back = try TapProbeReport.decode(old)
        #expect(back.schemaVersion == 2 && back.stats?.inputTime == nil && back.stats?.windows.count == 3 && back.stats?.windows.allSatisfy { $0.inputCallbacks == nil } == true)
    }

    @Test func theMarkdownHasTheSideBySideTableTheEstimatorTableAndBothLimitLists() {
        let md = report(series(count: 2500, now: { $0 % 2 == 0 ? 0 : 4_000 })).markdown()
        for needle in ["| window start (s) | callbacks | frames | inNow span (s) | inNow implied frames/s | inNow vs declared (ppm) | inNow cumulative frame offset | input callbacks | input span (s) | input implied frames/s | input vs declared (ppm) | input cumulative frame offset | complete |",
                       "**Input timestamps and the two estimators (Step 6a3):**", "| estimator | callbacks | span (s) | drift (ppm) | 1 s.e. (ppm) | offset SD (frames) | offset peak-to-peak (frames) | floor, whole run (ppm) | floor, one window (ppm) | fitted offset change (frames) |",
                       "| inNow |", "| input host time |", "**What each estimator can and cannot resolve (Step 6a3):**", "**What this does and does not show:**",
                       "`inInputTime` on 2500 callbacks: host time usable on 2500", "Sample-time continuity: 2499 consecutive pairs; 0 advanced"] {
            #expect(md.contains(needle), "missing \(needle)")
        }
        for limit in TapProbeReport.clockLimits + TapProbeReport.estimatorLimits { #expect(md.contains(limit)) }
        #expect(!md.contains("NaN") && md.range(of: #"(?i)\binf\b"#, options: .regularExpression) == nil)
    }

    @Test func theEstimatorTableRowsAndTheWindowColumnsCarryEachEstimatorsOwnNumbers() throws {
        // jitter only in inNow: the inNow row shows ~192 frames peak-to-peak, the input row 0.0
        let md1 = report(series(count: 2500, now: { $0 % 2 == 0 ? 0 : 4_000 })).markdown()
        let rows = md1.split(separator: "\n").map(String.init)
        let nowRow = try #require(rows.first { $0.hasPrefix("| inNow |") }), inRow = try #require(rows.first { $0.hasPrefix("| input host time |") })
        let nowCells = nowRow.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        let inCells = inRow.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        // columns: estimator, callbacks, span, drift, s.e., SD, peak-to-peak, floor run, floor window, fitted change
        #expect(nowCells.count == 10 && inCells.count == 10 && nowCells[1] == "2500" && inCells[1] == "2500")
        #expect((Double(nowCells[6]) ?? 0) > 190 && (Double(nowCells[6]) ?? 0) < 194 && inCells[6] == "0.0")
        // input clock +100 ppm, inNow exact: in the first window row the inNow ppm cell is ~0 and the input ppm cell ~+100.0
        let md2 = report(series(count: 2500, input: { -Int64($0) })).markdown()
        let w0 = try #require(md2.split(separator: "\n").map(String.init).first { $0.hasPrefix("| 0 | 1000 | 480000 |") })
        let c = w0.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        // columns: start, callbacks, frames, nowSpan, nowImplied, nowPPM, nowOffset, inCallbacks, inSpan, inImplied, inPPM, inOffset, complete
        #expect(c.count == 13 && c[7] == "1000")
        #expect(abs(Double(c[5]) ?? 99) < 0.05 && abs((Double(c[10]) ?? 0) - 100.0) < 0.05 && abs((Double(c[9]) ?? 0) - 48_004.80) < 0.01)
        // the cumulative offsets differ too: inNow's is ~0, the input one is 479,520 - 48,000 x 9.989001 = +47.952 at the window's last callback
        #expect(abs(Double(c[6]) ?? 99) < 0.05 && abs((Double(c[11]) ?? 0) - 47.952) < 0.06, "offset cells: \(c[6]) \(c[11])")
        // every 5th callback has no usable input host time: the input callbacks cell must say 800 where the callbacks cell says 1000
        let invalid: (Int) -> UInt32 = { $0 % 5 == 0 ? TapProbeFlag.inputHostTimeInvalid : 0 }
        let md3 = report(series(count: 2500, flags: invalid)).markdown()
        let w3 = try #require(md3.split(separator: "\n").map(String.init).first { $0.hasPrefix("| 0 | 1000 | 480000 |") })
        let c3 = w3.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(c3.count == 13 && c3[1] == "1000" && c3[7] == "800")
    }

    @Test func theRatesLineSaysItsTapRateIsAnEndpointEstimateAndPointsToTheEstimatorTable() {
        // the whole-run implied rate on the Rates line uses only the first and last callback; the report must not let it stand next to the fitted drift unlabelled
        let md = report(series(count: 2500)).markdown()
        let rates = md.split(separator: "\n").map(String.init).first { $0.hasPrefix("**Rates (numbers side by side, not a verdict):**") } ?? ""
        #expect(rates.contains("ENDPOINT estimate (first and last callback only, stamped by `inNow`)") && rates.contains("resolution floor in the estimator table below"))
    }

    @Test func theEstimatorLimitsSayWhatEachEstimatorCannotResolve() {
        let all = TapProbeReport.estimatorLimits.joined(separator: " ")
        for needle in ["against the host clock", "Neither involves the output device's clock", "includes any scheduling latency", "acquired from the hardware",
                       "UNVERIFIED", "a straight line is not proof of a steady clock", "peak-to-peak jitter", "a short run has a large floor", "Not resolved by either estimator",
                       "non-linear drift", "mRateScalar", "NOT recorded"] {
            #expect(all.contains(needle), "missing \(needle)")
        }
    }

    @Test func theStatementsQuoteTheMeasuredNumbersAndSayWhenTheSlopeIsNotAboveTheJitter() throws {
        let r = report(series(count: 2500, now: { $0 % 2 == 0 ? 0 : 4_000 }))               // jitter only: the slope is ~0, far below 192 frames of jitter
        let s = r.estimatorStatements
        #expect(s.count == 3)
        let t = try #require(r.stats?.inputTime), a = try #require(t.inNowFit)
        #expect(s[0].hasPrefix("inNow: over") && s[0].contains(String(format: "%.1f", a.residualPeakToPeakFrames)) && s[0].contains(String(format: "%.2f", a.resolutionPPM)))
        #expect(s[0].contains("NOT larger than the jitter") && s[0].contains("That is the tap against the HOST clock only."))
        #expect(s[1].hasPrefix("Input host time: over") && s[1].contains("0.0 frames peak-to-peak"))
        #expect(s[2].hasPrefix("Side by side, offset peak-to-peak: inNow") && s[2].contains("0.0 % of inNow's"))
    }

    @Test func theStatementsSayWhenTheSlopeIsLargerThanTheJitter() throws {
        let r = report(series(count: 2500, input: { -Int64($0) }))                          // input +100 ppm, no jitter
        let s = r.estimatorStatements
        #expect(s[1].contains("larger than the jitter") && !s[1].contains("NOT larger"))
    }

    @Test func withNoInputTimeTheStatementsSayNothingCanBeSaidFromItAndTheTableShowsDashes() {
        let all = TapProbeFlag.noInputTime | TapProbeFlag.inputHostTimeInvalid | TapProbeFlag.inputSampleTimeInvalid
        let r = report(series(count: 2500, flags: { _ in all }))
        #expect(r.estimatorStatements[1].hasPrefix("Input host time: no estimator"))
        #expect(r.markdown().contains("| input host time | — | — | — | — | — | — | — | — | — |"))
        #expect(r.estimatorStatements.count == 2)                                           // no side-by-side sentence without both
    }

    @Test func aRunWithoutStatsHasNoStatements() {
        let b = FakeBackend(); b.failing = ["createTap": -1]
        let t = FakeTime()
        let r = TapProbeRunner.run(backend: b, environment: TapProbeEnvironment(createdAt: "2026-11-07T12:00:00Z", macOSVersion: "27.2", hardwareModel: "Mac16,12", ownPID: 9, requestedSeconds: 5),
                                   clock: TapProbeClock(now: { t.t }, sleep: { t.t += $0 })) { _ in .timeout }
        #expect(r.estimatorStatements.isEmpty)
    }
}
