# STATUS

Tags: IMPLEMENTED (verified) · IMPLEMENTED-UNVERIFIED · PLANNED · EXPERIMENTAL · LATER

## Environment (observed 2026-11-04)
- Mac: Apple M4, model id `Mac16,12`, 16 GB RAM, macOS 26.1 (build 25B78)
- Swift 6.2 (swiftlang-6.2.0.19.9), target arm64-apple-macosx26.0
- **Full Xcode is NOT installed**; active developer dir is `/Library/Developer/CommandLineTools`.
  - `swift build` works.
  - Plain `swift test` fails (XCTest and Testing are not found by SwiftPM). `scripts/test.sh` passes the CLT `Testing.framework` path explicitly and works.
  - Xcode will be required for Step 9 (bundling/signing/notarization) and is recommended earlier (full SDK, Instruments for Step 5 profiling).
- Tests use Swift Testing (`import Testing`), not XCTest, because XCTest is unavailable without Xcode.

## Features
| Area | Status | Notes |
|---|---|---|
| Swift package skeleton (4 modules + test target) | IMPLEMENTED (verified) | `swift build` succeeded; placeholders only |
| Test harness (`scripts/test.sh`) | IMPLEMENTED (verified) | 1 smoke test passed; not a logic test |
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
