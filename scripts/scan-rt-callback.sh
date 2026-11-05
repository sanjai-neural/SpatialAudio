#!/bin/zsh
# Release-disassembly scan of the system-audio probe's real-time IO callback (Step 6a). Exit 0 = no calls, nothing leaves the function.
#
#   scripts/scan-rt-callback.sh                    builds release and scans the object SwiftPM produced for CTapProbe (the shipped code)
#   scripts/scan-rt-callback.sh --source FILE.c    compiles FILE.c with -O2 (compile-time function-effects check switched OFF) and scans that;
#                                                  used to show that the scan FAILS on a deliberately broken variant
# SA_SCAN_SYMBOL overrides the symbol (default _SATapProbeIOProc).
set -euo pipefail
cd "$(dirname "$0")/.."
SYMBOL="${SA_SCAN_SYMBOL:-_SATapProbeIOProc}"
if [[ "${1:-}" == "--source" ]]; then
  OBJ="${TMPDIR:-/tmp}/scan_rt_callback_variant.o"
  xcrun clang -std=c11 -O2 -c -mmacosx-version-min=14.0 -ISources/CTapProbe/include -Wno-function-effects "$2" -o "$OBJ"
else
  swift build -c release >/dev/null
  OBJ="$(find .build -path '*Release*' -path '*Objects-normal*' -name 'CTapProbe.o' | head -1)"
  [[ -n "$OBJ" ]] || { echo "error: release CTapProbe.o not found under .build" >&2; exit 2; }
fi
echo "scanning $OBJ"
python3 -I scripts/scan_rt_callback.py "$OBJ" "$SYMBOL"
