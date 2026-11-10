# SpatialAudio self-test report

- **Date:** 2026-11-09T21:51:16+05:30
- **Lighting:** normal light
- **Input:** camera (MacBook Air Camera), capture preset 640x480 (AVCaptureSession.Preset.vga640x480), Vision request revision 3
- **Machine:** Mac16,12, macOS Version 27.2 (Build 26B123)
- **Frames mirrored (observed):** 0%; **rotation angle(s):** 0°
- **Invert flags in effect during the test:** yaw=off pitch=off roll=off

## 1. Sign detection
Target convention: turn LEFT = +yaw, look UP = +pitch, tilt RIGHT ear down = +roll. Raw Vision angles, degrees.

| Axis | Result | Raw Vision sign during move | Invert needed* | Repetition Δ (leakage ratio) | Reasons / notes |
|---|---|---|---|---|---|
| yaw | LIKELY (not applied) | + | no | rep1: +17.2° (0.90) ✗; rep2: +48.9° (0.48) | LIKELY, not DETERMINED: the direction agrees in every repetition that had enough movement, but cross-axis leakage failed (repetition 1: wrong axis dominates: pitch changed 15.5° vs 17.2° on yaw (limit 0.6×)). It is NEVER applied automatically; repeat with a smaller, single-axis move. / note: repetition magnitudes differ by more than 2x (17.2° vs 48.9°); the direction still agrees |
| pitch | INCONCLUSIVE | — | — | rep1: +0.0° (999.00) ✗; rep2: +0.0° (999.00) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: too few hold samples (7, need 15) / repetition 2: too few hold samples (7, need 15) |
| roll | INCONCLUSIVE | — | — | rep1: +18.5° (3.20) ✗; rep2: +18.7° (2.56) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: wrong axis dominates: yaw changed 59.3° vs 18.5° on roll (limit 0.6×) / repetition 2: reference window not steady: spread 5.0° (drift 0.0°) while the head should have been still, so 18.7° of movement is not enough (required 24.8° = 5× that spread); the head was still moving in the phase before this hold |

\* relative to the documented default mapping (all invert flags off, including its mirror compensation). LIKELY results are hints only and are never applied automatically.

### Baseline statistics of the instructed axis (raw Vision degrees)
σ is 1.4826 × the median absolute deviation (robust; this is the "noise" the 5× rule uses). Range (max − min) is shown only to contrast it. Drift is how far the medians of overlapping 10-sample sub-windows wander.

| Axis | Rep | Window | n | median | σ (MAD) | range | p10–p90 | drift | required move |
|---|---|---|---|---|---|---|---|---|---|
| yaw | 1 | reference | 25 | +3.6 | 0.52 | 2.2 | 1.8 | 0.6 | 15.0° |
| yaw | 1 | hold | 33 | +20.8 | 4.56 | 26.6 | 10.5 | 7.9 | — |
| yaw | 2 | reference | 16 | -0.0 | 0.68 | 2.4 | 1.6 | 0.0 | 15.0° |
| yaw | 2 | hold | 33 | +48.9 | 6.39 | 17.9 | 14.4 | 11.0 | — |
| roll | 1 | reference | 17 | -3.3 | 1.04 | 18.5 | 3.2 | 0.0 | 10.0° |
| roll | 1 | hold | 33 | +15.3 | 4.69 | 16.7 | 13.9 | 11.8 | — |
| roll | 2 | reference | 17 | +0.0 | 4.95 | 20.4 | 16.9 | 0.0 | 24.8° |
| roll | 2 | hold | 34 | +18.7 | 2.48 | 15.8 | 10.9 | 4.6 | — |

## 2. Loss test (turn ~25° left, cover camera, uncover)
- **Verdict:** FAIL
- **Observed state sequence:** locked → holding → decaying → static → locked (expected locked → holding → decaying → static → locked)
- **Time in state:** locked-before-loss 2.40 s, holding 0.52 s (configured 0.50), decaying 1.50 s (configured 1.50), static 3.10 s
- **Holding → static:** 2.02 s; **reacquire after uncover cue:** 1.54 s (includes your reaction time)
- **Largest frame-to-frame pose step:** 10.53° (threshold 10.0°) → **FLAGGED** (in state locked, 1.25 s after the cover cue)
- **Held pose distance from neutral:** 23.1°

### Evidence around the largest pose step (10.53° output step, state locked, 1.25 s after the cover cue)
- **Shape: indeterminate**. The window does not fit any of the described shapes (missing frames after the step, or an irregular pattern).
- raw Vision step 24.3° (697°/s)
- shape thresholds are untuned: "back" = within 30% of the step, 5 frames; multi-frame = step < 50% of the 10-frame displacement
- the full ±15-frame window (raw, mapped, output, state, quality, limiting component, face box) is in the JSON file; ±8 frames are shown here:

| t (ms) | raw yaw/pitch/roll | mapped yaw/pitch/roll | output yaw/pitch/roll | state | quality | limiting | box h |
|---|---|---|---|---|---|---|---|
| -485 | +25.9 / -23.4 / -6.2 | +25.9 / +23.4 / -6.2 | +26.5 / +27.0 / -7.5 | locked | 0.72 | frame rate | 0.19 |
| -424 | +22.1 / -23.6 / -8.1 | +22.1 / +23.6 / -8.1 | +24.8 / +25.7 / -7.7 | locked | 0.72 | frame rate | 0.19 |
| -365 | +18.9 / -25.8 / -7.4 | +18.9 / +25.8 / -7.4 | +22.6 / +25.7 / -7.6 | locked | 0.72 | frame rate | 0.19 |
| -304 | +13.6 / -24.3 / -6.1 | +13.6 / +24.3 / -6.1 | +19.2 / +25.2 / -7.0 | locked | 0.72 | frame rate | 0.20 |
| -244 | +10.5 / -21.0 / -5.6 | +10.5 / +21.0 / -5.6 | +15.8 / +23.7 / -6.4 | locked | 0.72 | frame rate | 0.20 |
| -183 | +6.4 / -16.5 / -3.3 | +6.4 / +16.5 / -3.3 | +12.0 / +20.9 / -5.0 | locked | 0.72 | frame rate | 0.20 |
| -124 | +5.2 / -16.9 / -1.5 | +5.2 / +16.9 / -1.5 | +9.4 / +19.4 / -3.6 | locked | 0.72 | frame rate | 0.21 |
| -60 | +8.0 / -11.3 / -1.0 | +8.0 / +11.3 / -1.0 | +8.8 / +16.3 / -2.6 | locked | 0.72 | frame rate | 0.20 |
| +0 | +30.2 / -8.6 / -7.3 | +30.2 / +8.6 / -7.3 | +19.1 / +12.9 / -5.2 | locked | 0.72 | frame rate | 0.21 |
| +57 | no face | no face | +19.1 / +12.9 / -5.2 | locked | 0.00 | no face | — |
| +115 | no face | no face | +19.1 / +12.9 / -5.2 | locked | 0.00 | no face | — |
| +172 | no face | no face | +19.1 / +12.9 / -5.2 | holding | 0.00 | no face | — |
| +232 | no face | no face | +19.1 / +12.9 / -5.2 | holding | 0.00 | no face | — |
| +293 | no face | no face | +19.1 / +12.9 / -5.2 | holding | 0.00 | no face | — |
| +356 | no face | no face | +19.1 / +12.9 / -5.2 | holding | 0.00 | no face | — |
| +391 | no face | no face | +19.1 / +12.9 / -5.2 | holding | 0.00 | no face | — |
| +424 | no face | no face | +19.1 / +12.9 / -5.2 | holding | 0.00 | no face | — |

## 3. Statistics (30 s window, normal light)
- **Frames:** 499; **face found in:** 86%; **mean quality:** 0.60
- **Mean frame rate:** 16.6 fps

| Metric (ms) | mean | p95 | max |
|---|---|---|---|
| Frame interval | 60 | 60 | 60 |
| Delivery (sample timestamp → callback) | 62 | 65 | 68 |
| Vision | 14 | 16 | 23 |
| Total (sample timestamp → pose ready) | 76 | 81 | 87 |

## 4. Tracking quality: which component limited it
Per group of phases: share of frames in which each component was the weakest ("none" = all components 1). "Low" = quality below the recovery threshold. Gate: lose below 0.40 for 0.10 s, recover at or above 0.60 for 0.20 s.

| Group | frames | mean | min | < loss | < recover | limiting component (share of frames) | limiting when low |
|---|---|---|---|---|---|---|---|
| statistics window (hold + rest) | 499 | 0.60 | 0.00 | 16% | 19% | frame rate 78%, no face 14%, size 8%, angular speed 0% | no face 73%, size 26%, angular speed 1% |
| baseline | 33 | 0.72 | 0.72 | 0% | 0% | frame rate 100% | — |
| hold: turn LEFT | 100 | 0.71 | 0.43 | 0% | 1% | frame rate 96%, size 3%, angular speed 1% | angular speed 100% |
| hold: look UP | 99 | 0.31 | 0.00 | 54% | 63% | no face 53%, frame rate 32%, size 15% | no face 84%, size 16% |
| hold: tilt RIGHT EAR | 99 | 0.72 | 0.72 | 0% | 0% | frame rate 100% | — |
| rest | 201 | 0.63 | 0.00 | 12% | 16% | frame rate 81%, size 10%, no face 8% | no face 53%, size 47% |
| loss test: turn (incl. waiting for lock) | 50 | 0.66 | 0.51 | 0% | 20% | frame rate 52%, size 48% | size 100% |
| loss test: cover | 128 | 0.12 | 0.00 | 84% | 84% | no face 84%, frame rate 16% | no face 100% |
| loss test: uncover | 82 | 0.50 | 0.00 | 40% | 40% | frame rate 43%, no face 39%, none 9%, size 9% | no face 97%, angular speed 3% |
| whole run | 842 | 0.53 | 0.00 | 26% | 29% | frame rate 66%, no face 25%, size 8%, none 1% | no face 85%, size 14%, angular speed 1% |

### Per phase, whole phase, in run order
Every phase on its own (the groups above pool the repetitions). Box h = face-box height as a fraction of the frame height (with the default quality settings the size score is 0 at 0.10 and 1 at 0.20; the settings in effect are not recorded). "< loss" / "< recover" = share of frames with quality strictly below the gate's thresholds. State seconds add up to the phase length: a frame's state is taken to hold until the next frame arrives.

| # | phase | t (s) | frames | box h min / med / max | quality min / med | < loss | < recover | limiting (top 2) | locked / holding / decaying / static (s) |
|---|---|---|---|---|---|---|---|---|---|
| 0 | get ready | 0.0–3.0 | 50 | 0.176 / 0.185 / 0.197 | 0.72 / 0.72 | 0% | 0% | frame rate 100% | 3.00 / 0.00 / 0.00 / 0.00 |
| 1 | baseline | 3.0–5.0 | 33 | 0.183 / 0.186 / 0.188 | 0.72 / 0.72 | 0% | 0% | frame rate 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 2 | hold: turn LEFT #1 | 5.0–8.0 | 50 | 0.163 / 0.182 / 0.202 | 0.43 / 0.72 | 0% | 2% | frame rate 92%, size 6% | 3.00 / 0.00 / 0.00 / 0.00 |
| 3 | rest | 8.0–10.0 | 33 | 0.182 / 0.203 / 0.235 | 0.72 / 0.72 | 0% | 0% | frame rate 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 4 | hold: turn LEFT #2 | 10.0–13.0 | 50 | 0.175 / 0.185 / 0.247 | 0.72 / 0.72 | 0% | 0% | frame rate 100% | 3.00 / 0.00 / 0.00 / 0.00 |
| 5 | rest | 13.0–15.0 | 33 | 0.174 / 0.204 / 0.221 | 0.72 / 0.72 | 0% | 0% | frame rate 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 6 | hold: look UP #1 | 15.0–18.0 | 50 | 0.144 / 0.216 / 0.235 | 0.00 / 0.00 | 52% | 62% | no face 52%, frame rate 34% | 1.57 / 0.54 / 0.89 / 0.00 |
| 7 | rest | 18.0–20.0 | 34 | 0.113 / 0.186 / 0.219 | 0.00 / 0.68 | 35% | 44% | frame rate 47%, size 29% | 0.84 / 0.00 / 0.62 / 0.54 |
| 8 | hold: look UP #2 | 20.0–23.0 | 49 | 0.132 / 0.214 / 0.234 | 0.00 / 0.00 | 55% | 63% | no face 53%, frame rate 31% | 1.44 / 0.54 / 1.02 / 0.00 |
| 9 | rest | 23.0–25.0 | 34 | 0.099 / 0.175 / 0.192 | 0.00 / 0.59 | 38% | 50% | frame rate 41%, size 32% | 0.72 / 0.00 / 0.49 / 0.79 |
| 10 | hold: tilt RIGHT EAR #1 | 25.0–28.0 | 49 | 0.176 / 0.182 / 0.210 | 0.72 / 0.72 | 0% | 0% | frame rate 100% | 3.00 / 0.00 / 0.00 / 0.00 |
| 11 | rest | 28.0–30.0 | 34 | 0.174 / 0.207 / 0.242 | 0.72 / 0.72 | 0% | 0% | frame rate 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 12 | hold: tilt RIGHT EAR #2 | 30.0–33.0 | 50 | 0.174 / 0.184 / 0.279 | 0.72 / 0.72 | 0% | 0% | frame rate 100% | 3.00 / 0.00 / 0.00 / 0.00 |
| 13 | rest | 33.0–35.0 | 33 | 0.181 / 0.209 / 0.230 | 0.72 / 0.72 | 0% | 0% | frame rate 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 14 | loss test: turn | 35.0–38.0 | 50 | 0.151 / 0.176 / 0.243 | 0.51 / 0.72 | 0% | 20% | frame rate 52%, size 48% | 3.01 / 0.00 / 0.00 / 0.00 |
| 15 | loss test: cover | 38.0–43.0 | 128 | 0.186 / 0.197 / 0.210 | 0.00 / 0.00 | 84% | 84% | no face 84%, frame rate 16% | 1.42 / 0.52 / 1.50 / 1.56 |
| 16 | loss test: uncover | 43.0–47.0 | 82 | 0.182 / 0.191 / 0.216 | 0.00 / 0.73 | 40% | 40% | frame rate 43%, no face 39% | 2.46 / 0.00 / 0.00 / 1.54 |

Per-frame series: 842 frames (seconds from run start, phase, raw Vision yaw / pitch / roll in degrees, face-box height, quality, tracker state, watchdog flag) are stored column by column in the JSON file under `frameSeries`; they are not repeated here.

## 5. Camera release
- **Programmatic:** CLEAN — isRunning after stop=false, inputs=0, outputs=0, callbacks after stop=0, (informational: stop notifications seen=1, session object deallocated=true; both depend on the run loop and timing) — checked 1.3 s after stop
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
