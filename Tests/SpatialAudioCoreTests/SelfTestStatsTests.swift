import Testing
@testable import SpatialAudioCore

@Suite struct SelfTestStatsTests {
    @Test func medianOddEvenEmpty() {
        #expect(RobustStats.median([3, 1, 2]) == 2)
        #expect(RobustStats.median([4, 1, 3, 2]) == 2.5)
        #expect(RobustStats.median([]) == nil)
    }

    @Test func sigmaOfConstantIsZeroAndIgnoresOutliers() {
        #expect(RobustStats.sigma([5, 5, 5, 5]) == 0)
        let clean = (0..<99).map { Double($0 % 7) }
        let withOutlier = clean + [10_000]
        #expect(abs(RobustStats.sigma(withOutlier)! - RobustStats.sigma(clean)!) < 0.6)   // a standard deviation would explode
    }

    @Test func percentileIsNearestRank() {
        let xs = (1...100).map(Double.init)
        #expect(RobustStats.percentile(xs, 95) == 95)
        #expect(RobustStats.percentile(xs, 100) == 100)
        #expect(RobustStats.percentile(xs, 0) == 1)
        #expect(RobustStats.percentile([10, 20, 30], 95) == 30)      // ceil(0.95·3) = 3rd value
        #expect(RobustStats.percentile([30, 10, 20], 50) == 20)      // order-independent
        #expect(RobustStats.percentile([], 95) == nil)
    }

    @Test func nonFiniteValuesAreIgnored() {
        #expect(RobustStats.mean([1, .nan, 3, .infinity]) == 2)
        #expect(SeriesSummary([.nan]) == nil)
    }

    @Test func seriesSummaryFields() throws {
        let s = try #require(SeriesSummary((1...100).map(Double.init)))
        #expect(s.count == 100 && s.mean == 50.5 && s.p95 == 95 && s.max == 100)
        let ms = s.scaled(by: 1000)
        #expect(ms.mean == 50_500 && ms.max == 100_000)
    }

    @Test func statsAnalyzerComputesFpsAndLatencySeries() throws {
        // 90 frames at exactly 30 fps; delivery 80 ms except one 200 ms spike; watchdog ticks must be ignored.
        var frames: [SelfTestFrame] = (0..<90).map { k in
            SelfTestFrame(arrival: Double(k) / 30, captureTime: Double(k) / 30, angles: VisionFaceAngles(yaw: 0, pitch: 0, roll: 0),
                          frameMirrored: false, state: .locked, pose: .identity, qualityOverall: 1,
                          deliveryLatency: k == 45 ? 0.2 : 0.08, visionDuration: 0.014, totalLatency: k == 45 ? 0.22 : 0.1)
        }
        frames.append(SelfTestFrame(arrival: 3, captureTime: 3, angles: nil, frameMirrored: false, state: .holding, pose: .identity,
                                    qualityOverall: 0, isWatchdogTick: true, deliveryLatency: 9, visionDuration: 9, totalLatency: 9))
        let r = StatsAnalyzer.analyze(frames: frames, windowSeconds: 3, minimumFrames: 60)
        #expect(r.frameCount == 90 && r.sufficient)
        let fps = try #require(r.fpsMean)
        #expect(abs(fps - 30) < 0.01)
        let d = try #require(r.deliveryMs)
        #expect(d.max == 200 && abs(d.p95 - 80) < 1e-6 && d.mean > 80 && d.mean < 82)   // spike shows in max, not in p95
        let interval = try #require(r.frameIntervalMs)
        #expect(abs(interval.mean - 1000.0 / 30) < 0.01)
        #expect(r.facePresentFraction == 1)
    }

    @Test func aStallInFrameDeliveryIsReported() {
        func frames(skipping gap: Range<Int>) -> [SelfTestFrame] {
            (0..<120).filter { !gap.contains($0) }.map { k in
                SelfTestFrame(arrival: Double(k) / 30, captureTime: Double(k) / 30, angles: VisionFaceAngles(yaw: 0, pitch: 0, roll: 0),
                              frameMirrored: false, state: .locked, pose: .identity, qualityOverall: 1,
                              deliveryLatency: 0.08, visionDuration: 0.014, totalLatency: 0.094)
            }
        }
        let stalled = StatsAnalyzer.analyze(frames: frames(skipping: 50..<60), windowSeconds: 4, minimumFrames: 60)   // ~367 ms hole
        #expect(stalled.notes.contains { $0.contains("frame delivery stalled") && $0.contains("367 ms") })
        let regular = StatsAnalyzer.analyze(frames: frames(skipping: 0..<0), windowSeconds: 4, minimumFrames: 60)
        #expect(!regular.notes.contains { $0.contains("stalled") })
        // 66 ms frames (a camera dropping to 15 fps in low light) are slow but not a stall.
        let slowCamera = (0..<60).map { k in
            SelfTestFrame(arrival: Double(k) / 15, captureTime: Double(k) / 15, angles: nil, frameMirrored: false, state: .locked,
                          pose: .identity, qualityOverall: 1, deliveryLatency: 0, visionDuration: 0, totalLatency: 0)
        }
        #expect(!StatsAnalyzer.analyze(frames: slowCamera, windowSeconds: 4, minimumFrames: 60).notes.contains { $0.contains("stalled") })
    }

    @Test func statsWithTooFewFramesAreMarkedWeak() {
        let r = StatsAnalyzer.analyze(frames: [], windowSeconds: 30, minimumFrames: 150)
        #expect(!r.sufficient && r.fpsMean == nil && r.deliveryMs == nil && !r.notes.isEmpty)
    }
}
