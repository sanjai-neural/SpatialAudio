#!/usr/bin/env python3
"""Step 6b-2b mutation check of the offline resampling-consumption experiment (test-the-test; CLAUDE.md). The list M01-M12 was written BEFORE any code ran (scratch file time 21:02:15),
M13-M15 after the first table run but before any mutant ran (21:08:23). Each patch must match EXACTLY ONCE; the files are restored and compared byte for byte after every mutant.
Detector: swift test --filter 'ResamplingConsumption' (the analyzer tests and the control tests; the opt-in table prints and asserts nothing).

  python3 -I scripts/mutate_resampling.py [--only M01,M08] [--results FILE.json]        (run under caffeinate -i)
"""
import argparse, json, os, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
AN = "Sources/SpatialAudioCore/ResamplingConsumptionAnalyzer.swift"
HT = "Tests/SpatialAudioEngineTests/ResamplingConsumptionTests.swift"

MUTANTS = {
    "M01": ("slope against the wrong axis (sxy / syy instead of sxy / sxx)", [(AN, "let slope = sxy / sxx", "let slope = sxy / syy")]),
    "M02": ("the warm-up renders are not excluded (analyze)", [(AN, "let first = config.warmUpRenders\n", "let first = 0\n")]),
    "M03": ("the ideal ratio is inverted", [(AN, "let ideal = config.sourceRate / config.outputRate", "let ideal = config.outputRate / config.sourceRate")]),
    "M04": ("the gap uses the cursor BEFORE the render",
            [(AN, "gaps.append(Double(r.cursorAfter) - Double(r.samples[R - 1]) * unit / config.gain)",
              "gaps.append(Double(first + idx > 0 ? renders[first + idx - 1].cursorAfter : 0) - Double(r.samples[R - 1]) * unit / config.gain)")]),
    "M05": ("the gap does not divide by G", [(AN, "gaps.append(Double(r.cursorAfter) - Double(r.samples[R - 1]) * unit / config.gain)", "gaps.append(Double(r.cursorAfter) - Double(r.samples[R - 1]) * unit)")]),
    "M06": ("the mean pull is per call instead of per render", [(AN, "let pullMean = Double(pulledTotal) / Double(used.count)", "let pullMean = Double(pulledTotal) / Double(callsTotal)")]),
    "M07": ("the count of each distinct pull value is one too low", [(AN, "ResamplingPullCount(value: $0, count: counts[$0]!)", "ResamplingPullCount(value: $0, count: counts[$0]! - 1)")]),
    "M08": ("the gain guard is removed (no isInManualRenderingMode check)",
            [(HT, "        guard engine.isInManualRenderingMode else { throw ManualOnlyGainError.notManualRendering }\n", "")]),
    "M09": ("the ramp restarts at 0 on every 512-frame commit", [(HT, "let v = constant ?? Float(committed + Int64(i)) *", "let v = constant ?? Float(i) *")]),
    "M10": ("the producer commits nothing before a render (the fill target is ignored)", [(HT, "while snapshot(ring).reader.0.fill < fillTarget {", "while false && snapshot(ring).reader.0.fill < fillTarget {")]),
    "M11": ("node 1 is not muted (PREDICTED SURVIVOR: G absorbs the doubled signal)", [(HT, "(nodes[1] as? AVAudioMixing)?.volume = 0", "(nodes[1] as? AVAudioMixing)?.volume = 1")]),
    "M12": ("the control is built at the wrong output rate (44100)", [(HT, "let spec = CaseSpec(number: 1, sourceRate: 48_000, outputRate: 48_000, renderFrames: 512)", "let spec = CaseSpec(number: 1, sourceRate: 48_000, outputRate: 44_100, renderFrames: 512)")]),
    "M13": ("constantGain: the warm-up renders are not excluded", [(AN, "let first = warmUpRenders\n", "let first = 0\n")]),
    "M14": ("constantGain: gain = mean x constant instead of mean / constant", [(AN, "gain: mean / Double(constant))", "gain: mean * Double(constant))")]),
    "M15": ("the DC producer ignores its constant and writes the ramp", [(HT, "let v = constant ?? Float(committed", "let v = Float(committed")]),
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
    ap.add_argument("--only", default=""); ap.add_argument("--results", default=""); ap.add_argument("--filter", default="ResamplingConsumption"); ap.add_argument("--timeout", type=int, default=900)
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
                crashed = "Fatal error" in out or "signal" in out.lower() and "Test run with" not in out
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
