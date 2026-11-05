#!/bin/zsh
# Builds CTapProbe.c with a hostile-input harness using clang's integer-divide-by-zero sanitizer and runs it. Exit 0 = no division by zero
# reported and every result as expected. NON-ZERO if the sanitizer fires: recovery is disabled for that check
# (-fno-sanitize-recover=integer-divide-by-zero), so the first division by zero aborts the program. Written because the wrapped 32-bit
# divisor in the IO callback is undefined behaviour that arm64 turns into 0, which no behavioural test can observe.
#
#   scripts/ubsan-tapprobe.sh                      the real CTapProbe.c
#   TAPPROBE_C=/path/to/variant.c scripts/ubsan-tapprobe.sh    a variant (to show the check FAILS on a deliberately broken one)
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${TAPPROBE_C:-Sources/CTapProbe/CTapProbe.c}"
OUT="${TMPDIR:-/tmp}/tapprobe_ubsan_hostile"
xcrun clang -std=c11 -g -O1 -fsanitize=integer-divide-by-zero -fno-sanitize-recover=integer-divide-by-zero -mmacosx-version-min=14.0 \
    -Wno-function-effects -ISources/CTapProbe/include "$SRC" scripts/tapprobe_ubsan_hostile.c -o "$OUT"
"$OUT"
