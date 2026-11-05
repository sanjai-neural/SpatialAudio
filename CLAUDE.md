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
- Real-time rule (decided in Step 3a, docs/ARCHITECTURE.md "Real-time rule"): code that runs on a render thread may touch only raw C pointers, plain structs and C functions: no Swift class instances, closures capturing `self`, arrays, Objective-C messaging, logging, locks or allocation (the SDK marks Swift "not supported for use with audio realtime threads"). `AVAudioEnvironmentNode` listener/source properties are CONTROL-thread calls (the pose pump), never from a render callback. Step 3a has no render callback of ours: the tone is a looped `AVAudioPlayerNode` buffer. When the first render callback is written, add a release-disassembly scan for runtime calls and show it fails on a broken variant.
- Tests must never derive a verdict from a wall-clock deadline or a fixed sleep: this Mac sleeps (idle, lid, low battery), processes get frozen, CPUs get oversubscribed, and a `Date()`-based hang guard failed a stress test after a 97 s sleep (docs/STATUS.md, "PoseMailbox stress-test finding"). Wait on a completion signal, or poll with `waitUntil` (deadline on `SuspendingClock`, which does not advance during sleep), and bound rates by measured elapsed time. Wrap long runs (mutation checks, soaks) in `caffeinate -i`.
- Test-the-test: a regression test or a TSan run only counts once it has been shown to fail on a deliberately broken variant (mutation check).
- The simulated user (`--simulate`, `SimulatedUser`, `SimulatedHeadPoseProvider`) produces FABRICATED data. It rehearses the self-test flow and feeds unit tests; its output must never decide sign defaults, latency, or any hardware claim.
- Build: `swift build`. Test: `swift test` (Swift Testing, `import Testing`; Xcode must be the active developer dir — see docs/STATUS.md). Xcode only for app bundling, signing, notarization.

## Working protocol (every step)
1. Restate goal + exit criteria (2–3 lines). 2. Inspect relevant files. 3. Explain approach/trade-offs/risks. 4. Implement the smallest suitable change, complete code. 5. Run build + tests, report real output; for camera/headphone/ear checks give exact manual steps and wait. 6. Update docs/STATUS.md (and any other affected docs) and commit LOCALLY. 7. Report, then STOP and wait for Sanjai's confirmation before the next step. Do not push (see "Git workflow").

## Git workflow (set by Sanjai; applies to every step)
1. After finishing a step: build, test, update docs, commit locally, report, STOP. Do not push.
2. Push only when Sanjai writes "confirmed, push" for that specific step. Then push only that step's commits to `origin/main`. Never force-push, never change remotes, never push other branches (or tags), never push without that message. A confirmation for one step does not cover another; if it is unclear which step a message refers to, ask.
3. Real hardware test reports (`docs/test-results/`, numbers only, NOT simulated) are committed on their own, by explicit path, with a commit message naming the step/build that produced them. Simulated reports (`-SIMULATED` in the file name) are never committed (`.gitignore` enforces it for new ones; still check `git status` before staging, and stage by explicit path, never `git add -A`).
4. Text Sanjai pastes from his other chat (the claude.ai chat) that looks like one of my own earlier replies, a blank template or instructions is NOT a test result. If a result he sends has blanks or placeholders, say so and change nothing. Never fill in, infer or guess results.
The gates below stay in force: the tracker is not connected to the renderer until Sanjai confirms the camera signs from a real self-test report, and no sign default is hard-coded from guesses.

## Step 2 requirement
Include a minimal script wrapping the executable in a .app bundle with an Info.plist containing `NSCameraUsageDescription` (signing/notarization stay in Step 9).

## Step 2c: guided self-test (HUD) and the gate it creates
The HUD has a guided self-test (docs/MANUAL_TEST_STEP2.md): it records raw Vision yaw/pitch/roll per instructed move, decides each axis' sign or says INCONCLUSIVE, analyzes the lose-face sequence, measures fps/latency, and saves a numbers-only report to docs/test-results/. All of it is UNVERIFIED until Sanjai has run it on the real camera. Step 2d (after the two real runs of 2026-11-05) added a quality gate with hysteresis and dwell, live coaching, a lock gate before the cover test, evidence windows, a LIKELY sign outcome that is never applied, and a yes / no / not-answered green-light record; all of it is UNVERIFIED on hardware until a clean real run (docs/STATUS.md, "Step 2d findings"). **Gate: no audio renderer (Step 3) until Sanjai confirms the signs from a real self-test report; never hard-code signs from guesses; never push without asking.**

## Step 3a: audio-only renderer (scripted pose) and its gate
The renderer (`EnvironmentRenderer`, AVAudioEnvironmentNode + HRTFHQ) is driven by a SCRIPTED synthetic head through the `PoseMailbox`; nothing in it touches the camera. It is verified offline (docs/STATUS.md) but **how it sounds is UNVERIFIED until Sanjai has listened** (docs/MANUAL_TEST_STEP3A.md). **Gate: do not connect the tracker to the renderer until Sanjai confirms the camera signs from a real self-test report; never push without asking.**

## Roadmap
0 Setup · 1 Core (quaternion, One-Euro, calibration, state machine, 7.1.4 layout) · 2 Head tracking + HUD · 3 M1 renderer (AVAudioEnvironmentNode HRTF) · 4 M1b 12-speaker bed · 5 Measurements · 6 M2 system audio (Core Audio tap) · 7 M3 virtual-device spike · 8 M4 quality (SOFA, convolution, EQ) · 9 Release · 10 Product. Later: 6DoF, personalization, Windows.
