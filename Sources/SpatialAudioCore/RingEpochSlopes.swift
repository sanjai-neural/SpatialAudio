import Foundation

// Step 6b-3b (a2): the fill slope PER EPOCH of a recovery-mode run. IMPLEMENTED-UNVERIFIED.
//
// The question this serves: in a run with re-primes, is the ring still draining at the +1,294 ppm rounding rate inside each epoch, or at a smaller rate? The whole-run fill slope cannot say
// (the fill jumps at every re-prime by design), and the 2026-11-19 reading of the two Bluetooth reports that explained the 45 to 96 s gaps was done by an uncommitted script. This is that
// computation as a tested function. It decides nothing by itself: the pre-registered verdict (RateFixEvaluator) does not use it, except as an informational line.
//
// An epoch is the time between a restart and the next stop. The recovery records carry the RUN clock (the command's suspending clock); the samples carry host-tick time since sample 0.
// `firstSampleRunClockSeconds` (recorded by the runner at the first sample) converts one into the other, to within the time between reading the clock and taking the snapshot.

public struct RingEpochSlope: Codable, Equatable, Sendable {
    public var index: Int
    /// Measured seconds since sample 0 of the first and last sample in the epoch.
    public var startSeconds: Double
    public var endSeconds: Double
    public var sampleCount: Int
    /// [left, right]; nil with fewer than `RingEpochSlopes.minimumSamples` samples.
    public var slopeFramesPerSecond: [Double?]
    public var slopePPM: [Double?]
    public var fillFirst: [Int64]
    public var fillLast: [Int64]
    /// Underrun blocks counted inside the epoch (last sample minus first sample of the epoch), [left, right].
    public var underruns: [UInt64]
}

public enum RingEpochSlopes {
    public static let minimumSamples = 3

    /// One re-prime's two instants, on the RUN clock.
    public struct Cut: Equatable, Sendable {
        public var stopIssuedAtSeconds: Double
        public var restartedAtSeconds: Double
        public init(stopIssuedAtSeconds: Double, restartedAtSeconds: Double) { self.stopIssuedAtSeconds = stopIssuedAtSeconds; self.restartedAtSeconds = restartedAtSeconds }
    }

    /// With no cuts the whole series is ONE epoch. With cuts, `firstSampleRunClockSeconds` is required (nil: no epochs, never a guessed offset). Samples taken while the engine was
    /// stopped (between a stop and its restart) belong to no epoch. An epoch with no sample is left out.
    public static func compute(samples: [RingProbeSample], cuts: [Cut], firstSampleRunClockSeconds: Double?, tapRate: Double) -> [RingEpochSlope] {
        let usable = samples.filter { $0.readers.count == 2 }
        guard !usable.isEmpty else { return [] }
        var bounds: [(lo: Double, hi: Double)] = []
        if cuts.isEmpty {
            bounds = [(-Double.infinity, Double.infinity)]
        } else {
            guard let t0 = firstSampleRunClockSeconds else { return [] }
            var lo = -Double.infinity
            for c in cuts {
                bounds.append((lo, c.stopIssuedAtSeconds - t0))
                lo = c.restartedAtSeconds - t0
            }
            bounds.append((lo, Double.infinity))
        }
        let rateOK = tapRate > 0 && tapRate.isFinite
        var out: [RingEpochSlope] = []
        for (k, b) in bounds.enumerated() {
            let members = usable.filter { $0.elapsedSeconds >= b.lo && $0.elapsedSeconds < b.hi }
            guard let first = members.first, let last = members.last else { continue }
            var fps: [Double?] = [], ppm: [Double?] = []
            for r in 0..<2 {
                let s: Double? = members.count >= minimumSamples ? RingProbeAnalyzer.slopeOf(RingProbeAnalyzer.fillSeries(members, reader: r)) : nil
                fps.append(s)
                ppm.append(s.flatMap { rateOK ? $0 / tapRate * 1e6 : nil })
            }
            out.append(RingEpochSlope(
                index: k, startSeconds: first.elapsedSeconds, endSeconds: last.elapsedSeconds, sampleCount: members.count, slopeFramesPerSecond: fps, slopePPM: ppm,
                fillFirst: (0..<2).map { first.readers[$0].fill }, fillLast: (0..<2).map { last.readers[$0].fill },
                underruns: (0..<2).map { last.readers[$0].underrunBlocks &- first.readers[$0].underrunBlocks }))
        }
        return out
    }

    /// The epochs of a finished report: the cuts are its succeeded re-primes (a failed one ends the run and has no restart).
    public static func compute(report: RingProbeReport) -> [RingEpochSlope] {
        guard let tapRate = report.tapFormat?.sampleRate else { return [] }
        let cuts = (report.recovery?.rePrimes ?? []).compactMap { r -> Cut? in
            guard r.succeeded, let restart = r.restartedAtSeconds else { return nil }
            return Cut(stopIssuedAtSeconds: r.stopIssuedAtSeconds, restartedAtSeconds: restart)
        }
        return compute(samples: report.samples, cuts: cuts, firstSampleRunClockSeconds: report.timings.firstSampleRunClockSeconds, tapRate: tapRate)
    }
}
