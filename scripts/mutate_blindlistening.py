#!/usr/bin/env python3
"""Step 3a-2 mutation check of the blind listening test (test-the-test; CLAUDE.md). The list S01-S06, F01-F06, T01-T06 was written BEFORE the scoring / flag code existed
(scratch file blind-mutations.md, 09:35:45); T07, E01, E04 and E05 were appended after the code and tests existed but before any mutant ran (09:47:30). Each patch must match
EXACTLY ONCE; the files are restored and compared byte for byte after every mutant. Detector: swift test --filter BlindListening (Core and Engine tests).

  caffeinate -i python3 -I scripts/mutate_blindlistening.py [--only S01,F02] [--results FILE.json]
"""
import argparse, json, os, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CORE = "Sources/SpatialAudioCore/BlindListeningTest.swift"
ENG = "Sources/SpatialAudioEngine/BlindListeningSession.swift"

MUTANTS = {
    "S01": ("the head-left scene turns the head the other way (so the truth of a head-left trial is inverted)",
            [(CORE, "case .headLeft45: yaw = headTurnDegrees * eased ", "case .headLeft45: yaw = -headTurnDegrees * eased ")]),
    "S02": ("'can't tell' counts as correct",
            [(CORE, "            if r.answer.isDefinite {\n                perCondition[row].definite += 1\n                if r.answer.matches(r.truth) { perCondition[row].correct += 1 }\n            }\n",
              "            if r.answer.isDefinite { perCondition[row].definite += 1 }\n            if r.answer.matches(r.truth) || r.answer == .cantTell { perCondition[row].correct += 1 }\n")]),
    "S03": ("the accuracy divides by all trials", [(CORE, "Double(correct) / Double(definite) : nil,", "Double(correct) / Double(records.count) : nil,")]),
    "S04": ("the confusion table has answers as rows and conditions as columns", [(CORE, "confusion[row][r.answer.columnIndex] += 1", "confusion[r.answer.columnIndex][row] += 1")]),
    "S05": ("'not answered' counts as a (wrong) definite answer",
            [(CORE, "public var isDefinite: Bool { self == .leftEar || self == .rightEar || self == .middle }", "public var isDefinite: Bool { self == .leftEar || self == .rightEar || self == .middle || self == .notAnswered }")]),
    "S06": ("the binomial tail is off by one (more than k, not at least k)", [(CORE, "for i in k...n {", "for i in min(k + 1, n + 1)..<(n + 1) {")]),
    "F01": ("the flag minimum of definite answers is 5", [(CORE, "public static let flagMinimumDefinite = 6", "public static let flagMinimumDefinite = 5")]),
    "F02": ("the fraction test is > instead of >=", [(CORE, "Double(opposite) / Double(d.count) >= flagMinimumOppositeFraction", "Double(opposite) / Double(d.count) > flagMinimumOppositeFraction")]),
    "F03": ("'can't tell' counts as a definite answer in the flags",
            [(CORE, "-> BlindFlag {\n        let d = rs.filter { $0.answer.isDefinite }", "-> BlindFlag {\n        let d = rs.filter { $0.answer.isDefinite || $0.answer == .cantTell }")]),
    "F04": ("the head-hold trials are included in the channel-swap flag",
            [(CORE, "let staticSides = records.filter { $0.condition == .staticLeft || $0.condition == .staticRight }", "let staticSides = records.filter { $0.condition != .staticAhead }")]),
    "F05": ("'opposite' means the SAME ear",
            [(CORE, "(r.answer == .leftEar && r.truth == .rightEar) || (r.answer == .rightEar && r.truth == .leftEar)", "(r.answer == .leftEar && r.truth == .leftEar) || (r.answer == .rightEar && r.truth == .rightEar)")]),
    "F06": ("the head-turn flag does not require the static trials to be mostly right", [(CORE, "} else if isHead && !(pre ?? false) {", "} else if false {")]),
    "T01": ("the shuffle ignores the seed", [(CORE, "var rng = SplitMix64(seed: seed)\n        for _ in 0..<10_000 {", "var rng = SplitMix64(seed: 0)\n        for _ in 0..<10_000 {")]),
    "T02": ("the no-three-in-a-row constraint is removed", [(CORE, "if longestRun(order) <= maxRunLength { return order }", "if longestRun(order) <= maxRunLength || true { return order }")]),
    "T03": ("head-left has 3 trials instead of 4", [(CORE, "base += Array(repeating: c, count: repetitions)", "base += Array(repeating: c, count: c == .headLeft45 ? repetitions - 1 : repetitions)")]),
    "T04": ("the runner accepts an answer before the answer window opens", [(CORE, "now >= onset + config.answerEnableSeconds else { return false }", "now >= onset else { return false }")]),
    "T05": ("a timeout is recorded as an answer ('can't tell') instead of 'not answered'", [(CORE, "closeTrial(answer: .notAnswered, reaction: nil, at: deadline)", "closeTrial(answer: .cantTell, reaction: nil, at: deadline)")]),
    "T06": ("the runner's frame exposes the truth", [(CORE, "    public var inTrial: Bool\n    public var finished: Bool\n}", "    public var inTrial: Bool\n    public var finished: Bool\n    public var truth: BlindTruth? = nil\n}")]),
    "T07": ("the scene switch comes before the fade-out has finished", [(CORE, "public var sceneSwitchSeconds = 0.4", "public var sceneSwitchSeconds = 0.04")]),
    "E01": ("the volume is the fade gain alone (no base volume)", [(ENG, "let target = Float(baseVolume * f.gain)", "let target = Float(f.gain)")]),
    "E04": ("silent-and-finished is declared during the fade-out", [(ENG, "if f.finished, f.gain == 0, lastVolume == 0 {", "if f.finished {")]),
    "E05": ("the silent start is removed (no volume 0 before the first scene)", [(ENG, "        output.outputVolume = 0\n        lastVolume = 0\n        apply(f)", "        lastVolume = 0\n        apply(f)")]),
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
    ap.add_argument("--only", default=""); ap.add_argument("--results", default=""); ap.add_argument("--filter", default="BlindListening"); ap.add_argument("--timeout", type=int, default=900)
    args = ap.parse_args()
    ids = [i for i in MUTANTS if not args.only or i in args.only.split(",")]
    results = {}
    for mid in ids:
        desc, edits = MUTANTS[mid]
        files = sorted({f for f, _, _ in edits}); originals = {f: read(f) for f in files}
        try:
            for f, old, new in edits:
                text = read(f).decode()
                if text.count(old) != 1:
                    print(f"{mid}: PATCH DOES NOT MATCH EXACTLY ONCE in {f} ({text.count(old)} matches): {old[:70]!r}", file=sys.stderr)
                    results[mid] = {"description": desc, "verdict": "PATCH-ERROR"}; break
                write(f, text.replace(old, new, 1).encode())
            else:
                code, out, secs = run_tests(args.filter, args.timeout)
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
