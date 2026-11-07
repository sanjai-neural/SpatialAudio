#!/bin/zsh
# Proof that scripts/scan-rt-block.sh fails on deliberately broken variants (test-the-test, Step 6b). One case per run:
#   scripts/scan-rt-block-cases.sh 1     control: the shipped release objects (block + producer) pass
#   scripts/scan-rt-block-cases.sh 1v    control through the variant pipeline (unmodified sources, same compile flags SwiftPM uses)
#   scripts/scan-rt-block-cases.sh 2     the block calls a different, clean function (not allow-listed)
#   scripts/scan-rt-block-cases.sh 3     a direct malloc inside the block
#   scripts/scan-rt-block-cases.sh 4     the allow-listed callee called twice
#   scripts/scan-rt-block-cases.sh 5     the allow-listed callee itself calls malloc
#   scripts/scan-rt-block-cases.sh 6     the block ends with a tail call (a plain `b`) to a non-allow-listed symbol
#   scripts/scan-rt-block-cases.sh 7     the block makes an indirect call (`blr`)
#   scripts/scan-rt-block-cases.sh z     the render function without no_builtin (hidden bzero, the real trap)
#   scripts/scan-rt-block-cases.sh p1..p4   producer variants (malloc; helper not inlined; hidden memcpy; mutex)
# Exit code = the scan's (0 pass, 1 rule violated) unless the variant itself was not broken in the object (3) or the scan failed without naming
# the expected cause (4). Never edits Sources/. Scratch files go under $SA_SCRATCH (default $TMPDIR/sa-rt-cases).
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == "1" ]]; then
  exec scripts/scan-rt-block.sh
fi
exec python3 -I scripts/rt_block_cases.py "${1:-}"
