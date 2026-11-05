import Foundation

/// The test signal for the listening tests: a seamless 2 s loop of pink-ish noise bursts.
///
/// Why noise bursts and not a sine: a pure tone carries almost no spectral (pinna) cue, so HRTF rendering of it is
/// hard to place and front/back flips are common; broadband noise with clear onsets is what localization tests use.
/// The loop is generated once, off the audio thread, and played by `AVAudioPlayerNode` (`.loops`), so there is no
/// render callback of ours at all in Step 3a (see docs/ARCHITECTURE.md, "Real-time rule").
///
/// Layout of one 0.5 s cell: 0.2 s silence, then a 0.3 s burst with 10 ms raised-cosine ramps. Four cells per loop.
/// The loop starts and ends in silence, so the seam cannot click. Generation is deterministic (fixed seed).
public struct TestTone: Equatable, Sendable {
    public var sampleRate: Double
    public var cycleSeconds = 0.5
    public var burstSeconds = 0.3
    public var rampSeconds = 0.010
    public var cyclesPerLoop = 4
    /// RMS level inside the bursts, in dBFS. UNTUNED comfort level (about -26 dBFS RMS, peaks well below 0.5);
    /// the user still sets the real loudness with the system volume and the slider.
    public var burstRMSDecibels = -26.0
    public var seed: UInt64 = 0x5A17_A0D1

    public init(sampleRate: Double = 48_000) { self.sampleRate = sampleRate }

    public var cycleFrames: Int { max(1, Int((cycleSeconds * sampleRate).rounded())) }
    public var burstFrames: Int { min(cycleFrames, max(1, Int((burstSeconds * sampleRate).rounded()))) }
    public var loopFrames: Int { cycleFrames * max(1, cyclesPerLoop) }

    /// Frame range of burst `index` within the loop (for tests and for measuring only the loud parts).
    public func burstRange(_ index: Int) -> Range<Int> {
        let start = index * cycleFrames + (cycleFrames - burstFrames)
        return start..<(start + burstFrames)
    }

    public func makeLoop() -> [Float] {
        let cell = cycleFrames, burst = burstFrames
        let ramp = max(1, min(Int((rampSeconds * sampleRate).rounded()), burst / 2))
        let total = loopFrames

        var rng = SplitMix64(state: seed)
        var b0 = 0.0, b1 = 0.0, b2 = 0.0                          // pinking filter state (Kellet "economy" form)
        let a = 1 / (1 + 2 * Double.pi * 100 / sampleRate)           // one-pole high-pass at about 100 Hz (removes DC / rumble)
        var hpY = 0.0, hpX = 0.0

        var signal = [Double](repeating: 0, count: total)
        var sumSquares = 0.0, loud = 0
        for i in 0..<total {
            let white = Double(rng.next() >> 11) / Double(1 << 53) * 2 - 1
            b0 = 0.99765 * b0 + white * 0.0990460
            b1 = 0.96300 * b1 + white * 0.2965164
            b2 = 0.57000 * b2 + white * 1.0526913
            let pink = b0 + b1 + b2 + white * 0.1848
            hpY = a * (hpY + pink - hpX)
            hpX = pink

            let pos = i % cell - (cell - burst)                      // negative = in the silent part of the cell
            guard pos >= 0 else { continue }
            let rampIn = pos < ramp ? 0.5 * (1 - cos(Double.pi * Double(pos) / Double(ramp))) : 1
            let fromEnd = burst - 1 - pos
            let rampOut = fromEnd < ramp ? 0.5 * (1 - cos(Double.pi * Double(fromEnd) / Double(ramp))) : 1
            let v = hpY * rampIn * rampOut
            signal[i] = v
            sumSquares += v * v; loud += 1
        }

        let rms = loud > 0 ? (sumSquares / Double(loud)).squareRoot() : 0
        let gain = rms > 0 ? pow(10, burstRMSDecibels / 20) / rms : 0
        return signal.map { Float(min(max($0 * gain, -0.5), 0.5)) }
    }
}

/// Small deterministic generator (SplitMix64) so the test tone is identical on every run.
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
