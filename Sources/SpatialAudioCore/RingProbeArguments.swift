import Foundation

// Step 6b-2: the command-line switches of the ring probe, parsed here (pure, unit-tested) so the app module only forwards.
//
//   --ring-probe <seconds>            the REAL tap into the ring and a real-time AVAudioEngine at output gain 0 (1 ... 600 s)
//   --ring-probe-simulate <seconds>   the same flow on a SIMULATED source (no Core Audio, no device); the report says SIMULATED
//   --ring-probe-recovery <seconds>           (Step 6b-3a-2) the same as --ring-probe, plus the control-thread re-prime (stop the engine, re-prime, wait for T, restart); gain stays 0
//   --ring-probe-recovery-simulate <seconds>  the recovery mode on the SIMULATED source; the report says SIMULATED
//   --ring-probe-device-tap           (Step 6b-3b, a modifier of any of the four flags above; no value) build the tap BOUND TO THE DEFAULT OUTPUT DEVICE'S STREAM instead of the global
//                                     mixdown; the run then checks the tap's format and rate against the output device (docs/MANUAL_TEST_STEP6B3B.md). Gain stays 0.
//   --ring-sim-underrun=<at>,<stall>  (simulate only) the simulated producer stalls for <stall> s, <at> s after it started
//   --ring-sim-ppm=<n>                (simulate only) the simulated producer runs n ppm faster (+) or slower (-)
//
// There is deliberately no switch for the output gain: the mode forces it to 0, and any argument that names a gain or a volume is REFUSED (exit status 2)
// instead of being silently ignored.

public struct RingProbeRequest: Equatable, Sendable {
    public var seconds: Double
    public var simulate: Bool
    public var simulatedProducerPPM: Double
    public var simulatedUnderrunAtSeconds: Double?
    public var simulatedUnderrunStallSeconds: Double
    /// Step 6b-3a-2: run with the re-prime controller (`--ring-probe-recovery`, `--ring-probe-recovery-simulate`).
    public var recovery: Bool = false
    /// Step 6b-3b: `--ring-probe-device-tap`.
    public var deviceTap: Bool = false
    /// Step 6b-3c-0: `--ring-probe-process-pid=<pid>`: tap that ONE process only (never combined with `--ring-probe-device-tap`).
    public var processPID: Int32?
    /// `--ring-probe-tap-mute=...` (only with a process pid). The default is unmuted.
    public var tapMute: RingProbeMuteBehavior = RingProbeMuteBehavior.defaultBehavior
    /// `--ring-probe-mute-scenario=destroy-tap@<s>|stop-io@<s>` (only with a process pid).
    public var muteScenario: MuteScenario?
}

public enum RingProbeArguments {
    public enum Parsed: Equatable, Sendable {
        case notRequested
        case request(RingProbeRequest)
        case invalid(String)
    }

    public static func parse(_ arguments: [String]) -> Parsed {
        var seconds: Double?, simulate = false, sawFlag = false, recovery = false, deviceTap = false, sawDeviceTap = false
        var processPID: Int32?, sawProcessPID = false, tapMute = RingProbeMuteBehavior.defaultBehavior, sawTapMute = false, muteScenario: MuteScenario?, sawScenario = false
        var ppm = 0.0, underrunAt: Double?, underrunStall = 0.0, sawSimOption = false
        var invalid: String?
        var iterator = arguments.dropFirst().makeIterator()
        while let a = iterator.next() {
            let name = a.split(separator: "=", maxSplits: 1).first.map(String.init) ?? a
            if name == "--ring-probe-process-pid" {
                if sawProcessPID { invalid = invalid ?? "give --ring-probe-process-pid once" }
                sawProcessPID = true
                let value = a.contains("=") ? String(a.drop { $0 != "=" }.dropFirst()) : ""
                if let pid = Int32(value), pid > 0 { processPID = pid } else { invalid = invalid ?? "--ring-probe-process-pid=<pid> needs a positive process id, got: \(value.isEmpty ? "(missing)" : value)" }
            } else if name == "--ring-probe-tap-mute" {
                sawTapMute = true
                let value = a.contains("=") ? String(a.drop { $0 != "=" }.dropFirst()) : ""
                if let m = RingProbeMuteBehavior.parse(value) { tapMute = m } else { invalid = invalid ?? "--ring-probe-tap-mute needs unmuted, muted or mutedwhentapped, got: \(value.isEmpty ? "(missing)" : value)" }
            } else if name == "--ring-probe-mute-scenario" {
                sawScenario = true
                let value = a.contains("=") ? String(a.drop { $0 != "=" }.dropFirst()) : ""
                if let sc = MuteScenario.parse(value) { muteScenario = sc } else { invalid = invalid ?? "--ring-probe-mute-scenario needs destroy-tap@<seconds> or stop-io@<seconds> (seconds above 0), got: \(value.isEmpty ? "(missing)" : value)" }
            } else if name == "--ring-probe-device-tap" {
                if a.contains("=") { invalid = invalid ?? "--ring-probe-device-tap takes no value" }
                if sawDeviceTap { invalid = invalid ?? "give --ring-probe-device-tap once" }
                sawDeviceTap = true
                deviceTap = true
            } else if ["--ring-probe", "--ring-probe-simulate", "--ring-probe-recovery", "--ring-probe-recovery-simulate"].contains(name) {
                if sawFlag { invalid = invalid ?? "give one of --ring-probe, --ring-probe-simulate, --ring-probe-recovery, --ring-probe-recovery-simulate, once" }
                sawFlag = true
                simulate = name.hasSuffix("-simulate")
                recovery = name.hasPrefix("--ring-probe-recovery")
                let value: String? = a.contains("=") ? String(a.drop { $0 != "=" }.dropFirst()) : iterator.next()
                if let value, let s = Double(value) { seconds = s } else { invalid = invalid ?? "needs a number of seconds, got: \(value ?? "(missing)")" }
            } else if a.hasPrefix("--ring-sim-underrun=") {
                sawSimOption = true
                let parts = a.dropFirst("--ring-sim-underrun=".count).split(separator: ",").map { Double($0) }
                if parts.count == 2, let at = parts[0], let stall = parts[1], at >= 0, stall > 0, at.isFinite, stall.isFinite { underrunAt = at; underrunStall = stall }
                else { invalid = invalid ?? "--ring-sim-underrun needs <at>,<stall> in seconds (at >= 0, stall > 0)" }
            } else if a.hasPrefix("--ring-sim-ppm=") {
                sawSimOption = true
                if let v = Double(a.dropFirst("--ring-sim-ppm=".count)), v.isFinite, abs(v) <= 100_000 { ppm = v }
                else { invalid = invalid ?? "--ring-sim-ppm needs a number within +/- 100000" }
            }
        }
        guard sawFlag || sawSimOption || sawDeviceTap || sawProcessPID || sawTapMute || sawScenario else { return .notRequested }
        if !sawFlag {
            let needs = "one of --ring-probe, --ring-probe-simulate, --ring-probe-recovery, --ring-probe-recovery-simulate"
            return .invalid(sawSimOption ? "--ring-sim-* needs --ring-probe-simulate <seconds>" : (sawDeviceTap ? "--ring-probe-device-tap needs \(needs)" : "--ring-probe-process-pid, --ring-probe-tap-mute and --ring-probe-mute-scenario need \(needs)"))
        }
        // No gain option exists. Naming one is refused, so nobody believes it took effect.
        if let g = arguments.dropFirst().first(where: { $0.hasPrefix("--") && ($0.lowercased().contains("gain") || $0.lowercased().contains("volume")) }) {
            return .invalid("there is no gain or volume option (\(g.prefix(24))): this mode runs at output gain 0 and cannot be changed")
        }
        if let invalid { return .invalid(invalid) }
        if sawProcessPID && sawDeviceTap { return .invalid("--ring-probe-process-pid and --ring-probe-device-tap are two different taps: give one") }
        if (sawTapMute || sawScenario) && !sawProcessPID { return .invalid("--ring-probe-tap-mute and --ring-probe-mute-scenario exist only with --ring-probe-process-pid (a mute is never applied to the all-but-us tap)") }
        guard let seconds else { return .invalid("needs a number of seconds") }
        if let problem = RingProbeRunner.validate(seconds: seconds) { return .invalid(problem) }
        if sawSimOption && !simulate { return .invalid("--ring-sim-* options exist only with --ring-probe-simulate") }
        return .request(RingProbeRequest(seconds: seconds, simulate: simulate, simulatedProducerPPM: ppm, simulatedUnderrunAtSeconds: underrunAt,
                                         simulatedUnderrunStallSeconds: underrunStall, recovery: recovery, deviceTap: deviceTap, processPID: processPID, tapMute: tapMute, muteScenario: muteScenario))
    }
}
