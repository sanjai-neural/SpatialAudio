#!/usr/bin/env python3
"""Step 6b-3b (a2) mutation check of the device-bound-tap spike's logic (test-the-test; CLAUDE.md).

Question this serves: do the tests of the rate-equality guard, the stage classifier, the pre-registered verdict (G0 to G3), the per-epoch slopes, the runner integration, the new switch and
the engine-layer flag fail when that logic is deliberately broken? The original list (95 ids: A, B, C, D, E, F, G, H, R, P, Q, M) was written to a timestamped scratch file BEFORE any 6b-3b
code existed (2026-11-19 00:35 +0530, sha256 e9cc8896...; copied into docs/STATUS.md). Ids here follow it; where one patch serves two ids, or no patch is possible, the id is listed in
DUPLICATES / NOT_APPLICABLE below and in STATUS. Additions made later are labelled in the scratch file and in STATUS, never here.

Each mutant is one or more (file, old, new) edits; every `old` must occur EXACTLY ONCE in its file or the mutant is a PATCH-ERROR. Verdicts: KILLED (a test failed), HANG (not finished within the
timeout: reported separately, not a kill), SURVIVED (tests passed with the mutant in place: a hole, or an equivalent / untestable mutant to be argued by hand), DID-NOT-COMPILE (not a kill).
The original of every file is restored in a `finally` and compared byte for byte; SHA-256 of every touched file before and after, and of this script, are printed. The whole descendant
process tree of a hung `swift test` is killed (swiftpm-testing-helper has its own process group).

  python3 -I scripts/mutate_ratefix.py [--only A01,B02] [--results FILE.json] [--timeout 900]

Run under `caffeinate -i`, and do not touch the working tree while it runs. It does not push, commit or change anything else.
"""
import argparse
import hashlib
import json
import os
import signal
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
VERD = "Sources/SpatialAudioCore/RateFixVerdict.swift"
EPOCH = "Sources/SpatialAudioCore/RingEpochSlopes.swift"
RUNNER = "Sources/SpatialAudioCore/RingProbeRunner.swift"
PREP = "Sources/SpatialAudioCore/RingProbeReport.swift"
ARGS = "Sources/SpatialAudioCore/RingProbeArguments.swift"
SYS = "Sources/SpatialAudioEngine/SystemRingBackend.swift"
SIM = "Sources/SpatialAudioEngine/SimulatedRingBackend.swift"
CMD = "Sources/SpatialAudioEngine/RingProbeCommand.swift"

FILTER = "RateEquality|RateFix|RingEpoch|RingProbe|SimulatedRingProbe|RingRecovery|RePrime"

ONE = lambda f, o, n: [(f, o, n)]  # noqa: E731

# Ids of the original list that are NOT run as their own mutant, and why (also in docs/STATUS.md).
DUPLICATES = {"B05": "the same patch as B02 (the recovery flag is not required for S2)"}
NOT_APPLICABLE = {"M03": "the report's Codable conformance is synthesized: there is no code that could rename a key on encode only"}

MUTANTS = {
    # ---- A. rate-equality guard ----
    "A01": ("the tolerance test < becomes <=", ONE(VERD, "if abs(tapRate - output) < toleranceHz { return Result(passes: true, reason: nil) }", "if abs(tapRate - output) <= toleranceHz { return Result(passes: true, reason: nil) }")),
    "A02": ("the comparison is inverted", ONE(VERD, "if abs(tapRate - output) < toleranceHz { return Result(passes: true, reason: nil) }", "if !(abs(tapRate - output) < toleranceHz) { return Result(passes: true, reason: nil) }")),
    "A03": ("an unknown (nil) output rate passes", ONE(VERD, "            return Result(passes: false, reason: \"the output device's nominal rate is unknown\")", "            return Result(passes: outputNominalRate == nil, reason: \"the output device's nominal rate is unknown\")")),
    "A04": ("abs removed: a tap below the output rate passes", ONE(VERD, "if abs(tapRate - output) < toleranceHz {", "if (tapRate - output) < toleranceHz {")),
    "A05": ("an output rate of 0 or negative is not refused as unknown", ONE(VERD, "output.isFinite, output > 0 else {", "output.isFinite else {")),
    "A06": ("a non-finite output rate is not refused as unknown", ONE(VERD, "output.isFinite, output > 0 else {", "output > 0 else {")),
    "A07": ("the tolerance is 5 Hz instead of 0.5 Hz", ONE(VERD, "public static let toleranceHz = 0.5", "public static let toleranceHz = 5.0")),
    # ---- B. stage classification ----
    "B01": ("S1 recognises 181 s instead of 180 s", ONE(VERD, "if !recovery && requestedSeconds == 180 { return .s1 }", "if !recovery && requestedSeconds == 181 { return .s1 }")),
    "B02": ("the recovery flag is ignored for S2 (a 600 s plain run is S2); also B05", ONE(VERD, "if recovery && requestedSeconds == 600 { return .s2 }", "if requestedSeconds == 600 { return .s2 }")),
    "B03": ("the S0 and S3 durations are swapped", [(VERD, "if !recovery && requestedSeconds == 5 { return .s0 }", "if !recovery && requestedSeconds == 120 { return .s0 }"), (VERD, "if !recovery && requestedSeconds == 120 { return .s3 }", "if !recovery && requestedSeconds == 5 { return .s3 }")]),
    "B04": ("equality becomes >= for S1 (a 300 s plain run is S1)", ONE(VERD, "if !recovery && requestedSeconds == 180 { return .s1 }", "if !recovery && requestedSeconds >= 180 { return .s1 }")),
    "B06": ("an unlisted run is classified as S1", ONE(VERD, "        return .unclassified\n", "        return .s1\n")),
    # ---- C. G0 ----
    "C01": ("the Float32 check is dropped", ONE(VERD, "let formatOK = f.isFloat32 && f.isInterleaved && f.channelsPerFrame == 2", "let formatOK = f.isInterleaved && f.channelsPerFrame == 2")),
    "C02": ("the interleaved check is dropped", ONE(VERD, "let formatOK = f.isFloat32 && f.isInterleaved && f.channelsPerFrame == 2", "let formatOK = f.isFloat32 && f.channelsPerFrame == 2")),
    "C03": ("the channel count is not checked", ONE(VERD, "let formatOK = f.isFloat32 && f.isInterleaved && f.channelsPerFrame == 2", "let formatOK = f.isFloat32 && f.isInterleaved")),
    "C04": ("the rate guard result is used inverted", ONE(VERD, "status: formatOK && rate.passes ? .pass : .fail)", "status: formatOK && !rate.passes ? .pass : .fail)")),
    "C05": ("a missing tap format counts as a pass in S0", ONE(VERD, "            if g0.status != .pass {", "            if g0.status == .fail {")),
    "C06": ("a missing output rate counts as a pass in G0", ONE(VERD, "status: formatOK && rate.passes ? .pass : .fail)", "status: formatOK && (rate.passes || input.outputNominalRate == nil) ? .pass : .fail)")),
    # ---- D. G1 ----
    "D01": ("the G1 tolerance is 0.5 instead of 0.005", ONE(VERD, "public static let framesPerCallToleranceFrames = 0.005", "public static let framesPerCallToleranceFrames = 0.5")),
    "D02": ("only the left reader is checked", ONE(VERD, "for (i, r) in input.readers.enumerated() {", "for (i, r) in input.readers.enumerated() where i == 0 {")),
    "D03": ("only the minimum interval mean is checked", ONE(VERD, "let ok = abs(mn - expected) <= RateFixCriteria.framesPerCallToleranceFrames && abs(mx - expected) <= RateFixCriteria.framesPerCallToleranceFrames", "let ok = abs(mn - expected) <= RateFixCriteria.framesPerCallToleranceFrames")),
    "D04": ("the median is checked instead of min and max", ONE(VERD, "let ok = abs(mn - expected) <= RateFixCriteria.framesPerCallToleranceFrames && abs(mx - expected) <= RateFixCriteria.framesPerCallToleranceFrames", "let ok = abs((r.intervalMedian ?? .nan) - expected) <= RateFixCriteria.framesPerCallToleranceFrames")),
    "D05": ("a missing per-interval summary counts as a pass", ONE(VERD, 'guard let mn = r.intervalMin, let mx = r.intervalMax else { return no("a reader has no per-interval summary") }', "guard let mn = r.intervalMin, let mx = r.intervalMax else { continue }")),
    "D06": ("the expected value ignores the buffer size (512 constant)", ONE(VERD, "let expected = Double(buffer) * f.sampleRate / output", "let expected = 512.0 * f.sampleRate / output")),
    "D07": ("only the right reader is checked", ONE(VERD, "for (i, r) in input.readers.enumerated() {", "for (i, r) in input.readers.enumerated() where i == 1 {")),
    # ---- E. G2 ----
    "E01": ("the signed slope is compared instead of the absolute value", ONE(VERD, "return SlopeJudgement(worstPPM: max(abs(a), abs(b)), reason: nil)", "return SlopeJudgement(worstPPM: max(a, b), reason: nil)")),
    "E02": ("the go threshold 100 becomes 1000", ONE(VERD, "public static let goSlopePPM = 100.0", "public static let goSlopePPM = 1000.0")),
    "E03": ("the no-go threshold 300 becomes 3000", ONE(VERD, "public static let noGoSlopePPM = 300.0", "public static let noGoSlopePPM = 3000.0")),
    "E04": ("exactly 100 ppm is gray instead of go", ONE(VERD, "} else if let w = worst, w > RateFixCriteria.goSlopePPM {", "} else if let w = worst, w >= RateFixCriteria.goSlopePPM {")),
    "E05": ("only the left reader's slope is used", ONE(VERD, "return SlopeJudgement(worstPPM: max(abs(a), abs(b)), reason: nil)", "return SlopeJudgement(worstPPM: abs(a), reason: nil)")),
    "E06": ("the minimum over the two readers is used instead of the maximum", ONE(VERD, "return SlopeJudgement(worstPPM: max(abs(a), abs(b)), reason: nil)", "return SlopeJudgement(worstPPM: min(abs(a), abs(b)), reason: nil)")),
    "E07": ("the slope is judged although re-primes happened", ONE(VERD, '        if (input.rePrimes ?? 0) > 0 { return SlopeJudgement(worstPPM: nil, reason: "re-primes split the run, so the whole-run slope is not a drain measurement (see the per-epoch table)") }\n', "")),
    "E08": ("the slope is judged in S3", ONE(VERD, '        if stage == .s3 { return SlopeJudgement(worstPPM: nil, reason: "S3 does not judge the slope: 120 s cannot resolve 100 ppm") }\n', "")),
    "E09": ("the report's ppm is the frames/s slope (unit slip, in the builder)", ONE(VERD, "fillSlopePPM: r.fillSlopePPM,", "fillSlopePPM: r.fillSlopeFramesPerSecond,")),
    "E10": ("exactly 300 ppm is no-go instead of gray", ONE(VERD, "(worst.map { $0 > RateFixCriteria.noGoSlopePPM } ?? false)", "(worst.map { $0 >= RateFixCriteria.noGoSlopePPM } ?? false)")),
    # ---- F. G3 ----
    "F01": ("the re-prime count is ignored", ONE(VERD, 'measured: "\\(n) re-prime(s)", status: n == 0 ? .pass : .fail)', 'measured: "\\(n) re-prime(s)", status: .pass)')),
    "F02": ("one re-prime is tolerated", ONE(VERD, 'status: n == 0 ? .pass : .fail)', 'status: n <= 1 ? .pass : .fail)')),
    "F03": ("overrun jumps are not counted (builder)", ONE(VERD, "jumps = rr.overrunJumps + rr.divergenceJumps + rr.refusedJumps", "jumps = rr.divergenceJumps + rr.refusedJumps")),
    "F04": ("divergence jumps are not counted (builder)", ONE(VERD, "jumps = rr.overrunJumps + rr.divergenceJumps + rr.refusedJumps", "jumps = rr.overrunJumps + rr.refusedJumps")),
    "F05": ("refused jumps are not counted (builder)", ONE(VERD, "jumps = rr.overrunJumps + rr.divergenceJumps + rr.refusedJumps", "jumps = rr.overrunJumps + rr.divergenceJumps")),
    "F06": ("underruns are the absolute final count, not the delta after sample 0 (builder)", ONE(VERD, "let underruns = last.readers[i].underrunBlocks &- first.readers[i].underrunBlocks", "let underruns = last.readers[i].underrunBlocks")),
    "F07": ("only the left reader's underruns are checked", ONE(VERD, "let bad = input.readers.contains { $0.underrunsAfterFirstSample > 0 }", "let bad = input.readers.prefix(1).contains { $0.underrunsAfterFirstSample > 0 }")),
    "F08": ("only the left reader's phase mismatches are checked", ONE(VERD, "let bad = input.readers.contains { $0.phaseMismatches > 0 }", "let bad = input.readers.prefix(1).contains { $0.phaseMismatches > 0 }")),
    "F09": ("the valid-timestamp share must be only >= 0.5", ONE(VERD, "let ok = input.readers.allSatisfy { ($0.validTimestampShare ?? -1) == 1 }", "let ok = input.readers.allSatisfy { ($0.validTimestampShare ?? -1) >= 0.5 }")),
    "F10": ("a missing valid-timestamp share counts as a pass", ONE(VERD, "let ok = input.readers.allSatisfy { ($0.validTimestampShare ?? -1) == 1 }", "let ok = input.readers.allSatisfy { ($0.validTimestampShare ?? 1) == 1 }")),
    "F11": ("overrun blocks are ignored", ONE(VERD, "status: blocks == 0 && jumps == 0 ? .pass : .fail)", "status: jumps == 0 ? .pass : .fail)")),
    "F12": ("only the right reader's phase mismatches are checked", ONE(VERD, "let bad = input.readers.contains { $0.phaseMismatches > 0 }", "let bad = input.readers.suffix(1).contains { $0.phaseMismatches > 0 }")),
    # ---- G. verdict logic ----
    "G01": ("S2: a failed G3 item never prevents go (inconclusive is never returned)", ONE(VERD, "} else if [g0, g1, g2, g3a, g3b, g3c, g3d, g3e].allSatisfy({ $0.status == .pass }) {", "} else if true {")),
    "G02": ("S2: a gray slope returns go", ONE(VERD, "                    kind = .gray\n", "                    kind = .go\n")),
    "G03": ("S2: a gray slope returns noGo", ONE(VERD, "                    kind = .gray\n", "                    kind = .noGo\n")),
    "G04": ("S1: an underrun does not cause no-go", ONE(VERD, "let used = [g1, g2, g3c]", "let used = [g1, g2]")),
    "G05": ("S1: all clear returns go instead of continue to S2", ONE(VERD, "kind = .continueToS2", "kind = .go")),
    "G06": ("S3: a failed G3 item still returns control OK", ONE(VERD, "let used = [g0, g1, g3b, g3c, g3d, g3e]", "let used = [g0, g1]")),
    "G07": ("an S1-S3 run stopped by a signal is not incomplete", ONE(VERD, 'let completed = input.outcome == "ok" && input.stoppedBy == "timeout"', 'let completed = input.outcome == "ok"')),
    "G08": ("an outcome other than ok is not incomplete", ONE(VERD, 'let completed = input.outcome == "ok" && input.stoppedBy == "timeout"', 'let completed = input.stoppedBy == "timeout"')),
    "G09": ("a SIMULATED report's verdict does not say SIMULATED", ONE(VERD, 'if input.simulated { text = "SIMULATED (fabricated data, decides nothing): " + text }', "if input.simulated { }")),
    "G10": ("S0: a G0 failure returns proceed", ONE(VERD, "            if g0.status != .pass {\n                kind = .noGo", "            if g0.status != .pass {\n                kind = .proceedToS1")),
    "G11": ("a G0 failure in S1 to S3 returns incomplete instead of noGo", ONE(VERD, "            if g0.status == .fail {\n                kind = .noGo", "            if g0.status == .fail {\n                kind = .incomplete")),
    "G12": ("S2: a gray slope hides a hard no-go such as a G1 failure", ONE(VERD, "                if hardNoGo {", "                if hardNoGo && !(worst.map { $0 > RateFixCriteria.goSlopePPM } ?? false) {")),
    "G13": ("an unclassified run returns a verdict instead of none", ONE(VERD, "            kind = .unclassified\n", "            kind = .inconclusive\n")),
    "G14": ("the criteria version is not written into the report", ONE(VERD, "RateFixReport(criteriaVersion: RateFixCriteria.version,", 'RateFixReport(criteriaVersion: "",')),
    # ---- H. per-epoch slopes ----
    "H01": ("the run-clock to sample-time conversion adds the offset instead of subtracting it", [(EPOCH, "bounds.append((lo, c.stopIssuedAtSeconds - t0))", "bounds.append((lo, c.stopIssuedAtSeconds + t0))"), (EPOCH, "lo = c.restartedAtSeconds - t0", "lo = c.restartedAtSeconds + t0")]),
    "H02": ("samples between the stop and the restart are included in the epoch", ONE(EPOCH, "bounds.append((lo, c.stopIssuedAtSeconds - t0))", "bounds.append((lo, c.restartedAtSeconds - t0))")),
    "H03": ("the epoch's end is inclusive", ONE(EPOCH, "$0.elapsedSeconds >= b.lo && $0.elapsedSeconds < b.hi", "$0.elapsedSeconds >= b.lo && $0.elapsedSeconds <= b.hi")),
    "H04": ("the ppm is the frames/s slope (no division by the tap rate)", ONE(EPOCH, "ppm.append(s.flatMap { rateOK ? $0 / tapRate * 1e6 : nil })", "ppm.append(s.flatMap { rateOK ? $0 : nil })")),
    "H05": ("an epoch with 2 samples gets a slope (patched as: the minimum is 2, not 3)", ONE(EPOCH, "public static let minimumSamples = 3", "public static let minimumSamples = 2")),
    "H06": ("the right reader's slope is the left reader's", ONE(EPOCH, "RingProbeAnalyzer.fillSeries(members, reader: r)", "RingProbeAnalyzer.fillSeries(members, reader: 0)")),
    "H07": ("underruns per epoch are the final count, not the delta", ONE(EPOCH, "underruns: (0..<2).map { last.readers[$0].underrunBlocks &- first.readers[$0].underrunBlocks }))", "underruns: (0..<2).map { last.readers[$0].underrunBlocks }))")),
    "H08": ("the first epoch is bounded below by the first restart instead of starting at sample 0 (patched as such)", ONE(EPOCH, "var lo = -Double.infinity", "var lo = (cuts.first?.restartedAtSeconds ?? 0) - t0")),
    "H09": ("with no re-primes the whole series is not returned as one epoch", ONE(EPOCH, "bounds = [(-Double.infinity, Double.infinity)]", "bounds = []")),
    "H10": ("an unavailable offset (nil) is treated as 0 instead of returning no epochs", ONE(EPOCH, "guard let t0 = firstSampleRunClockSeconds else { return [] }", "let t0 = firstSampleRunClockSeconds ?? 0")),
    # ---- R. runner integration ----
    "R01": ("the rate-equality guard is skipped in device-bound mode", ONE(RUNNER, "            if backend.tapMode == .deviceBound {\n                let g = RateEqualityGuard.check", "            if false && backend.tapMode == .deviceBound {\n                let g = RateEqualityGuard.check")),
    "R02": ("the guard is applied in global mode too", ONE(RUNNER, "            if backend.tapMode == .deviceBound {\n                let g = RateEqualityGuard.check", "            if true {\n                let g = RateEqualityGuard.check")),
    "R03": ("a guard failure does not stop the run", [(RUNNER, "                guard g.passes else {\n                    failed(", "                if !g.passes {\n                    failed("), (RUNNER, "The tap format above is what it reported.\")\n                    break build", "The tap format above is what it reported.\")")]),
    "R04": ("firstSampleRunClockSeconds is not recorded", ONE(RUNNER, "timings.firstSampleRunClockSeconds = firstSampleClock", "_ = firstSampleClock")),
    "R05": ("rateFix is attached in global mode", ONE(RUNNER, "        if backend.tapMode == .deviceBound {\n            let epochs", "        if true {\n            let epochs")),
    "R06": ("rateFix is not attached in device-bound mode", ONE(RUNNER, "        if backend.tapMode == .deviceBound {\n            let epochs", "        if false {\n            let epochs")),
    "R07": ("the stage is classified with the wrong recovery flag (builder)", ONE(VERD, "RateFixStage.classify(recovery: report.recovery != nil,", "RateFixStage.classify(recovery: report.recovery == nil,")),
    "R08": ("the SIMULATED flag is not passed to the evaluator (builder)", ONE(VERD, "simulated = report.isSimulated", "simulated = false")),
    "R09": ("the tap format is not recorded when the guard fails", ONE(RUNNER, 'failed("tap rate: \\(g.reason ?? "not equal")")', 'failed("tap rate: \\(g.reason ?? "not equal")"); format = nil')),
    "M04": ("rateFix is dropped when the run is not ok", ONE(RUNNER, "        if backend.tapMode == .deviceBound {\n            let epochs", '        if backend.tapMode == .deviceBound && outcome == "ok" {\n            let epochs')),
    # ---- P. parser, stem; Q. engine layer; M. report ----
    "P01": ("--ring-probe-device-tap is ignored by the parser", ONE(ARGS, "                deviceTap = true\n", "                deviceTap = false\n")),
    "P02": ("--ring-probe-device-tap alone is silently ignored", ONE(ARGS, "guard sawFlag || sawSimOption || sawDeviceTap else { return .notRequested }", "guard sawFlag || sawSimOption else { return .notRequested }")),
    "P03": ("--ring-probe-device-tap alone gets the generic number-of-seconds message", ONE(ARGS, "        if !sawFlag {\n            return .invalid(sawSimOption", "        if !sawFlag && !sawDeviceTap {\n            return .invalid(sawSimOption")),
    "P04": ("the file stem ignores the device-tap mode", ONE(PREP, 'return (deviceTap ? "ringdevicetap-" : (recovery ? "ringrecovery-" : "ringprobe-")) + f.string(from: date)', 'return (recovery ? "ringrecovery-" : "ringprobe-") + f.string(from: date)')),
    "P05": ("a repeated --ring-probe-device-tap is silently accepted", ONE(ARGS, 'if sawDeviceTap { invalid = invalid ?? "give --ring-probe-device-tap once" }', 'if false { invalid = invalid ?? "give --ring-probe-device-tap once" }')),
    "Q01": ("SystemRingBackend ignores its device-tap init flag", ONE(SYS, "public init(deviceTap: Bool = false) { tapMode = deviceTap ? .deviceBound : .globalMixdown }", "public init(deviceTap: Bool = false) { tapMode = .globalMixdown }")),
    "Q02": ("SimulatedRingBackend ignores its device-tap init flag", ONE(SIM, "self.tapMode = deviceTap ? .deviceBound : .globalMixdown", "self.tapMode = .globalMixdown")),
    "Q03": ("the real backend's composition does not say the tap is device-bound", ONE(SYS, "let tap = tapMode == .deviceBound ? \"a tap BOUND TO THE DEFAULT OUTPUT DEVICE'S STREAM 0 (Step 6b-3b, device-bound)\" : \"the tap only\"", "let tap = \"the tap only\"")),
    "Q04": ("RingProbeCommand ignores options.deviceTap (simulated path)", ONE(CMD, "faults: options.simulatedFaults, deviceTap: options.deviceTap)", "faults: options.simulatedFaults, deviceTap: false)")),
    "Q05": ("the device-bound tap is created without excluding our own process (hardware-only code: expected to SURVIVE, no test can reach it)", ONE(SYS, "description = CATapDescription(__excludingProcesses: excludingProcessObjects.map { NSNumber(value: $0) }, andDeviceUID: deviceUID, withStream: 0)", "description = CATapDescription(__excludingProcesses: [], andDeviceUID: deviceUID, withStream: 0)")),
    "M01": ("the markdown omits the rate-fix section", ONE(PREP, "        if let r = rateFix {\n", "        if let r = rateFix, false {\n")),
    "M02": ("the markdown omits the verdict line", ONE(VERD, 'out.append("- **Verdict: \\(verdict.rawValue)** - \\(verdictText)")', "_ = verdictText")),
}


def read(rel):
    with open(os.path.join(ROOT, rel), "rb") as f:
        return f.read()


def write(rel, data):
    with open(os.path.join(ROOT, rel), "wb") as f:
        f.write(data)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def descendants(root_pid):
    """Every descendant of `root_pid` (children, grandchildren, ...), read from `ps` BEFORE anything is killed: once a parent dies its children are re-parented to PID 1 and
    can no longer be found this way. swiftpm-testing-helper puts itself in its OWN process group, so a killpg of the `swift test` group does not reach it."""
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
    """Runs `swift test`. On a timeout the WHOLE descendant tree (and the group) gets SIGTERM, then SIGKILL, so the test helper of a hung mutant is not left behind.
    (The first full run left one orphan swiftpm-testing-helper at 100 % CPU after each Q08 hang; the process-group-only version of this function, used for the second full
    run, still left one, PID 34587, because the helper has its own process group.)"""
    cmd = ["swift", "test", "--filter", filter_regex]
    t0 = time.time()
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
    return code, out, time.time() - t0


def classify(code, out):
    if code == 124:
        return "HANG"
    if "error:" in out and ("Build failed" in out or "failed with a nonzero exit code" in out) and "Test run with" not in out:
        return "DID-NOT-COMPILE"
    if code == 0:
        return "SURVIVED"
    return "KILLED"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--results", default="")
    ap.add_argument("--filter", default=FILTER)
    ap.add_argument("--timeout", type=int, default=900)
    args = ap.parse_args()
    ids = [i for i in MUTANTS if not args.only or i in args.only.split(",")]
    print("not run as their own mutant:", json.dumps({**DUPLICATES, **NOT_APPLICABLE}), flush=True)
    touched = sorted({f for i in ids for f, _, _ in MUTANTS[i][1]})
    before = {f: sha(read(f)) for f in touched}
    print("script sha256:", sha(open(__file__, "rb").read()), flush=True)
    print("files before:", json.dumps(before, indent=1), flush=True)
    results = {}
    for mid in ids:
        desc, edits = MUTANTS[mid]
        files = sorted({f for f, _, _ in edits})
        originals = {f: read(f) for f in files}
        try:
            for f, old, new in edits:
                text = read(f).decode()
                if text.count(old) != 1:
                    print(f"{mid}: PATCH DOES NOT MATCH EXACTLY ONCE in {f} ({text.count(old)} matches): {old[:70]!r}", file=sys.stderr, flush=True)
                    results[mid] = {"description": desc, "verdict": "PATCH-ERROR"}
                    break
                write(f, text.replace(old, new, 1).encode())
            else:
                code, out, secs = run_tests(args.filter, args.timeout)
                failing = sorted({line.split("Test ", 1)[1].split("(")[0].strip() for line in out.splitlines() if line.startswith("✘ Test ") and " recorded an issue" in line})
                verdict = classify(code, out)
                tail = [l for l in out.splitlines() if "error:" in l][:2] if verdict == "DID-NOT-COMPILE" else []
                results[mid] = {"description": desc, "verdict": verdict, "exit": code, "seconds": round(secs, 1), "failingTests": failing[:10], "compileErrors": tail}
                print(f"{mid}: {verdict} (exit {code}, {secs:.0f}s) {', '.join(failing[:4])}", flush=True)
        finally:
            for f, data in originals.items():
                write(f, data)
                assert read(f) == data, f"{f} was not restored"
        if args.results:
            with open(args.results, "w") as fh:
                json.dump(results, fh, indent=2)
    after = {f: sha(read(f)) for f in touched}
    print("files unchanged by the run:", before == after, flush=True)
    counts = {}
    for r in results.values():
        counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
    survivors = [m for m, r in results.items() if r["verdict"] == "SURVIVED"]
    hangs = [m for m, r in results.items() if r["verdict"] == "HANG"]
    bad = [m for m, r in results.items() if r["verdict"] in ("DID-NOT-COMPILE", "PATCH-ERROR")]
    print(f"\n{len(results)} mutants: {counts}; survived {survivors}; HANG {hangs}; did not compile / patch error {bad}")
    return 1 if survivors or bad or before != after else 0


if __name__ == "__main__":
    sys.exit(main())
