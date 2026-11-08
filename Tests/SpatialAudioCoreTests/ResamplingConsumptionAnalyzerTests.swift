import Testing
import Foundation
@testable import SpatialAudioCore

// Step 6b-2b. The arithmetic of the resampling-consumption experiment on SYNTHETIC renders with analytically known answers. Nothing here involves an engine, a device
// or a clock; it checks the analyzer, not the mixer.

private let unit = ResamplingConsumptionConfig.rampUnit

/// Synthetic renders. The "mixer" plays source position p(n) = start + (consumedPerRender / renderFrames) * n for output index n and scales it by `gain`;
/// the reader is asked `pull(k)` frames in `calls(k)` calls during render k, so its cursor is `cursorStart` + the running sum of the pulls.
private func synth(renderFrames R: Int, renders K: Int = 2000, gain: Double = 1, consumedPerRender: Double, start: Double = 400, cursorStart: Int64 = 1000,
                   pull: (Int) -> Int64, calls: (Int) -> Int64 = { _ in 1 }, garbageFirst: Int = 0) -> [ResamplingRender] {
    var out: [ResamplingRender] = []
    var cursor = cursorStart
    for k in 0..<K {
        cursor += pull(k)
        var samples = [Float](repeating: 0, count: R)
        for i in 0..<R {
            let p = start + consumedPerRender / Double(R) * Double(k * R + i)
            samples[i] = Float(gain * p / unit)
        }
        if k < garbageFirst { out.append(ResamplingRender(pulledFrames: 9999, calls: 7, cursorAfter: 0, samples: [Float](repeating: 5000, count: R))) }
        else { out.append(ResamplingRender(pulledFrames: pull(k), calls: calls(k), cursorAfter: cursor, samples: samples)) }
    }
    return out
}

private func cfg(_ s: Double, _ o: Double, _ R: Int, gain: Double = 1) -> ResamplingConsumptionConfig { ResamplingConsumptionConfig(sourceRate: s, outputRate: o, renderFrames: R, gain: gain) }

@Suite struct ResamplingConsumptionAnalyzerTests {
    @Test func anIdealResamplerGivesTheIdealRatioAndAFlatGap() throws {
        // 441 output frames at 44.1 kHz need exactly 480 source frames at 48 kHz: pulled = consumed = 480.
        let g = 0.7071                                                            // a pan-law-like gain: the ratio and the gap must not depend on it
        let rs = synth(renderFrames: 441, gain: g, consumedPerRender: 480, pull: { _ in 480 })
        let r = try #require(ResamplingConsumptionAnalyzer.analyze(renders: rs, config: cfg(48_000, 44_100, 441, gain: g)))
        #expect(abs(r.measuredRatio - 480.0 / 441.0) < 1e-6 && abs(r.idealRatio - 48_000.0 / 44_100.0) < 1e-12)
        #expect(abs(r.ratioDeviationPPM) < 1, "an ideal resampler deviates by 0 ppm, got \(r.ratioDeviationPPM)")
        #expect(abs(r.slopeTimesGain - g * 480.0 / 441.0) < 1e-5, "the slope carries the gain: \(r.slopeTimesGain)")
        #expect(abs(r.gapSlopePerRender) < 0.002 && r.gapPeakToPeak < r.gapTolerance + 1e-9, "flat gap: slope \(r.gapSlopePerRender), p-p \(r.gapPeakToPeak), tolerance \(r.gapTolerance)")
        // the gap is a known constant: cursorStart - start + consumed/render (the last output sample of a render sits one output frame short of the render's end)
        #expect(abs(r.gapMean - (1000 - 400 + 480.0 / 441.0)) < 0.2, "gap mean \(r.gapMean)")
        #expect(r.rSquared > 0.999999)
    }

    @Test func aMixerThatConsumesExactlyWhatWasPulledShowsTheRoundingAsAPositiveRatioDeviationAndAFlatGap() throws {
        // 558 pulled and consumed per 512 output frames at 48 -> 44.1 kHz: +1293.9 ppm against the ideal ratio, gap constant (the "H1" signature).
        let rs = synth(renderFrames: 512, consumedPerRender: 558, pull: { _ in 558 })
        let r = try #require(ResamplingConsumptionAnalyzer.analyze(renders: rs, config: cfg(48_000, 44_100, 512)))
        let expected = (558.0 / 512.0) / (48_000.0 / 44_100.0) * 1e6 - 1e6
        #expect(abs(expected - 1293.9) < 0.1)
        #expect(abs(r.ratioDeviationPPM - expected) < 0.5, "got \(r.ratioDeviationPPM), expected \(expected)")
        #expect(abs(r.gapSlopePerRender) < 0.002 && abs(r.gapSlopePPMOfPulled) < 5)
        #expect(r.pullMin == 558 && r.pullMax == 558 && abs(r.pullMean - 558) < 1e-12)
    }

    @Test func aMixerThatKeepsTheSurplusShowsAZeroRatioDeviationAndAGapGrowingBySurplusPerRender() throws {
        // 558 pulled per render, but the mixer plays the ideal 557.2789 per render (the "H2" signature): the gap grows by 0.7211 frames per render.
        let ideal = 512.0 * 48_000.0 / 44_100.0
        let rs = synth(renderFrames: 512, consumedPerRender: ideal, pull: { _ in 558 })
        let r = try #require(ResamplingConsumptionAnalyzer.analyze(renders: rs, config: cfg(48_000, 44_100, 512)))
        #expect(abs(r.ratioDeviationPPM) < 0.5, "got \(r.ratioDeviationPPM)")
        #expect(abs(r.gapSlopePerRender - (558 - ideal)) < 0.002, "gap slope \(r.gapSlopePerRender), expected \(558 - ideal)")
        #expect(abs(r.gapSlopePPMOfPulled - (558 - ideal) / 558 * 1e6) < 5)
    }

    @Test func aConstantGapIsReportedWithItsKnownValueNotJustItsFlatness() throws {
        // Two different cursor offsets must give two different gap means: this is what separates a gap against the cursor AFTER the render from one against the cursor before it.
        let a = synth(renderFrames: 441, consumedPerRender: 480, cursorStart: 1000, pull: { _ in 480 })
        let b = synth(renderFrames: 441, consumedPerRender: 480, cursorStart: 1500, pull: { _ in 480 })
        let ra = try #require(ResamplingConsumptionAnalyzer.analyze(renders: a, config: cfg(48_000, 44_100, 441)))
        let rb = try #require(ResamplingConsumptionAnalyzer.analyze(renders: b, config: cfg(48_000, 44_100, 441)))
        #expect(abs((rb.gapMean - ra.gapMean) - 500) < 0.2)
        #expect(abs(ra.gapMean - (1000 - 400 + 480.0 / 441.0)) < 0.2, "a gap taken against the cursor before the render would be off by one pull (480): \(ra.gapMean)")
    }

    @Test func theWarmUpRendersAreExcludedAndTheCountsAreTheCountsOfTheRendersThatWereUsed() throws {
        let rs = synth(renderFrames: 441, consumedPerRender: 480, pull: { _ in 480 }, garbageFirst: 20)
        let r = try #require(ResamplingConsumptionAnalyzer.analyze(renders: rs, config: cfg(48_000, 44_100, 441)))
        #expect(r.rendersAnalyzed == 1980 && r.distinctPulls == [ResamplingPullCount(value: 480, count: 1980)], "garbage in the 20 warm-up renders must not show: \(r.distinctPulls)")
        #expect(abs(r.ratioDeviationPPM) < 1 && abs(r.gapSlopePerRender) < 0.002)
        let none = try #require(ResamplingConsumptionAnalyzer.analyze(renders: rs, config: ResamplingConsumptionConfig(sourceRate: 48_000, outputRate: 44_100, renderFrames: 441, gain: 1, warmUpRenders: 0)))
        #expect(none.rendersAnalyzed == 2000 && abs(none.ratioDeviationPPM) > 1000, "without the exclusion the garbage must visibly spoil the fit (control of the control)")
    }

    @Test func pullStatisticsCountDistinctValuesAndCallsPerRenderNotPerCall() throws {
        // pulls alternate 557 / 558 (sum 1115 per two renders), 2 calls in every third render
        let rs = synth(renderFrames: 512, consumedPerRender: 557.5, pull: { $0 % 2 == 0 ? 557 : 558 }, calls: { $0 % 3 == 0 ? 2 : 1 })
        let r = try #require(ResamplingConsumptionAnalyzer.analyze(renders: rs, config: cfg(48_000, 44_100, 512)))
        #expect(r.pullMin == 557 && r.pullMax == 558 && abs(r.pullMean - 557.5) < 1e-9)
        #expect(r.distinctPulls == [ResamplingPullCount(value: 557, count: 990), ResamplingPullCount(value: 558, count: 990)], "\(r.distinctPulls)")
        #expect(r.callsPerRenderMin == 1 && r.callsPerRenderMax == 2)
        // renders 20...1999 (the analyzed ones): k % 3 == 0 for k = 21, 24, ..., 1998: 660 renders with 2 calls, 1320 with 1 -> mean 4/3
        #expect(abs(r.callsPerRenderMean - 4.0 / 3.0) < 1e-9, "\(r.callsPerRenderMean)")
        #expect(abs(r.pullMean - Double(r.distinctPulls.map { Int($0.value) * $0.count }.reduce(0, +)) / Double(r.rendersAnalyzed)) < 1e-9, "the mean is per render")
        let twoCalls = synth(renderFrames: 512, consumedPerRender: 480, pull: { _ in 480 }, calls: { _ in 2 })
        let t = try #require(ResamplingConsumptionAnalyzer.analyze(renders: twoCalls, config: cfg(48_000, 44_100, 512)))
        #expect(abs(t.pullMean - 480) < 1e-12 && t.callsPerRenderMean == 2, "a render with two calls still pulled 480 frames, not 240 per call: \(t.pullMean)")
    }

    @Test func theQuantizationStepIsOneFloatStepOfTheLargestSampleInSourceFrames() throws {
        // Largest sample in [0.5, 1): Float step 2^-24 -> 0.0625 source frames. In [1, 2): 2^-23 -> 0.125. The gain scales the samples (so their Float step) and divides the step back to source frames.
        let below = synth(renderFrames: 441, renders: 1500, consumedPerRender: 480, pull: { _ in 480 })            // 1500 x 480 = 720,000 frames: max sample 0.69
        let above = synth(renderFrames: 441, renders: 2400, consumedPerRender: 480, pull: { _ in 480 })            // 2400 x 480 = 1.152 M frames > 2^20: max sample 1.10
        let a = try #require(ResamplingConsumptionAnalyzer.analyze(renders: below, config: cfg(48_000, 44_100, 441)))
        let b = try #require(ResamplingConsumptionAnalyzer.analyze(renders: above, config: cfg(48_000, 44_100, 441)))
        #expect(a.quantizationStep == 0.0625 && a.gapTolerance == 0.25, "\(a.quantizationStep)")
        #expect(b.quantizationStep == 0.125 && b.gapTolerance == 0.5, "\(b.quantizationStep)")
        let scaled = synth(renderFrames: 441, renders: 2400, gain: 0.75, consumedPerRender: 480, pull: { _ in 480 })       // max sample 0.82, still in [0.5, 1)
        let c = try #require(ResamplingConsumptionAnalyzer.analyze(renders: scaled, config: cfg(48_000, 44_100, 441, gain: 0.75)))
        #expect(abs(c.quantizationStep - 0.0625 / 0.75) < 1e-12, "\(c.quantizationStep)")
    }

    @Test func theConstantGainIsTheMeanOfTheAnalyzedOutputOverTheConstantAndExcludesTheWarmUp() throws {
        // a mixer that scales a constant 0.25 by 0.7071 after 20 renders of start-up garbage
        let renders = (0..<400).map { k in ResamplingRender(pulledFrames: 480, calls: 1, cursorAfter: Int64(k * 480), samples: [Float](repeating: k < 20 ? 9 : Float(0.25 * 0.7071), count: 441)) }
        let g = try #require(ResamplingConsumptionAnalyzer.constantGain(renders: renders, constant: 0.25))
        #expect(abs(g.gain - 0.7071) < 1e-6, "gain \(g.gain)")
        #expect(g.samplesAnalyzed == 380 * 441 && g.peakToPeakRelative < 1e-12, "the garbage of the warm-up must not enter: \(g.samplesAnalyzed), p-p \(g.peakToPeakRelative)")
        let ripple = (0..<400).map { k in ResamplingRender(pulledFrames: 480, calls: 1, cursorAfter: 0, samples: [Float](repeating: Float(0.25 * (k % 2 == 0 ? 1.0 : 0.5)), count: 4)) }
        let rg = try #require(ResamplingConsumptionAnalyzer.constantGain(renders: ripple, constant: 0.25))
        #expect(abs(rg.gain - 0.75) < 1e-6 && abs(rg.max - 0.25) < 1e-6 && abs(rg.min - 0.125) < 1e-6, "mean / constant, not mean x constant: \(rg.gain)")
        #expect(ResamplingConsumptionAnalyzer.constantGain(renders: renders, constant: 0) == nil && ResamplingConsumptionAnalyzer.constantGain(renders: renders, constant: .nan) == nil)
        #expect(ResamplingConsumptionAnalyzer.constantGain(renders: Array(renders.prefix(22)), constant: 0.25) == nil)
    }

    @Test func inputThatCannotBeAnalyzedIsRefusedNotGuessed() {
        let ok = synth(renderFrames: 441, renders: 100, consumedPerRender: 480, pull: { _ in 480 })
        #expect(ResamplingConsumptionAnalyzer.analyze(renders: ok, config: cfg(48_000, 44_100, 441)) != nil)
        #expect(ResamplingConsumptionAnalyzer.analyze(renders: [], config: cfg(48_000, 44_100, 441)) == nil)
        #expect(ResamplingConsumptionAnalyzer.analyze(renders: Array(ok.prefix(22)), config: cfg(48_000, 44_100, 441)) == nil, "fewer than three renders after the warm-up")
        #expect(ResamplingConsumptionAnalyzer.analyze(renders: ok, config: cfg(48_000, 44_100, 441, gain: 0)) == nil)
        #expect(ResamplingConsumptionAnalyzer.analyze(renders: ok, config: cfg(48_000, 44_100, 441, gain: .nan)) == nil)
        #expect(ResamplingConsumptionAnalyzer.analyze(renders: ok, config: cfg(0, 44_100, 441)) == nil)
        #expect(ResamplingConsumptionAnalyzer.analyze(renders: ok, config: cfg(48_000, 44_100, 440)) == nil, "a render whose sample count is not renderFrames")
    }
}
