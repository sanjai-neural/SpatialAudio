#!/usr/bin/env python3
"""Step 6b-2 mutation check of the ring probe (test-the-test; CLAUDE.md). The mutant list was written BEFORE any code or mutant existed (R01-R22), with three
additions (R08b, R23, R25) written after the code and tests but before any mutant was run; both files are copied into docs/STATUS.md.

Each mutant is one or more (old, new) edits; every `old` must occur EXACTLY ONCE in its file, or the run stops (the patch would not be what the list says).
Every mutant is run against the ring-probe test suites with `swift test --filter`. KILLED = the test run failed (a test failed or the process died);
SURVIVED = it passed; DID-NOT-COMPILE = the build failed (not counted as killed). The original of every file is restored in a `finally` and compared byte for byte.

  python3 -I scripts/mutate_ringprobe.py [--only R01,R07] [--results FILE.json] [--filter REGEX] [--sanitize address]

Run it under `caffeinate -i` (a run takes several minutes; this Mac sleeps).
"""
import argparse
import json
import os
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
RUNNER = "Sources/SpatialAudioCore/RingProbeRunner.swift"
ANALYZER = "Sources/SpatialAudioCore/RingProbe.swift"
ENGINE = "Sources/SpatialAudioEngine/RingProbeEngine.swift"
SIM = "Sources/SpatialAudioEngine/SimulatedRingBackend.swift"
TICKER = "Sources/SpatialAudioEngine/DispatchRingTicker.swift"
REAL = "Sources/SpatialAudioEngine/SystemRingBackend.swift"

TEARDOWN_ENGINE_BLOCK = '''        if enginePrepared {
            backend.stopEngine(); order.append("engine stop")
            backend.detachSourceNodes(); order.append("source nodes detached")
        }
'''
IO_STOP_LINE = '''        if started, let a = aggregateID { let s = backend.stop(a); log(TapProbeRunner.Name.stop, s); destroyStatuses.append(s); order.append("IO stop") }
'''
TICKER_STOP_LINE = '''        ticker.stop(); order.append("sampling timer off")
'''

# id: (description, [(file, old, new), ...])
MUTANTS = {
    "R01": ("gain not forced to 0 (the engine does not set the main mixer's output volume)",
            [(ENGINE, "        mixer.outputVolume = 0                              // THE gain: forced here, read back by the runner, checked again before every start\n",
              "        // MUTANT R01: no assignment\n")]),
    "R02": ("node L fed reader 1 (the left source node is created with the right channel's reader)",
            [(ENGINE, "guard let reader = SARingGetReader(ring, UInt32(channel)), let node", "guard let reader = SARingGetReader(ring, 1), let node")]),
    "R03": ("slope computed with a wrong time unit (milliseconds)",
            [(ANALYZER, "samples.map { (x: $0.elapsedSeconds, y: Double($0.readers[reader].fill)) }", "samples.map { (x: $0.elapsedSeconds * 1000, y: Double($0.readers[reader].fill)) }")]),
    "R04": ("elapsed taken from the nominal second (the sample index) instead of the measured host ticks",
            [(ANALYZER, "let elapsed = ticksPerSecond > 0 && raw.hostTicks >= first.hostTicks ? Double(raw.hostTicks - first.hostTicks) / ticksPerSecond : 0",
              "let elapsed = Double(index)")]),
    "R05": ("config-change stop removed (the runner ignores the engine's configuration-change count)",
            [(RUNNER, "if backend.configurationChangeCount() > 0 {", "if false && backend.configurationChangeCount() > 0 {")]),
    "R06": ("teardown order changed: IO is stopped BEFORE the engine",
            [(RUNNER, IO_STOP_LINE, ""), (RUNNER, TEARDOWN_ENGINE_BLOCK, IO_STOP_LINE + TEARDOWN_ENGINE_BLOCK)]),
    "R07": ("early free in the simulated mode (the ring is freed before the render thread and the producer are joined)",
            [(SIM, "    public func stopEngine() {\n        renderThread?.requestStopAndJoin(); renderThread = nil\n",
              "    public func stopEngine() {\n        if let r = ring { SARingFree(r); ring = nil; producerCore = nil; record(\"ring freed\") }\n        renderThread?.requestStopAndJoin(); renderThread = nil\n")]),
    "R08": ("sampling cadence from a fixed sleep (the real ticker sleeps one second instead of using the timer)",
            [(TICKER, "while !(tickPending || signalPending || interruptPending) { condition.wait() }",
              "while !(tickPending || signalPending || interruptPending) { condition.unlock(); Thread.sleep(forTimeInterval: 1.0); condition.lock(); tickPending = true }")]),
    "R08b": ("sampling cadence from a fixed sleep, RUNNER variant (the runner sleeps one second on its clock instead of waiting on the ticker)",
             [(RUNNER, "                let wake = ticker.wait()\n", "                clock.sleep(1.0); let wake = RingProbeWake.tick\n")]),
    "R09": ("runner does not check the gain read-back before starting the engine",
            [(RUNNER, "guard gain.readBackBeforeStart == 0 else {", "guard true || gain.readBackBeforeStart == 0 else {")]),
    "R10": ("the engine's start does not re-check the mixer volume",
            [(ENGINE, "        guard mixer.outputVolume == 0 else { throw RingProbeEngineError.gainNotZero(mixer.outputVolume) }\n        startAttempts += 1\n",
              "        startAttempts += 1\n")]),
    "R11": ("readers never called (calls == 0) are reported ok instead of INVALID",
            [(RUNNER, 'if let why = invalidReason { outcome = "invalid: \\(why)" }', 'if let why = invalidReason, why.isEmpty { outcome = "invalid: \\(why)" }')]),
    "R12": ("the fill slope has its sign flipped",
            [(ANALYZER, "        return s.isFinite ? s : nil", "        return s.isFinite ? -s : nil")]),
    "R13": ("per-minute windows cut by sample index instead of measured time",
            [(ANALYZER, "groups[Int(s.elapsedSeconds / windowSeconds), default: []].append(s)", "groups[Int(Double(s.index) / windowSeconds), default: []].append(s)")]),
    "R14": ("the engine is started although priming never succeeded",
            [(RUNNER, "            guard primed else {", "            guard primed || true else {")]),
    "R15": ("the snapshot mapping swaps the two readers' counters",
            [(ENGINE, "[reader(s.reader.0), reader(s.reader.1)]", "[reader(s.reader.1), reader(s.reader.0)]")]),
    "R16": ("an output-rate change between samples is not flagged",
            [(ANALYZER, "if changes > 0 { flags.append(", "if changes > 0 && false { flags.append(")]),
    "R17": ("a gap between samples larger than 3 s is not flagged",
            [(ANALYZER, "if gaps > 0 { flags.append(", "if gaps > 0 && false { flags.append(")]),
    "R18": ("the REAL backend frees the ring",
            [(REAL, '        RingDisposition(freed: false, reason: "kept until the process exits:', '        if let r = ring { SARingFree(r); ringFreed = true }\n        return RingDisposition(freed: false, reason: "kept until the process exits:')]),
    "R19": ("the valid-timestamp share is invalid / (valid + invalid)",
            [(ANALYZER, "Double(fin.phaseValidCalls) / Double(fin.phaseValidCalls + fin.phaseInvalidCalls)", "Double(fin.phaseInvalidCalls) / Double(fin.phaseValidCalls + fin.phaseInvalidCalls)")]),
    "R20": ("the sampling timer is stopped AFTER the engine instead of first",
            [(RUNNER, TICKER_STOP_LINE, ""), (RUNNER, TEARDOWN_ENGINE_BLOCK, TEARDOWN_ENGINE_BLOCK + TICKER_STOP_LINE)]),
    "R21": ("a signal stop is recorded as a timeout",
            [(RUNNER, 'reason = "signal"; break sampling', 'reason = "timeout"; break sampling')]),
    "R22": ("the run ends after N ticks (samples) instead of when MEASURED time reaches the requested seconds",
            [(RUNNER, "if samples.last!.elapsedSeconds >= environment.requestedSeconds { break sampling }", "if samples.count > Int(environment.requestedSeconds) { break sampling }")]),
    "R23": ("the gain read-back AFTER the engine started is not checked",
            [(RUNNER, "guard gain.readBackAfterStart == 0 else {", "guard true || gain.readBackAfterStart == 0 else {")]),
    "R25": ("the wait for the first pull needs only the LEFT reader to have been called",
            [(RUNNER, "raw.readers[0].calls > 0, raw.readers[1].calls > 0 {", "raw.readers[0].calls > 0 {")]),
}


def read(rel):
    with open(os.path.join(ROOT, rel), "rb") as f:
        return f.read()


def write(rel, data):
    with open(os.path.join(ROOT, rel), "wb") as f:
        f.write(data)


def run_tests(filter_regex, sanitize, timeout):
    cmd = ["swift", "test", "--filter", filter_regex]
    if sanitize:
        cmd += ["--sanitize", sanitize]
    t0 = time.time()
    try:
        p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        out, code = p.stdout + p.stderr, p.returncode
    except subprocess.TimeoutExpired as e:
        out, code = (e.stdout or b"").decode(errors="replace") + "\nTIMEOUT", 124
    return code, out, time.time() - t0


def classify(code, out):
    if "error:" in out and ("Compiling" in out or "error: fatalError" in out or "Build failed" in out or "failed with a nonzero exit code" in out) and "Test run with" not in out:
        return "DID-NOT-COMPILE"
    if code == 0:
        return "SURVIVED"
    return "KILLED"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--results", default="")
    ap.add_argument("--filter", default="RingProbe|DispatchRingTicker")
    ap.add_argument("--sanitize", default="")
    ap.add_argument("--timeout", type=int, default=900)
    args = ap.parse_args()
    ids = [i for i in MUTANTS if not args.only or i in args.only.split(",")]
    results = {}
    for mid in ids:
        desc, edits = MUTANTS[mid]
        files = sorted({f for f, _, _ in edits})
        originals = {f: read(f) for f in files}
        try:
            for f, old, new in edits:
                text = read(f).decode()
                if text.count(old) != 1:
                    print(f"{mid}: PATCH DOES NOT MATCH EXACTLY ONCE in {f} ({text.count(old)} matches): {old[:70]!r}", file=sys.stderr)
                    results[mid] = {"description": desc, "verdict": "PATCH-ERROR"}
                    break
                write(f, text.replace(old, new, 1).encode())
            else:
                code, out, secs = run_tests(args.filter, args.sanitize, args.timeout)
                failing = sorted({line.split("Test ", 1)[1].split("(")[0].strip() for line in out.splitlines() if line.startswith("✘ Test ") and " recorded an issue" in line})
                verdict = classify(code, out)
                tail = [l for l in out.splitlines() if "error:" in l][:2] if verdict == "DID-NOT-COMPILE" else []
                results[mid] = {"description": desc, "verdict": verdict, "exit": code, "seconds": round(secs, 1), "failingTests": failing[:8], "compileErrors": tail}
                print(f"{mid}: {verdict} (exit {code}, {secs:.0f}s) {', '.join(failing[:3])}", flush=True)
        finally:
            for f, data in originals.items():
                write(f, data)
                assert read(f) == data, f"{f} was not restored"
    if args.results:
        with open(args.results, "w") as f:
            json.dump(results, f, indent=2)
    survivors = [m for m, r in results.items() if r["verdict"] == "SURVIVED"]
    bad = [m for m, r in results.items() if r["verdict"] in ("DID-NOT-COMPILE", "PATCH-ERROR")]
    print(f"\n{len(results)} mutants: {sum(1 for r in results.values() if r['verdict'] == 'KILLED')} killed, {len(survivors)} survived {survivors}, {len(bad)} did not compile / patch error {bad}")
    return 1 if survivors or bad else 0


if __name__ == "__main__":
    sys.exit(main())
