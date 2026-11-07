#!/usr/bin/env python3
"""Builds ONE deliberately broken variant of the Step 6b render path from the REAL sources, shows that the intended call is really in the object the
scan reads, and runs the scan on it (docs/ARCHITECTURE.md "Scan rule for the Step 6b block"). Driven by scripts/scan-rt-block-cases.sh.

  rt_block_cases.py CASE        CASE = 1v | 2 | 3 | 4 | 5 | p1 | p2 | p3 | p4     (case 1 is the shipped release objects: scripts/scan-rt-block.sh)

Every patch must match EXACTLY ONCE in the real source (else the run stops with exit 3). The objects are compiled with the flags SwiftPM uses for
this target (read from its build: -Os -g -fobjc-arc -std=c11, arm64-apple-macos14.0) except that -Werror=function-effects is turned off (the
compile-time check would otherwise reject the variant before the scan could be shown to). If the intended call is NOT in the object (clang deleted it)
the run stops with exit 3 and the variant is not counted. Otherwise the exit code is the scan's (0 pass, 1 rule violated); exit 4 = the scan failed but
did not name the expected cause.  Scratch output goes under $SA_SCRATCH (default: $TMPDIR/sa-rt-cases).
"""
import os, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Sources" / "CSystemAudioRing"
SCRATCH = Path(os.environ.get("SA_SCRATCH") or (Path(os.environ.get("TMPDIR", "/tmp")) / "sa-rt-cases"))
BLOCK_FN = "___SACreateSourceNode_block_invoke"
SINK = "static void *volatile gSink;"
MALLOC = "gSink = malloc(64);   /* stored through a volatile global so clang cannot delete the malloc */"


def sh(*args, check=True):
    return subprocess.run(args, capture_output=True, text=True, check=check)


def apply(text, edits, what):
    for find, repl in edits:
        if text.count(find) != 1:
            print(f"error: patch for {what} matches {text.count(find)} times (need exactly 1): {find[:70]!r}")
            sys.exit(3)
        text = text.replace(find, repl)
    return text


def clean_copy_of_render(c_text):
    i = c_text.index("OSStatus SARingRender(")
    body = c_text[i:]
    assert body.count("OSStatus SARingRender(") == 1
    return "\n/* variant: a clean copy under another name */\n" + body.replace("OSStatus SARingRender(", "OSStatus SARingRenderClean(")


M_DECL_OLD = '#import "CSystemAudioRing.h"'
CALL_OLD = "const OSStatus status = SARingRender(reader, &silent, timestamp, frameCount, outputData);"
IOPROC_OLD = "    SARing *ring = (SARing *)inClientData;\n    if (!ring) return 0;\n"
# case id -> (description, expected tag, C edits, M edits, extra C text, (object, function, callee symbol, how many call lines expected))
CASES = {
    "1v": ("control through the variant pipeline: UNMODIFIED sources", None, [], [], "", None),
    "2": ("the block calls a DIFFERENT, clean function (SARingRenderClean, a copy of SARingRender) instead of the allow-listed one",
          "NOT-ALLOW-LISTED", [], [(M_DECL_OLD, M_DECL_OLD + "\nOSStatus SARingRenderClean(SARingReader *reader, bool *isSilence, const AudioTimeStamp *timestamp, uint32_t frameCount, AudioBufferList *outputData);"),
                                  (CALL_OLD, CALL_OLD.replace("SARingRender(", "SARingRenderClean("))], "CLEAN", ("M", BLOCK_FN, "_SARingRenderClean", 1)),
    "3": ("a direct malloc inside the block", "NOT-ALLOW-LISTED", [],
          [("AVAudioSourceNode *SACreateSourceNode(", "#import <stdlib.h>\n" + SINK + "\nAVAudioSourceNode *SACreateSourceNode("),
           ("        bool silent = false;\n", "        bool silent = false;\n        " + MALLOC + "\n")], "", ("M", BLOCK_FN, "_malloc", 1)),
    "4": ("the allow-listed callee called TWICE", "CALL-COUNT", [],
          [(CALL_OLD, CALL_OLD.replace("const OSStatus status", "OSStatus status") + "\n        status |= SARingRender(reader, &silent, timestamp, frameCount, outputData);")], "", ("M", BLOCK_FN, "_SARingRender", 2)),
    "5": ("the allow-listed callee itself calls malloc", "CALLEE-CALLS",
          [("#define SA_PHASE_NONE_BITS 0x7ff8000000000000ull", "#define SA_PHASE_NONE_BITS 0x7ff8000000000000ull\n" + SINK),
           ("    const SARing *ring = rd->ring;\n", "    const SARing *ring = rd->ring;\n    " + MALLOC + "\n")], [], "", ("C", "_SARingRender", "_malloc", 1)),
    "p1": ("producer: malloc inside SARingIOProc", "CALLS",
           [("#define SA_PHASE_NONE_BITS 0x7ff8000000000000ull", "#define SA_PHASE_NONE_BITS 0x7ff8000000000000ull\n" + SINK),
            (IOPROC_OLD, IOPROC_OLD + "    " + MALLOC + "\n")], [], "", ("C", "_SARingIOProc", "_malloc", 1)),
    "p2": ("producer: the write helper is no longer inlined (SARingIOProc and SARingWrite each call it)", "CALLS",
           [("static inline __attribute__((always_inline)) CA_REALTIME_API void sa_write(", "static __attribute__((noinline)) CA_REALTIME_API void sa_write(")], [], "", ("C", "_SARingIOProc", "_sa_write", 1)),
    "p3": ("producer: a 512-byte struct copy that compiles to a hidden memcpy", "CALLS",
           [("#define SA_PHASE_NONE_BITS 0x7ff8000000000000ull", "#define SA_PHASE_NONE_BITS 0x7ff8000000000000ull\nstruct SABig { char b[512]; };\nstruct SABig gBigA, gBigB;"),
            (IOPROC_OLD, IOPROC_OLD + "    gBigA = gBigB;\n")], [], "", ("C", "_SARingIOProc", "_memcpy", 1)),
    "p4": ("producer: a mutex lock and unlock", "CALLS",
           [("#define SA_PHASE_NONE_BITS 0x7ff8000000000000ull", "#define SA_PHASE_NONE_BITS 0x7ff8000000000000ull\n#include <pthread.h>\nstatic pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;"),
            (IOPROC_OLD, IOPROC_OLD + "    pthread_mutex_lock(&gLock);\n    pthread_mutex_unlock(&gLock);\n")], [], "", ("C", "_SARingIOProc", "_pthread_mutex_lock", 1)),
}


def function_text(obj, fn):
    out, grab = [], False
    for line in sh("xcrun", "llvm-objdump", "-d", "-r", "--no-show-raw-insn", str(obj)).stdout.splitlines():
        m = re.match(r"^[0-9a-f]{16} <(.+)>:$", line)
        if m and m.group(1).startswith("_"):
            grab = m.group(1) == fn
        if grab:
            out.append(line)
    return out


def evidence(obj, fn, callee, expected):
    """Print the call instruction line(s) and their relocation line(s) found in `fn` of `obj`. Returns how many were found."""
    lines = function_text(obj, fn)
    found = 0
    for i, line in enumerate(lines):
        if re.search(r"\s(bl|b)\s", line) and i + 1 < len(lines):
            nxt = lines[i + 1]
            if re.search(r"ARM64_RELOC_BRANCH26\s+" + re.escape(callee) + r"\s*$", nxt) or (callee in line and "RELOC" not in nxt):
                print("   ", line.strip())
                if "RELOC" in nxt:
                    print("   ", nxt.strip())
                found += 1
    return found


def main():
    case = sys.argv[1] if len(sys.argv) > 1 else ""
    if case not in CASES:
        print(__doc__)
        return 2
    desc, expect_tag, c_edits, m_edits, extra, ev = CASES[case]
    d = SCRATCH / f"case-{case}"
    d.mkdir(parents=True, exist_ok=True)
    c_text = (SRC / "CSystemAudioRing.c").read_text()
    m_text = (SRC / "SASourceNode.m").read_text()
    c_new = apply(c_text, c_edits, f"case {case} (C)")
    m_new = apply(m_text, m_edits, f"case {case} (ObjC)")
    if extra == "CLEAN":
        c_new += clean_copy_of_render(c_text)
    (d / "CSystemAudioRing.c").write_text(c_new)
    (d / "SASourceNode.m").write_text(m_new)
    sdk = sh("xcrun", "--show-sdk-path").stdout.strip()
    common = ["-std=c11", "-Os", "-g", "-fobjc-arc", "-target", "arm64-apple-macos14.0", "-isysroot", sdk, "-I", str(SRC / "include"), "-Wno-function-effects", "-c"]
    c_obj, m_obj = d / "CSystemAudioRing.o", d / "SASourceNode.o"
    for lang, src, obj in (("c", d / "CSystemAudioRing.c", c_obj), ("objective-c", d / "SASourceNode.m", m_obj)):
        r = sh("xcrun", "clang", "-x", lang, *common, str(src), "-o", str(obj), check=False)
        if r.returncode != 0:
            print(f"error: variant did not compile ({src.name}):\n{r.stderr[:600]}")
            return 3
    print(f"case {case}: {desc}\nvariant sources and objects: {d}")
    if case == "5":   # bonus: with the real flag the compiler itself refuses this one
        r = sh("xcrun", "clang", "-x", "c", *[a for a in common if a != "-Wno-function-effects"], "-Werror=function-effects", str(d / "CSystemAudioRing.c"), "-o", str(d / "with-real-flags.o"), check=False)
        first = next((l for l in r.stderr.splitlines() if "error" in l), "(compiled: the compile-time check did NOT catch it)")
        print("compile-time check with the real flag (-Werror=function-effects):", first.split("error:")[-1].strip())
    if ev:
        which, fn, callee, expected = ev
        obj = c_obj if which == "C" else m_obj
        print(f"(a) disassembly of {fn} from the SAME object the scan reads ({obj.name}), `llvm-objdump -d -r`, lines with a call to {callee}:")
        n = evidence(obj, fn, callee, expected)
        if n != expected:
            print(f"VARIANT NOT BROKEN AT OBJECT LEVEL: expected {expected} call line(s) to {callee} in {fn}, found {n}. Not counted.")
            return 3
        if extra == "CLEAN":
            print(f"    the substituted callee is itself clean (existing zero-call rule on _SARingRenderClean in {c_obj.name}):")
            r = sh(sys.executable, "-I", str(ROOT / "scripts" / "scan_rt_callback.py"), str(c_obj), "_SARingRenderClean", check=False)
            print("   ", r.stdout.strip().splitlines()[-1], f"[exit {r.returncode}]")
    wrapper = [str(ROOT / "scripts" / "scan-rt-block.sh")] + (["--producer-object", str(c_obj)] if case.startswith("p") else ["--objects", str(m_obj), str(c_obj)])
    print("(b) scan:", " ".join(["scripts/scan-rt-block.sh"] + wrapper[1:]).replace(str(d) + "/", "<variant dir>/"))
    r = sh(*wrapper, check=False)
    print(r.stdout.rstrip())
    if r.stderr.strip():
        print(r.stderr.rstrip())
    print(f"scan exit code: {r.returncode}")
    if expect_tag is None:
        print("case verdict: AS REQUIRED (the control passes)" if r.returncode == 0 else "case verdict: NOT AS REQUIRED (the control failed)")
        return r.returncode
    if r.returncode != 1:
        print(f"case verdict: NOT AS REQUIRED (the scan should FAIL with exit 1, it exited {r.returncode})")
        return 4
    if f"[{expect_tag}]" not in r.stdout:
        print(f"case verdict: NOT AS REQUIRED (the scan failed, but never named the expected cause [{expect_tag}])")
        return 4
    print(f"case verdict: AS REQUIRED (the scan FAILED and the message names the cause [{expect_tag}])")
    return 1


sys.exit(main())
