#!/bin/zsh
# ThreadSanitizer run of the Step 6b-1 ring: the real producer IOProc and the two real readers on separate threads (scripts/systemaudioring_stress.c).
# Exit 0 = every check passed and TSan reported nothing (TSan itself exits 66 on a race). `swift test --sanitize=thread` DOES instrument C targets too
# (symbol check of 2026-11-08, docs/STATUS.md "Step 6b-2 real runs", Open items; this comment used to say it did not, which misread the 2026-11-04 finding). The C file
# is compiled here by hand because this script is the one shown to FAIL on broken variants, with plain samples where a missing release/acquire on `w` becomes a race (below).
#
#   scripts/tsan-systemaudioring.sh [plain|atomic|all]      default all
#     plain   CSystemAudioRing.c compiled with -DSA_RING_PLAIN_SAMPLES (plain float samples) and the PACED stress. THIS is the run that can see a
#             missing release/acquire on `w`: with plain samples the producer's data writes and the reader's data reads are ordinary accesses, so if
#             `w` does not order them TSan reports a data race. The paced mode never lets a reader be overtaken (that overtaking is a deliberate benign
#             race by design and is covered by the atomic build below), so a report here is a real ordering bug.
#     atomic  the production sample type (relaxed atomics), both modes. TSan cannot check the ORDER of relaxed atomics, so this run is expected to be
#             clean even on a broken `w` protocol: it shows the production code has no OTHER race (control-thread snapshots, counters, cursors), and
#             nothing more. Do not read it as evidence about the publication order.
#   SYSTEMAUDIORING_C=/path/variant.c scripts/tsan-systemaudioring.sh plain      a variant (to show the check FAILS on a deliberately broken one)
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-all}"
SRC="${SYSTEMAUDIORING_C:-Sources/CSystemAudioRing/CSystemAudioRing.c}"
OUT="${TMPDIR:-/tmp}/sa_ring_tsan.$$"
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT
FLAGS=(-std=c11 -g -O1 -fsanitize=thread -mmacosx-version-min=14.0 -Wno-function-effects -ISources/CSystemAudioRing/include -Iscripts -pthread)
if [[ "$MODE" == "plain" || "$MODE" == "all" ]]; then
  xcrun clang $FLAGS -DSA_RING_PLAIN_SAMPLES "$SRC" scripts/systemaudioring_stress.c -o "$OUT/stress_plain"
  echo "== TSan, plain samples, paced =="
  "$OUT/stress_plain" paced 600000
  echo "== TSan, plain samples, cycles (two readers concurrently, injected faults; Step 6b-3a-1) =="
  "$OUT/stress_plain" cycles 8000
fi
if [[ "$MODE" == "atomic" || "$MODE" == "all" ]]; then
  xcrun clang $FLAGS "$SRC" scripts/systemaudioring_stress.c -o "$OUT/stress_atomic"
  echo "== TSan, production (atomic) samples, paced =="
  "$OUT/stress_atomic" paced 600000
  echo "== TSan, production (atomic) samples, lapping =="
  "$OUT/stress_atomic" lapping 400000
  echo "== TSan, production (atomic) samples, cycles =="
  "$OUT/stress_atomic" cycles 8000
fi
