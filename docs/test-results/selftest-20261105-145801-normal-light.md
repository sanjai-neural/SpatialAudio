# SpatialAudio self-test report

- **Date:** 2026-11-05T14:58:01+05:30
- **Lighting:** normal light
- **Input:** camera (MacBook Air Camera), capture preset 640x480 (AVCaptureSession.Preset.vga640x480), Vision request revision 3
- **Machine:** Mac16,12, macOS Version 27.2 (Build 26B123)
- **Frames mirrored (observed):** 0%; **rotation angle(s):** 0°
- **Invert flags in effect during the test:** yaw=off pitch=off roll=off

## 1. Sign detection
Target convention: turn LEFT = +yaw, look UP = +pitch, tilt RIGHT ear down = +roll. Raw Vision angles, degrees.

| Axis | Result | Raw Vision sign during move | Invert needed* | Repetition Δ (leakage ratio) | Reasons / notes |
|---|---|---|---|---|---|
| yaw | DETERMINED | + | no | rep1: +66.0° (0.28); rep2: +72.0° (0.15) | — |
| pitch | DETERMINED | − | no | rep1: -40.9° (0.04); rep2: -28.5° (0.46) | — |
| roll | INCONCLUSIVE | — | — | rep1: -3.7° (15.67) ✗; rep2: -2.7° (20.31) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: movement too small: 3.7° < required 10.0° (floor 10°, 5× noise 1.0°) / repetition 2: movement too small: 2.7° < required 10.0° (floor 10°, 5× noise 0.3°) |

\* relative to the documented default mapping (all invert flags off, including its mirror compensation). LIKELY results are hints only and are never applied automatically.

### Baseline statistics of the instructed axis (raw Vision degrees)
σ is 1.4826 × the median absolute deviation (robust; this is the "noise" the 5× rule uses). Range (max − min) is shown only to contrast it. Drift is how far the medians of overlapping 10-sample sub-windows wander.

| Axis | Rep | Window | n | median | σ (MAD) | range | p10–p90 | drift | required move |
|---|---|---|---|---|---|---|---|---|---|
| yaw | 1 | reference | 45 | -2.2 | 3.65 | 9.4 | 7.3 | 6.9 | 18.2° |
| yaw | 1 | hold | 60 | +63.8 | 4.04 | 14.9 | 10.7 | 10.9 | — |
| yaw | 2 | reference | 30 | -2.5 | 0.46 | 10.1 | 6.8 | 3.6 | 15.0° |
| yaw | 2 | hold | 60 | +69.5 | 1.43 | 19.8 | 3.6 | 4.3 | — |
| pitch | 1 | reference | 30 | +6.5 | 1.24 | 8.8 | 6.3 | 4.7 | 10.0° |
| pitch | 1 | hold | 61 | -34.4 | 1.04 | 8.0 | 4.0 | 5.8 | — |
| pitch | 2 | reference | 30 | -5.1 | 0.81 | 3.6 | 2.4 | 1.1 | 10.0° |
| pitch | 2 | hold | 60 | -33.6 | 0.68 | 3.4 | 1.7 | 1.8 | — |
| roll | 1 | reference | 29 | +1.8 | 1.04 | 2.8 | 2.5 | 1.8 | 10.0° |
| roll | 1 | hold | 59 | -1.9 | 0.91 | 5.9 | 3.9 | 3.7 | — |
| roll | 2 | reference | 29 | +2.5 | 0.26 | 2.5 | 1.8 | 0.7 | 10.0° |
| roll | 2 | hold | 59 | -0.3 | 0.39 | 4.0 | 2.0 | 2.0 | — |

## 2. Loss test (turn ~25° left, cover camera, uncover)
- **Verdict:** PASS
- **Observed state sequence:** locked → holding → decaying → static → locked (expected locked → holding → decaying → static → locked)
- **Time in state:** locked-before-loss 2.93 s, holding 0.50 s (configured 0.50), decaying 1.50 s (configured 1.50), static 2.24 s
- **Holding → static:** 2.00 s; **reacquire after uncover cue:** 1.18 s (includes your reaction time)
- **Largest frame-to-frame pose step:** 8.59° (threshold 10.0°) → ok (in state locked, 0.74 s after the cover cue)
- **Held pose distance from neutral:** 2.4° — jump check is WEAK
- note: jump check is weak: the held pose was only 2.4° from neutral (need ≥ 10° for a meaningful test)

### Evidence around the largest pose step (8.59° output step, state locked, 0.74 s after the cover cue)
- **Shape: multiFrameMovement**. The largest one-frame raw step was 16.5°, less than half of the 41.9° the raw orientation moved over 10 frames: a movement spread over several frames, consistent with a real fast turn.
- raw Vision step 16.5° (498°/s), raw displacement over 10 frames 41.9°
- shape thresholds are untuned: "back" = within 30% of the step, 5 frames; multi-frame = step < 50% of the 10-frame displacement
- the full ±15-frame window (raw, mapped, output, state, quality, limiting component, face box) is in the JSON file; ±8 frames are shown here:

| t (ms) | raw yaw/pitch/roll | mapped yaw/pitch/roll | output yaw/pitch/roll | state | quality | limiting | box h |
|---|---|---|---|---|---|---|---|
| -266 | +68.8 / -12.3 / -8.9 | +68.8 / +12.3 / -8.9 | +68.4 / +12.5 / -10.3 | locked | 0.52 | size | 0.15 |
| -232 | +69.3 / -15.0 / -10.9 | +69.3 / +15.0 / -10.9 | +68.6 / +13.2 / -10.5 | locked | 0.55 | size | 0.16 |
| -198 | +66.8 / -15.0 / -15.4 | +66.8 / +15.0 / -15.4 | +68.1 / +13.7 / -12.0 | locked | 0.57 | size | 0.16 |
| -166 | +65.6 / -17.1 / -19.0 | +65.6 / +17.1 / -19.0 | +67.3 / +14.7 / -14.1 | locked | 0.58 | size | 0.16 |
| -133 | +64.8 / -14.4 / -18.9 | +64.8 / +14.4 / -18.9 | +66.5 / +14.6 / -15.5 | locked | 0.60 | size | 0.16 |
| -100 | +60.8 / -13.3 / -11.1 | +60.8 / +13.3 / -11.1 | +64.7 / +14.2 / -14.1 | locked | 0.72 | size | 0.17 |
| -67 | +54.3 / -12.1 / -9.0 | +54.3 / +12.1 / -9.0 | +61.3 / +13.6 / -12.4 | locked | 0.94 | size | 0.19 |
| -33 | +52.4 / -10.9 / -7.9 | +52.4 / +10.9 / -7.9 | +58.5 / +12.9 / -10.9 | locked | 1.00 | none | 0.20 |
| +0 | +37.4 / -5.4 / -14.8 | +37.4 / +5.4 / -14.8 | +50.7 / +10.0 / -12.0 | locked | 1.00 | none | 0.22 |
| +33 | +39.3 / -5.8 / -6.2 | +39.3 / +5.8 / -6.2 | +46.3 / +8.5 / -9.7 | locked | 1.00 | none | 0.22 |
| +69 | +40.2 / -10.5 / -5.6 | +40.2 / +10.5 / -5.6 | +44.1 / +9.3 / -8.2 | locked | 1.00 | none | 0.23 |
| +103 | +31.4 / -3.6 / -4.2 | +31.4 / +3.6 / -4.2 | +39.1 / +7.2 / -6.5 | locked | 1.00 | none | 0.23 |
| +134 | +29.8 / -9.8 / -4.9 | +29.8 / +9.8 / -4.9 | +35.6 / +8.2 / -6.0 | locked | 1.00 | none | 0.23 |
| +167 | +25.5 / -3.4 / -4.5 | +25.5 / +3.4 / -4.5 | +31.7 / +6.4 / -5.3 | locked | 1.00 | none | 0.23 |
| +201 | +21.6 / -8.0 / -4.0 | +21.6 / +8.0 / -4.0 | +27.9 / +7.0 / -4.9 | locked | 1.00 | none | 0.23 |
| +234 | +20.5 / -3.0 / -3.2 | +20.5 / +3.0 / -3.2 | +25.2 / +5.6 / -4.2 | locked | 1.00 | none | 0.24 |
| +267 | +19.9 / -2.7 / -2.0 | +19.9 / +2.7 / -2.0 | +23.3 / +4.6 / -3.4 | locked | 1.00 | none | 0.24 |

## 3. Statistics (30 s window, normal light)
- **Frames:** 899; **face found in:** 100%; **mean quality:** 0.86
- **Mean frame rate:** 30.0 fps

| Metric (ms) | mean | p95 | max |
|---|---|---|---|
| Frame interval | 33 | 33 | 33 |
| Delivery (sample timestamp → callback) | 63 | 65 | 73 |
| Vision | 18 | 21 | 32 |
| Total (sample timestamp → pose ready) | 81 | 83 | 90 |

## 4. Tracking quality: which component limited it
Per group of phases: share of frames in which each component was the weakest ("none" = all components 1). "Low" = quality below the recovery threshold. Gate: lose below 0.40 for 0.10 s, recover at or above 0.60 for 0.20 s.

| Group | frames | mean | min | < loss | < recover | limiting component (share of frames) | limiting when low |
|---|---|---|---|---|---|---|---|
| statistics window (hold + rest) | 899 | 0.86 | 0.29 | 7% | 14% | none 63%, size 37% | size 100% |
| baseline | 60 | 1.00 | 1.00 | 0% | 0% | none 100% | — |
| hold: turn LEFT | 180 | 0.78 | 0.50 | 0% | 8% | size 69%, none 31% | size 100% |
| hold: look UP | 180 | 0.65 | 0.29 | 29% | 52% | size 72%, none 28% | size 100% |
| hold: tilt RIGHT EAR | 180 | 1.00 | 0.90 | 0% | 0% | none 89%, size 11% | — |
| rest | 359 | 0.95 | 0.35 | 2% | 4% | none 83%, size 17% | size 100% |
| loss test: turn (incl. waiting for lock) | 91 | 0.71 | 0.38 | 2% | 38% | size 69%, none 31% | size 100% |
| loss test: cover | 150 | 0.31 | 0.00 | 63% | 75% | no face 63%, none 23%, size 14% | no face 84%, size 16% |
| loss test: uncover | 120 | 0.76 | 0.00 | 24% | 24% | none 75%, no face 24%, scale jump 1% | no face 100% |
| whole run | 1392 | 0.80 | 0.00 | 13% | 22% | none 61%, size 30%, no face 9%, scale jump 0% | size 58%, no face 42% |

## 5. Camera release
- **Programmatic:** CLEAN — isRunning after stop=false, inputs=0, outputs=0, callbacks after stop=0, (informational: stop notifications seen=1, session object deallocated=true; both depend on the run loop and timing) — checked 1.2 s after stop
- **Green light (visual, user-reported):** NOT ANSWERED (the question was shown but no answer was given)

## Thresholds used (all untuned)
- Sign detection: min movement yaw 15.0° / pitch 10.0° / roll 10.0° and ≥ 5.0× reference noise; hold spread ≤ 40% of the movement; other-axis leakage ≤ 0.60; ≥ 2 usable agreeing repetitions; ≥ 10/15 reference/hold samples; face in ≥ 60% of hold frames
- Loss test: jump threshold = max(10.0°, 1.25× the largest step the eased blend could produce); meaningful if held pose ≥ 10.0° from neutral
- State machine: hold 0.50 s, decay 1.50 s, reacquire blend 0.25 s
- Quality gate: loss below 0.40 for 0.10 s, recovery at or above 0.60 for 0.20 s (hysteresis and dwell; replaced the single 0.50 threshold)
- Loss test: the cover cue waits until tracking has been LOCKED for 1.0 s (at most 10 s), otherwise the run is INVALID
- Coaching targets: turn 30° / look up 20° / tilt 20°, keep the other axes still

## Assumptions and limits
- Signs assume each move was performed in the instructed direction; the test cannot see which way you actually moved.
- Angles are RAW Vision values (VNFaceObservation yaw/pitch/roll, revision 3) before any sign mapping.
- All thresholds are untuned proposals; the values used are listed in this report.
- Latency excludes any delay before the camera sample timestamp.
- Release check proves the capture session stopped; whether the green camera light is off is a visual check.
