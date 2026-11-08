import Foundation

// Step 6b-2b: the arithmetic of the offline resampling-consumption experiment. Pure Swift, no AVFoundation, no hardware. IMPLEMENTED-UNVERIFIED for anything but the
// offline manual-rendering engine it was written for.
//
// The question: when a mixer converts a source (48 kHz) to a different output rate, it pulls a whole number of source frames per render (the real Bluetooth runs
// showed exactly 558 per 512 frames at 44.1 kHz, which is ceil(557.28), +1294 ppm against the ideal ratio). Does it CONSUME all pulled frames (the stream then plays
// that much too fast and a count-only ring really drains), or does it consume the ideal ratio and keep or drop the surplus?
//
// The source is a RAMP: source frame j carries the value j * 2^-20 (exact in Float up to 2^24 frames). Whatever the mixer does, an output sample then says which source
// position it came from, and the reader's cursor says how many source frames were pulled. Two numbers answer the question:
//   * the slope of (sample * 2^20) against the output frame index = source frames consumed per output frame, times the mixer's gain G;
//   * the gap g_k = cursor_k - (last output sample of render k * 2^20 / G): source frames pulled but not (yet) played. A flat gap means everything pulled is played;
//     a gap that grows by `surplus` per render means the surplus is kept (or dropped from the count of consumption).

public struct ResamplingRender: Equatable, Sendable {
    /// Source frames the reader was asked for during this render: the delta of its frames-requested sum.
    public var pulledFrames: Int64
    /// Reader calls during this render: the delta of its call counter.
    public var calls: Int64
    /// The reader's cursor after this render.
    public var cursorAfter: Int64
    /// The left output channel of this render.
    public var samples: [Float]

    public init(pulledFrames: Int64, calls: Int64, cursorAfter: Int64, samples: [Float]) {
        self.pulledFrames = pulledFrames; self.calls = calls; self.cursorAfter = cursorAfter; self.samples = samples
    }
}

public struct ResamplingConsumptionConfig: Equatable, Sendable {
    /// sample * rampUnit = source frames (the producer writes Float(j) * 2^-20).
    public static let rampUnit = 1_048_576.0
    public var sourceRate: Double
    public var outputRate: Double
    /// Output frames per render.
    public var renderFrames: Int
    /// The mixer's gain G on the ramp (1 only if nothing scales it; measured in the control case, where the ratio is exactly 1).
    public var gain: Double
    /// Renders at the start that are excluded (the converter's start-up).
    public var warmUpRenders: Int

    public init(sourceRate: Double, outputRate: Double, renderFrames: Int, gain: Double, warmUpRenders: Int = 20) {
        self.sourceRate = sourceRate; self.outputRate = outputRate; self.renderFrames = renderFrames; self.gain = gain; self.warmUpRenders = warmUpRenders
    }
}

public struct ResamplingPullCount: Equatable, Sendable {
    public var value: Int64
    public var count: Int
}

public struct ResamplingConsumptionResult: Equatable, Sendable {
    public var rendersAnalyzed: Int
    // pulls (per render, after the warm-up)
    public var pullMin: Int64
    public var pullMax: Int64
    public var pullMean: Double
    public var distinctPulls: [ResamplingPullCount]
    public var callsPerRenderMin: Int64
    public var callsPerRenderMax: Int64
    public var callsPerRenderMean: Double
    // the ramp against the output index
    /// Least-squares slope of (sample * 2^20) against the output frame index: source frames per output frame, times G.
    public var slopeTimesGain: Double
    /// Coefficient of determination of that fit (how well the output is a straight ramp).
    public var rSquared: Double
    public var idealRatio: Double
    /// slopeTimesGain / G.
    public var measuredRatio: Double
    public var ratioDeviationPPM: Double
    // the gap series
    public var gapMean: Double
    public var gapMin: Double
    public var gapMax: Double
    public var gapPeakToPeak: Double
    /// Least-squares slope of the gap against the render index, source frames per render.
    public var gapSlopePerRender: Double
    /// That slope as parts per million of the mean frames pulled per render.
    public var gapSlopePPMOfPulled: Double
    // resolution
    /// One Float step of the largest output sample, in source frames (ulp * 2^20 / G): the quantization of the ramp measurement.
    public var quantizationStep: Double
    /// The tolerance a control must keep the gap's peak-to-peak under: four quantization steps, derived from the data, never loosened.
    public var gapTolerance: Double
}

/// The mixer's gain measured with a CONSTANT source (added after the first table run showed that G is not the same in every case).
public struct ResamplingConstantGain: Equatable, Sendable {
    public var samplesAnalyzed: Int
    public var mean: Double
    public var min: Double
    public var max: Double
    /// mean / constant: what the mixer did to the constant. Assumes the converter has unity gain for a constant (DC) input: UNVERIFIED.
    public var gain: Double
    public var peakToPeakRelative: Double { mean != 0 ? (max - min) / abs(mean) : .infinity }
}

public enum ResamplingConsumptionAnalyzer {
    /// The gain applied to a constant source: output mean (after the warm-up) divided by the constant. nil for a non-positive constant, too few renders, or an empty render.
    public static func constantGain(renders: [ResamplingRender], constant: Float, warmUpRenders: Int = 20) -> ResamplingConstantGain? {
        let first = warmUpRenders
        guard constant > 0, constant.isFinite, first >= 0, renders.count >= first + 3, renders[first...].allSatisfy({ !$0.samples.isEmpty }) else { return nil }
        var n = 0, sum = 0.0
        var lo = Double.infinity, hi = -Double.infinity
        for r in renders[first...] { for s in r.samples { let v = Double(s); sum += v; n += 1; lo = Swift.min(lo, v); hi = Swift.max(hi, v) } }
        let mean = sum / Double(n)
        return ResamplingConstantGain(samplesAnalyzed: n, mean: mean, min: lo, max: hi, gain: mean / Double(constant))
    }

    /// nil when the input cannot be analyzed: a non-positive rate, render size or gain, fewer than three renders after the warm-up, or a render whose sample count is not `renderFrames`.
    public static func analyze(renders: [ResamplingRender], config: ResamplingConsumptionConfig) -> ResamplingConsumptionResult? {
        let first = config.warmUpRenders
        guard config.sourceRate > 0, config.outputRate > 0, config.sourceRate.isFinite, config.outputRate.isFinite, config.renderFrames > 0,
              config.gain.isFinite, config.gain > 0, first >= 0, renders.count >= first + 3,
              renders[first...].allSatisfy({ $0.samples.count == config.renderFrames }) else { return nil }
        let used = Array(renders[first...])
        let unit = ResamplingConsumptionConfig.rampUnit
        let R = config.renderFrames

        // pulls
        var counts: [Int64: Int] = [:]
        var pulledTotal: Int64 = 0, callsTotal: Int64 = 0
        var callsMin = Int64.max, callsMax = Int64.min
        for r in used {
            counts[r.pulledFrames, default: 0] += 1
            pulledTotal += r.pulledFrames; callsTotal += r.calls
            callsMin = min(callsMin, r.calls); callsMax = max(callsMax, r.calls)
        }
        let distinct = counts.keys.sorted().map { ResamplingPullCount(value: $0, count: counts[$0]!) }
        let pullMean = Double(pulledTotal) / Double(used.count)

        // ramp against output index: two passes over every sample
        var n = 0.0, sumX = 0.0, sumY = 0.0
        var maxAbs: Float = 0
        for (idx, r) in used.enumerated() {
            let base = Double((first + idx) * R)
            for (i, s) in r.samples.enumerated() { sumX += base + Double(i); sumY += Double(s) * unit; n += 1; maxAbs = max(maxAbs, abs(s)) }
        }
        let mx = sumX / n, my = sumY / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for (idx, r) in used.enumerated() {
            let base = Double((first + idx) * R)
            for (i, s) in r.samples.enumerated() {
                let dx = base + Double(i) - mx, dy = Double(s) * unit - my
                sxx += dx * dx; sxy += dx * dy; syy += dy * dy
            }
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        let r2 = syy > 0 ? (sxy * sxy) / (sxx * syy) : 1

        // gap series
        var ks: [Double] = [], gaps: [Double] = []
        for (idx, r) in used.enumerated() {
            ks.append(Double(first + idx))
            gaps.append(Double(r.cursorAfter) - Double(r.samples[R - 1]) * unit / config.gain)
        }
        let gk = Double(gaps.count)
        let mk = ks.reduce(0, +) / gk, mg = gaps.reduce(0, +) / gk
        var skk = 0.0, skg = 0.0
        for (k, g) in zip(ks, gaps) { skk += (k - mk) * (k - mk); skg += (k - mk) * (g - mg) }
        let gapSlope = skk > 0 ? skg / skk : 0

        let ideal = config.sourceRate / config.outputRate
        let measured = slope / config.gain
        let q = Double(maxAbs.ulp) * unit / config.gain
        return ResamplingConsumptionResult(
            rendersAnalyzed: used.count, pullMin: used.map(\.pulledFrames).min()!, pullMax: used.map(\.pulledFrames).max()!, pullMean: pullMean, distinctPulls: distinct,
            callsPerRenderMin: callsMin, callsPerRenderMax: callsMax, callsPerRenderMean: Double(callsTotal) / Double(used.count),
            slopeTimesGain: slope, rSquared: r2, idealRatio: ideal, measuredRatio: measured, ratioDeviationPPM: (measured / ideal - 1) * 1e6,
            gapMean: mg, gapMin: gaps.min()!, gapMax: gaps.max()!, gapPeakToPeak: gaps.max()! - gaps.min()!, gapSlopePerRender: gapSlope,
            gapSlopePPMOfPulled: pullMean > 0 ? gapSlope / pullMean * 1e6 : 0, quantizationStep: q, gapTolerance: 4 * q)
    }
}
