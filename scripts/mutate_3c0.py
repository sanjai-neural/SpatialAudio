#!/usr/bin/env python3
"""Step 6b-3c-0 mutation check (test-the-test; CLAUDE.md): the pre-registered mute-experiment criteria and evaluator, the process-tap plan, mute option and scenario parsing, the synthetic channel-check pattern and WAV, the
new arguments, the runner's process-specific mode and scenarios, the engine layer, the level math and the gain-cap proposal, the file tool.

The original list (103 ids: A to G) was written to a timestamped scratch file BEFORE any 6b-3c-0 code existed (2026-11-19 08:19 +0530; its sha256 is recorded in docs/STATUS.md). Ids here follow it. Additions made later are
labelled in a separate file and in STATUS, never here.

Each mutant is one or more (file, old, new) edits; every `old` must occur EXACTLY ONCE in its file or the mutant is a PATCH-ERROR. Verdicts: KILLED (a test failed, or the test process crashed), HANG (not finished within the timeout,
which is measured on a clock that does NOT advance while the Mac sleeps; reported SEPARATELY, never a kill), HANG-OVERLAPS-SLEEP (the Mac slept during the run: not a real hang; the mutant is re-run alone once at the end),
SURVIVED (the tests passed with the mutant in place: a hole, or an equivalent / untestable mutant to be argued by hand), DID-NOT-COMPILE (not a kill).

SURVIVING A KILLED RUN (the 6b-3b run died in a clamshell sleep and left a mutant in the tree for hours): before anything is patched, the original of every file the run can touch is copied to .build/mutation-3c0/ (ignored by git)
and a journal records their sha256 and whether a mutant is in place. The journal is written and synced BEFORE each patch. SIGINT, SIGTERM and SIGHUP restore and exit; the normal exit restores. A SIGKILL or a crash cannot be caught:
the NEXT start of this script (any invocation) restores the tree from the backup first and says so, and `--restore` does only that. After any interrupted run, run `python3 -I -B scripts/mutate_3c0.py --restore`.

Every result line carries the wall-clock time; the results file records the wall-clock start, the seconds, and the seconds the Mac slept (wall clock minus monotonic clock) of each mutant.

  python3 -I -B scripts/mutate_3c0.py [--only A01,B02] [--results FILE.json] [--resume] [--timeout 900] [--filter REGEX]
  python3 -I -B scripts/mutate_3c0.py --dry-run     check that every patch matches exactly once; run nothing
  python3 -I -B scripts/mutate_3c0.py --restore     restore the tree from the backup and exit

Run under `caffeinate -i`, with the LID OPEN (caffeinate -i does not stop a clamshell sleep), and do not touch the working tree while it runs. It does not push, commit or change anything else.
"""
import argparse
import atexit
import hashlib
import json
import os
import signal
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BACKUP_DIR = os.path.join(ROOT, ".build", "mutation-3c0")
JOURNAL = os.path.join(BACKUP_DIR, "journal.json")

MUTE = "Sources/SpatialAudioCore/MuteExperiment.swift"
PAT = "Sources/SpatialAudioCore/ChannelCheckPattern.swift"
LEVEL = "Sources/SpatialAudioCore/LevelMath.swift"
ARGS = "Sources/SpatialAudioCore/RingProbeArguments.swift"
PREP = "Sources/SpatialAudioCore/RingProbeReport.swift"
RUNNER = "Sources/SpatialAudioCore/RingProbeRunner.swift"
SYS = "Sources/SpatialAudioEngine/SystemRingBackend.swift"
SIM = "Sources/SpatialAudioEngine/SimulatedRingBackend.swift"
MAPPING = "Sources/SpatialAudioEngine/ProcessTapMute.swift"
CMD = "Sources/SpatialAudioEngine/RingProbeCommand.swift"
CAL = "Sources/SpatialAudioEngine/StereoCalibration.swift"
TOOL = "Sources/SpatialAudioEngine/ChannelCheckFileTool.swift"

FILTER = "MuteExperiment|MuteBehavior|ProcessTap|MuteScenario|ChannelCheck|LevelMath|GainCap|StereoCalibration|RingProbe|RateFix|RateEquality|RingEpoch"

ONE = lambda f, o, n: [(f, o, n)]  # noqa: E731

MUTANTS = {
    # ---- A. criteria and evaluator ----
    "A01": ("the return window 5 s becomes 50 s", ONE(MUTE, "public static let returnWithinSeconds = 5.0", "public static let returnWithinSeconds = 50.0")),
    "A02": ("the boundary: exactly 5.0 s fails", ONE(MUTE, "else if seconds > MuteExperimentCriteria.returnWithinSeconds {", "else if seconds >= MuteExperimentCriteria.returnWithinSeconds {")),
    "A03": ("neverReturned counts as a pass", ONE(MUTE, 'case .neverReturned:\n                failed.append("\\(kind.rawValue) (never back)")', "case .neverReturned:\n                break")),
    "A04": ("neverMuted counts as a pass", ONE(MUTE, "case .neverMuted:\n                notMuted.append(kind)", "case .neverMuted:\n                break")),
    "A05": ("a missing scenario is ignored", ONE(MUTE, "if matching.isEmpty { missing.append(kind); continue }", "if matching.isEmpty { continue }")),
    "A06": ("one failing scenario among passing ones still gives go", ONE(MUTE, "        if !failed.isEmpty {\n", "        if failed.count > 1 {\n")),
    "A07": ("inconclusive takes precedence over noGo", ONE(MUTE, "        if !failed.isEmpty {\n", "        if !failed.isEmpty && notMuted.isEmpty {\n")),
    "A08": ("incomplete takes precedence over noGo", ONE(MUTE, "        if !failed.isEmpty {\n", "        if !failed.isEmpty && missing.isEmpty && duplicated.isEmpty && invalid.isEmpty {\n")),
    "A09": ("sigkill is not a required scenario", ONE(MUTE, "[.normalExit, .sigint, .sigkill, .tapDestroyedWhileIORuns, .ioStoppedWhileTapLives]", "[.normalExit, .sigint, .tapDestroyedWhileIORuns, .ioStoppedWhileTapLives]")),
    "A10": ("a negative number of seconds is accepted as a return", ONE(MUTE, "if !seconds.isFinite || seconds < 0 { invalid.append(kind) }", "if !seconds.isFinite { invalid.append(kind) }")),
    "A11": ("a NaN number of seconds is accepted as a return", ONE(MUTE, "if !seconds.isFinite || seconds < 0 { invalid.append(kind) }", "if seconds < 0 { invalid.append(kind) }")),
    "A12": ("a duplicated scenario is silently accepted", ONE(MUTE, "if matching.count > 1 { duplicated.append(kind); continue }", "if matching.count > 1 { }")),
    "A13": ("the criteria version is not in the verdict text", ONE(MUTE, 'let label = "criteria version \\(MuteExperimentCriteria.version): \\(MuteExperimentCriteria.registration)"', 'let label = "\\(MuteExperimentCriteria.registration)"')),
    "A14": ("the registration label is not in the verdict text", ONE(MUTE, 'let label = "criteria version \\(MuteExperimentCriteria.version): \\(MuteExperimentCriteria.registration)"', 'let label = "criteria version \\(MuteExperimentCriteria.version)"')),
    "A15": ("the argument parser accepts an unknown scenario name", ONE(MUTE, "guard parts.count == 2, let kind = MuteScenarioKind(rawValue: parts[0]) else {", "guard parts.count == 2, case let kind = (MuteScenarioKind(rawValue: parts[0]) ?? MuteScenarioKind.sigint) else {")),
    "A16": ("none parses as 0 seconds (a return)", ONE(MUTE, 'case "none": out.append(MuteObservation(kind: kind, value: .neverReturned))', 'case "none": out.append(MuteObservation(kind: kind, value: .returned(seconds: 0)))')),
    "A17": ("unmuted parses as a return", ONE(MUTE, 'case "unmuted": out.append(MuteObservation(kind: kind, value: .neverMuted))', 'case "unmuted": out.append(MuteObservation(kind: kind, value: .returned(seconds: 0)))')),
    "A18": ("an empty list is not incomplete (no observations can give go)", ONE(MUTE, "if !missing.isEmpty || !duplicated.isEmpty || !invalid.isEmpty {", "if (!missing.isEmpty && !observations.isEmpty) || !duplicated.isEmpty || !invalid.isEmpty {")),
    "A19": ("normal-exit and sigint are swapped in the name mapping", [(MUTE, 'case normalExit = "normal-exit"', 'case normalExit = "sigint"'), (MUTE, 'case sigint = "sigint"', 'case sigint = "normal-exit"')]),
    "A20": ("the NO-GO verdict does not say which scenario failed", ONE(MUTE, 'in: \\(failed.joined(separator: "; ")). Muting is not shipped', '. Muting is not shipped')),
    # ---- B. process tap plan, mute behaviour, scenario parsing ----
    "B01": ("the target being this process (same PID) is not refused", ONE(MUTE, "if targetPID == ownPID { return .failure(.targetIsThisProcess) }", "if false { return .failure(.targetIsThisProcess) }")),
    "B02": ("the target being this process (same object) is not refused", ONE(MUTE, "if let own = ownObject, own == targetObject { return .failure(.targetIsThisProcess) }", "if let own = ownObject, own == targetObject, false { return .failure(.targetIsThisProcess) }")),
    "B03": ("an unknown target object (0) is not refused", ONE(MUTE, "if targetObject == 0 { return .failure(.targetNotAnAudioProcess) }", "if false { return .failure(.targetNotAnAudioProcess) }")),
    "B04": ("the include list also contains our own object", ONE(MUTE, "return .success([targetObject])", "return .success([targetObject] + (ownObject.map { [$0] } ?? []))")),
    "B05": ("the include list is empty", ONE(MUTE, "return .success([targetObject])", "return .success([])")),
    "B06": ("the mute default is muted", ONE(MUTE, "public static let defaultBehavior = RingProbeMuteBehavior.unmuted", "public static let defaultBehavior = RingProbeMuteBehavior.muted")),
    "B07": ("mutedwhentapped parses as muted", ONE(MUTE, 'case "mutedwhentapped": return .mutedWhenTapped', 'case "mutedwhentapped": return .muted')),
    "B08": ("an unknown mute word is accepted as unmuted", ONE(MUTE, 'case "mutedwhentapped": return .mutedWhenTapped\n        default: return nil', 'case "mutedwhentapped": return .mutedWhenTapped\n        default: return .unmuted')),
    "B09": ("the scenario parser swaps destroy-tap and stop-io", ONE(MUTE, 'case "destroy-tap": return .destroyTap(atSeconds: seconds)\n        case "stop-io": return .stopIO(atSeconds: seconds)', 'case "destroy-tap": return .stopIO(atSeconds: seconds)\n        case "stop-io": return .destroyTap(atSeconds: seconds)')),
    "B10": ("a scenario time of 0 or negative is accepted", ONE(MUTE, "let seconds = Double(parts[1]), seconds.isFinite, seconds > 0 else { return nil }", "let seconds = Double(parts[1]), seconds.isFinite else { return nil }")),
    "B11": ("a scenario time that is infinite is accepted", ONE(MUTE, "let seconds = Double(parts[1]), seconds.isFinite, seconds > 0 else { return nil }", "let seconds = Double(parts[1]), seconds > 0 else { return nil }")),
    "B12": ("the scenario kind is not case-exact", ONE(MUTE, "switch parts[0] {\n        case \"destroy-tap\"", "switch parts[0].lowercased() {\n        case \"destroy-tap\"")),
    # ---- C. channel-check pattern and WAV ----
    "C01": ("the left-only segment also writes the right channel", ONE(PAT, "case 0: return (v, 0)", "case 0: return (v, v)")),
    "C02": ("the right-only segment also writes the left channel", ONE(PAT, "case 1: return (0, v)", "case 1: return (v, v)")),
    "C03": ("the both segment writes only the left channel", ONE(PAT, "default: return (v, v)", "default: return (v, 0)")),
    "C04": ("the peak amplitude is 0.316 (-10 dBFS)", ONE(PAT, "public static let peakAmplitude: Float = 0.0316", "public static let peakAmplitude: Float = 0.316")),
    "C05": ("no fade: the first sample of a burst is not zero", ONE(PAT, "let envelope = min(1, fadeIn, fadeOut)", "let envelope: Float = 1")),
    "C06": ("the burst length is 0.25 s", ONE(PAT, "public static let burstFrames = 22_050", "public static let burstFrames = 11_025")),
    "C07": ("the segment order is swapped (right first)", ONE(PAT, "case 0: return (v, 0)\n        case 1: return (0, v)", "case 0: return (0, v)\n        case 1: return (v, 0)")),
    "C08": ("the noise depends on the clock (not deterministic)", ONE(PAT, "var z = seed &+ UInt64(bitPattern: index) &* 0x9E37_79B9_7F4A_7C15", "var z = seed &+ UInt64(bitPattern: index) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(Date().timeIntervalSince1970 * 1e6)")),
    "C09": ("the segment length is 5 s instead of 10 s", ONE(PAT, "public static let segmentFrames = unitFrames * burstsPerSegment", "public static let segmentFrames = unitFrames * 5")),
    "C10": ("the WAV data size field is wrong", ONE(PAT, "let dataBytes = UInt32(frames * 4)", "let dataBytes = UInt32(frames * 2)")),
    "C11": ("the WAV RIFF size field is wrong", ONE(PAT, "u32(36 + dataBytes)", "u32(35 + dataBytes)")),
    "C12": ("the WAV channel count is 1", ONE(PAT, "u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate))", "u32(16); u16(1); u16(1); u32(UInt32(sampleRate))")),
    "C13": ("the WAV bits per sample is 8", ONE(PAT, "u16(UInt16(channels * 2)); u16(16)", "u16(UInt16(channels * 2)); u16(8)")),
    "C14": ("the WAV byte rate is wrong", ONE(PAT, "u32(UInt32(sampleRate * channels * 2))", "u32(UInt32(sampleRate * channels))")),
    "C15": ("the WAV block align is wrong", ONE(PAT, "u16(UInt16(channels * 2)); u16(16)", "u16(UInt16(channels)); u16(16)")),
    "C16": ("the quantizer truncates toward zero instead of rounding", ONE(PAT, "return Int16((c * 32767).rounded())", "return Int16((c * 32767).rounded(.towardZero))")),
    "C17": ("the quantizer does not clip at +/-1", ONE(PAT, "let c = min(max(x, -1), 1)", "let c = x")),
    "C18": ("the tool accepts 899 s (the minimum is 900)", ONE(PAT, "public static let minimumSeconds = 900", "public static let minimumSeconds = 899")),
    "C19": ("the tool accepts more than 3600 s", ONE(PAT, "if seconds > maximumSeconds {", "if seconds > maximumSeconds + 100 {")),
    "C20": ("the chunked writer drops the last partial chunk", ONE(TOOL, "while start < frames {", "while start + Int64(chunk) <= frames {")),
    "C21": ("chunk boundaries repeat a frame (the chunk starts one frame early)", ONE(TOOL, "ChannelCheckPattern.pcm16(startFrame: start, count: n)", "ChannelCheckPattern.pcm16(startFrame: max(start - 1, 0), count: n)")),
    "C22": ("samples are written big-endian", ONE(PAT, "out.append(UInt8(l & 0xFF)); out.append(UInt8(l >> 8))", "out.append(UInt8(l >> 8)); out.append(UInt8(l & 0xFF))")),
    "C23": ("the gap between bursts is not silence", ONE(PAT, "guard k < burstFrames else { return (0, 0) }", "guard k < burstFrames else { return (noise(index) * peakAmplitude, 0) }")),
    # ---- D. arguments, stem, report ----
    "D01": ("--ring-probe-process-pid is ignored", ONE(ARGS, "if let pid = Int32(value), pid > 0 { processPID = pid } else {", "if let pid = Int32(value), pid > 0 { _ = pid } else {")),
    "D02": ("a pid of 0 or negative is accepted", ONE(ARGS, "if let pid = Int32(value), pid > 0 { processPID = pid } else {", "if let pid = Int32(value) { processPID = pid } else {")),
    "D03": ("the process pid together with --ring-probe-device-tap is accepted", ONE(ARGS, "if sawProcessPID && sawDeviceTap { return .invalid(", "if false && sawProcessPID && sawDeviceTap { return .invalid(")),
    "D04": ("--ring-probe-tap-mute without a pid is accepted", ONE(ARGS, "if (sawTapMute || sawScenario) && !sawProcessPID {", "if sawScenario && !sawProcessPID {")),
    "D05": ("--ring-probe-mute-scenario without a pid is accepted", ONE(ARGS, "if (sawTapMute || sawScenario) && !sawProcessPID {", "if sawTapMute && !sawProcessPID {")),
    "D06": ("a repeated process pid is silently accepted", ONE(ARGS, 'if sawProcessPID { invalid = invalid ?? "give --ring-probe-process-pid once" }', 'if false { invalid = invalid ?? "give --ring-probe-process-pid once" }')),
    "D07": ("the tap-mute value is ignored by the parser", ONE(ARGS, "if let m = RingProbeMuteBehavior.parse(value) { tapMute = m } else {", "if let m = RingProbeMuteBehavior.parse(value) { _ = m } else {")),
    "D08": ("a gain or volume option is not refused when a process pid is given", ONE(ARGS, "if let g = arguments.dropFirst().first(where: {", "if !sawProcessPID, let g = arguments.dropFirst().first(where: {")),
    "D09": ("the file stem ignores the process mode", ONE(PREP, '(processTap ? "ringprocesstap-" : (deviceTap ? "ringdevicetap-" : (recovery ? "ringrecovery-" : "ringprobe-")))', '(deviceTap ? "ringdevicetap-" : (recovery ? "ringrecovery-" : "ringprobe-"))')),
    "D10": ("the markdown does not warn that the target's audio was muted", ONE(PREP, 'if muteBehavior != "unmuted" {', "if false {")),
    "D11": ("the report's mute behaviour stays unmuted whatever was requested", ONE(RUNNER, 'report.muteBehavior = backend.processTapSpec?.mute.rawValue ?? "unmuted"', 'report.muteBehavior = "unmuted"')),
    "D12": ("the target PID is not recorded in the report", ONE(RUNNER, "report.targetProcessPID = backend.processTapSpec?.targetPID", "report.targetProcessPID = nil")),
    # ---- E. runner ----
    "E01": ("the rate-equality guard is skipped in process-specific mode", ONE(RUNNER, "            if backend.tapMode != .globalMixdown {\n                let g = RateEqualityGuard.check", "            if backend.tapMode == .deviceBound {\n                let g = RateEqualityGuard.check")),
    "E02": ("the rate-fix section is not attached in process-specific mode", ONE(RUNNER, "        if backend.tapMode != .globalMixdown {\n            let epochs", "        if backend.tapMode == .deviceBound {\n            let epochs")),
    "E03": ("the guard is applied in global mode too", ONE(RUNNER, "            if backend.tapMode != .globalMixdown {\n                let g = RateEqualityGuard.check", "            if true {\n                let g = RateEqualityGuard.check")),
    "E04": ("a target process that is this process (same PID) is not refused by the runner", ONE(RUNNER, "targetPID: spec.targetPID, ownPID: environment.ownPID)", "targetPID: spec.targetPID, ownPID: -1)")),
    "E05": ("an unknown target object is not refused by the runner (the tap is created)", ONE(RUNNER, "targetObject: translated.object,", "targetObject: max(translated.object, 1),")),
    "E06": ("the target is not translated before the tap is created (a fixed object is used)", ONE(RUNNER, "guard let spec = backend.processTapSpec, let translated = backend.translateTargetProcess() else {", "guard let spec = backend.processTapSpec, let translated = Optional((object: UInt32(30), status: Int32(0))) else {")),
    "E07": ("the process tap is created with the global creation call", ONE(RUNNER, "tap = backend.createProcessTap(includingProcessObjects: include)", "tap = backend.createTap(excludingProcessObjects: excluded)")),
    "E08": ("the mute scenario fires one sample late", ONE(RUNNER, "samples.last!.elapsedSeconds >= scenario.atSeconds {", "samples.last!.elapsedSeconds > scenario.atSeconds {")),
    "E09": ("the mute scenario fires twice (at every later sample)", ONE(RUNNER, "scenarioRecord?.firedAtElapsedSeconds == nil, samples.last!.elapsedSeconds >= scenario.atSeconds {", "samples.last!.elapsedSeconds >= scenario.atSeconds {")),
    "E10": ("the destroy-tap scenario stops the IO instead", ONE(RUNNER, "status = backend.destroyTap(tap.tap)\n                            tapDestroyedEarly = true", "status = backend.stop(agg.device)\n                            tapDestroyedEarly = true")),
    "E11": ("the stop-io scenario destroys the tap instead", ONE(RUNNER, "status = backend.stop(agg.device)\n                            ioStoppedEarly = true", "status = backend.destroyTap(tap.tap)\n                            ioStoppedEarly = true")),
    "E12": ("the teardown destroys the tap a second time after the scenario destroyed it", ONE(RUNNER, "if tapDestroyedEarly { order.append", "if false { order.append")),
    "E13": ("the teardown stops the IO a second time after the scenario stopped it", ONE(RUNNER, "if ioStoppedEarly { order.append", "if false { order.append")),
    "E14": ("the scenario record is not put into the report", ONE(RUNNER, "report.muteScenario = scenarioRecord", "report.muteScenario = nil")),
    "E15": ("events are not sent through onEvent", ONE(RUNNER, "        var tapDestroyedEarly = false, ioStoppedEarly = false\n", "        var tapDestroyedEarly = false, ioStoppedEarly = false\n        let onEvent: ((String) -> Void)? = nil\n")),
    "E16": ("a mute scenario outside the process mode is not refused", ONE(RUNNER, "if muteScenario != nil && backend.tapMode != .processSpecific {", "if false && muteScenario != nil && backend.tapMode != .processSpecific {")),
    "E17": ("the gain guard is skipped in process-specific mode", ONE(RUNNER, "guard gain.readBackBeforeStart == 0 else {", "guard backend.tapMode == .processSpecific || gain.readBackBeforeStart == 0 else {")),
    "E18": ("the first-sample clock is not recorded in process-specific mode", ONE(RUNNER, "timings.firstSampleRunClockSeconds = firstSampleClock", "if backend.tapMode != .processSpecific { timings.firstSampleRunClockSeconds = firstSampleClock }")),
    # ---- F. engine layer, calibration, level math ----
    "F01": ("SystemRingBackend ignores its process-tap spec for the tap mode", ONE(SYS, "tapMode = processTap != nil ? .processSpecific : (deviceTap ? .deviceBound : .globalMixdown)", "tapMode = deviceTap ? .deviceBound : .globalMixdown")),
    "F02": ("SimulatedRingBackend ignores its process-tap spec for the tap mode", ONE(SIM, "self.tapMode = processTap != nil ? .processSpecific : (deviceTap ? .deviceBound : .globalMixdown)", "self.tapMode = deviceTap ? .deviceBound : .globalMixdown")),
    "F03": ("the composition does not say the tap is process-specific", ONE(SYS, 'tap = "a tap on ONE PROCESS (the test player) bound', 'tap = "the tap only bound')),
    "F04": ("the mute mapping maps muted to unmuted", ONE(MAPPING, "case .muted: return .muted", "case .muted: return .unmuted")),
    "F05": ("the mute mapping maps mutedWhenTapped to muted", ONE(MAPPING, "case .mutedWhenTapped: return .mutedWhenTapped", "case .mutedWhenTapped: return .muted")),
    "F06": ("RingProbeCommand ignores the process-tap options (simulated and real path)", [(CMD, "faults: options.simulatedFaults, deviceTap: options.deviceTap, processTap: options.processTap)", "faults: options.simulatedFaults, deviceTap: options.deviceTap, processTap: nil)"), (CMD, "SystemRingBackend(deviceTap: options.deviceTap, processTap: options.processTap)", "SystemRingBackend(deviceTap: options.deviceTap, processTap: nil)")]),
    "F07": ("the calibration puts the left source at +30 degrees (azimuth sign swapped)", ONE(CAL, "Vector3.direction(azimuthDegrees: -30, elevationDegrees: 0, distance: distance))", "Vector3.direction(azimuthDegrees: 30, elevationDegrees: 0, distance: distance))")),
    "F08": ("the calibration swaps the two sources' buffers", [(CAL, "leftPlayer.scheduleBuffer(try buffer(c.leftActive ? signal : silence)", "leftPlayer.scheduleBuffer(try buffer(c.rightActive ? signal : silence)"), (CAL, "rightPlayer.scheduleBuffer(try buffer(c.rightActive ? signal : silence)", "rightPlayer.scheduleBuffer(try buffer(c.leftActive ? signal : silence)")]),
    "F09": ("the calibration's default distance is 1 m instead of 2 m", ONE(CAL, "distance: Double = ListeningTest.sourceDistance) throws -> Row {", "distance: Double = 1.0) throws -> Row {")),
    "F10": ("the calibration measures from the first block (no warm-up skip)", ONE(CAL, "let skip = Int(warmupSeconds * sampleRate)", "let skip = 0")),
    "F11": ("the dB conversion uses 10 log10 for amplitudes", ONE(LEVEL, "{ 20 * log10(ratio) }", "{ 10 * log10(ratio) }")),
    "F12": ("the peak is computed as an RMS", ONE(LEVEL, "        return p\n", "        return rms(xs)\n")),
    "F13": ("the cap proposal rounds UP instead of down", ONE(LEVEL, "(raw * 100).rounded(.down) / 100", "(raw * 100).rounded(.up) / 100")),
    "F14": ("the cap proposal uses -6 dB instead of -16 dB", ONE(LEVEL, "public static let targetPeakDecibels = -16.0", "public static let targetPeakDecibels = -6.0")),
    "F15": ("the cap proposal uses the best case instead of the worst full-scale peak gain", ONE(CAL, "rows.filter(\\.fullScale).map(\\.peakGain).max()", "rows.filter(\\.fullScale).map(\\.peakGain).min()")),
    "F16": ("the cap proposal accepts a zero or negative peak gain", ONE(LEVEL, "guard worstFullScalePeakGain.isFinite, worstFullScalePeakGain > 0 else { return nil }", "guard worstFullScalePeakGain.isFinite else { return nil }")),
    # ---- G. the file tool ----
    "G01": ("the tool overwrites an existing file", ONE(TOOL, "if !overwrite { throw ToolError.fileExists }", "_ = overwrite")),
    "G02": ("the tool prints a peak of 0 dBFS whatever was written", ONE(TOOL, "peakDecibelsFullScale: LevelMath.amplitudeDecibels(Double(stats.peakAmplitude)),", "peakDecibelsFullScale: 0,")),
}


def read(rel):
    with open(os.path.join(ROOT, rel), "rb") as f:
        return f.read()


def write(rel, data):
    with open(os.path.join(ROOT, rel), "wb") as f:
        f.write(data)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def now():
    return time.strftime("%H:%M:%S")


def flat(rel):
    return rel.replace("/", "__") + ".orig"


def write_journal(obj):
    os.makedirs(BACKUP_DIR, exist_ok=True)
    tmp = JOURNAL + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=1)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, JOURNAL)


def read_journal():
    try:
        with open(JOURNAL) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def restore_from_backup(journal, reason):
    """Writes every backed-up original back and verifies its hash against the journal. Returns the files that DIFFERED before the restore."""
    changed = []
    for rel, h in journal["originals"].items():
        path = os.path.join(BACKUP_DIR, flat(rel))
        with open(path, "rb") as f:
            orig = f.read()
        if sha(orig) != h:
            raise SystemExit(f"BACKUP CORRUPT for {rel}: refusing to restore from it ({reason})")
        if sha(read(rel)) != h:
            changed.append(rel)
            write(rel, orig)
        assert sha(read(rel)) == h, f"{rel} was not restored"
    journal["state"] = "clean"
    journal["current"] = None
    write_journal(journal)
    return changed


def recover_if_needed(announce=True):
    j = read_journal()
    if not j:
        return None
    if j.get("state") == "mutating" or any(sha(read(rel)) != h for rel, h in j["originals"].items()):
        was_mutating = j.get("current")
        changed = restore_from_backup(j, "recovery")
        if announce:
            print(f"[{now()}] RECOVERED: a previous run left the tree mutated (mutant {was_mutating}); restored {changed or 'nothing differed'} from {os.path.relpath(BACKUP_DIR, ROOT)}", flush=True)
        return changed
    return []


STATE = {"journal": None}


def restore_now(reason):
    j = STATE["journal"]
    if j is None:
        return
    try:
        restore_from_backup(j, reason)
    except Exception as e:  # noqa: BLE001
        print(f"[{now()}] RESTORE FAILED ({reason}): {e}", file=sys.stderr, flush=True)


def install_handlers():
    def handler(signum, frame):
        print(f"[{now()}] signal {signum}: restoring the tree and exiting", flush=True)
        restore_now(f"signal {signum}")
        sys.exit(128 + signum)
    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(s, handler)
    atexit.register(lambda: restore_now("exit"))


def descendants(root_pid):
    out = subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True).stdout
    children = {}
    for line in out.splitlines():
        a = line.split()
        if len(a) == 2:
            children.setdefault(int(a[1]), []).append(int(a[0]))
    found, todo = [], [root_pid]
    while todo:
        for c in children.get(todo.pop(), []):
            found.append(c)
            todo.append(c)
    return found


def run_tests(filter_regex, timeout):
    """Runs `swift test`. The timeout is on the MONOTONIC clock, which does not advance while the Mac sleeps. On a timeout the WHOLE descendant tree (and the group) gets SIGTERM, then SIGKILL."""
    cmd = ["swift", "test", "--filter", filter_regex]
    t0 = time.monotonic()
    p = subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace", start_new_session=True)
    try:
        out, _ = p.communicate(timeout=timeout)
        code = p.returncode
    except subprocess.TimeoutExpired:
        victims = descendants(p.pid)
        out = ""
        for sig in (signal.SIGTERM, signal.SIGKILL):
            for pid in [p.pid] + victims:
                try:
                    os.kill(pid, sig)
                except (ProcessLookupError, PermissionError):
                    pass
            try:
                os.killpg(p.pid, sig)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                out, _ = p.communicate(timeout=10)
                break
            except subprocess.TimeoutExpired:
                continue
        out = (out or "") + "\nTIMEOUT"
        code = 124
    return code, out, time.monotonic() - t0


def classify(code, out):
    if code == 124:
        return "HANG"
    if "error:" in out and ("Build failed" in out or "failed with a nonzero exit code" in out) and "Test run with" not in out:
        return "DID-NOT-COMPILE"
    if code == 0:
        return "SURVIVED"
    return "KILLED"


def apply_patch(mid, edits):
    for f, old, new in edits:
        text = read(f).decode()
        if text.count(old) != 1:
            return f"{f} ({text.count(old)} matches): {old[:70]!r}"
    for f, old, new in edits:
        write(f, read(f).decode().replace(old, new, 1).encode())
    return None


def run_one(mid, args, journal):
    desc, edits = MUTANTS[mid]
    journal["state"], journal["current"] = "mutating", mid
    write_journal(journal)                                        # BEFORE the first byte is patched
    wall0, mono0 = time.time(), time.monotonic()
    try:
        problem = apply_patch(mid, edits)
        if problem:
            return {"description": desc, "verdict": "PATCH-ERROR", "detail": problem, "wallStart": time.strftime("%H:%M:%S", time.localtime(wall0))}
        code, out, secs = run_tests(args.filter, args.timeout)
    finally:
        restore_from_backup(journal, f"after {mid}")
    asleep = max(0.0, (time.time() - wall0) - (time.monotonic() - mono0))
    verdict = classify(code, out)
    failing = sorted({line.split("Test ", 1)[1].split("(")[0].strip() for line in out.splitlines() if line.startswith("✘ Test ") and " recorded an issue" in line})
    note = None
    if asleep > 30:
        note = f"the Mac slept for about {asleep:.0f} s during this mutant"
        if verdict == "HANG":
            verdict = "HANG-OVERLAPS-SLEEP"
    tail = [l for l in out.splitlines() if "error:" in l][:2] if verdict == "DID-NOT-COMPILE" else []
    crashed = verdict == "KILLED" and not failing and ("Fatal error" in out or "Illegal instruction" in out or "signal code" in out.lower() or code in (132, 133, 134, 139))
    return {"description": desc, "verdict": verdict, "exit": code, "seconds": round(secs, 1), "wallStart": time.strftime("%H:%M:%S", time.localtime(wall0)),
            "sleepSeconds": round(asleep), "note": note, "failingTests": failing[:10], "compileErrors": tail, "crash": crashed}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--results", default="")
    ap.add_argument("--resume", action="store_true")
    ap.add_argument("--filter", default=FILTER)
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--restore", action="store_true")
    args = ap.parse_args()

    if args.dry_run:
        bad = 0
        for mid, (desc, edits) in MUTANTS.items():
            for f, old, new in edits:
                n = read(f).decode().count(old)
                if n != 1:
                    print(f"{mid}: {f}: {n} matches for {old[:70]!r}")
                    bad += 1
        print(f"{len(MUTANTS)} mutants; patch problems: {bad}")
        return 1 if bad else 0

    recovered = recover_if_needed()
    if args.restore:
        print(f"[{now()}] restore done; tree matches the journal's hashes: {recovered is not None}", flush=True)
        return 0

    ids = [i for i in MUTANTS if not args.only or i in args.only.split(",")]
    results = {}
    if args.resume and args.results and os.path.exists(args.results):
        results = json.load(open(args.results))
        ids = [i for i in ids if i not in results]
    touched = sorted({f for i in ids for f, _, _ in MUTANTS[i][1]})
    originals = {f: sha(read(f)) for f in touched}
    os.makedirs(BACKUP_DIR, exist_ok=True)
    for f in touched:
        with open(os.path.join(BACKUP_DIR, flat(f)), "wb") as fh:
            fh.write(read(f))
    journal = {"state": "clean", "current": None, "pid": os.getpid(), "started": time.strftime("%Y-%m-%d %H:%M:%S %z"), "originals": originals}
    write_journal(journal)
    STATE["journal"] = journal
    install_handlers()

    print(f"[{now()}] script sha256:", sha(open(__file__, "rb").read()), flush=True)
    print(f"[{now()}] files before:", json.dumps(originals, indent=1), flush=True)
    print(f"[{now()}] {len(ids)} mutants to run; backup and journal in {os.path.relpath(BACKUP_DIR, ROOT)}", flush=True)
    rerun = []
    for mid in ids:
        r = run_one(mid, args, journal)
        results[mid] = r
        print(f"[{now()}] {mid}: {r['verdict']} (exit {r.get('exit')}, {r.get('seconds')}s{', CRASH' if r.get('crash') else ''}{', ' + r['note'] if r.get('note') else ''}) {', '.join(r.get('failingTests', [])[:4])}", flush=True)
        if r["verdict"] == "HANG-OVERLAPS-SLEEP":
            rerun.append(mid)
        if args.results:
            with open(args.results, "w") as fh:
                json.dump(results, fh, indent=2)
    for mid in rerun:
        r = run_one(mid, args, journal)
        r["rerunAlone"] = True
        results[mid] = r
        print(f"[{now()}] {mid} (re-run alone after a sleep overlap): {r['verdict']} (exit {r.get('exit')}, {r.get('seconds')}s)", flush=True)
        if args.results:
            with open(args.results, "w") as fh:
                json.dump(results, fh, indent=2)

    after = {f: sha(read(f)) for f in touched}
    print(f"[{now()}] files unchanged by the run: {originals == after}", flush=True)
    counts = {}
    for r in results.values():
        counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
    survivors = [m for m, r in results.items() if r["verdict"] == "SURVIVED"]
    hangs = [m for m, r in results.items() if r["verdict"].startswith("HANG")]
    bad = [m for m, r in results.items() if r["verdict"] in ("DID-NOT-COMPILE", "PATCH-ERROR")]
    print(f"\n{len(results)} mutants: {counts}; survived {survivors}; HANG {hangs}; did not compile / patch error {bad}")
    return 1 if survivors or bad or originals != after else 0


if __name__ == "__main__":
    sys.exit(main())
