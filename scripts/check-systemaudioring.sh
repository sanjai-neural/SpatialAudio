#!/bin/zsh
# Plain (no sanitizer) build and run of the Step 6b-1 C harnesses against the ring: deterministic checks, then the threaded stress in both modes.
# Exit 0 = every check passed. Same compiler flags as the SwiftPM build of the target (-Os), so this runs the code the scan reads.
#
#   scripts/check-systemaudioring.sh [check|paced|lapping|cycles|all]   which harness (default all); one at a time lets the mutation runner say WHICH detector killed a mutant
#   scripts/check-systemaudioring.sh                              the real Sources/CSystemAudioRing/CSystemAudioRing.c
#   SYSTEMAUDIORING_C=/path/variant.c scripts/check-systemaudioring.sh    a variant (to show the checks FAIL on a deliberately broken one)
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-all}"
SRC="${SYSTEMAUDIORING_C:-Sources/CSystemAudioRing/CSystemAudioRing.c}"
OUT="${TMPDIR:-/tmp}/sa_ring_check.$$"
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT
FLAGS=(-std=c11 -g -Os -mmacosx-version-min=14.0 -Wno-function-effects -ISources/CSystemAudioRing/include -Iscripts)
[[ "$MODE" == "check" || "$MODE" == "all" ]] && xcrun clang $FLAGS -DSA_RING_TEST_HOOKS "$SRC" scripts/systemaudioring_check.c -o "$OUT/check" && "$OUT/check"
if [[ "$MODE" != "check" ]]; then
  xcrun clang $FLAGS -pthread "$SRC" scripts/systemaudioring_stress.c -o "$OUT/stress"
  [[ "$MODE" == "paced" || "$MODE" == "all" ]] && "$OUT/stress" paced
  [[ "$MODE" == "lapping" || "$MODE" == "all" ]] && "$OUT/stress" lapping
  [[ "$MODE" == "cycles" || "$MODE" == "all" ]] && "$OUT/stress" cycles
fi
exit 0
