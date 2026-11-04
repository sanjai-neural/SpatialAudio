# STATUS

Tags: IMPLEMENTED (verified) · IMPLEMENTED-UNVERIFIED · PLANNED · EXPERIMENTAL · LATER

## Environment (observed 2026-11-04, re-checked after Xcode install)
- Mac: Apple M4, model id `Mac16,12`, 16 GB RAM. Marketing name NOT confirmed by Sanjai (the model field in the Step 1 prompt was left as a template placeholder); likely 13-inch MacBook Air M4 — unverified. Note: if it is a MacBook Air it is fanless, which matters for sustained-CPU measurements in Step 5.
- macOS 27.2, Xcode 27.2 (27B52), Swift 6.4.2 (swiftlang-6.4.2.1.9). `xcode-select -p` = `/Applications/Xcode.app/Contents/Developer`.
  (Earlier in the session the machine reported macOS 26.1 / Swift 6.2 / Command Line Tools only.)
- `swift build` and plain `swift test` both work (verified).
- Tests use Swift Testing (`import Testing`).
- Fallback if the active developer dir is ever the Command Line Tools: plain `swift test` fails to find `Testing`. Workaround (verified once on CLT): `F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift test -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F`.

## Features
"IMPLEMENTED (verified)" below means: built and covered by passing unit tests (`swift test`, 69 tests / 8 suites, 2026-11-04). Nothing has been run against a real camera, headphones or ears yet. All tuning defaults (One-Euro cutoffs/beta, hold 0.5 s, decay 1.5 s, blend 0.25 s, min confidence 0.5) are UNTUNED placeholders.

| Area | Status | Notes |
|---|---|---|
| Swift package skeleton (4 modules + test target) | IMPLEMENTED (verified) | `swift build` succeeds; Tracking/Engine/App are still placeholders |
| Test harness (Swift Testing via `swift test`) | IMPLEMENTED (verified) | |
| Vector3 / Quaternion math (multiply, rotate, inverse, slerp, average, angle) | IMPLEMENTED (verified) | Convention pinned by tests: +X right, +Y up, forward −Z; yaw+ = turn left, pitch+ = look up, roll+ = right ear down |
| Euler conversion (API boundary only) | IMPLEMENTED (verified) | Round-trip tested on a grid; gimbal lock (±90° pitch) handled (roll reported 0) |
| One-Euro filter (scalar + quaternion) | IMPLEMENTED (verified) | Jitter reduction, lag vs beta, step response, gap reset, non-finite/out-of-order input tested on synthetic data only |
| Calibration (neutral pose / recenter) | IMPLEMENTED (verified) | `calibrated = neutral⁻¹ · raw`; order verified with non-commuting rotations |
| Tracking state machine (Locked → Holding → Decaying → Static) | IMPLEMENTED (verified) | Tests assert no pose jump across loss, decay, reacquire, mid-blend loss, low confidence, NaN, backwards time. Synthetic input only |
| HeadPosePipeline (filter → calibrate → state machine, recenter) | IMPLEMENTED (verified) | Glue added in Step 1 so the end-to-end no-jump property is testable |
| 7.1.4 speaker layout (7 ear-level + LFE + 4 height; LFE not spatialized) | IMPLEMENTED (verified) | Angle provenance below |
| Lock-free pose handoff to audio thread | PLANNED | Step 3. Options analysed in ARCHITECTURE.md; awaiting decision |
| `HeadPoseProvider` protocol, camera head tracking (AVFoundation + Vision), debug HUD | PLANNED | Step 2. First check whether Vision exposes yaw/pitch/roll directly |
| Minimal `.app` bundling script with Info.plist incl. `NSCameraUsageDescription` | PLANNED | Step 2 (needed so macOS grants camera access to a SwiftPM executable). Signing/notarization stay in Step 9 |
| M1 renderer (AVAudioEnvironmentNode + HRTF) | PLANNED | Step 3 |
| M1b 12-speaker virtual bed | PLANNED | Step 4 |
| Latency / CPU / memory measurements | PLANNED | Step 5. No figures exist yet |
| System audio capture (Core Audio tap, stereo upmix labeled as upmix) | PLANNED | Step 6 |
| Virtual 5.1/7.1 device spike | EXPERIMENTAL (not started) | Step 7 |
| SOFA HRTF, room reflections, headphone EQ | PLANNED | Step 8 |
| Signed/notarized release | PLANNED | Step 9 |
| Free/Pro licensing, onboarding | LATER | Step 10 |
| 6DoF translation, personalization, Windows | LATER | |

## 7.1.4 angle provenance (checked 2026-11-04)
Source: Dolby Atmos Home Theater Installation Guidelines (PDF text extracted locally; figures not readable).
- Verified in text: L/R ±30°; rear surround ≈135°; overhead elevation 45° reference (30–55° allowed); front heights ≈±30° azimuth; ceiling-mounted rear heights ≈135° azimuth.
- NOT verified: side surround ±90°. The text does not state it (figure only). 90° is an assumption; common practice is 90–110°.
- Not checked: ITU-R BS.2051 nominal positions for this layout (the search did not surface the table). Wall-mounted height variants differ from the ceiling case used here.
