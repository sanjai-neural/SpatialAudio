# STATUS

Tags: IMPLEMENTED (verified) · IMPLEMENTED-UNVERIFIED · PLANNED · EXPERIMENTAL · LATER

## Environment (recorded 2026-11-04, supplied by Sanjai)
- Mac: MacBook Air, model id `Mac16,12`, Apple M4, 16 GB RAM, **fanless**.
- macOS 27.2 (build 26B123). Xcode 27.2 (27B52). Swift 6.4.2 (swiftlang-6.4.2.1.9).
- Built-in camera as reported by AVFoundation: "MacBook Air Camera"; 640x480, 1280x720, 1920x1080 and others at 15–30 fps; `position` reports unspecified.
- `swift build` and plain `swift test` both work (verified). Tests use Swift Testing (`import Testing`).
- No code-signing identities installed (`security find-identity` → 0 valid), so dev bundles are ad-hoc signed.
- **This Mac sleeps aggressively** when idle on battery and on every lid close (observed even with `caffeinate -i` held, and with the lid closed at 3% battery during one long run). Long or timing-sensitive jobs (mutation checks, soaks, simulated end-to-end runs) can be frozen mid-run. Before trusting a slow or odd result check `pmset -g log`; see the stress-test finding below.
- Fallback if the active developer dir is ever the Command Line Tools: plain `swift test` fails to find `Testing`. Workaround (verified once on CLT): `F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift test -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F`.

## Step 5 plan additions
- 30–60 minute **thermal soak** test (fanless MacBook Air): run tracking + rendering continuously and record CPU, frame rate, tracking latency and audio dropouts over time, plus whether the system throttles. (Only the short Step 2 session below has been measured so far.)
- **Investigate the ~81 ms delivery latency** (see Measured values). Things to TEST, not promises or known causes: how much is exposure/ISP time before the sample timestamp is stamped vs. buffering after it; whether `alwaysDiscardsLateVideoFrames` and queue depth matter; camera format / frame duration (`activeFormat`, `activeVideoMinFrameDuration`) vs. the 640x480 session preset; whether macOS camera effects (Center Stage, Portrait, Studio Light, etc.) add delay; lower frame-rate/exposure behavior in dim light; and what the sample timestamp actually marks. Also decide whether landmark stability (second Vision request) is worth its cost.

## Measured values (Step 2 manual session, user-reported from HUD screenshots)
Single session, normal light, MacBook Air M4 (Mac16,12), built-in camera, 640x480 preset, debug build, Vision revision 3. Not a benchmark: one sitting, a handful of readings, dim room not tested.
- Frame rate: **30.0 fps**.
- Capture→pose latency: **about 94–97 ms total = delivery ~81–82 ms + Vision ~13–15 ms** (our filter/state machine cost is inside the total and not separated). **The ~81 ms is delivery time** (from the frame's sample timestamp to our capture callback starting), not Vision. This is the dominant term; its cause is unknown (investigation is in the Step 5 plan). Note this excludes any delay before the sample timestamp, so true photon-to-pose latency is at least this much.
- `AVCaptureConnection`: `isVideoMirrored = false`, `videoRotationAngle = 0°` (so the mirroring compensation was not exercised on this Mac).
- Vision confidence: 0.87–0.89 with one face (so it is not a constant 1.0 here; still a weak signal).
- With all invert boxes unticked: raw yaw +25.3° → mapped +25.3°; raw pitch −11.7° → mapped +11.7°; raw roll −3.5° → mapped −3.5°. This only shows the mapping arithmetic (pitch negated); it does not say which physical direction the head was turned.

## Manual results still missing (so these remain UNVERIFIED)
**The guided self-test has never been run on a real camera**, so there is no real sign result. Still missing: turn left → yaw?, look up → pitch?, right ear down → roll? (all three signs are UNVERIFIED; pitch negation rests on the header text only), the lose-face sequence and pose-jump check on a real camera, normal-light and dim-room fps/latency statistics from the self-test, camera light off after Stop / window close / Cmd+Q, permission-prompt behaviour, and anything odd (crash, lag, heat). **No sign default has been changed and none may be hard-coded until a real self-test report says so.** Procedure: docs/MANUAL_TEST_STEP2.md.

## Features
"IMPLEMENTED (verified)" means: built and covered by passing unit tests (`swift test`: 227 tests, 187 Core + 40 Tracking, 2026-11-04; also clean under `swift test --sanitize=thread`). "IMPLEMENTED-UNVERIFIED" means it builds but has not been exercised on real hardware. Nothing has been run against a real face, headphones or ears yet. All tuning defaults (One-Euro cutoffs/beta, hold 0.5 s, decay 1.5 s, blend 0.25 s, min confidence 0.5) are UNTUNED placeholders.

| Area | Status | Notes |
|---|---|---|
| Swift package skeleton, Swift Testing harness | IMPLEMENTED (verified) | |
| Vector3 / Quaternion math, Euler boundary | IMPLEMENTED (verified) | +X right, +Y up, forward −Z; yaw+ = left, pitch+ = up, roll+ = right ear down |
| One-Euro filter (scalar + quaternion) | IMPLEMENTED (verified) | synthetic data only |
| Calibration, tracking state machine, HeadPosePipeline | IMPLEMENTED (verified) | no-jump property tested on synthetic input |
| 7.1.4 speaker layout (LFE not spatialized) | IMPLEMENTED (verified) | Side-surround ±90° is **UNVERIFIED** (see provenance below) |
| Vision→our-convention angle mapping (`HeadAngleMapping`, mirror compensation, invert overrides) | IMPLEMENTED (verified by unit tests) | **Yaw and roll sign defaults are UNVERIFIED on hardware** (header does not define the viewpoint of "counterclockwise"); pitch negation comes from the header ("positive = nodding down") |
| `HeadPoseProvider` protocol, `HeadTracker` (detections → mapping → pipeline → snapshots with latency fields) | IMPLEMENTED (verified by unit tests with a fake provider) | |
| Vision face detection wrapper (`VNDetectFaceRectanglesRequest` revision 3: yaw/pitch/roll) | IMPLEMENTED-UNVERIFIED | Blank frame → 0 faces, and angle extraction from constructed observations, are tested. Behavior on a real face is not verified. Vision exposes yaw/pitch/roll directly, so no custom estimator was written |
| Camera capture provider (AVFoundation, 640x480, built-in camera preferred, late frames dropped, releases on stop) | IMPLEMENTED-UNVERIFIED | Builds; app launches without crash and without touching camera auth. Capture, permission prompt and release have not been exercised |
| Camera mirroring | IMPLEMENTED-UNVERIFIED | Never set (macOS lacks `automaticallyAdjustsVideoMirroring`; setting `videoMirrored` can throw). Actual `isVideoMirrored` is read per frame and compensated |
| Debug HUD (pose, raw Vision angles, state, confidence, faces, latency breakdown, fps, mirrored/rotation, nose compass, recenter, invert toggles) | IMPLEMENTED-UNVERIFIED | Launches; not seen with live data |
| Pose latency readout | IMPLEMENTED-UNVERIFIED | Capture sample timestamp → pose ready, on the session sync clock; excludes delay before the timestamp. Not a validated end-to-end figure (Step 5). No numbers exist yet |
| `scripts/make-app.sh` (.app bundle, Info.plist with `NSCameraUsageDescription`, ad-hoc signing) | IMPLEMENTED (verified: plist lints, codesign verifies, app launches) | Dev only. Bundle id `dev.spatialaudio.SpatialAudio` is a placeholder. Signing/notarization/hardened runtime/camera entitlement = Step 9 |
| **Step 2c: guided self-test.** Script and session engine (17 phases, about 47 s: baseline, turn left ×2, look up ×2, tilt right ear ×2, then turn left + cover + uncover; deterministic, the clock is an input) | IMPLEMENTED (verified by unit tests; the whole flow ran end to end only with the SIMULATED user). **Real-camera run: UNVERIFIED** | |
| `SignDetector`: per-axis sign from raw Vision angles (hold − reference medians; movement ≥ 15° yaw / 10° pitch / 10° roll and ≥ 5× reference noise; hold spread ≤ 40% of the movement; both repetitions usable and the same sign; other axes ≤ 0.6×; mirror-aware; INCONCLUSIVE instead of guessing) | IMPLEMENTED (verified by unit tests on synthetic clean, weak, noisy, conflicting, leaky, unsteady, face-missing and mirrored data, incl. a property test that the detected flag always makes the instructed move map positive). **Behaviour on a real face UNVERIFIED; all thresholds untuned** | It cannot see which way you physically moved; the prompts say so |
| `LossAnalyzer`: locked → holding → decaying → static → locked sequence, time in each state, largest frame-to-frame pose step vs. an adaptive threshold (max(10°, 1.25× the largest legitimate eased-blend step)), WEAK flag when the held pose is < 10° from neutral, frame-stall note | IMPLEMENTED (verified by unit tests driven by the real state machine). Real camera UNVERIFIED | Threshold, timeouts untuned |
| Statistics (fps, frame interval, delivery / Vision / total latency: mean, p95, max over the 30 s hold + rest window; lighting tag; stall note) | IMPLEMENTED (verified by unit tests). No real-camera figures beyond the single Step 2 session above | |
| Numbers-only report (JSON + markdown, no image data expressible) saved to `docs/test-results/` with a timestamp; Copy report | IMPLEMENTED (verified by unit tests: round trip, numbers-only structure; written by simulated end-to-end runs, including the default `docs/test-results/` path from the dev bundle). The Copy button itself was never clicked | |
| Self-test HUD: run panel with countdown, colour per phase, flash, results, lighting tag, Apply with confirmation, green-light question | IMPLEMENTED-UNVERIFIED on a real camera. Layout was reviewed only through in-process renders of a simulated run; AppKit-backed controls (buttons, checkboxes, segmented picker) cannot be rendered that way and were not seen | |
| Cue sounds (system sounds Glass / Pop / Tink / Basso / Ping / Hero) | IMPLEMENTED-UNVERIFIED | Files verified to exist and load; never heard (all runs were muted) |
| Programmatic camera-release evidence (`isRunning` right after `stopRunning()`, inputs/outputs, no frames after stop; stop notification and "session object freed" are **informational**) | IMPLEMENTED-UNVERIFIED on hardware | Framework behaviour checked on a camera-less session; the physical green light remains a visual check |
| Apply detected signs (after confirmation) + saved mapping (`UserDefaults`) + reset to documented defaults | IMPLEMENTED-UNVERIFIED | Mapping logic is unit-tested (`recommendedMapping`, `setMapping` reset); the confirm UI and persistence were never exercised; never offered for SIMULATED runs |
| `HeadTracker.setMapping` resets filter, state machine and calibration when the signs change | IMPLEMENTED (verified by unit tests) | |
| Process-activity assertion while tracking (prevents App Nap) | IMPLEMENTED (verified on the simulated source: 3/3 runs at 30 fps with it, vs 8/8 measured runs at 26.3–26.6 fps without it). Effect on real camera frame delivery UNVERIFIED | See the App Nap finding |
| Developer switches (`--simulate`, `--sim-flip`, `--sim-mirrored`, `--autorun-selftest`, `--exit-after-selftest`, `--mute`, `--lighting`, `--results-dir`, `--render-ui`), `SimulatedUser`, `SimulatedHeadPoseProvider` | IMPLEMENTED (verified); **dev only, FABRICATED data** | Must not be used for the real test or for any hardware claim |
| Manual camera test | PLANNED (needs Sanjai) | docs/MANUAL_TEST_STEP2.md: guided self-test first, manual checklist as fallback |
| Lock-free pose handoff: C11 triple buffer `CPoseMailbox` (SwiftPM C target) + Swift wrapper `PoseMailbox` in Core; min macOS 14.0 kept | IMPLEMENTED (verified) | Wait-free single-producer/single-consumer. Unit tests + a two-thread stress test (200k samples by default, `SA_STRESS_ITERATIONS=…` for soaks; its verdict uses no clock, see the stress-test finding) + standalone `scripts/tsan-mailbox.sh` (2M samples under ThreadSanitizer). Mutation-checked: TSan flags relaxed memory orders and a no-atomics variant. NOT yet used by anything (audio renderer is Step 3) and not yet measured inside a real audio callback |
| Tracking-quality signal (face presence, size, edge cropping, bounding-box + pose-angle continuity, frame rate, Vision confidence; weakest-link; components shown in HUD) | IMPLEMENTED (verified by unit tests) | All thresholds are UNTUNED placeholders. Landmark stability deliberately NOT included (needs a 2nd Vision request per frame; cost unmeasured on a fanless Air). It now gates the state machine in place of Vision confidence, so a bad threshold could cause false "face lost" holds; tune on real recordings |
| Frame watchdog (no frame for 250 ms on a monotonic `CLOCK_UPTIME_RAW` clock → face loss → hold → decay → static; 50 ms check interval) | IMPLEMENTED (verified by unit tests with a fake clock + one real-timer test) | 250 ms timeout is an untuned placeholder. Not yet exercised with a real stalled camera |
| M1 renderer (AVAudioEnvironmentNode + HRTF) | PLANNED | Step 3 |
| M1b 12-speaker virtual bed | PLANNED | Step 4 |
| Latency / CPU / memory measurements, 30–60 min thermal soak | PLANNED | Step 5 |
| System audio capture (Core Audio tap, stereo upmix labeled as upmix) | PLANNED | Step 6 |
| Virtual 5.1/7.1 device spike | EXPERIMENTAL (not started) | Step 7 |
| SOFA HRTF, room reflections, headphone EQ | PLANNED | Step 8 |
| Signed/notarized release | PLANNED | Step 9 |
| Free/Pro licensing, onboarding | LATER | Step 10 |
| 6DoF translation, personalization, Windows | LATER | |

## Known limitations of Step 2 (stated, not measured)
- `VNObservation.confidence` is a weak signal (Apple says it can be a constant 1.0; measured 0.87–0.89 in one session). Our own quality signal now gates tracking, but its thresholds are untuned guesses.
- The watchdog handles a stalled or silent camera. It does not handle sleep/wake or device unplug explicitly (Step 6 covers sleep/wake for audio); a tick after wake may see a large frame age and simply treat it as loss.
- Sleep/wake and camera-unplug handling are not implemented.
- Only the largest face is used. No camera selection UI.
- The new Swift-native Vision API (`DetectFaceRectanglesRequest`) is macOS 15+, so the legacy `VN*` classes are used to keep the 14.0 minimum.
- The self-test cannot know which way you actually moved; a tilt of the wrong ear silently inverts the roll result.
- All self-test thresholds (movement, noise, steadiness, leakage, jump, stall) are untuned proposals; real data may show them to be too strict or too loose. INCONCLUSIVE is the designed outcome for weak data.
- The self-test stops the camera when it finishes (to verify the release), so verifying applied signs needs another Start camera.
- Reports from a throttled or overloaded run are flagged by a stall note, but nothing prevents you from running while the Mac is busy.

## ThreadSanitizer finding (2026-11-04, worth remembering)
`swift test --sanitize=thread` initially stayed silent on a deliberately injected race in the C target: a plain struct assignment compiles to `___tsan_memcpy`, which this TSan runtime did not race-check, even though the code was instrumented. Fixed by copying the six fields individually in `CPoseMailbox.c`. After that, both `scripts/tsan-mailbox.sh` and `swift test --sanitize=thread` flag a relaxed-ordering mutation (which produced zero torn reads, i.e. only TSan catches it) and a no-atomics mutation, and stay clean on the real code. Lesson: a green TSan run only counts if TSan has been shown to fail on a broken variant.

## PoseMailbox stress-test finding (2026-11-04): a clock-dependent TEST, not a mailbox bug
**Symptom.** During the first 18-mutation run, `concurrentStressHasNoTornReadsAndMonotonicSequences` failed together with a loss-analyzer test, although the injected bug (M13) touched unrelated code.

**Classification: timing-dependent test (a wall-clock hang guard). Not a mailbox bug, and not ordinary load flakiness.**

Evidence:
1. **Timeline** (`pmset -g log` plus source-file mtimes). The run started 17:50:36 with the lid closed on battery at 3%. The Mac slept at 17:50:57 and 18:01:15, so the script advanced only during brief maintenance wakes (36 minutes in total; the same run takes about 70 s on a settled machine). M13's run ended at 18:25:58, the same second as the wake that ended a 97 s sleep (18:24:21 → 18:25:58): its test process was frozen mid-run.
2. **Mechanism in the code.** The reader ended on `Date() < deadline`, a 60 s *wall-clock* deadline, and wall-clock time keeps running during sleep. The other assertions (`torn`, `backwards`, `newReads`) cannot depend on time, and the algorithm cannot produce torn or backwards reads (the reader only swaps in a slot published after its current one; the `acq_rel` exchanges give the happens-before).
3. **Reproduction.** Freezing the test process (SIGSTOP) for 65 s during a 100M-iteration run made exactly one assertion fail, `r.lastSeq == total` (the reader had seen 22.4M of 100M values), while torn/backwards stayed green: the signature of the original failure.
4. **No failures without a freeze.** 170 valid runs on the unmodified code, 0 failures: stress test alone ×60, whole suite ×30, under ThreadSanitizer ×40 (30 stress + 10 whole suite), with 20 busy processes on 10 cores ×40 (30 stress + 10 whole suite). (An earlier loaded set was INVALID and is not counted: the bundles were still TSan-instrumented from the previous phase and aborted with "Interceptors are not working". Redone correctly.)
5. **Re-run.** The same 18 mutations on a settled machine caught M13 only with its own test (no stress-test failure).

**Fix (test only).** The reader now stops when the writer has finished and it has done one more read. That read starts after the final publish, so a latest-value mailbox must return the final sequence: the verdict uses no clock. Same 65 s freeze and 100M iterations: old design **fails**, new design **passes** (79.5 s, 196M reads). The new test still catches real mailbox bugs: a no-atomics single slot fails `torn == 0`; a reader that never swaps in new data fails `lastSeq == total` in 28 ms (the old design would have spun toward its deadline). Repeats of the new test: 40 plain, 30 under load, 30 under TSan, 0 failures; a 10M-iteration TSan soak is clean.

**The same class of hazard, found by auditing the rest of the suite and fixed:**
- `SimulatedHeadPoseProvider.stop()` was a **real race in production code** (added in Step 2c): it cancelled the timer without waiting for a tick already running, so one more detection could arrive after `stop()` returned, contradicting the protocol's "blocks until released". It now drains the in-flight tick. Regression test `noDetectionIsDeliveredAfterStopReturns`: **6/6 runs fail without the drain, 0/6 with it**.
- `HeadTracker.stopWatchdog()` had the same hole for watchdog snapshots; fixed the same way. Its first regression test was too weak (0/6 failures without the fix, so it proved nothing); it now uses a deliberately slow snapshot handler to keep a tick in flight: **6/6 fail without the drain, 0/6 with it**.
- Fixed sleeps and exact count windows replaced by `waitUntil` (deadline on `SuspendingClock`, which does not advance during sleep) and by an upper bound derived from the measured elapsed awake time; a test that started a real watchdog and asserted an exact snapshot count now disables the watchdog.
Rule recorded in CLAUDE.md: tests never derive a verdict from a wall-clock deadline or fixed sleep.

## App Nap finding (2026-11-04): the app must hold an activity assertion while tracking
While checking the default report path with a simulated run, the loss test began to fail (INCOMPLETE or FAIL, state flapping). The report's own statistics showed why: every run delivered 26.4 fps on average with 125–131 ms frame gaps (≈790 of 900 frames) instead of 30.0 fps and ≈35 ms. Elimination: a bare 30 Hz `DispatchSourceTimer` in a command-line process in the same minute was perfectly regular (33.3 ms, max < 39 ms, at several QoS and leeway settings); the app used only 0–7% of one core and its thread stacks were parked, so nothing was busy or blocked; launching through LaunchServices did not help (foreground launch: 26.4 fps too). Confirmed with the documented `NSAppSleepDisabled=YES` switch on the dev bundle (since removed): **900 frames, 30.0 fps, 33/34/34 ms, PASS**, versus the same minute without it: **789 frames, 26.3 fps, 38/100/130 ms, INCOMPLETE**. So macOS was App-Napping the app because its window was hidden behind others, coalescing its timers.

**Fix.** `HeadTrackingModel` holds `ProcessInfo.beginActivity([.userInitiatedAllowingIdleSystemSleep, .latencyCritical])` from a successful start until stop (API checked in NSProcessInfo.h and by compiling; the "allowing idle system sleep" variant does not keep the Mac awake). With it, simulated runs under the same conditions: 3/3 PASS, 900 / 897 / 900 frames, 30.0 fps. The report now says so when frames stall (statistics note for gaps over 100 ms, loss-test note for gaps over 150 ms); run 2 of those 3 showed a single 134 ms stall and the note fired while the verdict stayed PASS. **Not verified:** whether real camera frame delivery (an AVFoundation callback, not a timer) is affected by App Nap; the assertion is held there too.

## Step 2c verification record (2026-11-04)
**Run, and passed**
- `swift build`; `swift test` 227 tests (187 Core + 40 Tracking); the same under `swift test --sanitize=thread` with no race reports; `scripts/tsan-mailbox.sh` (2M samples: torn=0, backwards=0, exit 0).
- Mutation check: 18 deliberately injected bugs in the new sign / report / loss / session / statistics / tracker logic, one at a time, each file restored and verified afterwards. The first run caught 18/18 but is not trustworthy (the Mac was asleep for most of its 36 minutes). Re-run on a settled machine and again on the final code: **18/18 caught** (71 s each time).
- Stop-contract regression tests (above): 6/6 vs 0/6.
- Simulated end-to-end runs of the real app (real timers, file writing, release step, quitting): documented conventions; `--sim-flip=yaw,roll` (detected: invert yaw and roll only); `--sim-mirrored --lighting=dim` (frames mirrored 100%, same invert answer as unmirrored); the default `docs/test-results/` path from the dev bundle (files written, parsed, numbers-only check passed, then deleted); 3/3 PASS at 30 fps after the App Nap fix.
- HUD layout reviewed by rendering it in-process during a simulated run (idle, mid-hold, cover, results).
- SDK checks (macOS 27.2): `NSSound` named sounds (loaded), `NSPasteboard` (round trip on a private pasteboard; the real clipboard was not touched), `NSWorkspace` file reveal, `AVCaptureSession` `isRunning` / `inputs` / `outputs` / `stopRunning` and its stop notification, `NSProcessInfo` activity options. `AVCaptureSession.isInterrupted` is unavailable on macOS (unused).

**Not run (needs Sanjai and the real camera)**
The self-test on a real camera (so no real sign result exists), the permission prompt inside the self-test flow, the audible cues, the Copy report / Apply / green-light buttons (never clicked), window-close and Cmd+Q camera release, and the behaviour of real frame delivery under App Nap.

## 7.1.4 angle provenance (checked 2026-11-04)
Source: Dolby Atmos Home Theater Installation Guidelines (PDF text extracted locally; figures not readable).
- Verified in text: L/R ±30°; rear surround ≈135°; overhead elevation 45° reference (30–55° allowed); front heights ≈±30° azimuth; ceiling-mounted rear heights ≈135° azimuth.
- NOT verified: side surround ±90°. The text does not state it (figure only). 90° is an assumption; common practice is 90–110°.
- Not checked: ITU-R BS.2051 nominal positions for this layout (the search did not surface the table). Wall-mounted height variants differ from the ceiling case used here.
