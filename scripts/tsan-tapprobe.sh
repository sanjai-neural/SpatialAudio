#!/bin/zsh
# Builds CTapProbe.c together with a two-thread stress harness using clang's ThreadSanitizer, then runs it. Exit 0 = every record
# was whole and in order, overflow was counted, and TSan reported no races (TSan itself exits 66 on a race). A dedicated
# check: SwiftPM's `swift test --sanitize=thread` DOES instrument C targets too (symbol check of 2026-11-08, docs/STATUS.md "Step 6b-2 real runs", Open items;
# this comment used to say it did not, which misread the 2026-11-04 finding), but only this script has been shown to FAIL on broken variants of CTapProbe.
#
#   scripts/tsan-tapprobe.sh                      the real CTapProbe.c
#   TAPPROBE_C=/path/to/variant.c scripts/tsan-tapprobe.sh    a variant (to show the check FAILS on a deliberately broken one)
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${TAPPROBE_C:-Sources/CTapProbe/CTapProbe.c}"
OUT="${TMPDIR:-/tmp}/tapprobe_tsan_stress"
xcrun clang -std=c11 -g -O1 -fsanitize=thread -mmacosx-version-min=14.0 -Wno-function-effects \
    -ISources/CTapProbe/include "$SRC" scripts/tapprobe_tsan_stress.c -o "$OUT"
"$OUT"
