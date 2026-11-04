#!/bin/zsh
# Builds CPoseMailbox.c together with a two-thread stress harness using clang's ThreadSanitizer,
# then runs it. Exit 0 = no torn reads, no backwards sequences, and TSan reported no races.
# (TSan itself exits 66 on a race.) Written because `swift test --sanitize=thread` did not report
# a deliberately injected race inside the C target (see docs/STATUS.md).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/mailbox_tsan_stress"
xcrun clang -std=c11 -g -O1 -fsanitize=thread -mmacosx-version-min=14.0 \
    -ISources/CPoseMailbox/include \
    Sources/CPoseMailbox/CPoseMailbox.c scripts/mailbox_tsan_stress.c -o "$OUT"
"$OUT"
