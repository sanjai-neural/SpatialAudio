import Testing
import Foundation
@testable import SpatialAudioEngine

@Suite struct TestToneTests {
    let tone = TestTone(sampleRate: 48_000)

    func rms(_ x: ArraySlice<Float>) -> Double {
        (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
    }

    @Test func theLoopHasTheDocumentedLayout() {
        #expect(tone.cycleFrames == 24_000 && tone.burstFrames == 14_400 && tone.loopFrames == 96_000)
        let samples = tone.makeLoop()
        #expect(samples.count == tone.loopFrames)
        for c in 0..<tone.cyclesPerLoop {
            let silent = samples[(c * tone.cycleFrames)..<tone.burstRange(c).lowerBound]
            #expect(silent.allSatisfy { $0 == 0 }, "cell \(c) should start with 0.2 s of exact silence")
            #expect(silent.count == 9_600)
        }
    }

    @Test func burstsAreAtTheTargetLevelAndStayWellBelowFullScale() {
        let samples = tone.makeLoop()
        for c in 0..<tone.cyclesPerLoop {
            let level = 20 * log10(rms(samples[tone.burstRange(c)]))
            #expect(abs(level - tone.burstRMSDecibels) < 0.5, "burst \(c) is \(level) dBFS")
        }
        #expect(samples.map { abs($0) }.max()! <= 0.5)
    }

    @Test func theSeamCannotClickBecauseTheLoopStartsAndEndsInSilence() {
        let s = tone.makeLoop()
        #expect(s.first == 0 && s.last == 0)
        // The burst ramps down to exactly zero on its last sample, and the first cell begins silent.
        #expect(abs(s[s.count - 2]) < 0.05 && abs(s[s.count - 1]) < 1e-6)
    }

    @Test func burstsFadeInAndOutOverTenMilliseconds() {
        let s = tone.makeLoop()
        let r = tone.burstRange(0)
        let ramp = Int(0.010 * 48_000)
        let head = rms(s[r.lowerBound..<(r.lowerBound + ramp)]), body = rms(s[(r.lowerBound + ramp)..<(r.lowerBound + 2 * ramp)])
        #expect(head < 0.7 * body, "the first 10 ms should be quieter than the next 10 ms")
        let tail = rms(s[(r.upperBound - ramp)..<r.upperBound]), before = rms(s[(r.upperBound - 2 * ramp)..<(r.upperBound - ramp)])
        #expect(tail < 0.7 * before)
    }

    @Test func isDeterministicAndTheSeedMatters() {
        #expect(tone.makeLoop() == tone.makeLoop())
        var other = tone; other.seed = 42
        #expect(other.makeLoop() != tone.makeLoop())
    }

    @Test func hasNoDCAndEnoughHighFrequencyEnergyForHRTFCues() {
        let burst = Array(tone.makeLoop()[tone.burstRange(1)]).map(Double.init)
        let mean = burst.reduce(0, +) / Double(burst.count)
        let level = (burst.reduce(0) { $0 + $1 * $1 } / Double(burst.count)).squareRoot()
        #expect(abs(mean) < 0.05 * level, "DC offset \(mean) vs RMS \(level)")

        // Energy above 2 kHz through a 2nd-order high-pass (RBJ cookbook, Q = 0.707). Pink noise has about 45% of its
        // energy above 2 kHz; a low-frequency rumble would have almost none, which is what this guards against.
        let w0 = 2 * Double.pi * 2000 / 48_000, alpha = sin(w0) / (2 * 0.7071)
        let b0 = (1 + cos(w0)) / 2, b1 = -(1 + cos(w0)), b2 = b0
        let a0 = 1 + alpha, a1 = -2 * cos(w0), a2 = 1 - alpha
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0, high = 0.0, all = 0.0
        for x in burst {
            let y = (b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
            x2 = x1; x1 = x; y2 = y1; y1 = y
            high += y * y; all += x * x
        }
        #expect(high / all > 0.2, "only \(high / all) of the energy is above 2 kHz")
    }

    @Test func otherSampleRatesAlsoLoopCleanly() {
        for rate in [44_100.0, 96_000.0] {
            let t = TestTone(sampleRate: rate)
            let s = t.makeLoop()
            #expect(s.count == t.loopFrames)
            #expect(Double(t.loopFrames) / rate == 2.0)
            #expect(s.first == 0 && s.last == 0)
            #expect(abs(20 * log10(rms(s[t.burstRange(2)])) - t.burstRMSDecibels) < 0.5)
        }
    }
}
