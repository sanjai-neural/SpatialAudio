# SpatialAudio self-test report

- **Date:** 2026-11-10T09:25:16+05:30
- **Lighting:** normal light
- **Input:** camera (MacBook Air Camera), capture preset 640x480 (AVCaptureSession.Preset.vga640x480), Vision request revision 3
- **Machine:** Mac16,12, macOS Version 27.2 (Build 26B123)
- **Frames mirrored (observed):** 0%; **rotation angle(s):** 0°
- **Invert flags in effect during the test:** yaw=off pitch=off roll=off

## 1. Sign detection
Target convention: turn LEFT = +yaw, look UP = +pitch, tilt RIGHT ear down = +roll. Raw Vision angles, degrees.

| Axis | Result | Raw Vision sign during move | Invert needed* | Repetition Δ (leakage ratio) | Reasons / notes |
|---|---|---|---|---|---|
| yaw | DETERMINED | + | no | rep1: +46.5° (0.38); rep2: +50.2° (0.33) | — |
| pitch | INCONCLUSIVE | — | — | rep1: -15.7° (1.14) ✗; rep2: -16.6° (1.65) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: wrong axis dominates: yaw changed 17.8° vs 15.7° on pitch (limit 0.6×) / repetition 2: reference window not steady: spread 4.7° (drift 8.4°) while the head should have been still, so 16.6° of movement is not enough (required 23.6° = 5× that spread); the head was still moving in the phase before this hold |
| roll | INCONCLUSIVE | — | — | rep1: +4.4° (11.83) ✗; rep2: +3.5° (15.50) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: movement too small: 4.4° < required 10.0° (floor 10°, 5× noise 0.4°) / repetition 2: movement too small: 3.5° < required 10.0° (floor 10°, 5× noise 1.6°) |

\* relative to the documented default mapping (all invert flags off, including its mirror compensation). LIKELY results are hints only and are never applied automatically.

### Baseline statistics of the instructed axis (raw Vision degrees)
σ is 1.4826 × the median absolute deviation (robust; this is the "noise" the 5× rule uses). Range (max − min) is shown only to contrast it. Drift is how far the medians of overlapping 10-sample sub-windows wander.

| Axis | Rep | Window | n | median | σ (MAD) | range | p10–p90 | drift | required move |
|---|---|---|---|---|---|---|---|---|---|
| yaw | 1 | reference | 45 | -0.5 | 2.22 | 6.5 | 4.4 | 4.1 | 15.0° |
| yaw | 1 | hold | 60 | +46.1 | 2.93 | 25.9 | 11.3 | 9.5 | — |
| yaw | 2 | reference | 30 | -0.9 | 2.02 | 5.6 | 4.0 | 2.9 | 15.0° |
| yaw | 2 | hold | 60 | +49.2 | 2.80 | 56.0 | 40.3 | 42.4 | — |
| pitch | 1 | reference | 30 | -2.0 | 1.92 | 4.7 | 4.2 | 2.4 | 10.0° |
| pitch | 1 | hold | 60 | -17.7 | 2.61 | 12.1 | 9.0 | 7.4 | — |
| pitch | 2 | reference | 30 | -4.8 | 4.72 | 11.4 | 9.2 | 8.4 | 23.6° |
| pitch | 2 | hold | 60 | -21.4 | 1.30 | 13.6 | 5.1 | 5.4 | — |
| roll | 1 | reference | 30 | +3.5 | 0.39 | 2.1 | 1.1 | 0.4 | 10.0° |
| roll | 1 | hold | 60 | +7.9 | 1.04 | 7.7 | 2.8 | 2.6 | — |
| roll | 2 | reference | 30 | +1.9 | 1.56 | 5.3 | 3.9 | 2.7 | 10.0° |
| roll | 2 | hold | 60 | +5.4 | 1.56 | 7.2 | 3.9 | 3.6 | — |

## 2. Loss test (turn ~25° left, cover camera, uncover)
- **Verdict:** PASS
- **Observed state sequence:** locked → holding → decaying → static → locked (expected locked → holding → decaying → static → locked)
- **Time in state:** locked-before-loss 2.43 s, holding 0.50 s (configured 0.50), decaying 1.51 s (configured 1.50), static 2.69 s
- **Holding → static:** 2.01 s; **reacquire after uncover cue:** 1.15 s (includes your reaction time)
- **Largest frame-to-frame pose step:** 5.91° (threshold 10.0°) → ok (in state locked, 1.33 s after the cover cue)
- **Held pose distance from neutral:** 8.1° — jump check is WEAK
- note: jump check is weak: the held pose was only 8.1° from neutral (need ≥ 10° for a meaningful test)

### Evidence around the largest pose step (5.91° output step, state locked, 1.33 s after the cover cue)
- **Shape: indeterminate**. The window does not fit any of the described shapes (missing frames after the step, or an irregular pattern).
- raw Vision step 14.6° (426°/s)
- shape thresholds are untuned: "back" = within 30% of the step, 5 frames; multi-frame = step < 50% of the 10-frame displacement
- the full ±15-frame window (raw, mapped, output, state, quality, limiting component, face box) is in the JSON file; ±8 frames are shown here:

| t (ms) | raw yaw/pitch/roll | mapped yaw/pitch/roll | output yaw/pitch/roll | state | quality | limiting | box h |
|---|---|---|---|---|---|---|---|
| -268 | +1.4 / +4.9 / +2.3 | +1.4 / -4.9 / +2.3 | +2.1 / -0.8 / +1.8 | locked | 1.00 | none | 0.23 |
| -235 | +0.8 / +1.7 / +2.5 | +0.8 / -1.7 / +2.5 | +1.8 / -1.0 / +1.9 | locked | 1.00 | none | 0.22 |
| -200 | +0.5 / +0.9 / +2.3 | +0.5 / -0.9 / +2.3 | +1.5 / -1.0 / +2.0 | locked | 1.00 | none | 0.23 |
| -169 | +0.5 / +1.2 / +2.3 | +0.5 / -1.2 / +2.3 | +1.3 / -1.1 / +2.1 | locked | 1.00 | none | 0.22 |
| -134 | +0.4 / +0.7 / +2.5 | +0.4 / -0.7 / +2.5 | +1.1 / -1.0 / +2.2 | locked | 1.00 | none | 0.23 |
| -101 | +0.1 / +1.6 / +1.6 | +0.1 / -1.6 / +1.6 | +0.9 / -1.1 / +2.0 | locked | 1.00 | none | 0.23 |
| -67 | -0.3 / +0.3 / +0.5 | -0.3 / -0.3 / +0.5 | +0.6 / -0.9 / +1.7 | locked | 1.00 | none | 0.23 |
| -36 | +6.9 / -1.8 / -3.3 | +6.9 / +1.8 / -3.3 | +2.2 / -0.2 / +0.4 | locked | 1.00 | none | 0.22 |
| +0 | +20.7 / +1.1 / +0.2 | +20.7 / -1.1 / +0.2 | +8.1 / -0.5 / +0.3 | locked | 0.78 | size | 0.18 |
| +26 | no face | no face | +8.1 / -0.5 / +0.3 | locked | 0.00 | no face | — |
| +61 | no face | no face | +8.1 / -0.5 / +0.3 | locked | 0.00 | no face | — |
| +94 | no face | no face | +8.1 / -0.5 / +0.3 | locked | 0.00 | no face | — |
| +126 | no face | no face | +8.1 / -0.5 / +0.3 | holding | 0.00 | no face | — |
| +154 | no face | no face | +8.1 / -0.5 / +0.3 | holding | 0.00 | no face | — |
| +207 | no face | no face | +8.1 / -0.5 / +0.3 | holding | 0.00 | no face | — |
| +267 | no face | no face | +8.1 / -0.5 / +0.3 | holding | 0.00 | no face | — |
| +328 | no face | no face | +8.1 / -0.5 / +0.3 | holding | 0.00 | no face | — |

## 3. Statistics (30 s window, normal light)
- **Frames:** 900; **face found in:** 100%; **mean quality:** 0.74
- **Mean frame rate:** 30.0 fps

| Metric (ms) | mean | p95 | max |
|---|---|---|---|
| Frame interval | 33 | 33 | 33 |
| Delivery (sample timestamp → callback) | 62 | 63 | 66 |
| Vision | 19 | 22 | 30 |
| Total (sample timestamp → pose ready) | 80 | 83 | 86 |

## 4. Tracking quality: which component limited it
Per group of phases: share of frames in which each component was the weakest ("none" = all components 1). "Low" = quality below the recovery threshold. Gate: lose below 0.40 for 0.10 s, recover at or above 0.60 for 0.20 s.

| Group | frames | mean | min | < loss | < recover | limiting component (share of frames) | limiting when low |
|---|---|---|---|---|---|---|---|
| statistics window (hold + rest) | 900 | 0.74 | 0.00 | 18% | 22% | size 56%, none 44% | size 100% |
| baseline | 60 | 1.00 | 1.00 | 0% | 0% | none 100% | — |
| hold: turn LEFT | 180 | 0.79 | 0.48 | 0% | 13% | size 60%, none 40% | size 100% |
| hold: look UP | 180 | 0.37 | 0.00 | 63% | 64% | size 71%, none 29% | size 100% |
| hold: tilt RIGHT EAR | 180 | 0.89 | 0.74 | 0% | 0% | size 68%, none 32% | — |
| rest | 360 | 0.82 | 0.00 | 12% | 15% | none 59%, size 41% | size 100% |
| loss test: turn (incl. waiting for lock) | 91 | 1.00 | 1.00 | 0% | 0% | none 100% | — |
| loss test: cover | 103 | 0.39 | 0.00 | 61% | 61% | no face 61%, none 38%, size 1% | no face 100% |
| loss test: uncover | 106 | 0.85 | 0.00 | 14% | 14% | none 81%, no face 14%, frame rate 5% | no face 100% |
| whole run | 1349 | 0.76 | 0.00 | 18% | 20% | none 56%, size 38%, no face 6%, frame rate 0% | size 71%, no face 29% |

### Per phase, whole phase, in run order
Every phase on its own (the groups above pool the repetitions). Box h = face-box height as a fraction of the frame height (with the default quality settings the size score is 0 at 0.10 and 1 at 0.20; the settings in effect are not recorded). "< loss" / "< recover" = share of frames with quality strictly below the gate's thresholds. State seconds add up to the phase length: a frame's state is taken to hold until the next frame arrives.

| # | phase | t (s) | frames | box h min / med / max | quality min / med | < loss | < recover | limiting (top 2) | locked / holding / decaying / static (s) |
|---|---|---|---|---|---|---|---|---|---|
| 0 | get ready | 0.0–3.0 | 89 | 0.173 / 0.227 / 0.239 | 0.00 / 1.00 | 3% | 3% | none 90%, size 7% | 3.00 / 0.00 / 0.00 / 0.00 |
| 1 | baseline | 3.0–5.0 | 60 | 0.225 / 0.229 / 0.242 | 1.00 / 1.00 | 0% | 0% | none 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 2 | hold: turn LEFT #1 | 5.0–8.0 | 90 | 0.148 / 0.168 / 0.245 | 0.48 / 0.68 | 0% | 8% | size 64%, none 36% | 3.00 / 0.00 / 0.00 / 0.00 |
| 3 | rest | 8.0–10.0 | 60 | 0.168 / 0.225 / 0.231 | 0.68 / 1.00 | 0% | 0% | none 70%, size 30% | 2.00 / 0.00 / 0.00 / 0.00 |
| 4 | hold: turn LEFT #2 | 10.0–13.0 | 90 | 0.155 / 0.174 / 0.232 | 0.55 / 0.74 | 0% | 18% | size 56%, none 44% | 3.00 / 0.00 / 0.00 / 0.00 |
| 5 | rest | 13.0–15.0 | 60 | 0.155 / 0.221 / 0.228 | 0.55 / 1.00 | 0% | 10% | none 67%, size 33% | 2.00 / 0.00 / 0.00 / 0.00 |
| 6 | hold: look UP #1 | 15.0–18.0 | 90 | 0.090 / 0.105 / 0.231 | 0.00 / 0.05 | 63% | 64% | size 70%, none 30% | 1.20 / 0.50 / 1.30 / 0.00 |
| 7 | rest | 18.0–20.0 | 60 | 0.096 / 0.171 / 0.216 | 0.00 / 0.71 | 40% | 43% | size 68%, none 32% | 0.93 / 0.00 / 0.20 / 0.87 |
| 8 | hold: look UP #2 | 20.0–23.0 | 90 | 0.094 / 0.104 / 0.219 | 0.00 / 0.04 | 62% | 64% | size 71%, none 29% | 1.23 / 0.50 / 1.26 / 0.00 |
| 9 | rest | 23.0–25.0 | 60 | 0.094 / 0.184 / 0.217 | 0.00 / 0.84 | 35% | 38% | size 60%, none 40% | 1.03 / 0.00 / 0.24 / 0.73 |
| 10 | hold: tilt RIGHT EAR #1 | 25.0–28.0 | 90 | 0.174 / 0.185 / 0.221 | 0.74 / 0.85 | 0% | 0% | size 68%, none 32% | 3.00 / 0.00 / 0.00 / 0.00 |
| 11 | rest | 28.0–30.0 | 60 | 0.181 / 0.231 / 0.236 | 0.81 / 1.00 | 0% | 0% | none 73%, size 27% | 2.00 / 0.00 / 0.00 / 0.00 |
| 12 | hold: tilt RIGHT EAR #2 | 30.0–33.0 | 90 | 0.175 / 0.185 / 0.235 | 0.75 / 0.85 | 0% | 0% | size 68%, none 32% | 3.00 / 0.00 / 0.00 / 0.00 |
| 13 | rest | 33.0–35.0 | 60 | 0.188 / 0.228 / 0.233 | 0.88 / 1.00 | 0% | 0% | none 70%, size 30% | 2.00 / 0.00 / 0.00 / 0.00 |
| 14 | loss test: turn | 35.0–38.0 | 91 | 0.202 / 0.215 / 0.232 | 1.00 / 1.00 | 0% | 0% | none 100% | 3.02 / 0.00 / 0.00 / 0.00 |
| 15 | loss test: cover | 38.0–43.0 | 103 | 0.178 / 0.224 / 0.226 | 0.00 / 0.00 | 61% | 61% | no face 61%, none 38% | 1.45 / 0.50 / 1.51 / 1.54 |
| 16 | loss test: uncover | 43.0–47.0 | 106 | 0.212 / 0.228 / 0.232 | 0.00 / 1.00 | 14% | 14% | none 81%, no face 14% | 2.85 / 0.00 / 0.00 / 1.15 |

Per-frame series: 1349 frames (seconds from run start, phase, raw Vision yaw / pitch / roll in degrees, face-box height, quality, tracker state, watchdog flag) are stored column by column in the JSON file under `frameSeries`; they are not repeated here.

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
