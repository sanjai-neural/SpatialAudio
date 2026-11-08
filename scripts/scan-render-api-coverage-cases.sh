#!/bin/zsh
# Test-the-test for scripts/scan-render-api-coverage.sh: the real tree must pass, and each deliberately broken variant (built in a temporary copy of Sources/ and
# Tests/, never in the repository) must fail for the right reason. Exit 0 only if EVERY case behaves as expected.
set -uo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

fresh() { rm -rf "$tmp/tree"; mkdir -p "$tmp/tree"; cp -R Sources Tests "$tmp/tree/"; }
expect() {   # expect <name> <want-exit> <must-contain-or-empty>
  local out rc
  out="$(scripts/scan-render-api-coverage.sh --root "$tmp/tree" 2>&1)"; rc=$?
  print -r -- "--- $1: exit $rc (wanted $2)"; print -r -- "$out" | sed -n '1,4p'
  if [[ $rc -ne $2 ]]; then print "    UNEXPECTED exit status"; fail=1; fi
  if [[ -n "$3" && "$out" != *"$3"* ]]; then print "    UNEXPECTED: output lacks '$3'"; fail=1; fi
}

fresh; expect "control: the repository's own Sources and Tests" 0 "0 violation(s)"

fresh; cat > "$tmp/tree/Sources/SpatialAudioEngine/Broken.swift" <<'SWIFT'
import AVFoundation
func makeBroken() -> AVAudioNode {
    let n = AVAudioSourceNode { _, _, frameCount, _ in return noErr }   // a Swift render block, outside the scanned file
    return n
}
SWIFT
expect "1: a Swift file with an AVAudioSourceNode render block" 1 "Broken.swift:3: AVAudioSourceNode"

fresh; printf 'import AVFoundation\nfunc s() { _ = AVAudioSinkNode { _, _, _ in noErr } }\n' > "$tmp/tree/Sources/SpatialAudioEngine/Sink.swift"
expect "2: an AVAudioSinkNode in Swift" 1 "AVAudioSinkNode"

fresh; printf '#import <AVFAudio/AVFAudio.h>\nAVAudioSourceNode *Other(void) { return [[AVAudioSourceNode alloc] initWithRenderBlock:^OSStatus(BOOL *s, const AudioTimeStamp *t, AVAudioFrameCount f, AudioBufferList *o) { return 0; }]; }\n' > "$tmp/tree/Sources/CSystemAudioRing/Other.m"
expect "3: a second Objective-C file with a render block (not SASourceNode.m)" 1 "Other.m:2"

fresh; printf '\nstatic inline AVAudioSourceNode *Extra(void) { return nil; }\n' >> "$tmp/tree/Sources/CSystemAudioRing/include/CSystemAudioRing.h"
expect "4: another AVAudioSourceNode line in the header (only the factory declaration is allowed)" 1 "CSystemAudioRing.h"

fresh; printf '#include <AudioUnit/AudioUnit.h>\nstatic AURenderCallbackStruct cb;\n' > "$tmp/tree/Sources/CSystemAudioRing/Callback.c"
expect "5: another render-callback API (AURenderCallbackStruct) in a C file" 1 "AURenderCallbackStruct"

fresh; printf 'import Testing\n@Test func t() { let _ = AVAudioSourceNode.self }\n' > "$tmp/tree/Tests/SpatialAudioEngineTests/InTest.swift"
expect "6: a token in a TEST file (tests are source too)" 1 "InTest.swift"

fresh; printf '// AVAudioSourceNode is only named in this comment\n/* and AVAudioSinkNode in this one */\nlet x = 1\n' > "$tmp/tree/Sources/SpatialAudioEngine/Comment.swift"
expect "7: a token only in comments (prose is not code: must PASS)" 0 "0 violation(s)"

fresh; printf 'let url = "https://example.com"   // AVAudioSourceNode in a trailing comment\nlet s = "AVAudioSourceNode"\n' > "$tmp/tree/Sources/SpatialAudioEngine/Str.swift"
expect "8: a string literal that names the API is code (and a // inside a string is not a comment)" 1 "Str.swift:2"

if [[ $fail -ne 0 ]]; then print "\nSOME CASE BEHAVED UNEXPECTEDLY"; exit 1; fi
print "\nall cases behaved as expected"
