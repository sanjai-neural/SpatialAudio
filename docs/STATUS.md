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
- 30–60 minute **thermal soak** test (fanless MacBook Air): run tracking + rendering continuously and record CPU, frame rate, tracking latency and audio dropouts over time, plus whether the system throttles. No numbers exist yet.

## Features
"IMPLEMENTED (verified)" means: built and covered by passing unit tests (`swift test`: 93 tests, 78 Core + 15 Tracking, 2026-11-04). "IMPLEMENTED-UNVERIFIED" means it builds but has not been exercised on real hardware. Nothing has been run against a real face, headphones or ears yet. All tuning defaults (One-Euro cutoffs/beta, hold 0.5 s, decay 1.5 s, blend 0.25 s, min confidence 0.5) are UNTUNED placeholders.

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
| Lock-free pose handoff (C-target triple buffer + TSan stress test, min macOS 14.0) | PLANNED | Approved by Sanjai; first task of Step 3 |
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
- `VNObservation.confidence` may be a constant 1.0 (Apple says so for requests where it has no meaning), so it is not a reliable tracking-quality signal. A better gate (e.g. face-capture quality, bounding-box sanity, angle-jump rejection) is future work.
- State-machine hold/decay time advances only when frames arrive. If the camera stalls entirely, the pose is simply frozen.
- Sleep/wake and camera-unplug handling are not implemented.
- Only the largest face is used. No camera selection UI.
- The new Swift-native Vision API (`DetectFaceRectanglesRequest`) is macOS 15+, so the legacy `VN*` classes are used to keep the 14.0 minimum.

## 7.1.4 angle provenance (checked 2026-11-04)
Source: Dolby Atmos Home Theater Installation Guidelines (PDF text extracted locally; figures not readable).
- Verified in text: L/R ±30°; rear surround ≈135°; overhead elevation 45° reference (30–55° allowed); front heights ≈±30° azimuth; ceiling-mounted rear heights ≈135° azimuth.
- NOT verified: side surround ±90°. The text does not state it (figure only). 90° is an assumption; common practice is 90–110°.
- Not checked: ITU-R BS.2051 nominal positions for this layout (the search did not surface the table). Wall-mounted height variants differ from the ceiling case used here.
