import Testing
import Foundation
@testable import SpatialAudioCore

@Suite struct OneEuroFilterTests {
    private func stddev(_ xs: [Double]) -> Double {
        let m = xs.reduce(0, +) / Double(xs.count)
        return (xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)).squareRoot()
    }

    @Test func firstSamplePassesThrough() {
        var f = OneEuroFilter()
        #expect(f.filter(5, at: 0) == 5)
    }

    @Test func constantSignalStaysConstant() {
        var f = OneEuroFilter()
        for i in 0..<100 { #expect(abs(f.filter(3.25, at: Double(i) / 60) - 3.25) < 1e-12) }
    }

    @Test func stepResponseIsMonotonicAndConverges() {
        var f = OneEuroFilter(parameters: .init(minCutoff: 1, beta: 0))
        _ = f.filter(0, at: 0)
        var prev = 0.0
        var last = 0.0
        for i in 1...600 {
            last = f.filter(1, at: Double(i) / 60)
            #expect(last >= prev)
            #expect(last <= 1 + 1e-12)
            prev = last
        }
        #expect(abs(last - 1) < 1e-3)
    }

    @Test func reducesJitterOnStationarySignal() {
        var rng = DeterministicNoise(seed: 42)
        var f = OneEuroFilter(parameters: .init(minCutoff: 1, beta: 0))
        var raw: [Double] = [], out: [Double] = []
        for i in 0..<600 {
            let x = rng.next()
            raw.append(x)
            out.append(f.filter(x, at: Double(i) / 60))
        }
        #expect(stddev(Array(out.dropFirst(60))) < 0.4 * stddev(Array(raw.dropFirst(60))))
    }

    @Test func higherBetaReducesLagOnFastRamp() {
        func lag(beta: Double) -> Double {
            var f = OneEuroFilter(parameters: .init(minCutoff: 1, beta: beta))
            var err = 0.0
            for i in 0..<120 {
                let t = Double(i) / 60
                let x = 10 * t                  // 10 units/s ramp
                err = x - f.filter(x, at: t)
            }
            return err
        }
        #expect(lag(beta: 2) < 0.5 * lag(beta: 0))
    }

    @Test func nonIncreasingTimestampReturnsPreviousOutput() {
        var f = OneEuroFilter()
        _ = f.filter(0, at: 0)
        let a = f.filter(1, at: 0.016)
        #expect(f.filter(100, at: 0.016) == a)   // same timestamp
        #expect(f.filter(100, at: 0.010) == a)   // earlier timestamp
    }

    @Test func largeGapRestartsFromNewSample() {
        var f = OneEuroFilter()
        _ = f.filter(0, at: 0)
        #expect(f.filter(50, at: 5) == 50)
    }

    @Test func nonFiniteInputIsIgnored() {
        var f = OneEuroFilter()
        _ = f.filter(1, at: 0)
        let a = f.filter(2, at: 0.016)
        #expect(f.filter(.nan, at: 0.032) == a)
    }
}

@Suite struct OneEuroQuaternionFilterTests {
    @Test func firstSamplePassesThroughAndOutputIsUnit() {
        var f = OneEuroQuaternionFilter()
        let q = eulerQ(20, 10, 5)
        #expect(angleDeg(f.filter(q, at: 0), q) < 1e-9)
    }

    @Test func constantOrientationStaysConstant() {
        var f = OneEuroQuaternionFilter()
        let q = eulerQ(20, 10, 5)
        for i in 0..<100 { #expect(angleDeg(f.filter(q, at: Double(i) / 60), q) < 1e-9) }
    }

    @Test func reducesAngularJitter() {
        var rng = DeterministicNoise(seed: 7)
        var f = OneEuroQuaternionFilter(parameters: .init(minCutoff: 1, beta: 0))
        var rawErr = 0.0, outErr = 0.0
        var n = 0
        for i in 0..<600 {
            let noisy = eulerQ(2 * rng.next(), 2 * rng.next(), 2 * rng.next())  // ±2° noise around identity
            let out = f.filter(noisy, at: Double(i) / 60)
            if i >= 60 { rawErr += angleDeg(noisy, .identity); outErr += angleDeg(out, .identity); n += 1 }
        }
        #expect(outErr / Double(n) < 0.5 * rawErr / Double(n))
    }

    @Test func followsRotationAndConverges() {
        var f = OneEuroQuaternionFilter()
        let target = yawQ(60)
        _ = f.filter(.identity, at: 0)
        var last = Quaternion.identity
        for i in 1...300 { last = f.filter(target, at: Double(i) / 60) }
        #expect(angleDeg(last, target) < 0.1)
    }

    @Test func negatedQuaternionDoesNotCauseJump() {
        var f = OneEuroQuaternionFilter()
        let q = yawQ(30)
        let a = f.filter(q, at: 0)
        let b = f.filter(Quaternion(w: -q.w, x: -q.x, y: -q.y, z: -q.z), at: 1.0 / 60)
        #expect(angleDeg(a, b) < 1e-6)
    }

    @Test func nonFiniteInputReturnsPreviousOutput() {
        var f = OneEuroQuaternionFilter()
        _ = f.filter(yawQ(10), at: 0)
        let a = f.filter(yawQ(12), at: 1.0 / 60)
        let b = f.filter(Quaternion(w: .nan, x: 0, y: 0, z: 0), at: 2.0 / 60)
        #expect(b == a)
    }
}
