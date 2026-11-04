import Foundation

/// Small statistics helpers. All return nil for empty input and ignore non-finite values.
public enum RobustStats {
    public static func mean(_ xs: [Double]) -> Double? {
        let v = xs.filter(\.isFinite)
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    public static func median(_ xs: [Double]) -> Double? {
        let s = xs.filter(\.isFinite).sorted()
        guard !s.isEmpty else { return nil }
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// 1.4826 × median absolute deviation: a standard-deviation estimate that ignores outliers.
    public static func sigma(_ xs: [Double]) -> Double? {
        guard let m = median(xs), let mad = median(xs.map { abs($0 - m) }) else { return nil }
        return 1.4826 * mad
    }

    /// Nearest-rank percentile, `p` in 0...100: the smallest sample such that at least p % of the
    /// samples are less than or equal to it.
    public static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        let s = xs.filter(\.isFinite).sorted()
        guard !s.isEmpty else { return nil }
        let rank = Int((p / 100 * Double(s.count)).rounded(.up))
        return s[min(max(rank, 1), s.count) - 1]
    }
}

/// mean / p95 / max of a series (units are the caller's). p95 is nearest-rank.
public struct SeriesSummary: Codable, Equatable, Sendable {
    public var count: Int
    public var mean: Double
    public var p95: Double
    public var max: Double

    public init(count: Int, mean: Double, p95: Double, max: Double) {
        self.count = count; self.mean = mean; self.p95 = p95; self.max = max
    }

    /// nil when there are no finite samples.
    public init?(_ xs: [Double]) {
        let v = xs.filter(\.isFinite)
        guard let mean = RobustStats.mean(v), let p95 = RobustStats.percentile(v, 95), let mx = v.max() else { return nil }
        self.init(count: v.count, mean: mean, p95: p95, max: mx)
    }

    public func scaled(by k: Double) -> SeriesSummary {
        SeriesSummary(count: count, mean: mean * k, p95: p95 * k, max: max * k)
    }
}
