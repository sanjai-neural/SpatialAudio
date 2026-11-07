#!/usr/bin/env python3
"""Mutation check of the Step 6b-1 ring (test-the-test, CLAUDE.md). Applies ONE deliberate bug at a time to Sources/CSystemAudioRing/CSystemAudioRing.c and
runs every detector. Every patch must match EXACTLY ONCE in the real file (else the run stops). A mutant SURVIVES if no detector fails on it.

  scripts/mutate_systemaudioring.py [--swift] [--only M01,M05] [--out DIR]

Detectors (each is one script run against a copy of the mutated file, so Sources/ is untouched, except --swift):
  D1 check    scripts/check-systemaudioring.sh check     deterministic checks, plain -Os build
  D2 paced    scripts/check-systemaudioring.sh paced     threaded stress, readers never overtaken
  D2 lapping  scripts/check-systemaudioring.sh lapping   threaded stress, readers overrun and torn
  D3 tsan     scripts/tsan-systemaudioring.sh plain      ThreadSanitizer, plain-sample build, paced stress
  D4 ubsan    scripts/ubsan-systemaudioring.sh hostile   UBSan (recovery off) on hostile inputs, guard pages
  D5 swift    swift test --filter SystemAudioRingTests   (--swift only) patches Sources/ IN PLACE, restores it and verifies the sha afterwards
  D6 scan     scan_rt_block.py zero on _SARingIOProc, _SARingWrite, _SARingRender, compiled with the flags SwiftPM uses
Also recorded: whether the mutant's object code (SwiftPM flags, -Os) is byte-identical to the real one (the only acceptable proof of an "equivalent mutant").
A detector run that does not finish within HANG_SECONDS is reported as HANG (a mutant that stops the harness is not a pass, but it is not counted as a clean kill
either); the limit uses time.monotonic(), which on macOS does not advance while the Mac sleeps. No verdict about the REAL code depends on it.
"""
import argparse, hashlib, json, os, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Sources" / "CSystemAudioRing" / "CSystemAudioRing.c"
HANG_SECONDS = 240

# (id, description, [(find, replace), ...], added_after_the_list_was_written)
W_STORE = "atomic_store_explicit(&ring->w, w0 + (int64_t)frames, memory_order_release);"
FENCE_REL = "    atomic_thread_fence(memory_order_release);\n    sa_write_samples(ring, in, frames, w0);\n"
CURSOR_STORE = "atomic_store_explicit(&rd->cursor, r + F, memory_order_relaxed);"
R_LOAD = "    const int64_t r = atomic_load_explicit(&rd->cursor, memory_order_relaxed);\n\n    /* Count-only"
M = [
 ("M01", "publish w BEFORE the data writes", [(FENCE_REL, "    " + W_STORE + "\n" + FENCE_REL), ("    " + W_STORE + "   /* publish only after every sample is written */\n", "")], False),
 ("M02", "relaxed instead of release on the store of w", [(W_STORE, W_STORE.replace("release", "relaxed"))], False),
 ("M03", "relaxed instead of acquire on the render's load of w", [("const int64_t w1 = atomic_load_explicit(&ring->w, memory_order_acquire);", "const int64_t w1 = atomic_load_explicit(&ring->w, memory_order_relaxed);")], False),
 ("M04", "cursor advances by frameCount + 1", [(CURSOR_STORE, CURSOR_STORE.replace("r + F", "r + F + 1"))], False),
 ("M05", "cursor advances by frameCount - 1", [(CURSOR_STORE, CURSOR_STORE.replace("r + F", "r + F - 1"))], False),
 ("M06", "mask off by one at capacity (mask = capacity)", [("ring->mask = capacityFrames - 1u;", "ring->mask = capacityFrames;")], False),
 ("M07", "wrap off by one (slot = index % (capacity - 1), producer and readers consistently)",
  [("const uint64_t slot = (uint64_t)(w0 + (int64_t)i) & mask;", "const uint64_t slot = (uint64_t)(w0 + (int64_t)i) % (uint64_t)(ring->capacity - 1u);"),
   ("dst[i] = SA_SAMPLE_LOAD(&src[(uint64_t)(r + i) & mask]);", "dst[i] = SA_SAMPLE_LOAD(&src[(uint64_t)(r + i) % (uint64_t)(ring->capacity - 1u)]);")], False),
 ("M08", "underrun not zero-filled (stale data stays in the output)", [("for (int64_t i = 0; i < F; i++) dst[i] = 0.0f;", "for (int64_t i = 0; i < 0; i++) dst[i] = 0.0f;")], False),
 ("M09", "channel swapped (each reader reads the other plane)", [("const SASample *src = ring->plane[rd->channel];", "const SASample *src = ring->plane[1u - rd->channel];")], False),
 ("M10", "both readers read ONE channel (plane 0)", [("const SASample *src = ring->plane[rd->channel];", "const SASample *src = ring->plane[0];")], False),
 ("M11", "order-dependent design: ONE shared cursor, advanced by whichever block runs (every call moves it)",
  [(R_LOAD, R_LOAD.replace("&rd->cursor", "&((SARing *)rd->ring)->readers[0].cursor")),
   (CURSOR_STORE + "   /* advance", CURSOR_STORE.replace("&rd->cursor", "&((SARing *)rd->ring)->readers[0].cursor") + "   /* advance")], False),
 ("M11b", "order-dependent design, the withdrawn draft: ONE shared cursor advanced only by the block that is assumed to run second (channel 1)",
  [(R_LOAD, R_LOAD.replace("&rd->cursor", "&((SARing *)rd->ring)->readers[0].cursor")),
   (CURSOR_STORE + "   /* advance", "if (rd->channel == 1) " + CURSOR_STORE.replace("&rd->cursor", "&((SARing *)rd->ring)->readers[0].cursor") + "   /* advance")], True),
 ("M12", "cursor advances only by the frames actually served (silent blocks do not advance it)", [(CURSOR_STORE, CURSOR_STORE.replace("r + F", "r + (silent ? 0 : F)"))], False),
 ("M13", "underrun test off by one (r + F >= w1)", [("} else if (r + F > w1) {", "} else if (r + F >= w1) {")], False),
 ("M14", "underrun test with an unsigned difference ((uint64_t)(w1 - r) < F: a reader AHEAD of the producer wraps)", [("} else if (r + F > w1) {", "} else if ((uint64_t)(w1 - r) < (uint64_t)F) {")], False),
 ("M15", "post-copy (torn read) check removed", [("if (w2 - r > window) {", "if (0) {")], False),
 ("M16", "safety margin removed (window = capacity)", [("const int64_t window = (int64_t)ring->capacity - (int64_t)ring->maxCommit;   /* frames behind w that", "const int64_t window = (int64_t)ring->capacity;   /* frames behind w that")], False),
 ("M17", "pre-copy overrun test removed (the post-copy check still catches it, as a torn block)", [("} else if (w1 - r > window) {", "} else if (0) {")], False),
 ("M18", "producer writes left and right swapped", [("SA_SAMPLE_STORE(&left[slot], in[2u * (size_t)i]);", "SA_SAMPLE_STORE(&left[slot], in[2u * (size_t)i + 1u]);"), ("SA_SAMPLE_STORE(&right[slot], in[2u * (size_t)i + 1u]);", "SA_SAMPLE_STORE(&right[slot], in[2u * (size_t)i]);")], False),
 ("M19", "producer accepts an oversize commit (guard removed)", [("    if (frames > ring->maxCommit) { sa_reject(ring, SA_RING_REJECT_OVERSIZE); return; }\n", "")], False),
 ("M20", "producer accepts a byte size that is not a whole number of frames (guard removed)", [("    if ((buf->mDataByteSize % 8u) != 0) { sa_reject(ring, SA_RING_REJECT_PARTIAL); return 0; }\n", "")], False),
 ("M21", "producer's release fence removed", [(FENCE_REL, "    sa_write_samples(ring, in, frames, w0);\n")], False),
 ("M22", "render's acquire fence removed", [("            atomic_thread_fence(memory_order_acquire);   /* the samples above are read before w is read again */\n", "")], False),
 ("M23", "prime: cursors start at w (no standing fill)", [("const int64_t start = w - depth;", "const int64_t start = w;")], False),
 ("M24", "prime: only the first reader's cursor is set", [("    for (uint32_t c = 0; c < SA_RING_CHANNELS; c++) {\n        SARingReader *rd = &ring->readers[c];\n        atomic_store_explicit(&rd->cursor, start, memory_order_relaxed);",
                                                      "    for (uint32_t c = 0; c < 1; c++) {\n        SARingReader *rd = &ring->readers[c];\n        atomic_store_explicit(&rd->cursor, start, memory_order_relaxed);")], False),
 ("M25", "prime accepts fewer commits than T (guard removed)", [("    if (commits < primeCallbacks) return false;\n", "")], False),
 ("M26", "snapshot: fill sign flipped (r - w)", [("s->fill = w - r;", "s->fill = r - w;")], False),
 ("M27", "snapshot: fill from a re-read of w instead of the w loaded for the snapshot", [("s->fill = w - r;", "s->fill = atomic_load_explicit(&ring->w, memory_order_acquire) - r;")], False),
 ("M28", "phase uses cursor + frameCount", [("const double phase = (double)r - ts->mSampleTime;", "const double phase = (double)(r + F) - ts->mSampleTime;")], False),
 ("M29", "phase accepted without the kAudioTimeStampSampleTimeValid flag", [("if (ts && (ts->mFlags & kAudioTimeStampSampleTimeValid) && __builtin_isfinite(ts->mSampleTime)) {", "if (ts && __builtin_isfinite(ts->mSampleTime)) {")], False),
 ("M30", "weaker rule accepts any gap", [("if (d != 0 && d != F) sa_bump", "if (0) sa_bump")], False),
 ("M31", "output size check with a 32-bit product", [("(uint64_t)out->mBuffers[0].mDataByteSize >= (uint64_t)frameCount * 4u", "(uint32_t)out->mBuffers[0].mDataByteSize >= (uint32_t)(frameCount * 4u)")], False),
 ("M32", "output size check removed", [(" && (uint64_t)out->mBuffers[0].mDataByteSize >= (uint64_t)frameCount * 4u)) {", ")) {")], False),
 ("M33", "isSilence not set on a silent block", [("            silent = true;\n", "")], False),
 ("M34", "isSilence set although the block was served", [("                served = true;\n", "                served = true;\n                silent = true;\n")], False),
 ("M35", "producer does not count refused commits", [("    sa_bump(&ring->rejectedCommits, 1);\n    atomic_store_explicit(&ring->rejectFlags", "    atomic_store_explicit(&ring->rejectFlags")], False),
 ("M36", "an underrun is counted as served", [("sa_bump(&rd->underrunBlocks, 1);", "sa_bump(&rd->servedBlocks, 1);")], False),
 ("M37", "snapshot reads reader 0's counters for both channels", [("const SARingReader *rd = &ring->readers[c];", "const SARingReader *rd = &ring->readers[0];")], False),
 ("M38", "creation accepts a capacity that is not a power of two", [(" || (capacityFrames & (capacityFrames - 1u)) != 0", "")], True),
 ("M39", "margin removed at the producer (maxCommit = capacity)", [("ring->maxCommit = capacityFrames / 2u;", "ring->maxCommit = capacityFrames;")], True),
 ("M40", "producer does not store the last commit's size", [("    atomic_store_explicit(&ring->lastCommitFrames, frames, memory_order_relaxed);\n", "")], True),
 ("M41", "producer does not count commits", [("    sa_bump(&ring->commits, 1);\n", "")], True),
 ("M43", "render does not publish its phase", [("        atomic_store_explicit(&rd->phaseBits, sa_double_to_bits(phase), memory_order_relaxed);\n", "")], True),
 ("M44", "prime does not forget the published phase", [("        atomic_store_explicit(&rd->phaseBits, SA_PHASE_NONE_BITS, memory_order_relaxed);\n    }\n    atomic_store_explicit(&ring->rejectedCommits", "    }\n    atomic_store_explicit(&ring->rejectedCommits")], True),
 ("M45", "producer ignores w when choosing the slot (always slot i)", [("const uint64_t slot = (uint64_t)(w0 + (int64_t)i) & mask;", "const uint64_t slot = (uint64_t)i & mask;")], True),
 ("M46", "zero fill stops one sample short", [("for (int64_t i = 0; i < F; i++) dst[i] = 0.0f;", "for (int64_t i = 0; i < F - 1; i++) dst[i] = 0.0f;")], True),
 ("M47", "copy loop stops one sample short", [("for (int64_t i = 0; i < F; i++) dst[i] = SA_SAMPLE_LOAD(", "for (int64_t i = 0; i < F - 1; i++) dst[i] = SA_SAMPLE_LOAD(")], True),
]


def apply(text, edits, mid):
    for find, repl in edits:
        if text.count(find) != 1:
            sys.exit(f"{mid}: patch matches {text.count(find)} times (need exactly 1): {find[:80]!r}")
        text = text.replace(find, repl)
    return text


def run(cmd, env=None, timeout=HANG_SECONDS):
    start = time.monotonic()
    try:
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        return "HANG", f"no result within {timeout} s (monotonic)"
    tail = (r.stdout + r.stderr).strip().splitlines()
    return ("PASS" if r.returncode == 0 else "FAIL"), (tail[-1] if tail else f"exit {r.returncode}")[:200] + f"  [exit {r.returncode}]"


def objcode(c_path, out_obj):
    sdk = subprocess.run(["xcrun", "--show-sdk-path"], capture_output=True, text=True).stdout.strip()
    r = subprocess.run(["xcrun", "clang", "-x", "c", "-std=c11", "-Os", "-g", "-fobjc-arc", "-target", "arm64-apple-macos14.0", "-isysroot", sdk, "-I", str(SRC.parent / "include"),
                        "-Wno-function-effects", "-c", str(c_path), "-o", str(out_obj)], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    d = subprocess.run(["xcrun", "llvm-objdump", "-d", "--no-show-raw-insn", str(out_obj)], capture_output=True, text=True).stdout
    return "\n".join(l for l in d.splitlines() if "file format" not in l)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--swift", action="store_true")
    ap.add_argument("--only")
    ap.add_argument("--out", default=str(Path(os.environ.get("TMPDIR", "/tmp")) / "sa-ring-mutants"))
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    pristine = SRC.read_text()
    sha0 = hashlib.sha256(pristine.encode()).hexdigest()
    base_obj = objcode(SRC, out / "base.o")
    only = set(a.only.split(",")) if a.only else None
    results = []
    for mid, desc, edits, added in M:
        if only and mid not in only:
            continue
        text = apply(pristine, edits, mid)
        assert text != pristine, mid
        mpath = out / f"{mid}.c"
        mpath.write_text(text)
        env = dict(os.environ, SYSTEMAUDIORING_C=str(mpath))
        res = {"id": mid, "desc": desc, "addedAfterList": added, "detectors": {}}
        syn = subprocess.run(["xcrun", "clang", "-fsyntax-only", "-std=c11", "-Wno-function-effects", "-I", str(SRC.parent / "include"), str(mpath)], capture_output=True, text=True)
        if syn.returncode != 0:
            res["verdict"] = "DOES NOT COMPILE"; res["detail"] = syn.stderr.strip().splitlines()[0][:160]
            results.append(res); print(f"{mid:5} DOES NOT COMPILE  {res['detail']}", flush=True); continue
        D = res["detectors"]
        D["D1 check"] = run(["scripts/check-systemaudioring.sh", "check"], env)
        D["D2 paced"] = run(["scripts/check-systemaudioring.sh", "paced"], env)
        D["D2 lapping"] = run(["scripts/check-systemaudioring.sh", "lapping"], env)
        D["D3 tsan"] = run(["scripts/tsan-systemaudioring.sh", "plain"], env)
        D["D4 ubsan"] = run(["scripts/ubsan-systemaudioring.sh", "hostile"], env)
        mobj = objcode(mpath, out / f"{mid}.o")
        res["objectCodeIdentical"] = (mobj is not None and mobj == base_obj)
        if mobj is not None:
            sc = subprocess.run([sys.executable, "-I", str(ROOT / "scripts" / "scan_rt_block.py"), "zero", "--object", str(out / f"{mid}.o"), "_SARingIOProc", "_SARingWrite", "_SARingRender"], capture_output=True, text=True)
            D["D6 scan"] = ("PASS" if sc.returncode == 0 else "FAIL", (sc.stdout.strip().splitlines() or ["?"])[-1][:200])
        if a.swift:
            try:
                SRC.write_text(text)
                D["D5 swift"] = run(["swift", "test", "--filter", "SystemAudioRingTests"], timeout=900)
            finally:
                SRC.write_text(pristine)
            assert hashlib.sha256(SRC.read_bytes()).hexdigest() == sha0, "source not restored"
        killed = [k for k, v in D.items() if v[0] in ("FAIL", "HANG")]
        res["killedBy"] = killed
        res["verdict"] = "KILLED" if killed else "SURVIVED"
        results.append(res)
        print(f"{mid:5} {res['verdict']:9} by {', '.join(k.split()[0] + ' ' + k.split()[1] for k in killed) or '-':50} objcode-identical={res['objectCodeIdentical']}  {desc}", flush=True)
    assert hashlib.sha256(SRC.read_bytes()).hexdigest() == sha0, "source changed"
    (out / "results.json").write_text(json.dumps(results, indent=1))
    surv = [r["id"] for r in results if r["verdict"] == "SURVIVED"]
    print(f"\n{len(results)} mutants: {sum(r['verdict'] == 'KILLED' for r in results)} killed, {len(surv)} survived {surv}, {sum(r['verdict'] == 'DOES NOT COMPILE' for r in results)} did not compile. Source sha unchanged: {sha0[:12]}")
    return 0


sys.exit(main())
