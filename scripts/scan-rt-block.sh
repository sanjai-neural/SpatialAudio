#!/bin/zsh
# Release-disassembly scan of the Step 6b render path (see docs/ARCHITECTURE.md "Scan rule for the Step 6b block"; the rule is for Step 6b ONLY).
# Exit 0 = every check passed.
#
#   scripts/scan-rt-block.sh                              builds release and scans the objects SwiftPM produced for CSystemAudioRing:
#                                                         (1) the block's invoke function: one allow-listed callee, called once, and that callee has no calls;
#                                                         (2) the producer (_SARingIOProc, _SARingWrite): zero calls.
#   scripts/scan-rt-block.sh --objects BLOCK.o CALLEE.o   block check only, on the given objects (used to show it FAILS on broken variants)
#   scripts/scan-rt-block.sh --producer-object C.o        producer check only, on the given object (same purpose)
# The allow-list is the committed file scripts/rt-block-allowlist.txt; there is no option to change it. scripts/scan-rt-callback.sh and
# scripts/scan_rt_callback.py (Step 6a) are unchanged and are used as-is for the zero-call rule.
set -euo pipefail
cd "$(dirname "$0")/.."
PRODUCER_SYMBOLS=(_SARingIOProc _SARingWrite)

if [[ "${1:-}" == "--objects" ]]; then
  exec python3 -I scripts/scan_rt_block.py block --block-object "$2" --callee-object "$3"
elif [[ "${1:-}" == "--producer-object" ]]; then
  exec python3 -I scripts/scan_rt_block.py zero --object "$2" "${PRODUCER_SYMBOLS[@]}"
fi

swift build -c release >/dev/null
find_one() {
  local found; found=("${(@f)$(find .build -path "*/Release/CSystemAudioRing-t.build/Objects-normal/arm64/$1" | sort)}")
  [[ ${#found[@]} -eq 1 && -n "${found[1]}" ]] || { echo "error: expected exactly one release $1 under .build, found: ${found[*]:-none}" >&2; exit 2; }
  print -r -- "${found[1]}"
}
C_OBJ="$(find_one CSystemAudioRing.o)"
M_OBJ="$(find_one SASourceNode.o)"
# Both checks always run; the exit code is the worst of the two (0 pass, 1 rule violated, 2 the scan could not run). Not named `status`: that is a
# read-only parameter in zsh.
rc=0
echo "== block =="
python3 -I scripts/scan_rt_block.py block --block-object "$M_OBJ" --callee-object "$C_OBJ" || rc=$?
echo "== producer =="
python3 -I scripts/scan_rt_block.py zero --object "$C_OBJ" "${PRODUCER_SYMBOLS[@]}" || { r2=$?; (( r2 > rc )) && rc=$r2; }
exit $rc
