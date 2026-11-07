#!/usr/bin/env python3
"""Release-disassembly scan for the Step 6b render path. A SIBLING of scan_rt_callback.py (which is unchanged and still the zero-call rule).

  scan_rt_block.py block --block-object B.o --callee-object C.o
  scan_rt_block.py zero  --object C.o SYMBOL [SYMBOL ...]

`block` (the rule adopted for Step 6b ONLY, docs/ARCHITECTURE.md "Scan rule for the Step 6b block"):
  - every Objective-C block invoke function in B.o (symbol `___*_block_invoke*`) must have an entry in scripts/rt-block-allowlist.txt, and every
    entry must exist in B.o;
  - the invoke function may make EXACTLY ONE call, to the symbol its entry allows, exactly once. Callee names are read from the relocation of the
    branch instruction (`llvm-objdump -d -r`), not from `otool`, which shows only an address. Any other call, a tail call, an indirect call
    (blr/br), a call with no relocation, or a branch out of the function fails, each with its own tag;
  - the allowed symbol must be DEFINED as code in our own C object C.o (`nm -U -g`), so a library function such as malloc can never be allow-listed;
  - that callee must satisfy the zero-call rule: no call of any kind and no branch out. It is checked twice: by this script's relocation reader
    (which names what is called) and by the unchanged scripts/scan_rt_callback.py (the existing rule, run as a subprocess).
`zero` applies the zero-call rule to the named functions of one object (the producer's SARingIOProc / SARingWrite), same two checks.

Exit 0 = pass, 1 = rule violated, 2 = the scan itself could not run (tool missing, symbol not found). Reads the code actually generated, not the source.
It does not prove the code correct, and it scans only what it is pointed at (the shipped release objects by default; the debug build is not scanned).
"""
import argparse, os, re, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ALLOWLIST = HERE / "rt-block-allowlist.txt"          # committed; deliberately NOT a command-line option
OLD_SCANNER = HERE / "scan_rt_callback.py"
CALLS = {"bl", "blr", "blraa", "blrab", "blraaz", "blrabz"}
INDIRECT = {"br", "braa", "brab", "braaz", "brabz"}
COND = {"cbz", "cbnz", "tbz", "tbnz"}
BLOCK_NAME = re.compile(r"^___.*_block_invoke(_\d+)?$")

LABEL = re.compile(r"^([0-9a-f]{16}) <(.+)>:$")
INSN = re.compile(r"^\s+([0-9a-f]+):\s+(\S+)(?:\s+(.*))?$")
RELOC = re.compile(r"^\s+([0-9a-f]{16}):\s+(ARM64_RELOC_\w+)\s+(\S+)\s*$")
TARGET = re.compile(r"(0x[0-9a-f]+)(?:\s*<([^>+]+)(?:\+0x[0-9a-f]+)?>)?\s*$")


def tool(*args):
    try:
        return subprocess.run(["xcrun", *args], capture_output=True, text=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"error: could not run xcrun {' '.join(args)}: {e}", file=sys.stderr)
        sys.exit(2)


def disassemble(obj):
    """{function symbol: [dict(addr, mn, ops, reloc)]} for every function (label starting with `_`) of the object, in text order."""
    funcs, cur, last = {}, None, None
    for line in tool("llvm-objdump", "-d", "-r", "--no-show-raw-insn", obj).splitlines():
        m = LABEL.match(line)
        if m:
            if m.group(2).startswith("_"):
                cur = m.group(2)
                funcs[cur] = []
            last = None
            continue
        if cur is None:
            continue
        m = RELOC.match(line)
        if m:
            if last is not None and last["addr"] == int(m.group(1), 16):
                last["reloc"] = (m.group(2), m.group(3))
            continue
        m = INSN.match(line)
        if m and not m.group(2).startswith("ARM64_RELOC"):
            last = {"addr": int(m.group(1), 16), "mn": m.group(2), "ops": (m.group(3) or "").split(";")[0].strip(), "reloc": None}
            funcs[cur].append(last)
    return funcs


def defined_code_symbols(obj):
    out = set()
    for line in tool("nm", "-U", "-g", obj).splitlines():
        p = line.split()
        if len(p) == 3 and p[1] == "T":
            out.add(p[2])
    return out


def control_flow(insns):
    """Classify the function's control transfers. Returns (calls, violations): calls = [(name, addr)], violations = [(tag, text)]."""
    start, end = insns[0]["addr"], insns[-1]["addr"] + 4
    calls, bad = [], []
    for i in insns:
        mn, base, ops, addr = i["mn"], i["mn"].split(".")[0], i["ops"], i["addr"]
        t = TARGET.search(ops)
        target = int(t.group(1), 16) if t else None
        if base in INDIRECT or mn in INDIRECT:
            bad.append(("INDIRECT-BRANCH", f"0x{addr:x} {mn} {ops}: indirect branch (a jump table or tail call through a register)"))
        elif mn in CALLS:
            if mn != "bl":
                bad.append(("INDIRECT-CALL", f"0x{addr:x} {mn} {ops}: call through a register, callee cannot be named"))
            elif i["reloc"] and i["reloc"][0] == "ARM64_RELOC_BRANCH26":
                calls.append((i["reloc"][1], addr))
            elif t and t.group(2):
                calls.append((t.group(2), addr))      # resolved inside the object without a relocation: still named, still must be allow-listed
            else:
                bad.append(("UNRESOLVED-CALL", f"0x{addr:x} bl {ops}: callee has no relocation and no symbol"))
        elif mn == "b":
            if i["reloc"] and i["reloc"][0] == "ARM64_RELOC_BRANCH26":
                calls.append((i["reloc"][1], addr))   # a tail call is a call
            elif target is None or not (start <= target < end):
                bad.append(("BRANCH-LEAVES-FUNCTION", f"0x{addr:x} b {ops}: target outside the function"))
        elif mn.startswith("b.") or base in COND:
            if target is None or not (start <= target < end):
                bad.append(("BRANCH-LEAVES-FUNCTION", f"0x{addr:x} {mn} {ops}: target outside the function"))
    return calls, bad


def run_old_zero_call_rule(obj, symbol):
    r = subprocess.run([sys.executable, "-I", str(OLD_SCANNER), obj, symbol], capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def zero_call_checks(label, obj, funcs, symbol, violations):
    """The zero-call rule for one function: this script's reader (names the callee) and the unchanged existing scanner."""
    insns = funcs.get(symbol)
    if not insns:
        print(f"error: {symbol} not found in {obj}", file=sys.stderr)
        sys.exit(2)
    calls, bad = control_flow(insns)
    print(f"  {label} {symbol}: {len(insns)} instructions, calls: {len(calls)}" + "".join(f"\n    call at 0x{a:x} -> {n}" for n, a in calls))
    for n, a in calls:
        violations.append(("CALLEE-CALLS" if label == "callee" else "CALLS", f"{symbol} calls {n} at 0x{a:x}; the zero-call rule allows no call"))
    for tag, text in bad:
        violations.append((tag, f"{symbol}: {text}"))
    code, text = run_old_zero_call_rule(obj, symbol)
    print("  existing rule (scan_rt_callback.py): " + text.splitlines()[-1] + f"  [exit {code}]")
    if code != 0:
        violations.append(("EXISTING-ZERO-CALL-RULE", f"scan_rt_callback.py failed {symbol}: " + " | ".join(text.splitlines())))


def read_allowlist():
    entries = {}
    for n, line in enumerate(ALLOWLIST.read_text().splitlines(), 1):
        line = line.split("#")[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 2 or parts[0] in entries:
            print(f"error: {ALLOWLIST}:{n}: expected '<block symbol> <callee>' once per block", file=sys.stderr)
            sys.exit(2)
        entries[parts[0]] = parts[1]
    return entries


def scan_block(block_obj, callee_obj):
    allow = read_allowlist()
    bfuncs, cfuncs = disassemble(block_obj), disassemble(callee_obj)
    cdefs = defined_code_symbols(callee_obj)
    print(f"block object : {block_obj}\ncallee object: {callee_obj}\nallow-list   : {ALLOWLIST} ({len(allow)} entr{'y' if len(allow) == 1 else 'ies'})")
    violations = []
    blocks = sorted(s for s in bfuncs if BLOCK_NAME.match(s))
    for s in blocks:
        if s not in allow:
            violations.append(("UNLISTED-BLOCK", f"{s} is a block invoke function with no allow-list entry"))
    for s in sorted(allow):
        if s not in bfuncs:
            violations.append(("MISSING-BLOCK", f"allow-listed block {s} not found in {block_obj}"))
    for s in blocks:
        if s not in allow:
            continue
        allowed = allow[s]
        insns = bfuncs[s]
        calls, bad = control_flow(insns)
        print(f"  block  {s}: {len(insns)} instructions, calls: {len(calls)}, allowed callee: {allowed}")
        for n, a in calls:
            print(f"    call at 0x{a:x} -> {n}")
        for tag, text in bad:
            violations.append((tag, f"{s}: {text}"))
        for n, a in calls:
            if n != allowed:
                violations.append(("NOT-ALLOW-LISTED", f"{s} calls {n} at 0x{a:x}; its only allowed callee is {allowed}"))
            if n not in cdefs:
                violations.append(("NOT-DEFINED-IN-OUR-C-OBJECT", f"{s} calls {n}, which is not defined as code (nm -U -g) in {callee_obj}"))
        n_allowed = sum(1 for n, _ in calls if n == allowed)
        if n_allowed != 1:
            violations.append(("CALL-COUNT", f"{s} has {n_allowed} call site(s) to the allow-listed {allowed}; exactly 1 is required"))
        if allowed not in cdefs:
            violations.append(("NOT-DEFINED-IN-OUR-C-OBJECT", f"allow-listed {allowed} is not defined as code (nm -U -g) in {callee_obj}"))
        else:
            zero_call_checks("callee", callee_obj, cfuncs, allowed, violations)
    return violations


def scan_zero(obj, symbols):
    funcs = disassemble(obj)
    print(f"object: {obj}")
    violations = []
    for s in symbols:
        zero_call_checks("function", obj, funcs, s, violations)
    return violations


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="mode", required=True)
    b = sub.add_parser("block")
    b.add_argument("--block-object", required=True)
    b.add_argument("--callee-object", required=True)
    z = sub.add_parser("zero")
    z.add_argument("--object", required=True)
    z.add_argument("symbols", nargs="+")
    a = ap.parse_args()
    for p in [getattr(a, k) for k in ("block_object", "callee_object", "object") if hasattr(a, k)]:
        if not os.path.isfile(p):
            print(f"error: {p} not found", file=sys.stderr)
            return 2
    violations = scan_block(a.block_object, a.callee_object) if a.mode == "block" else scan_zero(a.object, a.symbols)
    for tag, text in violations:
        print(f"  VIOLATION [{tag}] {text}")
    if violations:
        print("FAIL: " + ", ".join(sorted({t for t, _ in violations})))
        return 1
    print("PASS: " + ("one allow-listed callee, called once, and that callee has no calls" if a.mode == "block" else "no calls and no branch out of the function"))
    return 0


sys.exit(main())
