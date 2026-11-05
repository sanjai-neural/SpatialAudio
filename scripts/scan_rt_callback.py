#!/usr/bin/env python3
"""Release-disassembly scan of a real-time callback (CLAUDE.md "Real-time rule": added when the first render callback was written, Step 6a).

Usage: scan_rt_callback.py <object file> <symbol, e.g. _SATapProbeIOProc>

Disassembles the object with `otool -tvV`, cuts out the one function and FAILS (exit 1) if it
  - contains any call instruction (bl, blr and the pointer-authenticated variants): a real-time callback may not call anything,
    not malloc/free, not a lock, not a logger, not an Objective-C or Swift runtime function, not even a library maths routine;
  - contains any branch that leaves the function (a tail call, or an indirect `br`), or a branch to a symbol name;
  - is missing or empty (so the scan cannot pass by finding nothing).
It passes only if the function is straight arithmetic, loads/stores and branches inside itself. This checks the code actually
generated for this build, not the source. It does not prove the callback is correct or wait-free in every build configuration
(the debug build is -O0 and is not scanned).
"""
import re, subprocess, sys

CALLS = {"bl", "blr", "blraa", "blrab", "blraaz", "blrabz"}
BRANCHES = {"b", "br", "braa", "brab", "braaz", "brabz"}
CONDITIONAL = {"cbz", "cbnz", "tbz", "tbnz"}

def main() -> int:
    obj, symbol = sys.argv[1], sys.argv[2]
    out = subprocess.run(["xcrun", "otool", "-tvV", obj], capture_output=True, text=True, check=True).stdout
    lines, inside = [], False
    for line in out.splitlines():
        if re.match(r"^_[A-Za-z0-9_]+:$", line):
            inside = line.rstrip(":") == symbol
            continue
        if inside and re.match(r"^[0-9a-f]{8,16}\t", line):
            lines.append(line.split("\t"))
    if len(lines) < 10:
        print(f"FAIL: {symbol} not found or implausibly short in {obj} ({len(lines)} instructions)")
        return 1
    start = int(lines[0][0], 16)
    end = int(lines[-1][0], 16) + 4
    calls, leaving, symbolic = [], [], []
    for parts in lines:
        addr, mnemonic = parts[0], parts[1]
        operands = parts[2] if len(parts) > 2 else ""
        if mnemonic in CALLS:
            calls.append(f"{addr} {mnemonic} {operands}")
            continue
        base = mnemonic.split(".")[0]
        if base in BRANCHES or base in CONDITIONAL or mnemonic.startswith("b."):
            m = re.search(r"(0x[0-9a-f]+)\s*$", operands)
            if base.startswith("br"):
                leaving.append(f"{addr} {mnemonic} {operands}  (indirect branch)")
            elif m:
                target = int(m.group(1), 16)
                if not (start <= target < end):
                    leaving.append(f"{addr} {mnemonic} {operands}  (target outside the function)")
            elif operands:
                symbolic.append(f"{addr} {mnemonic} {operands}")
    print(f"{symbol}: {len(lines)} instructions, range 0x{start:x}-0x{end:x}, calls: {len(calls)}, branches leaving the function: {len(leaving)}, branches to a symbol: {len(symbolic)}")
    for x in calls + leaving + symbolic:
        print("  VIOLATION:", x)
    if calls or leaving or symbolic:
        print("FAIL: the callback is not straight-line real-time code")
        return 1
    print("PASS: no calls and no branch out of the function")
    return 0

sys.exit(main())
