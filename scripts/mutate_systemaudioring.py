#!/usr/bin/env python3
"""Mutation check of the Step 6b-1 ring (test-the-test, CLAUDE.md). Applies ONE deliberate bug at a time to Sources/CSystemAudioRing/CSystemAudioRing.c and
runs every detector. Every patch must match EXACTLY ONCE in the real file (else the run stops). A mutant SURVIVES if no detector fails on it.

  scripts/mutate_systemaudioring.py [--swift] [--only M01,M05] [--out DIR]

Detectors (each is one script run against a copy of the mutated file, so Sources/ is untouched, except --swift):
  D1 check    scripts/check-systemaudioring.sh check     deterministic checks, plain -Os build
  D2 paced    scripts/check-systemaudioring.sh paced     threaded stress, readers never overtaken
  D2 lapping  scripts/check-systemaudioring.sh lapping   threaded stress, readers overrun and torn (and jumping, Step 6b-3a-1)
  D2 cycles   scripts/check-systemaudioring.sh cycles    threaded, both readers concurrently in engine-like cycles with injected faults (Step 6b-3a-1)
  D3 tsan     scripts/tsan-systemaudioring.sh plain      ThreadSanitizer, plain-sample build, paced stress
  D4 ubsan    scripts/ubsan-systemaudioring.sh hostile   UBSan (recovery off) on hostile inputs, guard pages
  D5 swift    swift test --filter SystemAudioRingTests   (--swift only) patches Sources/ IN PLACE, restores it and verifies the sha afterwards
  D6 scan     scan_rt_block.py zero on _SARingIOProc, _SARingWrite, _SARingRender, compiled with the flags SwiftPM uses
Step 6b-3a-1 (render-side recovery): the mutants M01-M47 are the Step 6b-1 list, re-anchored where the recovery code moved the text they patch (M04, M05, M11, M11b, M12, M28,
M30, M44: same bug, new anchor); T01-T11 (frame-count table), O01-O12 (overrun jump), D01-D14 (divergence jump), P01-P09 (flags, standing fill), L01 are NEW and were written to a
timestamped scratch file (ring-recovery-mutations.md, 2026-11-17 22:27:24) BEFORE any code or harness change; the few marked `addedAfterList` were added after the code existed.
Run integrity (added in Step 6b-3a-1 after a run was killed by a lid sleep): every mutant's full detector result is appended to <out>/results.jsonl AS IT FINISHES and `--resume` skips
the ids already there; a detector that HANGs is reported separately from one that FAILs (a mutant that only hangs is KILLED-BY-HANG-ONLY, not a clean kill); with --swift the pristine source
is saved to <out>/PRISTINE.c and a lock file is written before it is patched in place, and the NEXT start restores the source from that file if a killed run left the lock behind.
Equivalent mutants must be listed in EQUIVALENT with the argument; nothing else may be called equivalent.
Also recorded: whether the mutant's object code (SwiftPM flags, -Os) is byte-identical to the real one (the only acceptable proof of an "equivalent mutant").
A detector run that does not finish within HANG_SECONDS is reported as HANG (a mutant that stops the harness is not a pass, but it is not counted as a clean kill
either); the limit uses time.monotonic(), which on macOS does not advance while the Mac sleeps. No verdict about the REAL code depends on it.
"""
import argparse, hashlib, json, os, signal, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Sources" / "CSystemAudioRing" / "CSystemAudioRing.c"
HANG_SECONDS = 240

# (id, description, [(find, replace), ...], added_after_the_list_was_written)
W_STORE = "atomic_store_explicit(&ring->w, w0 + (int64_t)frames, memory_order_release);"
FENCE_REL = "    atomic_thread_fence(memory_order_release);\n    sa_write_samples(ring, in, frames, w0);\n"
CURSOR_STORE = "atomic_store_explicit(&rd->cursor, next, memory_order_relaxed);"
NEXT_DECL = "    int64_t next = r + F;   /* where the cursor ends: the normal advance, unless an overrun moves it forward */\n"
R_LOAD = "    int64_t r = atomic_load_explicit(&rd->cursor, memory_order_relaxed);\n    sa_record_frames(rd, frameCount);\n"
M = [
 ("M01", "publish w BEFORE the data writes", [(FENCE_REL, "    " + W_STORE + "\n" + FENCE_REL), ("    " + W_STORE + "   /* publish only after every sample is written */\n", "")], False),
 ("M02", "relaxed instead of release on the store of w", [(W_STORE, W_STORE.replace("release", "relaxed"))], False),
 ("M03", "relaxed instead of acquire on the render's load of w", [("const int64_t w1 = atomic_load_explicit(&ring->w, memory_order_acquire);", "const int64_t w1 = atomic_load_explicit(&ring->w, memory_order_relaxed);")], False),
 ("M04", "cursor advances by frameCount + 1", [(NEXT_DECL, NEXT_DECL.replace("r + F;", "r + F + 1;"))], False),
 ("M05", "cursor advances by frameCount - 1", [(NEXT_DECL, NEXT_DECL.replace("r + F;", "r + F - 1;"))], False),
 ("M06", "mask off by one at capacity (mask = capacity)", [("ring->mask = capacityFrames - 1u;", "ring->mask = capacityFrames;")], False),
 ("M07", "wrap off by one (slot = index % (capacity - 1), producer and readers consistently)",
  [("const uint64_t slot = (uint64_t)(w0 + (int64_t)i) & mask;", "const uint64_t slot = (uint64_t)(w0 + (int64_t)i) % (uint64_t)(ring->capacity - 1u);"),
   ("dst[i] = SA_SAMPLE_LOAD(&src[(uint64_t)(r + i) & mask]);", "dst[i] = SA_SAMPLE_LOAD(&src[(uint64_t)(r + i) % (uint64_t)(ring->capacity - 1u)]);")], False),
 ("M08", "underrun not zero-filled (stale data stays in the output)", [("for (int64_t i = 0; i < F; i++) dst[i] = 0.0f;", "for (int64_t i = 0; i < 0; i++) dst[i] = 0.0f;")], False),
 ("M09", "channel swapped (each reader reads the other plane)", [("const SASample *src = ring->plane[rd->channel];", "const SASample *src = ring->plane[1u - rd->channel];")], False),
 ("M10", "both readers read ONE channel (plane 0)", [("const SASample *src = ring->plane[rd->channel];", "const SASample *src = ring->plane[0];")], False),
 ("M11", "order-dependent design: ONE shared cursor, advanced by whichever block runs (every call moves it)  [NAMED in the design]",
  [(R_LOAD, R_LOAD.replace("&rd->cursor", "&((SARing *)rd->ring)->readers[0].cursor")),
   (CURSOR_STORE + "   /* exactly", CURSOR_STORE.replace("&rd->cursor", "&((SARing *)rd->ring)->readers[0].cursor") + "   /* exactly")], False),
 ("M11b", "order-dependent design, the withdrawn draft: ONE shared cursor advanced only by the block that is assumed to run second (channel 1)  [NAMED in the design]",
  [(R_LOAD, R_LOAD.replace("&rd->cursor", "&((SARing *)rd->ring)->readers[0].cursor")),
   (CURSOR_STORE + "   /* exactly", "if (rd->channel == 1) " + CURSOR_STORE.replace("&rd->cursor", "&((SARing *)rd->ring)->readers[0].cursor") + "   /* exactly")], True),
 ("M12", "cursor advances only by the frames actually served (silent blocks do not advance it)  [NAMED in the design: advance by the frames read instead of the frames asked]", [(CURSOR_STORE, CURSOR_STORE.replace("next", "(silent ? r : next)"))], False),
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
 ("M28", "phase uses cursor + frameCount", [("double phase = (double)r - ts->mSampleTime;", "double phase = (double)(r + F) - ts->mSampleTime;")], False),
 ("M29", "phase accepted without the kAudioTimeStampSampleTimeValid flag", [("if (ts && (ts->mFlags & kAudioTimeStampSampleTimeValid) && __builtin_isfinite(ts->mSampleTime)) {", "if (ts && __builtin_isfinite(ts->mSampleTime)) {")], False),
 ("M30", "weaker rule accepts any gap", [("if (d != 0 && d != F) {", "if (0) {")], False),
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
 ("M44", "prime does not forget the published phase", [("        atomic_store_explicit(&rd->phaseBits, SA_PHASE_NONE_BITS, memory_order_relaxed);\n    }\n    atomic_store_explicit(&ring->standingFill", "    }\n    atomic_store_explicit(&ring->standingFill")], True),
 ("M45", "producer ignores w when choosing the slot (always slot i)", [("const uint64_t slot = (uint64_t)(w0 + (int64_t)i) & mask;", "const uint64_t slot = (uint64_t)i & mask;")], True),
 ("M46", "zero fill stops one sample short", [("for (int64_t i = 0; i < F; i++) dst[i] = 0.0f;", "for (int64_t i = 0; i < F - 1; i++) dst[i] = 0.0f;")], True),
 ("M47", "copy loop stops one sample short", [("for (int64_t i = 0; i < F; i++) dst[i] = SA_SAMPLE_LOAD(", "for (int64_t i = 0; i < F - 1; i++) dst[i] = SA_SAMPLE_LOAD(")], True),
 # ---- Step 6b-3a-1: the per-call frame-count record ----
 ("T01", "table: a repeat is counted in slot 0 instead of its own slot", [("        sa_bump(&rd->ftCalls[i], 1);\n", "        sa_bump(&rd->ftCalls[0], 1);\n")], False),
 ("T02", "table: a new distinct value is never added (always overflow)", [("} else if (used < SA_RING_FRAME_TABLE_SLOTS) {", "} else if (0) {")], False),
 ("T03", "table: overflow calls are not counted", [("        sa_bump(&rd->ftOverflow, 1);\n", "")], False),
 ("T04", "table: overflow condition off by one (the last slot is never used)", [("} else if (used < SA_RING_FRAME_TABLE_SLOTS) {", "} else if (used + 1u < SA_RING_FRAME_TABLE_SLOTS) {")], False),
 ("T05", "table: min is never updated", [("    if ((uint64_t)frameCount < atomic_load_explicit(&rd->minFrames, memory_order_relaxed)) atomic_store_explicit(&rd->minFrames, frameCount, memory_order_relaxed);\n", "")], False),
 ("T06", "table: max update uses < (stores the minimum)", [("if ((uint64_t)frameCount > atomic_load_explicit(&rd->maxFrames, memory_order_relaxed))", "if ((uint64_t)frameCount < atomic_load_explicit(&rd->maxFrames, memory_order_relaxed))")], False),
 ("T07", "table: min and max ignore a value the first time it appears", [("    if ((uint64_t)frameCount < atomic_load_explicit(&rd->minFrames", "    if (i < used && (uint64_t)frameCount < atomic_load_explicit(&rd->minFrames"), ("    if ((uint64_t)frameCount > atomic_load_explicit(&rd->maxFrames", "    if (i < used && (uint64_t)frameCount > atomic_load_explicit(&rd->maxFrames")], False),
 ("T08", "table: a bad-buffer call is not recorded (recorded only after the buffer check)", [("    sa_record_frames(rd, frameCount);\n    const int64_t standing", "    const int64_t standing"), ("        float *dst = (float *)out->mBuffers[0].mData;\n", "        sa_record_frames(rd, frameCount);\n        float *dst = (float *)out->mBuffers[0].mData;\n")], False),
 ("T09", "table: the count of a repeated value is not incremented", [("        sa_bump(&rd->ftCalls[i], 1);\n", "        (void)i;\n")], False),
 ("T10", "table: snapshot copies reader 0's values for both channels", [("atomic_load_explicit(&rd->ftValue[k], memory_order_relaxed) : 0;", "atomic_load_explicit(&ring->readers[0].ftValue[k], memory_order_relaxed) : 0;")], False),
 ("T11", "table: prime does not reset the table", [("        atomic_store_explicit(&rd->ftUsed, 0, memory_order_relaxed);\n", "")], False),
 # ---- the overrun forward jump to w - T ----
 ("O01", "overrun jump: target off by one (w - T + 1)", [("const int64_t target = w1 - standing;", "const int64_t target = w1 - standing + 1;")], False),
 ("O02", "overrun jump: target = w - T - 1", [("const int64_t target = w1 - standing;", "const int64_t target = w1 - standing - 1;")], False),
 ("O03", "overrun jump: forward-only removed (a target behind the normal advance is taken)", [("            if (target > next) {", "            if (target != next) {")], False),
 ("O04", "overrun jump: a jump of exactly N - T is refused (> replaced by >=)", [("                if (jump > maxJump) {", "                if (jump >= maxJump) {")], False),
 ("O05", "overrun jump: a jump of N - T + 1 is allowed", [("                if (jump > maxJump) {", "                if (jump > maxJump + 1) {")], False),
 ("O06", "overrun jump: the jump size counted is the TARGET, not the frames beyond the normal advance", [("sa_bump(&rd->overrunJumpFrames, (uint64_t)jump);", "sa_bump(&rd->overrunJumpFrames, (uint64_t)target);")], False),
 ("O06b", "overrun jump: the jump is made but not counted", [("                    sa_bump(&rd->overrunJumps, 1);\n                    sa_bump(&rd->overrunJumpFrames", "                    sa_bump(&rd->overrunJumpFrames")], FTrue),
 ("O07", "overrun jump: the bound check is removed (any jump is made)", [("                if (jump > maxJump) {", "                if (0) {")], False),
 ("O08", "overrun jump: a refused jump does not set needsReprime", [("                    sa_bump(&rd->refusedJumps, 1);\n                    atomic_store_explicit(&rd->needsReprime, 1, memory_order_relaxed);\n                } else {\n                    next = target;", "                    sa_bump(&rd->refusedJumps, 1);\n                } else {\n                    next = target;")], False),
 ("O09", "overrun jump: a refused jump is made anyway (and flagged)", [("                } else {\n                    next = target;", "                }\n                if (1) {\n                    next = target;")], False),
 ("O10", "overrun jump: an UNDERRUN also moves the cursor to w - T (unconditionally: BACKWARD when the cursor is ahead of w - T)", [("            sa_bump(&rd->underrunBlocks, 1);\n", "            sa_bump(&rd->underrunBlocks, 1);\n            next = w1 - standing;\n")], False),
 ("O10x", "overrun jump: an underrun moves the cursor to w - T only if that is beyond the normal advance (the guarded form the list first described)", [("            sa_bump(&rd->underrunBlocks, 1);\n", "            sa_bump(&rd->underrunBlocks, 1);\n            if (w1 - standing > next) next = w1 - standing;\n")], True),
 ("O11", "overrun jump: the cursor ends at the target PLUS frameCount", [("                    next = target;\n", "                    next = target + F;\n")], False),
 ("O12", "overrun jump: no standing fill (target = w)", [("const int64_t target = w1 - standing;", "const int64_t target = w1;")], False),
 ("L01", "largest jump is never recorded for an overrun jump", [("                if ((uint64_t)jump > atomic_load_explicit(&rd->largestJump, memory_order_relaxed)) atomic_store_explicit(&rd->largestJump, (uint64_t)jump, memory_order_relaxed);\n", "")], True),
 # ---- the divergence jump by the phase rule ----
 ("D01", "divergence jump: direction swapped (the block that is AHEAD jumps)", [("            const double diff = theirs - phase;\n", "            const double diff = phase - theirs;\n")], False),
 ("D02", "divergence jump: size off by one (k + 1)", [("                        r += k;\n", "                        r += k + 1;\n")], False),
 ("D03", "divergence jump: the behind block jumps BACKWARD  [NAMED in the design]", [("                        r += k;\n", "                        r -= k;\n")], False),
 ("D04", "divergence jump: BOTH blocks jump by |difference| whenever the phases differ", [("            const double diff = theirs - phase;\n", "            const double diff = theirs > phase ? theirs - phase : phase - theirs;\n")], False),
 ("D05", "divergence: with an unusable timestamp the block jumps by the cursor difference instead of only counting and flagging", [("        if (d != 0 && d != F) {\n            sa_bump(&rd->weakRuleViolations, 1);", "        if (d > 0 && d != F) r += d;\n        if (d != 0 && d != F) {\n            sa_bump(&rd->weakRuleViolations, 1);")], False),
 ("D06", "divergence: with an unusable timestamp the diverged flag and needsReprime are not set", [("            atomic_store_explicit(&rd->diverged, 1, memory_order_relaxed);        /* no phase to realign by: count, flag, no jump */\n            atomic_store_explicit(&rd->needsReprime, 1, memory_order_relaxed);\n        }\n        sa_bump(&rd->phaseInvalidCalls", "        }\n        sa_bump(&rd->phaseInvalidCalls")], False),
 ("D07", "divergence jump: the phase published after the jump is the OLD one", [("                        phase = (double)r - ts->mSampleTime;   /* the phase after the jump: what the other block should now see */\n", "")], False),
 ("D08", "divergence jump: the whole-frames check is removed (a fractional difference is rounded and jumped)", [("if (k <= 0 || __builtin_fabs((double)k - diff) > 1.0e-6) {", "if (k <= 0) {")], False),
 ("D09", "divergence: the 'peer has published no phase' (NaN) guard is removed", [("if (theirs == theirs && theirs != phase) {", "if (theirs != phase) {")], False),
 ("D10", "divergence jump: the bound check is removed", [("                    if (k > maxJump) {", "                    if (0) {")], False),
 ("D11", "divergence jump: a refused jump does not set needsReprime", [("                        sa_bump(&rd->refusedJumps, 1);\n                        atomic_store_explicit(&rd->needsReprime, 1, memory_order_relaxed);\n                    } else {\n                        r += k;", "                        sa_bump(&rd->refusedJumps, 1);\n                    } else {\n                        r += k;")], False),
 ("D12", "divergence jump: the jump is made but not counted", [("                        sa_bump(&rd->divergenceJumps, 1);\n", "")], False),
 ("D12b", "divergence jump: the jump frames are not counted", [("                        sa_bump(&rd->divergenceJumpFrames, (uint64_t)k);\n", "")], FTrue),
 ("D13", "divergence jump: the block still READS from its old position this call (the jump only moves where the cursor ends)",
  [("    sa_record_frames(rd, frameCount);\n    const int64_t standing", "    sa_record_frames(rd, frameCount);\n    int64_t lateJump = 0;\n    const int64_t standing"), ("                        r += k;\n", "                        lateJump = k;\n"), (CURSOR_STORE, CURSOR_STORE.replace("next", "next + lateJump"))], False),
 ("D14", "divergence jump: the size guard (diff < 9e15) before the float-to-integer cast is removed", [("const int64_t k = diff < 9.0e15 ? (int64_t)(diff + 0.5) : 0;", "const int64_t k = (int64_t)(diff + 0.5);")], True),
 # ---- flags, standing fill, snapshot ----
 ("P01", "prime does not clear needsReprime", [("        atomic_store_explicit(&rd->diverged, 0, memory_order_relaxed); atomic_store_explicit(&rd->needsReprime, 0, memory_order_relaxed);\n", "        atomic_store_explicit(&rd->diverged, 0, memory_order_relaxed);\n")], False),
 ("P02", "prime does not clear the sticky diverged flag", [("        atomic_store_explicit(&rd->diverged, 0, memory_order_relaxed); atomic_store_explicit(&rd->needsReprime, 0, memory_order_relaxed);\n", "        atomic_store_explicit(&rd->needsReprime, 0, memory_order_relaxed);\n")], False),
 ("P03", "snapshot reports needsReprime from reader 0 only", [("if (s->needsReprime) out->needsReprime = 1;", "if (c == 0 && s->needsReprime) out->needsReprime = 1;")], False),
 ("P04", "needsReprime is set on an ordinary underrun (it must not be)", [("            sa_bump(&rd->underrunBlocks, 1);\n", "            sa_bump(&rd->underrunBlocks, 1);\n            atomic_store_explicit(&rd->needsReprime, 1, memory_order_relaxed);\n")], False),
 ("P05", "the weak rule treats d == 0 (lockstep) as a violation", [("if (d != 0 && d != F) {", "if (d != F) {")], False),
 ("P06", "prime does not store the standing fill T", [("    atomic_store_explicit(&ring->standingFill, (uint32_t)depth, memory_order_relaxed);   /* T := the depth just primed (depth <= window, so it fits) */\n", "")], False),
 ("P07", "default standing fill T is 0", [("atomic_init(&ring->standingFill, t);", "atomic_init(&ring->standingFill, 0);")], False),
 ("P08", "snapshot reports standingFill 0", [("out->standingFill = atomic_load_explicit(&ring->standingFill, memory_order_relaxed);", "out->standingFill = 0;")], False),
 ("P09", "snapshot: the overrun-jump counter is read from reader 0 for both channels", [("s->overrunJumps = atomic_load_explicit(&rd->overrunJumps, memory_order_relaxed);", "s->overrunJumps = atomic_load_explicit(&ring->readers[0].overrunJumps, memory_order_relaxed);")], False),
]


# Mutants shown EQUIVALENT by an argument (not merely "no detector killed it"). Each reason must be checkable from the source.
EQUIVALENT = {
    "O10x": "in the underrun branch the condition is r + F > w1, and `next` is r + F, so next > w1 >= w1 - standing (standing >= 0): the guard `w1 - standing > next` is never true; the added line is dead code",
}


def apply(text, edits, mid):
    for find, repl in edits:
        if text.count(find) != 1:
            sys.exit(f"{mid}: patch matches {text.count(find)} times (need exactly 1): {find[:80]!r}")
        text = text.replace(find, repl)
    return text


def run(cmd, env=None, timeout=HANG_SECONDS):
    """Run one detector. It gets its OWN session (process group); if it does not finish within `timeout` seconds (time.monotonic) the WHOLE group is sent SIGTERM and, if
    anything is left after 5 s, SIGKILL, so a hung harness binary cannot outlive the detector script that started it. (Until Step 6b-3a-1 this used subprocess.run(timeout=), which
    kills only the direct child: the stress binaries of the six HUNG detectors of M11 and M11b kept spinning for about an hour and used about 8 cores. The script version that ran the
    97 mutants of the Step 6b-3a-1 record has the sha256 9588e999e02d210f20a567bcbca2d87f9b2738235a64c32acbe4b1599ba0e638.)"""
    p = subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, start_new_session=True)
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        for sig, grace in ((signal.SIGTERM, 5), (signal.SIGKILL, None)):
            try:
                os.killpg(p.pid, sig)
            except ProcessLookupError:
                break
            if grace is not None:
                try:
                    p.communicate(timeout=grace)
                    break
                except subprocess.TimeoutExpired:
                    continue
        try:
            p.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        return "HANG", f"no result within {timeout} s (monotonic); the whole process group was terminated"
    tail = (out + err).strip().splitlines()
    return ("PASS" if p.returncode == 0 else "FAIL"), (tail[-1] if tail else f"exit {p.returncode}")[:200] + f"  [exit {p.returncode}]"


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
    ap.add_argument("--resume", action="store_true", help="skip the ids already in <out>/results.jsonl (they are included in the summary)")
    ap.add_argument("--out", default=str(Path(os.environ.get("TMPDIR", "/tmp")) / "sa-ring-mutants"))
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    lock = out / "INPLACE.lock"
    if lock.exists():   # a previous --swift run was killed while the source was patched: put the saved pristine text back first
        SRC.write_text((out / "PRISTINE.c").read_text()); lock.unlink()
        print(f"RESTORED {SRC} from {out / 'PRISTINE.c'} (a previous run was killed while it was patched)", flush=True)
    pristine = SRC.read_text()
    sha0 = hashlib.sha256(pristine.encode()).hexdigest()
    base_obj = objcode(SRC, out / "base.o")
    only = set(a.only.split(",")) if a.only else None
    results = []
    jsonl = out / "results.jsonl"
    done = {}
    if a.resume and jsonl.exists():
        for line in jsonl.read_text().splitlines():
            r = json.loads(line); done[r["id"]] = r
    for mid, desc, edits, added in M:
        if only and mid not in only:
            continue
        if mid in done:
            results.append(done[mid]); print(f"{mid:5} (from results.jsonl) {done[mid]['verdict']}", flush=True); continue
        text = apply(pristine, edits, mid)
        assert text != pristine, mid
        mpath = out / f"{mid}.c"
        mpath.write_text(text)
        env = dict(os.environ, SYSTEMAUDIORING_C=str(mpath))
        res = {"id": mid, "desc": desc, "addedAfterList": added, "detectors": {}}
        syn = subprocess.run(["xcrun", "clang", "-fsyntax-only", "-std=c11", "-Wno-function-effects", "-I", str(SRC.parent / "include"), str(mpath)], capture_output=True, text=True)
        if syn.returncode != 0:
            res["verdict"] = "DOES NOT COMPILE"; res["detail"] = syn.stderr.strip().splitlines()[0][:160]
            results.append(res); jsonl.open("a").write(json.dumps(res) + "\n"); print(f"{mid:5} DOES NOT COMPILE  {res['detail']}", flush=True); continue
        D = res["detectors"]
        D["D1 check"] = run(["scripts/check-systemaudioring.sh", "check"], env)
        D["D2 paced"] = run(["scripts/check-systemaudioring.sh", "paced"], env)
        D["D2 lapping"] = run(["scripts/check-systemaudioring.sh", "lapping"], env)
        D["D2 cycles"] = run(["scripts/check-systemaudioring.sh", "cycles"], env)
        D["D3 tsan"] = run(["scripts/tsan-systemaudioring.sh", "plain"], env)
        D["D4 ubsan"] = run(["scripts/ubsan-systemaudioring.sh", "hostile"], env)
        mobj = objcode(mpath, out / f"{mid}.o")
        res["objectCodeIdentical"] = (mobj is not None and mobj == base_obj)
        if mobj is not None:
            sc = subprocess.run([sys.executable, "-I", str(ROOT / "scripts" / "scan_rt_block.py"), "zero", "--object", str(out / f"{mid}.o"), "_SARingIOProc", "_SARingWrite", "_SARingRender"], capture_output=True, text=True)
            D["D6 scan"] = ("PASS" if sc.returncode == 0 else "FAIL", (sc.stdout.strip().splitlines() or ["?"])[-1][:200])
        if a.swift:
            try:
                (out / "PRISTINE.c").write_text(pristine); lock.write_text(mid)   # a killed run leaves these behind; the next start restores
                SRC.write_text(text)
                D["D5 swift"] = run(["swift", "test", "--filter", "SystemAudioRingTests"], timeout=900)
            finally:
                SRC.write_text(pristine); lock.unlink(missing_ok=True)
            assert hashlib.sha256(SRC.read_bytes()).hexdigest() == sha0, "source not restored"
        fails = [k for k, v in D.items() if v[0] == "FAIL"]
        hangs = [k for k, v in D.items() if v[0] == "HANG"]
        res["killedBy"] = fails; res["hangedOn"] = hangs
        res["verdict"] = "KILLED" if fails else ("KILLED-BY-HANG-ONLY" if hangs else ("EQUIVALENT" if mid in EQUIVALENT else "SURVIVED"))
        if mid in EQUIVALENT: res["equivalentBecause"] = EQUIVALENT[mid]
        results.append(res)
        jsonl.open("a").write(json.dumps(res) + "\n")
        tag = lambda k: k.split()[0] + " " + k.split()[1]
        print(f"{mid:5} {res['verdict']:9} by {', '.join(tag(k) for k in fails) or '-':50}{(' HANG ' + ', '.join(tag(k) for k in hangs)) if hangs else ''} objcode-identical={res['objectCodeIdentical']}  {desc}", flush=True)
    assert hashlib.sha256(SRC.read_bytes()).hexdigest() == sha0, "source changed"
    (out / "results.json").write_text(json.dumps(results, indent=1))
    surv = [r["id"] for r in results if r["verdict"] == "SURVIVED"]
    eq = [r["id"] for r in results if r["verdict"] == "EQUIVALENT"]
    hangonly = [r["id"] for r in results if r["verdict"] == "KILLED-BY-HANG-ONLY"]
    per = {}
    for r in results:
        for k in r.get("killedBy", []): per.setdefault(k, [0, 0])[0] += 1
        for k in r.get("hangedOn", []): per.setdefault(k, [0, 0])[1] += 1
    print(f"\n{len(results)} mutants: {sum(r['verdict'] == 'KILLED' for r in results)} killed (at least one detector FAILED cleanly), {len(hangonly)} killed only by a HANG {hangonly}, {len(eq)} equivalent {eq}, "
          f"{len(surv)} survived {surv}, {sum(r['verdict'] == 'DOES NOT COMPILE' for r in results)} did not compile. Source sha unchanged: {sha0[:12]}")
    print("per detector (clean FAILs / HANGs): " + ", ".join(f"{k}: {v[0]} / {v[1]}" for k, v in sorted(per.items())))
    return 0


sys.exit(main())
