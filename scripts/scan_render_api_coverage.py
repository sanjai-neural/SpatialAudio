#!/usr/bin/env python3
"""Step 6b-2: the scan-coverage guard. scripts/scan-rt-block.sh scans ONE render block (the one in SASourceNode.m). This guard makes sure there is no OTHER
render block it does not scan: it fails if a render-block API appears in compiled source (code, not comments) anywhere except where the 6b exception allows it.

Rule (docs/ARCHITECTURE.md, "Step 6b-2"):
  * `Sources/CSystemAudioRing/SASourceNode.m` may contain any of the APIs below (it is the file the block scan reads).
  * `Sources/CSystemAudioRing/include/CSystemAudioRing.h` may contain exactly ONE code line: the declaration of the factory,
    `AVAudioSourceNode *_Nullable SACreateSourceNode(...)`. The header cannot declare the factory without naming its return type, and rule 1 of Step 6b-2 forbids
    editing it; every other line of it is checked like any other file. (This is the one departure from "any file except SASourceNode.m".)
  * Every other .swift / .m / .mm / .c / .h / .cpp file under Sources/ and Tests/ must contain none of them, comments excluded. Swift files are not special-cased:
    a Swift file with an AVAudioSourceNode render block fails.
Comments (// and /* */) are stripped before the search, so prose that names an API does not trip it; a string literal that names one does.
Docs (*.md) and scripts/ are not source and are not scanned.

Exit status: 0 = clean, 1 = a violation, 2 = the scan could not run (no such root).
"""
import argparse
import os
import re
import sys

# Render-block APIs: anything that hands the audio system a callback or block that runs on a render / IO thread.
APIS = [
    r"AVAudioSourceNode", r"AVAudioSinkNode",                                   # includes AVAudioSourceNodeRenderBlock and AVAudioSinkNodeReceiverBlock
    r"AURenderCallback", r"AURenderCallbackStruct",                            # AudioUnit render / input callbacks
    r"kAudioUnitProperty_SetRenderCallback", r"kAudioOutputUnitProperty_SetInputCallback",
    r"AUInternalRenderBlock", r"internalRenderBlock", r"AURenderBlock", r"AUAudioUnit",   # a custom audio unit's render block
    r"manualRenderingBlock", r"AVAudioEngineManualRenderingBlock",             # the engine's own render block handed to our thread
    r"setManualRenderingInputPCMFormat", r"AVAudioIONodeInputBlock",           # the input block of a manual-rendering engine
    r"AudioQueueNewOutput", r"AudioQueueNewInput",                             # AudioQueue callbacks
    r"AudioDeviceCreateIOProcIDWithBlock",                                     # an IO block (the IOProc function pointer is scanned by scan-rt-block.sh --producer-object)
]
API_RE = re.compile("|".join(APIS))
EXTENSIONS = {".swift", ".m", ".mm", ".c", ".h", ".cpp", ".cc", ".hpp"}
SCAN_DIRS = ["Sources", "Tests"]
ALLOWED_FILES = {"Sources/CSystemAudioRing/SASourceNode.m"}
ALLOWED_LINES = {
    "Sources/CSystemAudioRing/include/CSystemAudioRing.h": [re.compile(r"^\s*AVAudioSourceNode\s*\*\s*_Nullable\s+SACreateSourceNode\s*\(")],
}

# Strings are kept (so a "//" inside one is not a comment); comments are replaced by the same number of newlines (so line numbers survive).
TOKEN_RE = re.compile(r'("(?:\\.|[^"\\\n])*")|(//[^\n]*)|(/\*.*?\*/)', re.S)


def strip_comments(text):
    def repl(m):
        if m.group(1) is not None:
            return m.group(1)
        return "\n" * m.group(0).count("\n") if m.group(3) is not None else ""
    return TOKEN_RE.sub(repl, text)


def scan_file(root, rel):
    with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as f:
        text = f.read()
    hits = []
    for number, line in enumerate(strip_comments(text).split("\n"), 1):
        m = API_RE.search(line)
        if not m:
            continue
        if any(rx.search(line) for rx in ALLOWED_LINES.get(rel, [])):
            continue
        hits.append((number, m.group(0), line.strip()))
    return hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    args = ap.parse_args()
    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        print(f"error: no such directory: {root}", file=sys.stderr)
        return 2
    scanned = allowed = 0
    violations = []
    for d in SCAN_DIRS:
        for dirpath, _, files in os.walk(os.path.join(root, d)):
            for name in sorted(files):
                if os.path.splitext(name)[1] not in EXTENSIONS:
                    continue
                rel = os.path.relpath(os.path.join(dirpath, name), root)
                scanned += 1
                if rel in ALLOWED_FILES:
                    allowed += 1
                    continue
                for number, api, line in scan_file(root, rel):
                    violations.append((rel, number, api, line))
    for rel, number, api, line in violations:
        print(f"VIOLATION {rel}:{number}: {api}: {line}")
    print(f"scanned {scanned} source files ({allowed} allowed whole, 1 allowed line in CSystemAudioRing.h); {len(violations)} violation(s)")
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
