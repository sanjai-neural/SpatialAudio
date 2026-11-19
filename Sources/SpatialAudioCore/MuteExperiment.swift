import Foundation

// Step 6b-3c-0: the mute-failure experiments of a PROCESS-SPECIFIC tap, and the plain types around them. IMPLEMENTED-UNVERIFIED: nothing here has seen a real muted tap.
//
// The question this file serves (docs/STATUS.md "Step 6b-3c plan", docs/ARCHITECTURE.md section 3 "Muting the original", docs/MANUAL_TEST_STEP6B3C0.md): if our process holds a tap on the TEST PLAYER ONLY with a mute behaviour,
// does the player's audio come back, and how fast, when the tap goes away in each of five ways (a normal exit, SIGINT, SIGKILL, the tap destroyed while IO runs, IO stopped while the tap lives)? The headers say nothing about
// that (CATapDescription.h defines the three behaviours and AudioHardwareDestroyProcessTap only "destroys the given Tap"). **If the audio does not come back in any scenario, muting is not shipped** (ARCHITECTURE section 3).
//
// The criteria below are "pre-registered GUESS, fixed before the run". They were written BEFORE the code that uses them and before any run. If one is ever changed, `MuteExperimentCriteria.version` changes with it and
// docs/STATUS.md records what changed and why. The observations are Sanjai's (by ear and stopwatch); the evaluator only applies the registered rule to the numbers he reports. Nothing here is audible from our engine:
// the probe runs at output gain 0 and has no gain option.

// MARK: - The pre-registered criteria

public enum MuteScenarioKind: String, CaseIterable, Codable, Sendable {
    case normalExit = "normal-exit"
    case sigint = "sigint"
    case sigkill = "sigkill"
    case tapDestroyedWhileIORuns = "destroy-tap"
    case ioStoppedWhileTapLives = "stop-io"
}

public enum MuteExperimentCriteria {
    /// Bump with any change below and record it in docs/STATUS.md.
    public static let version = "6b-3c0-prereg-1"
    public static let registration = "pre-registered GUESS, fixed before the run"
    /// After the scenario's event the test player's audio must be audible again within this many seconds (inclusive). A GUESS, not a measurement.
    public static let returnWithinSeconds = 5.0
    /// Every one of these must be observed, once each, for a verdict other than noGo. Sleep and wake are NOT in this step.
    public static let requiredScenarios: [MuteScenarioKind] = [.normalExit, .sigint, .sigkill, .tapDestroyedWhileIORuns, .ioStoppedWhileTapLives]
}

public enum MuteObservationValue: Equatable, Sendable {
    /// The player's audio was heard again this many seconds after the scenario's event.
    case returned(seconds: Double)
    /// It was not heard again within the observation window (the manual says how long Sanjai waits).
    case neverReturned
    /// The player's audio never went silent while the probe ran: the mute did not take effect, so the scenario says nothing (a control failure, not a success).
    case neverMuted
}

public struct MuteObservation: Equatable, Sendable {
    public var kind: MuteScenarioKind
    public var value: MuteObservationValue
    public init(kind: MuteScenarioKind, value: MuteObservationValue) { self.kind = kind; self.value = value }
}

public enum MuteExperimentVerdictKind: String, Codable, Sendable, Equatable {
    /// Every required scenario returned within the window.
    case go
    /// At least one scenario failed: muting is not shipped.
    case noGo
    /// No failure, but at least one scenario never muted: the experiment did not test it.
    case inconclusive
    /// A required scenario is missing, duplicated or has an invalid number, and nothing failed.
    case incomplete
}

public struct MuteExperimentVerdict: Equatable, Sendable {
    public var kind: MuteExperimentVerdictKind
    public var text: String
}

public enum MuteExperimentEvaluator {
    /// Precedence: noGo (any scenario failed) > incomplete (missing, duplicated or invalid) > inconclusive (any neverMuted) > go. A failure already decides "muting is not shipped", whatever else is missing.
    public static func evaluate(_ observations: [MuteObservation]) -> MuteExperimentVerdict {
        var failed: [String] = [], notMuted: [MuteScenarioKind] = [], missing: [MuteScenarioKind] = [], duplicated: [MuteScenarioKind] = [], invalid: [MuteScenarioKind] = []
        for kind in MuteExperimentCriteria.requiredScenarios {
            let matching = observations.filter { $0.kind == kind }
            if matching.isEmpty { missing.append(kind); continue }
            if matching.count > 1 { duplicated.append(kind); continue }
            switch matching[0].value {
            case .returned(let seconds):
                if !seconds.isFinite || seconds < 0 { invalid.append(kind) }
                else if seconds > MuteExperimentCriteria.returnWithinSeconds { failed.append("\(kind.rawValue) (back after \(String(format: "%.1f", seconds)) s)") }
            case .neverReturned:
                failed.append("\(kind.rawValue) (never back)")
            case .neverMuted:
                notMuted.append(kind)
            }
        }
        let label = "criteria version \(MuteExperimentCriteria.version): \(MuteExperimentCriteria.registration)"
        let window = String(format: "%.0f", MuteExperimentCriteria.returnWithinSeconds)
        let names: ([MuteScenarioKind]) -> String = { $0.map(\.rawValue).joined(separator: ", ") }
        if !failed.isEmpty {
            return MuteExperimentVerdict(kind: .noGo, text: "NO-GO: the player's audio did not come back within \(window) s in: \(failed.joined(separator: "; ")). Muting is not shipped (docs/ARCHITECTURE.md section 3). (\(label))")
        }
        if !missing.isEmpty || !duplicated.isEmpty || !invalid.isEmpty {
            var parts: [String] = []
            if !missing.isEmpty { parts.append("missing: \(names(missing))") }
            if !duplicated.isEmpty { parts.append("given more than once: \(names(duplicated))") }
            if !invalid.isEmpty { parts.append("invalid number of seconds: \(names(invalid))") }
            return MuteExperimentVerdict(kind: .incomplete, text: "INCOMPLETE (\(parts.joined(separator: "; "))): no verdict. (\(label))")
        }
        if !notMuted.isEmpty {
            return MuteExperimentVerdict(kind: .inconclusive, text: "INCONCLUSIVE: the player's audio never went silent in \(names(notMuted)), so the mute did not take effect there and the scenario tested nothing. (\(label))")
        }
        return MuteExperimentVerdict(kind: .go, text: "GO: in all five scenarios the player's audio came back within \(window) s. This says nothing about sleep and wake, other players, other devices, or a longer-lived failure. (\(label))")
    }
}

/// `--mute-experiment-verdict normal-exit=2.5,sigint=none,sigkill=unmuted,destroy-tap=3,stop-io=4`: a number is seconds until the audio came back, `none` = it did not come back, `unmuted` = it never went silent.
public enum MuteExperimentArguments {
    public enum Parsed: Equatable, Sendable {
        case notRequested
        case request([MuteObservation])
        case invalid(String)
    }

    public static func parse(_ arguments: [String]) -> Parsed {
        var list: String?
        var iterator = arguments.dropFirst().makeIterator()
        while let a = iterator.next() {
            if a == "--mute-experiment-verdict" {
                guard let next = iterator.next() else { return .invalid("--mute-experiment-verdict needs a list like normal-exit=2.5,sigint=none,...") }
                list = next
            }
            else if a.hasPrefix("--mute-experiment-verdict=") { list = String(a.dropFirst("--mute-experiment-verdict=".count)) }
        }
        guard let list else { return .notRequested }
        var out: [MuteObservation] = []
        for item in list.split(separator: ",", omittingEmptySubsequences: true) {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let kind = MuteScenarioKind(rawValue: parts[0]) else { return .invalid("not a scenario=value pair: \(item)") }
            switch parts[1] {
            case "none": out.append(MuteObservation(kind: kind, value: .neverReturned))
            case "unmuted": out.append(MuteObservation(kind: kind, value: .neverMuted))
            default:
                guard let seconds = Double(parts[1]) else { return .invalid("\(parts[0]): the value is seconds, `none` or `unmuted`, got: \(parts[1])") }
                out.append(MuteObservation(kind: kind, value: .returned(seconds: seconds)))
            }
        }
        return .request(out)
    }
}

// MARK: - The process-specific tap: behaviour, plan, scenario

/// How the tapped PROCESS's own audio is treated (CATapDescription.h, `CATapMuteBehavior`). The default is `unmuted`; the mute options exist ONLY for the process-specific tap, never for the all-but-us tap.
public enum RingProbeMuteBehavior: String, Codable, Sendable, Equatable, CaseIterable {
    case unmuted
    case muted
    case mutedWhenTapped

    public static let defaultBehavior = RingProbeMuteBehavior.unmuted

    /// `unmuted`, `muted`, `mutedwhentapped` (lower case, exact).
    public static func parse(_ word: String) -> RingProbeMuteBehavior? {
        switch word {
        case "unmuted": return .unmuted
        case "muted": return .muted
        case "mutedwhentapped": return .mutedWhenTapped
        default: return nil
        }
    }
}

public struct ProcessTapSpec: Equatable, Sendable {
    public var targetPID: Int32
    public var mute: RingProbeMuteBehavior
    public init(targetPID: Int32, mute: RingProbeMuteBehavior = RingProbeMuteBehavior.defaultBehavior) { self.targetPID = targetPID; self.mute = mute }
}

/// What the process-specific tap is allowed to include. The tap lists ONLY the target, so our own process is absent from it (it is never added).
public enum ProcessTapPlan {
    public enum Failure: Error, Equatable, Sendable {
        case targetIsThisProcess
        case targetNotAnAudioProcess
    }

    public static func make(targetObject: UInt32, ownObject: UInt32?, targetPID: Int32, ownPID: Int32) -> Result<[UInt32], Failure> {
        if targetPID == ownPID { return .failure(.targetIsThisProcess) }
        if targetObject == 0 { return .failure(.targetNotAnAudioProcess) }
        if let own = ownObject, own == targetObject { return .failure(.targetIsThisProcess) }
        return .success([targetObject])
    }

    public static func message(_ f: Failure) -> String {
        switch f {
        case .targetIsThisProcess: return "the target process is this process: the probe never taps itself"
        case .targetNotAnAudioProcess: return "the target PID is not a process the audio system knows (is the player running and playing?)"
        }
    }
}

/// A fault the probe injects into its OWN resources at a given measured time, to see whether the target's audio returns (docs/MANUAL_TEST_STEP6B3C0.md). `normal exit`, SIGINT and SIGKILL are done from outside.
public enum MuteScenario: Equatable, Sendable {
    case destroyTap(atSeconds: Double)
    case stopIO(atSeconds: Double)

    public var atSeconds: Double {
        switch self { case .destroyTap(let s), .stopIO(let s): return s }
    }

    public var kind: MuteScenarioKind {
        switch self {
        case .destroyTap: return .tapDestroyedWhileIORuns
        case .stopIO: return .ioStoppedWhileTapLives
        }
    }

    /// `destroy-tap@20` or `stop-io@20.5`: the time is finite and above 0; the kind is lower case, exact.
    public static func parse(_ text: String) -> MuteScenario? {
        let parts = text.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, let seconds = Double(parts[1]), seconds.isFinite, seconds > 0 else { return nil }
        switch parts[0] {
        case "destroy-tap": return .destroyTap(atSeconds: seconds)
        case "stop-io": return .stopIO(atSeconds: seconds)
        default: return nil
        }
    }
}

/// What the runner did for a scenario, numbers only.
public struct MuteScenarioRecord: Codable, Equatable, Sendable {
    public var kind: String
    public var requestedAtSeconds: Double
    /// Measured seconds since sample 0 of the sample at which it fired (nil if the run ended first).
    public var firedAtElapsedSeconds: Double?
    public var status: Int32?
    public init(kind: String, requestedAtSeconds: Double, firedAtElapsedSeconds: Double? = nil, status: Int32? = nil) {
        self.kind = kind; self.requestedAtSeconds = requestedAtSeconds; self.firedAtElapsedSeconds = firedAtElapsedSeconds; self.status = status
    }
}
