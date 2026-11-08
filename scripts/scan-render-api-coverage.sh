#!/bin/zsh
# Step 6b-2 scan-coverage guard (see scripts/scan_render_api_coverage.py and docs/ARCHITECTURE.md "Step 6b-2"): fails if a render-block API (AVAudioSourceNode,
# AVAudioSinkNode, AURenderCallback, ...) appears in compiled source anywhere except Sources/CSystemAudioRing/SASourceNode.m (plus the one factory declaration
# line in CSystemAudioRing.h). scripts/scan-rt-block.sh only scans that one file's block; this makes sure no other block exists.
#   scripts/scan-render-api-coverage.sh                scan this tree
#   scripts/scan-render-api-coverage.sh --root DIR     scan another tree (used by scripts/scan-render-api-coverage-cases.sh on broken variants)
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 -I scripts/scan_render_api_coverage.py "$@"
