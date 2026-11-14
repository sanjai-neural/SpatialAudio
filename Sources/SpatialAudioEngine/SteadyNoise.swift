import Foundation

/// The source sound of head-tracked listening (Step 3b): CONTINUOUS pink-ish noise, a seamless loop with no gaps.
///
/// Why this and not the old 0.3 s burst loop (`TestTone`): while you turn your head the bursts come and go, so there is nothing to follow between them. Why noise and
/// not a sine: a pure tone carries almost no spectral (pinna) cue, so an HRTF cannot place it. A steady broadband noise is audible all the time and carries the cues; its
/// drawback is that it can sound like a hiss and, without onsets, front/back is harder (a moving head helps). The level is an UNTUNED comfort guess (-30 dBFS RMS);
/// the real loudness is the system volume times the card's slider.
///
/// Seam: the loop is N samples of a longer noise stream whose first `crossfade` samples are an equal-power blend of the stream's samples N.. and 0.. , so the last sample
/// continues into the first one as the original noise does (no click, no level dip: uncorrelated noise keeps its power under an equal-power crossfade).
/// Generation is deterministic (fixed seed) and runs off the audio thread; the loop is played by Apple's player node (no render callback of ours).
public struct SteadyNoise: Equatable, Sendable {
    public var sampleRate: Double
    public var loopSeconds = 4.0
    public var crossfadeSeconds = 0.25
    /// RMS level of the whole loop in dBFS. UNTUNED.
    public var rmsDecibels = -30.0
    public var seed: UInt64 = 0x57EA_D1A0_5EED_0001

    public init(sampleRate: Double = 48_000) { self.sampleRate = sampleRate }

    public var loopFrames: Int { max(2, Int((loopSeconds * sampleRate).rounded())) }
    public var crossfadeFrames: Int { min(max(1, Int((crossfadeSeconds * sampleRate).rounded())), loopFrames / 2) }

    public func makeLoop() -> [Float] {
        let n = loopFrames, x = crossfadeFrames
        var rng = SplitMix64(state: seed)
        var b0 = 0.0, b1 = 0.0, b2 = 0.0                          // pinking filter state (Kellet "economy" form, as in TestTone)
        let a = 1 / (1 + 2 * Double.pi * 100 / sampleRate)           // one-pole high-pass at about 100 Hz (removes DC / rumble)
        var hpY = 0.0, hpX = 0.0

        var stream = [Double](repeating: 0, count: n + x)
        for i in 0..<(n + x) {
            let white = Double(rng.next() >> 11) / Double(1 << 53) * 2 - 1
            b0 = 0.99765 * b0 + white * 0.0990460
            b1 = 0.96300 * b1 + white * 0.2965164
            b2 = 0.57000 * b2 + white * 1.0526913
            let pink = b0 + b1 + b2 + white * 0.1848
            hpY = a * (hpY + pink - hpX)
            hpX = pink
            stream[i] = hpY
        }

        var loop = [Double](repeating: 0, count: n)
        for i in 0..<n {
            if i < x {
                let u = (Double(i) + 0.5) / Double(x)
                loop[i] = stream[n + i] * cos(Double.pi / 2 * u) + stream[i] * sin(Double.pi / 2 * u)
            } else {
                loop[i] = stream[i]
            }
        }

        var sumSquares = 0.0
        for v in loop { sumSquares += v * v }
        let rms = (sumSquares / Double(n)).squareRoot()
        let gain = rms > 0 ? pow(10, rmsDecibels / 20) / rms : 0
        return loop.map { Float(min(max($0 * gain, -0.5), 0.5)) }
    }
}
