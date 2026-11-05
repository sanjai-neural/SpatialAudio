# SpatialAudio self-test report

- **Date:** 2026-11-05T07:45:51+05:30
- **Lighting:** normal light
- **Input:** camera (MacBook Air Camera), capture preset 640x480 (AVCaptureSession.Preset.vga640x480), Vision request revision 3
- **Machine:** Mac16,12, macOS Version 27.2 (Build 26B123)
- **Frames mirrored (observed):** 0%; **rotation angle(s):** 0°
- **Invert flags in effect during the test:** yaw=off pitch=off roll=off

## 1. Sign detection
Target convention: turn LEFT = +yaw, look UP = +pitch, tilt RIGHT ear down = +roll. Raw Vision angles, degrees.

| Axis | Result | Raw Vision sign during move | Invert needed* | Repetition Δ (leakage ratio) | Reasons / notes |
|---|---|---|---|---|---|
| yaw | INCONCLUSIVE | — | — | rep1: +37.0° (0.46) ✗; rep2: +57.8° (0.99) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: movement too small: 37.0° < required 70.4° (floor 15°, 5× noise 14.1°) / repetition 2: wrong axis dominates: roll changed 57.3° vs 57.8° on yaw (limit 0.6×) |
| pitch | INCONCLUSIVE | — | — | rep1: -27.5° (0.17); rep2: -26.4° (0.63) ✗ | only 1 of 2 repetitions usable (need 2) / repetition 2: wrong axis dominates: roll changed 16.6° vs 26.4° on pitch (limit 0.6×) |
| roll | INCONCLUSIVE | — | — | rep1: +17.8° (2.32) ✗; rep2: -7.3° (2.21) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: movement too small: 17.8° < required 67.4° (floor 10°, 5× noise 13.5°) / repetition 2: movement too small: 7.3° < required 10.0° (floor 10°, 5× noise 0.3°) |

\* relative to the documented default mapping (all invert flags off, including its mirror compensation).

## 2. Loss test (turn ~25° left, cover camera, uncover)
- **Verdict:** FAIL
- **Observed state sequence:** locked → holding → decaying → static → locked (expected locked → holding → decaying → static → locked)
- **Time in state:** locked-before-loss 3.23 s, holding 0.50 s (configured 0.50), decaying 1.50 s (configured 1.50), static 1.54 s
- **Holding → static:** 2.00 s; **reacquire after uncover cue:** 0.80 s (includes your reaction time)
- **Largest frame-to-frame pose step:** 16.93° (threshold 10.0°) → **FLAGGED** (in state locked, 2.23 s after the cover cue)
- **Held pose distance from neutral:** 11.8°

## 3. Statistics (30 s window, normal light)
- **Frames:** 900; **face found in:** 100%; **mean quality:** 0.80
- **Mean frame rate:** 30.0 fps

| Metric (ms) | mean | p95 | max |
|---|---|---|---|
| Frame interval | 33 | 33 | 33 |
| Delivery (sample timestamp → callback) | 61 | 65 | 67 |
| Vision | 18 | 22 | 32 |
| Total (sample timestamp → pose ready) | 79 | 84 | 93 |

## 4. Camera release
- **Programmatic:** CLEAN — isRunning after stop=false, inputs=0, outputs=0, callbacks after stop=0, (informational: stop notifications seen=1, session object deallocated=true; both depend on the run loop and timing) — checked 1.2 s after stop
- **Green light (visual, user-reported):** not asked

## Thresholds used (all untuned)
- Sign detection: min movement yaw 15.0° / pitch 10.0° / roll 10.0° and ≥ 5.0× reference noise; hold spread ≤ 40% of the movement; other-axis leakage ≤ 0.60; ≥ 2 usable agreeing repetitions; ≥ 10/15 reference/hold samples; face in ≥ 60% of hold frames
- Loss test: jump threshold = max(10.0°, 1.25× the largest step the eased blend could produce); meaningful if held pose ≥ 10.0° from neutral
- State machine: min confidence 0.50, hold 0.50 s, decay 1.50 s, reacquire blend 0.25 s

## Assumptions and limits
- Signs assume each move was performed in the instructed direction; the test cannot see which way you actually moved.
- Angles are RAW Vision values (VNFaceObservation yaw/pitch/roll, revision 3) before any sign mapping.
- All thresholds are untuned proposals; the values used are listed in this report.
- Latency excludes any delay before the camera sample timestamp.
- Release check proves the capture session stopped; whether the green camera light is off is a visual check.
