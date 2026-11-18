#!/bin/zsh
# UndefinedBehaviorSanitizer run of the Step 6b-1 ring with recovery DISABLED (-fno-sanitize-recover=all): the first undefined behaviour aborts the
# program and the script exits non-zero. Runs the deterministic checks, the hostile-input harness (guard pages after every buffer; 32-bit-wrapping
# frame counts and byte sizes; absurd channel counts) and a short paced stress. Exit 0 = nothing undefined and every check passed.
#
#   scripts/ubsan-systemaudioring.sh [all|check|hostile|stress]     default all
#   SYSTEMAUDIORING_C=/path/variant.c scripts/ubsan-systemaudioring.sh      a variant (to show the check FAILS on a deliberately broken one)
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-all}"
SRC="${SYSTEMAUDIORING_C:-Sources/CSystemAudioRing/CSystemAudioRing.c}"
OUT="${TMPDIR:-/tmp}/sa_ring_ubsan.$$"
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT
FLAGS=(-std=c11 -g -O1 -fsanitize=undefined,float-cast-overflow -fno-sanitize-recover=all -mmacosx-version-min=14.0 -Wno-function-effects -ISources/CSystemAudioRing/include -Iscripts -pthread)
if [[ "$MODE" == "all" || "$MODE" == "check" ]]; then xcrun clang $FLAGS -DSA_RING_TEST_HOOKS "$SRC" scripts/systemaudioring_check.c -o "$OUT/check"; "$OUT/check"; fi
if [[ "$MODE" == "all" || "$MODE" == "hostile" ]]; then xcrun clang $FLAGS "$SRC" scripts/systemaudioring_hostile.c -o "$OUT/hostile"; "$OUT/hostile"; fi
if [[ "$MODE" == "all" || "$MODE" == "stress" ]]; then xcrun clang $FLAGS "$SRC" scripts/systemaudioring_stress.c -o "$OUT/stress"; "$OUT/stress" paced 400000; "$OUT/stress" lapping 300000; "$OUT/stress" cycles 4000; fi
