import Foundation

// Step 6b-3c-0: level arithmetic for the offline calibration, pure. IMPLEMENTED-UNVERIFIED as a measurement of anything but itself.
//
// The question it serves (docs/STATUS.md "Step 6b-3c plan", decision 3): what does the HRTF graph (two sources at -30 / +30 degrees, 2 m) do to the level of a KNOWN input at output gain 1, so that a hard gain cap
// can be PROPOSED (never applied here) that keeps the rendered peak at or below -16 dB relative to a full-scale input? Nothing here is audible and nothing here says anything about loudness at the headphones.

public enum LevelMath {
    /// 20 log10 of an amplitude ratio; -infinity for 0.
    public static func amplitudeDecibels(_ ratio: Double) -> Double { 20 * log10(ratio) }

    public static func rms(_ xs: ArraySlice<Float>) -> Double {
        guard !xs.isEmpty else { return 0 }
        var sum = 0.0
        for x in xs { sum += Double(x) * Double(x) }
        return (sum / Double(xs.count)).squareRoot()
    }

    public static func peak(_ xs: ArraySlice<Float>) -> Double {
        var p = 0.0
        for x in xs { p = max(p, Double(abs(x))) }
        return p
    }
}

public enum GainCapProposal {
    /// The registered target: the rendered peak at or below this many dB relative to a full-scale input (decision 3 of the approved 6b-3c plan; a GUESS, approved by Sanjai as a target to PROPOSE against).
    public static let targetPeakDecibels = -16.0

    /// The largest gain (output volume, 0 to 1) at which the WORST full-scale peak gain stays at or below the target, rounded DOWN to two decimals. nil for a peak gain that is not a positive finite number.
    public static func propose(worstFullScalePeakGain: Double, targetDecibels: Double = targetPeakDecibels) -> Double? {
        guard worstFullScalePeakGain.isFinite, worstFullScalePeakGain > 0 else { return nil }
        let raw = pow(10, targetDecibels / 20) / worstFullScalePeakGain
        return min(1, (raw * 100).rounded(.down) / 100)
    }
}
