# ARCHITECTURE

Status: SpatialAudioCore is IMPLEMENTED (verified by unit tests, Step 1). Tracking, Engine and App are placeholders. Everything else below is PLANNED.

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

## Pose handoff to the audio thread — options (checked 2026-11-04, decision pending)
Requirement: single writer (tracking), single reader (audio callback); no locks, allocation, I/O or logging in the reader. A pose is 4 doubles (32 B) or 4 floats (16 B), too large to rely on a single atomic word, so every lock-free option needs a seqlock or triple buffer built on atomic integer operations.

| Option | Available at macOS 14.0? | Trade-offs |
|---|---|---|
| Swift `Synchronization` (`Atomic`, `Mutex`) | **No.** Verified in the SDK `.swiftinterface`: `Atomic`, `AtomicLazyReference`, `Mutex` are `@available(macOS 15.0)` | Clean Swift API, but would force a macOS 15 minimum, excluding 14.x Macs. Core Audio taps only need 14.2, so this would cost users for no audio reason |
| C target using `<stdatomic.h>` | Yes. Verified: a C file using `atomic_fetch_add_explicit`/`atomic_load_explicit` compiles with clang for `arm64-apple-macos14.0`. Not yet built as a SwiftPM C target | No third-party dependency; explicit memory orders; a triple buffer is ~40 lines of C and is wait-free for reader and writer. Cost: a mixed-language package and careful memory-order review; needs a stress test |
| `swift-atomics` package (Apple) | Not verified here (deployment target and API not checked) | Well-known library, but a new dependency (needs a stated reason); we would still build the triple buffer ourselves |
| Locks (`os_unfair_lock`, even try-lock) | Yes | Violates the no-locks-in-audio-callback rule; priority-inversion risk. Rejected |
| `OSAtomic*` | Present but deprecated in the SDK headers | Rejected |

Recommendation (not yet decided): C target with a `stdatomic.h` triple buffer, built and stress-tested in Step 3, because it works at 14.0 with no dependency and is wait-free for both sides. The reader would then interpolate (slerp) between the previous and latest pose per audio block. Needs Sanjai's approval before Step 3.
