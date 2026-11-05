# SpatialAudio self-test report

- **Date:** 2026-11-05T08:12:18+05:30
- **Lighting:** normal light
- **Input:** camera (MacBook Air Camera), capture preset 640x480 (AVCaptureSession.Preset.vga640x480), Vision request revision 3
- **Machine:** Mac16,12, macOS Version 27.2 (Build 26B123)
- **Frames mirrored (observed):** 0%; **rotation angle(s):** 0°
- **Invert flags in effect during the test:** yaw=off pitch=off roll=off

## 1. Sign detection
Target convention: turn LEFT = +yaw, look UP = +pitch, tilt RIGHT ear down = +roll. Raw Vision angles, degrees.

| Axis | Result | Raw Vision sign during move | Invert needed* | Repetition Δ (leakage ratio) | Reasons / notes |
|---|---|---|---|---|---|
| yaw | DETERMINED | + | no | rep1: +53.4° (0.49); rep2: +63.0° (0.40) | — |
| pitch | INCONCLUSIVE | — | — | rep1: -17.9° (1.62) ✗; rep2: -7.0° (1.45) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: wrong axis dominates: yaw changed 28.9° vs 17.9° on pitch (limit 0.6×) / repetition 2: movement too small: 7.0° < required 11.6° (floor 10°, 5× noise 2.3°) |
| roll | INCONCLUSIVE | — | — | rep1: +24.6° (2.06) ✗; rep2: +7.0° (8.13) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: movement too small: 24.6° < required 41.7° (floor 10°, 5× noise 8.3°) / repetition 2: movement too small: 7.0° < required 20.8° (floor 10°, 5× noise 4.2°) |

\* relative to the documented default mapping (all invert flags off, including its mirror compensation).

## 2. Loss test (turn ~25° left, cover camera, uncover)
- **Verdict:** FAIL
- **Observed state sequence:** decaying → locked → holding → locked → holding → locked → holding → decaying → locked → holding → locked → holding → decaying → static → locked (expected locked → holding → decaying → static → locked)
- **Time in state:** locked-before-loss 0.00 s, holding 1.17 s (configured 0.50), decaying 1.76 s (configured 1.50), static 1.25 s
- **Holding → static:** 5.23 s; **reacquire after uncover cue:** 0.65 s (includes your reaction time)
- **Largest frame-to-frame pose step:** 18.68° (threshold 10.0°) → **FLAGGED** (in state locked, 6.35 s after the cover cue)
- **Held pose distance from neutral:** 58.7°
- note: holding lasted 0.07 s, configured 0.50 s
- note: decaying lasted 0.13 s, configured 1.50 s

## 3. Statistics (30 s window, normal light)
- **Frames:** 900; **face found in:** 100%; **mean quality:** 0.76
- **Mean frame rate:** 30.0 fps

| Metric (ms) | mean | p95 | max |
|---|---|---|---|
| Frame interval | 33 | 33 | 33 |
| Delivery (sample timestamp → callback) | 63 | 65 | 68 |
| Vision | 18 | 21 | 31 |
| Total (sample timestamp → pose ready) | 81 | 84 | 92 |

## 4. Camera release
- **Programmatic:** CLEAN — isRunning after stop=false, inputs=0, outputs=0, callbacks after stop=0, (informational: stop notifications seen=1, session object deallocated=true; both depend on the run loop and timing) — checked 1.3 s after stop
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
