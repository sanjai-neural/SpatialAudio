# SpatialAudio self-test report

- **Date:** 2026-11-10T15:34:25+05:30
- **Lighting:** normal light
- **Input:** camera (MacBook Air Camera), capture preset 640x480 (AVCaptureSession.Preset.vga640x480), Vision request revision 3
- **Machine:** Mac16,12, macOS Version 27.2 (Build 26B123)
- **Frames mirrored (observed):** 0%; **rotation angle(s):** 0°
- **Invert flags in effect during the test:** yaw=off pitch=off roll=off

## 1. Sign detection
Target convention: turn LEFT = +yaw, look UP = +pitch, tilt RIGHT ear down = +roll. Raw Vision angles, degrees.

| Axis | Result | Raw Vision sign during move | Invert needed* | Repetition Δ (leakage ratio) | Reasons / notes |
|---|---|---|---|---|---|
| yaw | INCONCLUSIVE | — | — | rep1: +36.5° (0.78) ✗; rep2: +42.1° (1.39) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: hold not steady: spread 18.1° vs movement 36.5° (limit 40%) / repetition 1: wrong axis dominates: roll changed 28.5° vs 36.5° on yaw (limit 0.6×) / repetition 2: wrong axis dominates: roll changed 58.4° vs 42.1° on yaw (limit 0.6×) |
| pitch | DETERMINED | − | no | rep1: -30.7° (0.48); rep2: -19.0° (0.22) | — |
| roll | INCONCLUSIVE | — | — | rep1: +31.5° (1.92) ✗; rep2: +27.0° (2.12) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: reference window not steady: spread 9.4° (drift 15.9°) while the head should have been still, so 31.5° of movement is not enough (required 46.9° = 5× that spread); the head was still moving in the phase before this hold / repetition 2: reference window not steady: spread 7.0° (drift 13.4°) while the head should have been still, so 27.0° of movement is not enough (required 35.2° = 5× that spread); the head was still moving in the phase before this hold |

\* relative to the documented default mapping (all invert flags off, including its mirror compensation). LIKELY results are hints only and are never applied automatically.

### Baseline statistics of the instructed axis (raw Vision degrees)
σ is 1.4826 × the median absolute deviation (robust; this is the "noise" the 5× rule uses). Range (max − min) is shown only to contrast it. Drift is how far the medians of overlapping 10-sample sub-windows wander.

| Axis | Rep | Window | n | median | σ (MAD) | range | p10–p90 | drift | required move |
|---|---|---|---|---|---|---|---|---|---|
| yaw | 1 | reference | 45 | +0.9 | 2.35 | 12.8 | 10.6 | 10.4 | 15.0° |
| yaw | 1 | hold | 60 | +37.4 | 18.11 | 49.7 | 43.4 | 41.2 | — |
| yaw | 2 | reference | 30 | +0.1 | 0.72 | 23.6 | 15.2 | 10.9 | 15.0° |
| yaw | 2 | hold | 60 | +42.2 | 6.32 | 42.4 | 22.7 | 23.9 | — |
| pitch | 1 | reference | 30 | -2.9 | 0.72 | 3.5 | 2.6 | 1.7 | 10.0° |
| pitch | 1 | hold | 60 | -33.6 | 1.63 | 6.5 | 4.5 | 4.6 | — |
| pitch | 2 | reference | 30 | -11.3 | 1.47 | 6.3 | 3.9 | 2.8 | 10.0° |
| pitch | 2 | hold | 60 | -30.2 | 4.95 | 24.3 | 17.4 | 17.6 | — |
| roll | 1 | reference | 30 | -7.1 | 9.38 | 25.4 | 17.4 | 15.9 | 46.9° |
| roll | 1 | hold | 60 | +24.4 | 2.22 | 13.0 | 9.0 | 3.0 | — |
| roll | 2 | reference | 30 | -7.2 | 7.04 | 39.1 | 18.5 | 13.4 | 35.2° |
| roll | 2 | hold | 60 | +19.9 | 6.91 | 18.8 | 13.2 | 14.2 | — |

## 2. Loss test (turn ~25° left, cover camera, uncover)
- **Verdict:** FAIL
- **Observed state sequence:** locked → holding → decaying → static → locked (expected locked → holding → decaying → static → locked)
- **Time in state:** locked-before-loss 2.36 s, holding 0.50 s (configured 0.50), decaying 1.50 s (configured 1.50), static 2.41 s
- **Holding → static:** 2.00 s; **reacquire after uncover cue:** 0.78 s (includes your reaction time)
- **Largest frame-to-frame pose step:** 16.20° (threshold 10.0°) → **FLAGGED** (in state locked, 6.21 s after the cover cue)
- **Held pose distance from neutral:** 16.8°

### Evidence around the largest pose step (16.20° output step, state locked, 6.21 s after the cover cue)
- **Shape: spike**. The raw Vision orientation jumped 25.4° in one frame (758.2°/s) and was back within 30% of that 3 frame(s) later: shaped like a single-frame outlier.
- raw Vision step 25.4° (758°/s), raw back near its old value after 3 frame(s)
- shape thresholds are untuned: "back" = within 30% of the step, 5 frames; multi-frame = step < 50% of the 10-frame displacement
- the full ±15-frame window (raw, mapped, output, state, quality, limiting component, face box) is in the JSON file; ±8 frames are shown here:

| t (ms) | raw yaw/pitch/roll | mapped yaw/pitch/roll | output yaw/pitch/roll | state | quality | limiting | box h |
|---|---|---|---|---|---|---|---|
| -268 | -1.9 / -7.5 / -19.6 | -1.9 / +7.5 / -19.6 | -1.6 / +5.8 / -18.1 | locked | 1.00 | none | 0.29 |
| -230 | -1.2 / -6.6 / -33.8 | -1.2 / +6.6 / -33.8 | -1.6 / +6.7 / -24.6 | locked | 1.00 | none | 0.29 |
| -198 | -1.7 / -6.7 / -42.2 | -1.7 / +6.7 / -42.2 | -1.6 / +7.1 / -31.9 | locked | 1.00 | none | 0.29 |
| -162 | -1.4 / -6.5 / -46.5 | -1.4 / +6.5 / -46.5 | -1.5 / +7.0 / -37.0 | locked | 0.76 | scale jump | 0.21 |
| -131 | -1.5 / -5.7 / -50.8 | -1.5 / +5.7 / -50.8 | -1.5 / +6.6 / -41.5 | locked | 1.00 | none | 0.21 |
| -98 | -0.5 / -6.9 / -56.2 | -0.5 / +6.9 / -56.2 | -1.2 / +6.7 / -46.4 | locked | 1.00 | none | 0.21 |
| -63 | -0.7 / -8.4 / -45.4 | -0.7 / +8.4 / -45.4 | -1.0 / +7.3 / -46.0 | locked | 1.00 | none | 0.21 |
| -30 | +0.5 / -8.4 / -28.1 | +0.5 / +8.4 / -28.1 | -0.4 / +7.7 / -39.0 | locked | 0.44 | scale jump | 0.28 |
| +0 | -0.3 / -8.6 / -2.9 | -0.3 / +8.6 / -2.9 | -0.2 / +8.1 / -22.8 | locked | 1.00 | none | 0.29 |
| +34 | +0.6 / -8.9 / -9.9 | +0.6 / +8.9 / -9.9 | +0.2 / +8.4 / -17.2 | locked | 1.00 | none | 0.29 |
| +68 | +0.8 / -7.4 / -18.8 | +0.8 / +7.4 / -18.8 | +0.4 / +8.0 / -17.9 | locked | 1.00 | none | 0.29 |
| +97 | +0.2 / -5.5 / -27.2 | +0.2 / +5.5 / -27.2 | +0.4 / +6.9 / -21.9 | locked | 1.00 | none | 0.29 |
| +109 | +1.7 / -3.6 / -20.1 | +1.7 / +3.6 / -20.1 | +0.9 / +5.5 / -21.2 | locked | 1.00 | none | 0.29 |
| +141 | +3.9 / -3.7 / -34.5 | +3.9 / +3.7 / -34.5 | +2.3 / +4.8 / -27.0 | locked | 1.00 | none | 0.29 |
| +173 | +4.9 / -4.6 / -31.6 | +4.9 / +4.6 / -31.6 | +3.4 / +4.7 / -28.9 | locked | 1.00 | none | 0.29 |
| +208 | +7.3 / -5.4 / -40.1 | +7.3 / +5.4 / -40.1 | +5.0 / +5.1 / -33.5 | locked | 1.00 | none | 0.29 |
| +244 | +6.0 / -5.1 / -37.2 | +6.0 / +5.1 / -37.2 | +5.4 / +5.1 / -35.0 | locked | 1.00 | none | 0.29 |

## 3. Statistics (30 s window, normal light)
- **Frames:** 900; **face found in:** 100%; **mean quality:** 0.91
- **Mean frame rate:** 30.0 fps

| Metric (ms) | mean | p95 | max |
|---|---|---|---|
| Frame interval | 33 | 33 | 33 |
| Delivery (sample timestamp → callback) | 57 | 59 | 61 |
| Vision | 14 | 16 | 18 |
| Total (sample timestamp → pose ready) | 71 | 75 | 77 |

## 4. Tracking quality: which component limited it
Per group of phases: share of frames in which each component was the weakest ("none" = all components 1). "Low" = quality below the recovery threshold. Gate: lose below 0.40 for 0.10 s, recover at or above 0.60 for 0.20 s.

| Group | frames | mean | min | < loss | < recover | limiting component (share of frames) | limiting when low |
|---|---|---|---|---|---|---|---|
| statistics window (hold + rest) | 900 | 0.91 | 0.16 | 4% | 13% | none 69%, size 30%, scale jump 1%, angular speed 0% | size 98%, scale jump 2% |
| baseline | 60 | 1.00 | 1.00 | 0% | 0% | none 100% | — |
| hold: turn LEFT | 180 | 0.94 | 0.16 | 1% | 1% | none 59%, size 39%, scale jump 2% | scale jump 100% |
| hold: look UP | 180 | 0.68 | 0.32 | 16% | 56% | size 59%, none 41% | size 100% |
| hold: tilt RIGHT EAR | 180 | 0.97 | 0.86 | 0% | 0% | none 67%, size 33% | — |
| rest | 360 | 0.97 | 0.35 | 1% | 4% | none 89%, size 9%, scale jump 1%, angular speed 1% | size 100% |
| loss test: turn (incl. waiting for lock) | 91 | 0.90 | 0.63 | 0% | 0% | none 51%, size 45%, scale jump 4% | — |
| loss test: cover | 149 | 0.22 | 0.00 | 76% | 76% | no face 75%, size 13%, none 11%, scale jump 1% | no face 99%, scale jump 1% |
| loss test: uncover | 121 | 0.82 | 0.00 | 15% | 17% | none 72%, scale jump 14%, no face 12%, angular speed 1% | no face 75%, scale jump 20%, angular speed 5% |
| whole run | 1396 | 0.83 | 0.00 | 12% | 18% | none 64%, size 24%, no face 9%, scale jump 3% | no face 50%, size 46%, scale jump 3%, angular speed 1% |

### Per phase, whole phase, in run order
Every phase on its own (the groups above pool the repetitions). Box h = face-box height as a fraction of the frame height (with the default quality settings the size score is 0 at 0.10 and 1 at 0.20; the settings in effect are not recorded). "< loss" / "< recover" = share of frames with quality strictly below the gate's thresholds. State seconds add up to the phase length: a frame's state is taken to hold until the next frame arrives.

| # | phase | t (s) | frames | box h min / med / max | quality min / med | < loss | < recover | limiting (top 2) | locked / holding / decaying / static (s) |
|---|---|---|---|---|---|---|---|---|---|
| 0 | get ready | 0.0–3.0 | 75 | 0.231 / 0.300 / 0.308 | 0.00 / 1.00 | 1% | 4% | none 91%, scale jump 7% | 2.19 / 0.00 / 0.00 / 0.81 |
| 1 | baseline | 3.0–5.0 | 60 | 0.292 / 0.298 / 0.304 | 1.00 / 1.00 | 0% | 0% | none 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 2 | hold: turn LEFT #1 | 5.0–8.0 | 90 | 0.177 / 0.270 / 0.294 | 0.30 / 1.00 | 1% | 1% | none 87%, size 10% | 3.00 / 0.00 / 0.00 / 0.00 |
| 3 | rest | 8.0–10.0 | 60 | 0.221 / 0.288 / 0.296 | 0.75 / 1.00 | 0% | 0% | none 97%, scale jump 3% | 2.00 / 0.00 / 0.00 / 0.00 |
| 4 | hold: turn LEFT #2 | 10.0–13.0 | 90 | 0.174 / 0.190 / 0.297 | 0.16 / 0.90 | 1% | 1% | size 68%, none 31% | 3.00 / 0.00 / 0.00 / 0.00 |
| 5 | rest | 13.0–15.0 | 60 | 0.226 / 0.291 / 0.296 | 0.71 / 1.00 | 0% | 0% | none 97%, scale jump 3% | 2.00 / 0.00 / 0.00 / 0.00 |
| 6 | hold: look UP #1 | 15.0–18.0 | 90 | 0.132 / 0.150 / 0.294 | 0.32 / 0.50 | 11% | 67% | size 70%, none 30% | 1.46 / 0.50 / 1.04 / 0.00 |
| 7 | rest | 18.0–20.0 | 60 | 0.135 / 0.259 / 0.274 | 0.35 / 1.00 | 3% | 27% | none 70%, size 30% | 1.24 / 0.00 / 0.46 / 0.30 |
| 8 | hold: look UP #2 | 20.0–23.0 | 90 | 0.135 / 0.207 / 0.274 | 0.35 / 1.00 | 20% | 44% | none 51%, size 49% | 1.83 / 0.50 / 0.67 / 0.00 |
| 9 | rest | 23.0–25.0 | 60 | 0.260 / 0.269 / 0.275 | 1.00 / 1.00 | 0% | 0% | none 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 10 | hold: tilt RIGHT EAR #1 | 25.0–28.0 | 90 | 0.186 / 0.195 / 0.274 | 0.86 / 0.95 | 0% | 0% | size 60%, none 40% | 3.00 / 0.00 / 0.00 / 0.00 |
| 11 | rest | 28.0–30.0 | 60 | 0.189 / 0.292 / 0.299 | 0.70 / 1.00 | 0% | 0% | none 70%, size 27% | 2.00 / 0.00 / 0.00 / 0.00 |
| 12 | hold: tilt RIGHT EAR #2 | 30.0–33.0 | 90 | 0.197 / 0.228 / 0.299 | 0.97 / 1.00 | 0% | 0% | none 94%, size 6% | 3.00 / 0.00 / 0.00 / 0.00 |
| 13 | rest | 33.0–35.0 | 60 | 0.203 / 0.284 / 0.295 | 1.00 / 1.00 | 0% | 0% | none 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 14 | loss test: turn | 35.0–38.0 | 91 | 0.169 / 0.215 / 0.284 | 0.63 / 1.00 | 0% | 0% | none 51%, size 45% | 3.04 / 0.00 / 0.00 / 0.00 |
| 15 | loss test: cover | 38.0–43.0 | 149 | 0.174 / 0.190 / 0.276 | 0.00 / 0.00 | 76% | 76% | no face 75%, size 13% | 1.37 / 0.50 / 1.50 / 1.63 |
| 16 | loss test: uncover | 43.0–47.0 | 121 | 0.199 / 0.287 / 0.300 | 0.00 / 1.00 | 15% | 17% | none 72%, scale jump 14% | 3.22 / 0.00 / 0.00 / 0.78 |

Per-frame series: 1396 frames (seconds from run start, phase, raw Vision yaw / pitch / roll in degrees, face-box height, quality, tracker state, watchdog flag) are stored column by column in the JSON file under `frameSeries`; they are not repeated here.

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
