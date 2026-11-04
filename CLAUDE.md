# CLAUDE.md — SpatialAudio

Project: macOS-first desktop app giving ordinary headphones head-tracked spatial audio. The MacBook webcam is the head sensor (computer vision → head orientation). Our own engine renders a virtual speaker room with HRTF binaural output so the soundstage stays fixed in the room as the listener turns. Must NOT depend on AirPods/head-tracking headphones. Owner: Sanjai (software engineering student, building this as a startup). Target: Apple Silicon, macOS 14.2+. Windows, virtual devices, custom HRTF, 6DoF, personalization, Free/Pro licensing are LATER.

## Honesty rules (strict)
- Never invent APIs, library functions, capabilities, benchmarks or test results. If unsure, say so and check Apple docs / SDK headers.
- Never claim something works unless it was built and run. State what was run and what was not.
- Tag every feature in docs: IMPLEMENTED (verified), IMPLEMENTED-UNVERIFIED, PLANNED, EXPERIMENTAL, LATER.
- Tell Sanjai when an idea is unrealistic; don't just agree.
- No DRM circumvention. No Dolby Atmos/DTS:X decoding claims. Upmixed content is labeled as upmix.
- No exact X/Y/Z-in-cm tracking claims and no latency/RAM figures until measured.

## Engineering rules
- Read existing code before changing it. Small, focused changes. Preserve working code.
- Modules: SpatialAudioCore (pure logic, no hardware, unit-tested), SpatialAudioTracking (AVFoundation + Vision behind `HeadPoseProvider`), SpatialAudioEngine (`AudioSource`, `SpatialRenderer`), SpatialAudioApp (SwiftUI, debug HUD). No DSP or CV logic in the UI module.
- Quaternions internally; Euler angles only at API boundaries.
- Conventions (tested): +X right, +Y up, forward −Z; yaw+ = turn left, pitch+ = up, roll+ = right ear down; speaker azimuth + = right. See docs/ARCHITECTURE.md.
- One-Euro filter for pose smoothing. Tracking state machine: Locked → Holding → Decaying to neutral → Static. Pose must never jump on face loss.
- Audio callback: no locks, allocation, file/network I/O, or logging. Pose handoff via lock-free latest-value slot, interpolated per audio block.
- Privacy: camera frames processed in memory only, never saved, no network code, camera released on stop and exit.
- Add a dependency only with a stated reason. Unit-test all logic in SpatialAudioCore.
- Pose handoff to the audio thread: `PoseMailbox` (C11 triple buffer in `Sources/CPoseMailbox`). Keep copies field-by-field (TSan does not race-check the bulk memcpy). After touching it run `scripts/tsan-mailbox.sh` and `swift test --sanitize=thread`; a TSan result only counts if it fails on a deliberately broken variant.
- Build: `swift build`. Test: `swift test` (Swift Testing, `import Testing`; Xcode must be the active developer dir — see docs/STATUS.md). Xcode only for app bundling, signing, notarization.

## Working protocol (every step)
1. Restate goal + exit criteria (2–3 lines). 2. Inspect relevant files. 3. Explain approach/trade-offs/risks. 4. Implement the smallest suitable change, complete code. 5. Run build + tests, report real output; for camera/headphone/ear checks give exact manual steps and wait. 6. Update docs/STATUS.md and commit. 7. STOP and wait for Sanjai's confirmation before the next step.

## Step 2 requirement
Include a minimal script wrapping the executable in a .app bundle with an Info.plist containing `NSCameraUsageDescription` (signing/notarization stay in Step 9).

## Roadmap
0 Setup · 1 Core (quaternion, One-Euro, calibration, state machine, 7.1.4 layout) · 2 Head tracking + HUD · 3 M1 renderer (AVAudioEnvironmentNode HRTF) · 4 M1b 12-speaker bed · 5 Measurements · 6 M2 system audio (Core Audio tap) · 7 M3 virtual-device spike · 8 M4 quality (SOFA, convolution, EQ) · 9 Release · 10 Product. Later: 6DoF, personalization, Windows.
