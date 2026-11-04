#!/bin/zsh
# Runs `swift test`. With only the Command Line Tools active (no full Xcode),
# SwiftPM does not find Testing.framework on its own, so add its path explicitly.
# With full Xcode active this is a plain `swift test`.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="$(xcode-select -p)"
if [[ "$DEV" == "/Library/Developer/CommandLineTools" ]]; then
  F="$DEV/Library/Developer/Frameworks"
  exec swift test -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" "$@"
else
  exec swift test "$@"
fi
