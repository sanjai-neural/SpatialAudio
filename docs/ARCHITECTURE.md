# ARCHITECTURE

Status of everything below: PLANNED unless stated. Only the package skeleton exists (Step 0).

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

## Constraints
- Quaternions internally; Euler only at API boundaries.
- Audio callback: no locks, allocation, I/O or logging.
- Camera frames stay in memory, are never saved, no network code; camera released on stop/exit.
- Core Audio taps need macOS 14.2+; SwiftPM can only declare 14.0, so gate with `#available` at runtime.

## Open questions (to resolve with evidence, not assumption)
- Does Vision expose head yaw/pitch/roll directly (Step 2 starts by checking SDK headers)?
- Latency budget and whether prediction is needed (decide after Step 5 measurements).
