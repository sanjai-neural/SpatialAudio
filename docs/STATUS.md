# STATUS

Tags: IMPLEMENTED (verified) · IMPLEMENTED-UNVERIFIED · PLANNED · EXPERIMENTAL · LATER

## Environment (observed 2026-11-04, re-checked after Xcode install)
- Mac: Apple M4, model id `Mac16,12`, 16 GB RAM. Marketing name not yet confirmed by Sanjai (likely 13-inch MacBook Air M4 — unverified).
- macOS 27.2, Xcode 27.2 (27B52), Swift 6.4.2 (swiftlang-6.4.2.1.9). `xcode-select -p` = `/Applications/Xcode.app/Contents/Developer`.
  (Earlier in the session the machine reported macOS 26.1 / Swift 6.2 / Command Line Tools only.)
- `swift build` and plain `swift test` both work (verified).
- Tests use Swift Testing (`import Testing`).
- Fallback if the active developer dir is ever the Command Line Tools: plain `swift test` fails to find `Testing`. Workaround (verified once on CLT): `F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift test -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F`.

## Features
| Area | Status | Notes |
|---|---|---|
| Swift package skeleton (4 modules + test target) | IMPLEMENTED (verified) | `swift build` succeeded; placeholders only |
| Test harness (Swift Testing via `swift test`) | IMPLEMENTED (verified) | 1 smoke test passed; not a logic test |
| Quaternion math, One-Euro filter, calibration, tracking state machine, 7.1.4 layout | PLANNED | Step 1 |
| Camera head tracking (AVFoundation + Vision), debug HUD | PLANNED | Step 2 |
| M1 renderer (AVAudioEnvironmentNode + HRTF) | PLANNED | Step 3 |
| M1b 12-speaker virtual bed | PLANNED | Step 4 |
| Latency / CPU / memory measurements | PLANNED | Step 5. No figures exist yet. |
| System audio capture (Core Audio tap, stereo upmix labeled as upmix) | PLANNED | Step 6 |
| Virtual 5.1/7.1 device spike | EXPERIMENTAL (not started) | Step 7 |
| SOFA HRTF, room reflections, headphone EQ | PLANNED | Step 8 |
| Signed/notarized release | PLANNED | Step 9 |
| Free/Pro licensing, onboarding | LATER | Step 10 |
| 6DoF translation, personalization, Windows | LATER | |
