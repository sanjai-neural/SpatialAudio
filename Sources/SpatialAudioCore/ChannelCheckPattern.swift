import Foundation

// Step 6b-3c-0: a SYNTHETIC channel-check test file, pure logic. IMPLEMENTED-UNVERIFIED.
//
// The question it serves (docs/STATUS.md "Step 6b-3c plan", docs/MANUAL_TEST_STEP6B3C0.md): the mute experiments and the first audible run need ONE long-lived player process whose PID does not change, playing a signal whose
// channels can be told apart by ear. The pattern is generated here, not recorded: no copyrighted audio and no captured audio. It is NOT music and says nothing about how music will sound.
//
// Pattern: 44,100 Hz, 16-bit PCM, stereo. A 30 s cycle of three 10 s segments: LEFT only, RIGHT only, BOTH (the same samples in both channels). Each segment holds ten 1 s units: 0.5 s of noise burst (10 ms linear
// fades in and out, so no click) and 0.5 s of silence. The noise is a deterministic function of the frame index (SplitMix64), uniform in [-1, 1), scaled to a peak of 0.0316 = -30 dBFS. The inactive channel is exactly 0.

public enum ChannelCheckPattern {
    public static let sampleRate = 44_100
    public static let channels = 2
    /// 0.0316 = -30.0 dBFS peak (20 log10 0.0316 = -30.0). A known low level; with the system volume low the file is quiet.
    public static let peakAmplitude: Float = 0.0316
    public static let burstFrames = 22_050              // 0.5 s
    public static let unitFrames = 44_100               // one burst and one gap: 1 s
    public static let burstsPerSegment = 10
    public static let segmentFrames = unitFrames * burstsPerSegment     // 10 s
    public static let cycleFrames = segmentFrames * 3                    // 30 s
    public static let fadeFrames = 441                  // 10 ms
    /// The tool's limits: long enough that ONE afplay process plays it (15 minutes or more); and the WAV data chunk stays far below 4 GiB.
    public static let minimumSeconds = 900
    public static let maximumSeconds = 3600
    static let seed: UInt64 = 0x5A3C_0C0F_FEE1_2345

    /// A problem with the requested duration, or nil.
    public static func validate(seconds: Int) -> String? {
        if seconds < minimumSeconds { return "the file must be at least \(minimumSeconds) s (15 minutes) so that ONE player process plays it from start to end" }
        if seconds > maximumSeconds { return "the file is limited to \(maximumSeconds) s" }
        return nil
    }

    /// Deterministic noise in [-1, 1) for a frame index.
    static func noise(_ index: Int64) -> Float {
        var z = seed &+ UInt64(bitPattern: index) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(Double(z >> 11) / Double(1 << 53) * 2 - 1)
    }

    /// The sample pair of one frame, as floats.
    public static func frame(_ index: Int64) -> (left: Float, right: Float) {
        let pos = Int(index % Int64(cycleFrames))
        let segment = pos / segmentFrames
        let k = (pos % segmentFrames) % unitFrames
        guard k < burstFrames else { return (0, 0) }
        let fadeIn = Float(k) / Float(fadeFrames)
        let fadeOut = Float(burstFrames - 1 - k) / Float(fadeFrames)
        let envelope = min(1, fadeIn, fadeOut)
        let v = noise(index) * peakAmplitude * envelope
        switch segment {
        case 0: return (v, 0)
        case 1: return (0, v)
        default: return (v, v)
        }
    }

    /// Float to 16-bit, rounded to nearest and clipped to +/-1.
    public static func quantize(_ x: Float) -> Int16 {
        let c = min(max(x, -1), 1)
        return Int16((c * 32767).rounded())
    }

    /// Interleaved little-endian 16-bit PCM for `count` frames starting at `startFrame`.
    public static func pcm16(startFrame: Int64, count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count * 4)
        for i in 0..<count {
            let f = frame(startFrame + Int64(i))
            let l = UInt16(bitPattern: quantize(f.left)), r = UInt16(bitPattern: quantize(f.right))
            out.append(UInt8(l & 0xFF)); out.append(UInt8(l >> 8))
            out.append(UInt8(r & 0xFF)); out.append(UInt8(r >> 8))
        }
        return out
    }

    /// The 44-byte RIFF/WAVE header of a 16-bit PCM stereo file of `frames` frames.
    public static func wavHeader(frames: Int64) -> [UInt8] {
        let dataBytes = UInt32(frames * 4)
        var h: [UInt8] = []
        func u32(_ v: UInt32) { for s in [0, 8, 16, 24] { h.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
        func u16(_ v: UInt16) { h.append(UInt8(v & 0xFF)); h.append(UInt8(v >> 8)) }
        h += Array("RIFF".utf8); u32(36 + dataBytes); h += Array("WAVE".utf8)
        h += Array("fmt ".utf8); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        h += Array("data".utf8); u32(dataBytes)
        return h
    }

    public struct Statistics: Equatable, Sendable {
        public var peakAmplitude: Float
        public var leftRMS: Double
        public var rightRMS: Double
    }

    /// Peak and per-channel RMS over the first `frames` frames of the pattern (float values, before quantizing).
    public static func statistics(frames: Int64) -> Statistics {
        var peak: Float = 0, sl = 0.0, sr = 0.0
        for i in 0..<frames {
            let f = frame(i)
            peak = max(peak, abs(f.left), abs(f.right))
            sl += Double(f.left) * Double(f.left); sr += Double(f.right) * Double(f.right)
        }
        let n = max(Double(frames), 1)
        return Statistics(peakAmplitude: peak, leftRMS: (sl / n).squareRoot(), rightRMS: (sr / n).squareRoot())
    }
}
