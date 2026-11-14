#!/usr/bin/env python3
"""Step 3b mutation check of head-tracked listening (test-the-test; CLAUDE.md). The list R01-R03, X01-X02, V01-V02, T01-T02, N01-N02, S01-S05, C01-C03 was written to a
timestamped scratch file (tracked-mutations.md, 01:34:06) BEFORE any of the new logic existed; Z01 and Z02 were appended (01:40:26) after the first silent self-check showed a
0.003 degree roll at the pump output, before any mutant ran. Each patch must match EXACTLY ONCE; the files are restored and compared byte for byte after every mutant.
Detector: swift test --filter <regex> (default: the Step 3b suites; the C mutants, which change EXISTING code, use only the face-loss chain test so that it is the one being tested).

  caffeinate -i python3 -I scripts/mutate_trackedlistening.py [--only R01,C02] [--results FILE.json]
"""
import argparse, json, os, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
TL = "Sources/SpatialAudioCore/TrackedListening.swift"
LF = "Sources/SpatialAudioCore/ListenerFrame.swift"
HT = "Sources/SpatialAudioTracking/HeadTracker.swift"
SN = "Sources/SpatialAudioEngine/SteadyNoise.swift"
SS = "Sources/SpatialAudioEngine/TrackedListeningSession.swift"
PI = "Sources/SpatialAudioCore/PoseInterpolator.swift"
SM = "Sources/SpatialAudioCore/TrackingStateMachine.swift"
DEFAULT = "Tracked|RollRemoval|SteadyNoise|ListeningMode|zeroRoll"
CHAIN = "faceLossHoldsDecaysAndComesBackWithoutAJump"

MUTANTS = {
    "R01": ("removingRoll returns its input unchanged", [(TL, "Quaternion(euler: removingRoll(from: q.euler))", "q")], None),
    "R02": ("removingRoll zeroes yaw instead of roll", [(TL, "EulerAngles(yaw: e.yaw, pitch: e.pitch, roll: 0)", "EulerAngles(yaw: 0, pitch: e.pitch, roll: e.roll)")], None),
    "R03": ("removingRoll zeroes pitch as well as roll", [(TL, "EulerAngles(yaw: e.yaw, pitch: e.pitch, roll: 0)", "EulerAngles(yaw: e.yaw, pitch: 0, roll: 0)")], None),
    "X01": ("the scripted test and the camera mode may run together", [(TL, "active.subtracting([requested])", "active.subtracting([requested, .scripted])")], None),
    "X02": ("the blind test and the camera mode may run together", [(TL, "active.subtracting([requested])", "active.subtracting([requested, .blind])")], None),
    "V01": ("the volume cap is not applied", [(TL, "return min(max(v, 0), maximumVolume)", "return min(max(v, 0), 1)")], None),
    "V02": ("the default volume is above the cap", [(TL, "public static let defaultVolume = 0.15", "public static let defaultVolume = 0.6")], None),
    "T01": ("the roll switch is ignored", [(HT, "Quaternion(euler: rollZero ? RollRemoval.removingRoll(from: e) : e)", "Quaternion(euler: e)")], None),
    "T02": ("the switch also zeroes the displayed raw roll", [(HT, "            mappedEuler = e\n", "            mappedEuler = rollZero ? RollRemoval.removingRoll(from: e) : e\n")], None),
    "N01": ("the loop seam is a hard cut (no crossfade)", [(SN, "            if i < x {", "            if false {")], None),
    "N02": ("the level normalisation is wrong (+12 dB)", [(SN, "pow(10, rmsDecibels / 20) / rms : 0", "pow(10, rmsDecibels / 20) / rms * 4 : 0")], None),
    "S01": ("publish() does not remove roll", [(SS, "let q = RollRemoval.removingRoll(from: pose)", "let q = pose")], None),
    "S02": ("publish() accepts a non-finite pose", [(SS, "guard pose.isFinite else {", "guard true else {")], None),
    "S03": ("setVolume does not apply the cap", [(SS, "let c = TrackedListeningPolicy.clampedVolume(v)", "let c = min(max(v, 0), 1)")], None),
    "S04": ("start() sets the volume after starting the engine",
            [(SS, "        output.outputVolume = Float(v)\n        output.setSourcePosition(", "        output.setSourcePosition("),
             (SS, "        pump.start(period: blockPeriod)", "        output.outputVolume = Float(v)\n        pump.start(period: blockPeriod)")], None),
    "S05": ("stop() does not set the volume to 0 before stopping", [(SS, "        pump.stop()\n        output.outputVolume = 0\n        output.stop()", "        pump.stop()\n        output.stop()")], None),
    "Z01": ("ListenerMapping.apply ignores zeroRoll", [(LF, "        if zeroRoll { e.roll = 0 }\n", "")], None),
    "Z02": ("the session's output mapping does not set zeroRoll", [(SS, "ListenerMapping(zeroRoll: true)", "ListenerMapping()")], None),
    "C01": ("the pose interpolator has time constant 0 (no smoothing)",
            [(PI, "public var timeConstant: Double = 0.020\n\n        public init(timeConstant: Double = 0.020)", "public var timeConstant: Double = 0\n\n        public init(timeConstant: Double = 0)")], CHAIN),
    "C02": ("the state machine's decay duration is 0", [(SM, "decayDuration: Double = 1.5", "decayDuration: Double = 0")], CHAIN),
    "C03": ("the state machine's reacquire blend duration is 0", [(SM, "reacquireBlendDuration: Double = 0.25", "reacquireBlendDuration: Double = 0")], CHAIN),
}

def read(rel): return open(os.path.join(ROOT, rel), "rb").read()
def write(rel, data): open(os.path.join(ROOT, rel), "wb").write(data)

def run_tests(filter_regex, timeout):
    t0 = time.time()
    try:
        p = subprocess.run(["swift", "test", "--filter", filter_regex], cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout + p.stderr, time.time() - t0
    except subprocess.TimeoutExpired as e:
        return 124, (e.stdout or b"").decode(errors="replace") + "\nTIMEOUT", time.time() - t0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default=""); ap.add_argument("--results", default=""); ap.add_argument("--timeout", type=int, default=900)
    args = ap.parse_args()
    ids = [i for i in MUTANTS if not args.only or i in args.only.split(",")]
    results = {}
    for mid in ids:
        desc, edits, flt = MUTANTS[mid]
        files = sorted({f for f, _, _ in edits}); originals = {f: read(f) for f in files}
        try:
            for f, old, new in edits:
                text = read(f).decode()
                if text.count(old) != 1:
                    print(f"{mid}: PATCH DOES NOT MATCH EXACTLY ONCE in {f} ({text.count(old)} matches): {old[:70]!r}", file=sys.stderr)
                    results[mid] = {"description": desc, "verdict": "PATCH-ERROR"}; break
                write(f, text.replace(old, new, 1).encode())
            else:
                code, out, secs = run_tests(flt or DEFAULT, args.timeout)
                failing = sorted({l.split("Test ", 1)[1].split("(")[0].strip() for l in out.splitlines() if l.startswith("✘ Test ") and " recorded an issue" in l})
                compiled_fail = ("error:" in out and "Test run with" not in out and "Build complete" not in out)
                crashed = "Fatal error" in out or ("signal" in out.lower() and "Test run with" not in out)
                verdict = "DID-NOT-COMPILE" if compiled_fail and code != 0 and not failing else ("SURVIVED" if code == 0 else "KILLED")
                results[mid] = {"description": desc, "verdict": verdict, "exit": code, "seconds": round(secs, 1), "failingTests": failing[:10], "crash": bool(crashed)}
                print(f"{mid}: {verdict} (exit {code}, {secs:.0f}s){' CRASH' if crashed else ''} {', '.join(failing[:3])}", flush=True)
        finally:
            for f, data in originals.items():
                write(f, data); assert read(f) == data, f"{f} was not restored"
    if args.results: json.dump(results, open(args.results, "w"), indent=2)
    surv = [m for m, r in results.items() if r["verdict"] == "SURVIVED"]; bad = [m for m, r in results.items() if r["verdict"] in ("DID-NOT-COMPILE", "PATCH-ERROR")]
    print(f"\n{len(results)} mutants: {sum(1 for r in results.values() if r['verdict']=='KILLED')} killed, {len(surv)} survived {surv}, {len(bad)} did not compile / patch error {bad}")
    return 1 if surv or bad else 0

if __name__ == "__main__": sys.exit(main())
