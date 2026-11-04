# STATUS

Tags: IMPLEMENTED (verified) · IMPLEMENTED-UNVERIFIED · PLANNED · EXPERIMENTAL · LATER

## Environment (recorded 2026-11-04, supplied by Sanjai)
- Mac: MacBook Air, model id `Mac16,12`, Apple M4, 16 GB RAM, **fanless**.
- macOS 27.2 (build 26B123). Xcode 27.2 (27B52). Swift 6.4.2 (swiftlang-6.4.2.1.9).
- Built-in camera as reported by AVFoundation: "MacBook Air Camera"; 640x480, 1280x720, 1920x1080 and others at 15–30 fps; `position` reports unspecified.
- `swift build` and plain `swift test` both work (verified). Tests use Swift Testing (`import Testing`).
- No code-signing identities installed (`security find-identity` → 0 valid), so dev bundles are ad-hoc signed.
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
Sign tests (turn left → yaw?, look up → pitch?, right ear down → roll?), cover-camera hold/decay/reacquire on a real camera, camera light off after Stop / window close / Cmd+Q, permission-prompt behavior, dim-room fps, anything odd. **No sign default has been changed.** Yaw, pitch and roll signs are all UNVERIFIED on hardware (pitch negation is justified by the header text only).

## Features
"IMPLEMENTED (verified)" means: built and covered by passing unit tests (`swift test`: 126 tests, 100 Core + 26 Tracking; also clean under `swift test --sanitize=thread`). "IMPLEMENTED-UNVERIFIED" means it builds but has not been exercised on real hardware. Nothing has been run against a real face, headphones or ears yet. All tuning defaults (One-Euro cutoffs/beta, hold 0.5 s, decay 1.5 s, blend 0.25 s, min confidence 0.5) are UNTUNED placeholders.

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
| Manual camera test | PLANNED (needs Sanjai) | docs/MANUAL_TEST_STEP2.md |
| Lock-free pose handoff: C11 triple buffer `CPoseMailbox` (SwiftPM C target) + Swift wrapper `PoseMailbox` in Core; min macOS 14.0 kept | IMPLEMENTED (verified) | Wait-free single-producer/single-consumer. Unit tests + 200k-sample two-thread stress test; plus standalone `scripts/tsan-mailbox.sh` (2M samples under ThreadSanitizer). Mutation-checked: TSan flags relaxed memory orders and a no-atomics variant. NOT yet used by anything (audio renderer is Step 3) and not yet measured inside a real audio callback |
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

## ThreadSanitizer finding (2026-11-04, worth remembering)
`swift test --sanitize=thread` initially stayed silent on a deliberately injected race in the C target: a plain struct assignment compiles to `___tsan_memcpy`, which this TSan runtime did not race-check, even though the code was instrumented. Fixed by copying the six fields individually in `CPoseMailbox.c`. After that, both `scripts/tsan-mailbox.sh` and `swift test --sanitize=thread` flag a relaxed-ordering mutation (which produced zero torn reads, i.e. only TSan catches it) and a no-atomics mutation, and stay clean on the real code. Lesson: a green TSan run only counts if TSan has been shown to fail on a broken variant.

## 7.1.4 angle provenance (checked 2026-11-04)
Source: Dolby Atmos Home Theater Installation Guidelines (PDF text extracted locally; figures not readable).
- Verified in text: L/R ±30°; rear surround ≈135°; overhead elevation 45° reference (30–55° allowed); front heights ≈±30° azimuth; ceiling-mounted rear heights ≈135° azimuth.
- NOT verified: side surround ±90°. The text does not state it (figure only). 90° is an assumption; common practice is 90–110°.
- Not checked: ITU-R BS.2051 nominal positions for this layout (the search did not surface the table). Wall-mounted height variants differ from the ceiling case used here.
