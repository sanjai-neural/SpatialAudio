# ARCHITECTURE

Status: SpatialAudioCore is IMPLEMENTED (verified by unit tests). SpatialAudioTracking and the HUD in SpatialAudioApp are IMPLEMENTED-UNVERIFIED on hardware (Step 2; logic tested with fakes, camera not yet exercised). SpatialAudioEngine is a placeholder. Everything else below is PLANNED.

## Modules (Swift Package `SpatialAudio`, macOS 14+)
```
SpatialAudioApp ──► SpatialAudioTracking ──► SpatialAudioCore
        │                                          ▲
        └────────► SpatialAudioEngine ─────────────┘
```
- **SpatialAudioCore** — pure logic, no hardware or Apple media frameworks: quaternion math, One-Euro filter, calibration, tracking state machine, speaker layouts. Unit-tested.
- **SpatialAudioTracking** — AVFoundation capture + Vision, exposed only through the `HeadPoseProvider` protocol (pose + timestamp + confidence).
- **SpatialAudioEngine** — `AudioSource` and `SpatialRenderer` protocols and implementations (first: AVAudioEnvironmentNode with HRTF).
- **SpatialAudioApp** — SwiftUI shell and debug HUD. No DSP or CV logic.

## Data flow (target)
camera → Vision → raw pose → One-Euro filter → state machine (Locked/Holding/Decaying/Static) → calibrated quaternion → lock-free latest-value slot → audio thread interpolates per block → renderer listener orientation.

## Head tracking (Step 2)
```
AVCaptureSession (640x480, serial video queue, late frames dropped)
  -> VisionFaceDetector  (VNDetectFaceRectanglesRequest rev 3: yaw/pitch/roll in radians, Vision conventions)
  -> HeadPoseDetection   (timestamps on session sync clock, mirrored flag, rotation angle, error)
  -> HeadTracker         (HeadAngleMapping -> TrackingQualityEstimator -> HeadPosePipeline -> TrackingSnapshot)   [no AVFoundation/Vision here]
       + watchdog timer (monotonic clock): no frame for 250 ms => "lost" tick => hold -> decay -> static
       (planned, Step 3) -> PoseMailbox.publish() -> audio thread PoseMailbox.read() + per-block slerp
  -> HeadTrackingModel   (@MainActor view model) -> HUDView
```
- `HeadPoseProvider` is the seam: the camera implementation is `CameraHeadPoseProvider`; tests use a fake.
- API facts verified against the macOS 27.2 SDK headers on 2026-11-04: Vision `yaw/pitch/roll` exist on `VNFaceObservation` (revision 3 required for pitch and continuous values); header signs: yaw "counterclockwise", pitch "positive = nodding down", roll "counterclockwise"; `AVCaptureConnection.isVideoMirrored` exists on macOS but `automaticallyAdjustsVideoMirroring` does not; `AVCaptureSession.synchronizationClock` (macOS 12.3+) is the timebase of output timestamps.
- Quality gate: `TrackingQualityEstimator` (Core) scores each frame 0...1 as the weakest of: face size, edge cropping, bounding-box jump, scale jump, pose-angle speed, frame rate, Vision confidence. That score, not Vision's confidence, is the sample confidence the state machine compares against its threshold. Rejected samples never reach the One-Euro filter.
- Mirroring: never set; read per frame; yaw and roll signs are flipped by the mapping when a frame is mirrored.
- Latency fields per frame: delivery (received − capture timestamp), vision (detected − received), total (pose ready − capture timestamp).

## Guided self-test (Step 2c) — logic IMPLEMENTED (verified by unit tests); real-camera behavior UNVERIFIED
```
HeadTracker snapshots (+ watchdog ticks)
  -> HeadTrackingModel.receive(snapshot, arrival)         arrival = CLOCK_UPTIME_RAW stamped on the capture queue
  -> SelfTestController   (App: only orchestration + I/O: clock ticks, cue sounds, files, clipboard)
       -> SelfTestSession  (Core, pure: plays SelfTestScript against the clock it is handed; files each frame
                            under the phase it ARRIVED in; emits phase-start events once, in order)
       -> SelfTestAnalyzer (Core, pure)
            SignDetector  : raw Vision angles per instructed move -> per-axis sign or INCONCLUSIVE
            LossAnalyzer  : locked/holding/decaying/static/locked sequence, time in state, largest pose step
            StatsAnalyzer : fps, delivery, Vision, total latency (mean / p95 / max) over the 30 s hold+rest window
       -> SelfTestReport   (Core: numbers + short strings; JSON and markdown; no image data can be expressed)
       -> ReportStore (App) -> docs/test-results/*.json|.md
  -> model.stopAndVerifyRelease() -> CameraReleaseReport (programmatic) -> user answers the green-light question (visual)
```
- **Sign semantics.** The detector works on RAW Vision angles (before `HeadAngleMapping`) as hold-minus-reference differences, so rest offsets cancel. The invert flag it reports is derived by pushing the measured delta through the REAL `HeadAngleMapping` (including its mirror compensation), so it cannot disagree with the mapping. It cannot know which physical direction the person moved; the prompts and the report say so.
- **Thresholds** (all untuned proposals, printed in every report): movement ≥ 15° yaw / 10° pitch / 10° roll and ≥ 5× the reference-window noise; hold spread ≤ 40% of the movement; both repetitions usable and the same sign; other axes ≤ 0.6× the intended one; ≥ 10 reference / 15 hold samples and a face in ≥ 60% of hold frames. Loss test: pose-step threshold = max(10°, 1.25 × the largest step the eased blend could legitimately produce), a held pose < 10° from neutral marks the jump check WEAK.
- **Apply.** Only after an explicit confirmation: sets the invert flags of the DETERMINED axes (inconclusive axes keep their current setting), stores them in `UserDefaults`, and resets the filter, state machine and calibration (they live in mapped space; the user must Recenter). Never applied from a SIMULATED run.
- **Camera release evidence** is what code can prove: `AVCaptureSession.isRunning` read right after `stopRunning()` returned (it "blocks until the session object has completely stopped"), inputs/outputs removed, no sample callbacks after stop. Stop notifications and "session object freed" are INFORMATIONAL (they depend on the run loop and timing; verified on a camera-less session that they arrive only while the run loop spins). The physical green light is a visual check.
- **Simulated user** (`SimulatedUser`, `SimulatedHeadPoseProvider`, `--simulate`): deterministic made-up person for unit tests and for rehearsing the flow without a camera. Fabricated data, labeled SIMULATED everywhere, never usable for decisions about hardware.
- **Developer switches** (`LaunchOptions`): `--simulate`, `--sim-flip=…`, `--sim-mirrored`, `--autorun-selftest`, `--exit-after-selftest`, `--mute`, `--lighting=…`, `--results-dir=…`, `--render-ui=…` (renders the HUD to PNG in-process; used to review layout without screen-recording permission).

## Conventions (IMPLEMENTED, pinned by tests)
- Right-handed; +X right, +Y up, forward = −Z (matches AVAudioEnvironmentNode).
- Pose: yaw about +Y (positive = turn left), pitch about +X (positive = look up), roll about forward (positive = right ear down). Euler order yaw → pitch → roll; Euler used only at API boundaries.
- Speaker angles use the audio-standard convention instead: azimuth 0 = front, positive = right; elevation positive = up. `Speaker.position()` converts to the frame above.
- `calibrated = neutral⁻¹ · raw`. Pipeline order: One-Euro filter (raw camera space) → calibration → state machine, so decay always returns to calibrated neutral.
- Mirroring/sign handling of the camera is the Tracking module's job (Step 2) and must be verified manually.

## Constraints
- Quaternions internally; Euler only at API boundaries.
- Audio callback: no locks, allocation, I/O or logging.
- Camera frames stay in memory, are never saved, no network code; camera released on stop/exit.
- Core Audio taps need macOS 14.2+; SwiftPM can only declare 14.0, so gate with `#available` at runtime.

## Open questions (to resolve with evidence, not assumption)
- Does Vision expose head yaw/pitch/roll directly (Step 2 starts by checking SDK headers)?
- Latency budget and whether prediction is needed (decide after Step 5 measurements).

## Pose handoff to the audio thread — options (checked 2026-11-04) — DECIDED and implemented: C triple buffer (`CPoseMailbox`)
Requirement: single writer (tracking), single reader (audio callback); no locks, allocation, I/O or logging in the reader. A pose is 4 doubles (32 B) or 4 floats (16 B), too large to rely on a single atomic word, so every lock-free option needs a seqlock or triple buffer built on atomic integer operations.

| Option | Available at macOS 14.0? | Trade-offs |
|---|---|---|
| Swift `Synchronization` (`Atomic`, `Mutex`) | **No.** Verified in the SDK `.swiftinterface`: `Atomic`, `AtomicLazyReference`, `Mutex` are `@available(macOS 15.0)` | Clean Swift API, but would force a macOS 15 minimum, excluding 14.x Macs. Core Audio taps only need 14.2, so this would cost users for no audio reason |
| C target using `<stdatomic.h>` | Yes. Verified: a C file using `atomic_fetch_add_explicit`/`atomic_load_explicit` compiles with clang for `arm64-apple-macos14.0`. Not yet built as a SwiftPM C target | No third-party dependency; explicit memory orders; a triple buffer is ~40 lines of C and is wait-free for reader and writer. Cost: a mixed-language package and careful memory-order review; needs a stress test |
| `swift-atomics` package (Apple) | Not verified here (deployment target and API not checked) | Well-known library, but a new dependency (needs a stated reason); we would still build the triple buffer ourselves |
| Locks (`os_unfair_lock`, even try-lock) | Yes | Violates the no-locks-in-audio-callback rule; priority-inversion risk. Rejected |
| `OSAtomic*` | Present but deprecated in the SDK headers | Rejected |

Decision (approved by Sanjai): C target with a `stdatomic.h` triple buffer, because it works at 14.0 with no dependency and is wait-free for both sides. Implemented as `Sources/CPoseMailbox` + `PoseMailbox` (Core); stress- and TSan-tested (see STATUS). The audio reader will interpolate (slerp) between the previous and latest pose per block. Still open for Step 3: whether Swift class access (ARC) is acceptable in the audio callback or the render side should hold the raw C pointer.
