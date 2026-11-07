import Foundation

// Step 6a3: the input-timestamp estimator and the numbers that say how much it can resolve. Pure arithmetic on the callback records;
// nothing here touches Core Audio. Everything is about the tap's callbacks against the HOST clock (a host-clock timestamp per callback
// against the frames the tap delivered): none of it involves the output device's clock.

/// One estimator's whole-run result. The series is the "offset" of the window table: frames delivered before a callback minus the declared rate
/// times that callback's stamp time (both measured from the estimator's first callback). A tap whose frame rate equals the declared rate against
/// the host clock gives a flat offset; a different rate gives a straight line; stamp jitter gives scatter around it.
public struct TapOffsetFit: Codable, Equatable, Sendable {
    /// Callbacks that went into the fit.
    public var callbacks: Int
    /// Last stamp minus first stamp, seconds.
    public var spanSeconds: Double
    /// Least-squares slope of the offset against stamp time, divided by the declared rate, x 1e6: the tap's frame rate against the host clock as parts per
    /// million of the declared rate (+ = more frames than declared per host second). It is a measurement of this series, with the uncertainty next to it.
    public var driftPPM: Double
    /// One standard error of `driftPPM`. It assumes the jitter of successive callbacks is independent, which is UNVERIFIED for real stamps: use
    /// `resolutionPPM` (no such assumption) as the conservative figure.
    public var driftStdErrPPM: Double
    /// Standard deviation of the offset about the fitted line, in frames.
    public var residualSDFrames: Double
    /// Largest minus smallest offset about the fitted line, in frames: the jitter, all of it, outliers included.
    public var residualPeakToPeakFrames: Double
    /// Resolution floor over the whole series: `residualPeakToPeakFrames / (declared rate x spanSeconds) x 1e6`. A drift smaller than this changes
    /// the offset by less than the jitter over the whole run and cannot be told from it.
    public var resolutionPPM: Double
    /// The same floor for ONE window of `windowSeconds` (the window table's ppm column): `residualPeakToPeakFrames / (declared rate x windowSeconds) x 1e6`.
    public var windowResolutionPPM: Double
    public var windowSeconds: Double
    /// `slope x spanSeconds`: how many frames the fitted line moved the offset over the run (to compare with `residualPeakToPeakFrames`).
    public var fittedOffsetChangeFrames: Double
}

public enum TapOffsetEstimator {
    /// `points`: (stamp time in seconds since the estimator's first callback, frames delivered before that callback since its first callback).
    /// nil with fewer than three points, no spread in time, or a declared rate that is not positive and finite.
    public static func fit(points: [(t: Double, f: Double)], declaredRate: Double, windowSeconds: Double) -> TapOffsetFit? {
        guard points.count >= 3, declaredRate > 0, declaredRate.isFinite, windowSeconds > 0, windowSeconds.isFinite else { return nil }
        let n = Double(points.count)
        let offsets = points.map { $0.f - declaredRate * $0.t }
        let tMean = points.reduce(0.0) { $0 + $1.t } / n
        let oMean = offsets.reduce(0.0, +) / n
        var sxx = 0.0, sxo = 0.0
        for (p, o) in zip(points, offsets) { sxx += (p.t - tMean) * (p.t - tMean); sxo += (p.t - tMean) * (o - oMean) }
        guard sxx > 0, let tMin = points.map(\.t).min(), let tMax = points.map(\.t).max(), tMax > tMin else { return nil }
        let slope = sxo / sxx
        let intercept = oMean - slope * tMean
        var sse = 0.0, lo = Double.infinity, hi = -Double.infinity
        for (p, o) in zip(points, offsets) {
            let e = o - (intercept + slope * p.t)
            sse += e * e; lo = min(lo, e); hi = max(hi, e)
        }
        let sd = (sse / (n - 2)).squareRoot()
        let span = tMax - tMin
        let peakToPeak = hi - lo
        return TapOffsetFit(
            callbacks: points.count, spanSeconds: span,
            driftPPM: slope / declaredRate * 1e6, driftStdErrPPM: sd / sxx.squareRoot() / declaredRate * 1e6,
            residualSDFrames: sd, residualPeakToPeakFrames: peakToPeak,
            resolutionPPM: peakToPeak / (declaredRate * span) * 1e6, windowResolutionPPM: peakToPeak / (declaredRate * windowSeconds) * 1e6,
            windowSeconds: windowSeconds, fittedOffsetChangeFrames: slope * span)
    }
}

/// What the input timestamps looked like, and the two estimators side by side.
public struct TapInputTimeStats: Codable, Equatable, Sendable {
    public var callbacks: Int
    /// Callbacks whose input host time was valid (by the callback's flag) and non-zero.
    public var hostTimeUsable: Int
    /// Callbacks whose input sample time was valid (by the callback's flag) and finite.
    public var sampleTimeUsable: Int
    /// Callbacks that got no `inInputTime` pointer at all.
    public var noInputTime: Int
    /// `inNow` host time minus input host time in milliseconds, over the callbacks that have both. The header says `inNow` "includes any scheduling latency" and the
    /// input time is when the first frame "was acquired from the hardware"; this is the number, not a conclusion about which is which.
    public var nowMinusInputHostMs: MinMedianMax?
    /// Consecutive callback pairs whose input sample times were both usable.
    public var sampleTimeSteps: Int
    /// Of those, pairs where the sample time advanced by something other than the earlier callback's frame count (more than half a frame off).
    public var sampleTimeStepMismatches: Int
    /// Sum over the mismatching pairs of (sample-time advance - frames delivered): + means the sample clock skipped frames the callbacks never delivered.
    public var sampleTimeSurplusFrames: Double
    public var sampleTimeMaxMismatchFrames: Double
    /// The `inNow` estimator over the callbacks bucketed in the window table.
    public var inNowFit: TapOffsetFit?
    /// The input-host-time estimator over the callbacks that had a usable one.
    public var inputFit: TapOffsetFit?

    /// `inNowPoints` / `inputPoints` come from the aggregator's single pass over the stamped callbacks (see `TapProbeAggregator.summarize`).
    /// `hostTicksPerSecond` 0 = unknown (no millisecond figure). nil for no records.
    public static func make(records: [TapProbeRecord], hostTicksPerSecond: Double, declaredRate: Double?, windowSeconds: Double,
                            inNowPoints: [(t: Double, f: Double)], inputPoints: [(t: Double, f: Double)]) -> TapInputTimeStats? {
        guard !records.isEmpty else { return nil }
        var diffsMs: [Double] = []
        if hostTicksPerSecond > 0 {
            for r in records where r.hostTime != 0 && r.inputHostTimeUsable {
                let ticks = r.hostTime >= r.inputHostTime ? Double(r.hostTime - r.inputHostTime) : -Double(r.inputHostTime - r.hostTime)
                diffsMs.append(ticks / hostTicksPerSecond * 1000)
            }
        }
        var steps = 0, mismatches = 0
        var surplus = 0.0, maxMismatch = 0.0
        for (a, b) in zip(records, records.dropFirst()) where a.inputSampleTimeUsable && b.inputSampleTimeUsable {
            steps += 1
            let d = (b.inputSampleTime - a.inputSampleTime) - Double(a.frames)
            if abs(d) > 0.5 { mismatches += 1; surplus += d; maxMismatch = max(maxMismatch, abs(d)) }
        }
        let rate = declaredRate ?? 0
        return TapInputTimeStats(
            callbacks: records.count, hostTimeUsable: records.filter(\.inputHostTimeUsable).count,
            sampleTimeUsable: records.filter(\.inputSampleTimeUsable).count,
            noInputTime: records.filter { $0.flags & TapProbeFlag.noInputTime != 0 }.count,
            nowMinusInputHostMs: MinMedianMax(diffsMs), sampleTimeSteps: steps, sampleTimeStepMismatches: mismatches,
            sampleTimeSurplusFrames: surplus, sampleTimeMaxMismatchFrames: maxMismatch,
            inNowFit: TapOffsetEstimator.fit(points: inNowPoints, declaredRate: rate, windowSeconds: windowSeconds),
            inputFit: TapOffsetEstimator.fit(points: inputPoints, declaredRate: rate, windowSeconds: windowSeconds))
    }
}
