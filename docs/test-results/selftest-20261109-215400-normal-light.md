# SpatialAudio self-test report

- **Date:** 2026-11-09T21:54:00+05:30
- **Lighting:** normal light
- **Input:** camera (MacBook Air Camera), capture preset 640x480 (AVCaptureSession.Preset.vga640x480), Vision request revision 3
- **Machine:** Mac16,12, macOS Version 27.2 (Build 26B123)
- **Frames mirrored (observed):** 0%; **rotation angle(s):** 0°
- **Invert flags in effect during the test:** yaw=off pitch=off roll=off

## 1. Sign detection
Target convention: turn LEFT = +yaw, look UP = +pitch, tilt RIGHT ear down = +roll. Raw Vision angles, degrees.

| Axis | Result | Raw Vision sign during move | Invert needed* | Repetition Δ (leakage ratio) | Reasons / notes |
|---|---|---|---|---|---|
| yaw | DETERMINED | + | no | rep1: +37.6° (0.27); rep2: +49.0° (0.52) | — |
| pitch | DETERMINED | − | no | rep1: -19.1° (0.34); rep2: -14.0° (0.57) | — |
| roll | INCONCLUSIVE | — | — | rep1: +2.3° (19.09) ✗; rep2: +3.5° (14.92) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: movement too small: 2.3° < required 10.0° (floor 10°, 5× noise 0.5°) / repetition 2: movement too small: 3.5° < required 10.0° (floor 10°, 5× noise 0.8°) |

\* relative to the documented default mapping (all invert flags off, including its mirror compensation). LIKELY results are hints only and are never applied automatically.

### Baseline statistics of the instructed axis (raw Vision degrees)
σ is 1.4826 × the median absolute deviation (robust; this is the "noise" the 5× rule uses). Range (max − min) is shown only to contrast it. Drift is how far the medians of overlapping 10-sample sub-windows wander.

| Axis | Rep | Window | n | median | σ (MAD) | range | p10–p90 | drift | required move |
|---|---|---|---|---|---|---|---|---|---|
| yaw | 1 | reference | 24 | +1.5 | 1.50 | 7.7 | 3.4 | 0.2 | 15.0° |
| yaw | 1 | hold | 28 | +39.1 | 10.10 | 34.3 | 28.3 | 5.6 | — |
| yaw | 2 | reference | 17 | +5.9 | 0.65 | 2.4 | 1.8 | 0.0 | 15.0° |
| yaw | 2 | hold | 33 | +54.8 | 2.74 | 12.2 | 6.2 | 2.8 | — |
| pitch | 1 | reference | 17 | -0.5 | 3.00 | 11.4 | 9.3 | 0.0 | 15.0° |
| pitch | 1 | hold | 34 | -19.6 | 2.35 | 13.4 | 8.2 | 3.4 | — |
| pitch | 2 | reference | 17 | -10.4 | 0.46 | 4.4 | 2.1 | 0.0 | 10.0° |
| pitch | 2 | hold | 34 | -24.3 | 3.26 | 8.9 | 6.5 | 5.5 | — |
| roll | 1 | reference | 17 | +2.5 | 0.52 | 2.3 | 1.2 | 0.0 | 10.0° |
| roll | 1 | hold | 34 | +4.7 | 0.78 | 7.2 | 3.5 | 3.0 | — |
| roll | 2 | reference | 17 | +0.5 | 0.78 | 5.4 | 5.1 | 0.0 | 10.0° |
| roll | 2 | hold | 33 | +4.0 | 1.04 | 3.9 | 3.0 | 1.5 | — |

## 2. Loss test (turn ~25° left, cover camera, uncover)
- **Verdict:** PASS
- **Observed state sequence:** locked → holding → decaying → static → locked (expected locked → holding → decaying → static → locked)
- **Time in state:** locked-before-loss 3.00 s, holding 0.54 s (configured 0.50), decaying 1.51 s (configured 1.50), static 1.93 s
- **Holding → static:** 2.05 s; **reacquire after uncover cue:** 1.03 s (includes your reaction time)
- **Largest frame-to-frame pose step:** 5.47° (threshold 10.0°) → ok (in state locked, 0.73 s after the cover cue)
- **Held pose distance from neutral:** 4.3° — jump check is WEAK
- note: jump check is weak: the held pose was only 4.3° from neutral (need ≥ 10° for a meaningful test)

### Evidence around the largest pose step (5.47° output step, state locked, 0.73 s after the cover cue)
- **Shape: multiFrameMovement**. The largest one-frame raw step was 6.9°, less than half of the 34.7° the raw orientation moved over 10 frames: a movement spread over several frames, consistent with a real fast turn.
- raw Vision step 6.9° (115°/s), raw displacement over 10 frames 34.7°
- shape thresholds are untuned: "back" = within 30% of the step, 5 frames; multi-frame = step < 50% of the 10-frame displacement
- the full ±15-frame window (raw, mapped, output, state, quality, limiting component, face box) is in the JSON file; ±8 frames are shown here:

| t (ms) | raw yaw/pitch/roll | mapped yaw/pitch/roll | output yaw/pitch/roll | state | quality | limiting | box h |
|---|---|---|---|---|---|---|---|
| -481 | +34.4 / -20.5 / -6.7 | +34.4 / +20.5 / -6.7 | +36.2 / +21.2 / -6.2 | locked | 0.72 | frame rate | 0.23 |
| -426 | +35.5 / -19.0 / -5.3 | +35.5 / +19.0 / -5.3 | +36.0 / +20.5 / -5.9 | locked | 0.72 | frame rate | 0.22 |
| -364 | +36.0 / -20.4 / -5.0 | +36.0 / +20.4 / -5.0 | +36.0 / +20.5 / -5.6 | locked | 0.72 | frame rate | 0.22 |
| -304 | +33.6 / -19.2 / -4.2 | +33.6 / +19.2 / -4.2 | +35.2 / +20.1 / -5.1 | locked | 0.72 | frame rate | 0.21 |
| -243 | +31.0 / -16.4 / -3.9 | +31.0 / +16.4 / -3.9 | +33.8 / +18.8 / -4.7 | locked | 0.72 | frame rate | 0.21 |
| -183 | +27.0 / -16.6 / -4.0 | +27.0 / +16.6 / -4.0 | +31.4 / +18.1 / -4.4 | locked | 0.72 | frame rate | 0.22 |
| -127 | +22.8 / -12.2 / -3.5 | +22.8 / +12.2 / -3.5 | +28.2 / +15.9 / -4.0 | locked | 0.72 | frame rate | 0.22 |
| -63 | +19.2 / -9.3 / -3.6 | +19.2 / +9.3 / -3.6 | +24.8 / +13.4 / -3.7 | locked | 0.72 | frame rate | 0.22 |
| +0 | +13.6 / -5.3 / -4.6 | +13.6 / +5.3 / -4.6 | +20.4 / +10.2 / -3.9 | locked | 0.72 | frame rate | 0.22 |
| +58 | +13.4 / -6.2 / -3.5 | +13.4 / +6.2 / -3.5 | +17.8 / +8.7 / -3.7 | locked | 0.72 | frame rate | 0.23 |
| +119 | +11.3 / -3.3 / -2.1 | +11.3 / +3.3 / -2.1 | +15.4 / +6.7 / -3.0 | locked | 0.72 | frame rate | 0.23 |
| +180 | +6.9 / -2.8 / -1.7 | +6.9 / +2.8 / -1.7 | +12.2 / +5.3 / -2.4 | locked | 0.72 | frame rate | 0.23 |
| +243 | +4.0 / -1.8 / -1.8 | +4.0 / +1.8 / -1.8 | +9.2 / +4.0 / -2.2 | locked | 0.72 | frame rate | 0.23 |
| +297 | +1.9 / -0.9 / -1.5 | +1.9 / +0.9 / -1.5 | +6.6 / +2.9 / -1.9 | locked | 0.72 | frame rate | 0.23 |
| +357 | +0.4 / -3.3 / -0.7 | +0.4 / +3.3 / -0.7 | +4.4 / +3.1 / -1.5 | locked | 0.72 | frame rate | 0.23 |
| +419 | +0.9 / -2.8 / +0.2 | +0.9 / +2.8 / +0.2 | +3.2 / +3.0 / -0.9 | locked | 0.72 | frame rate | 0.23 |
| +478 | -0.4 / -2.0 / +0.7 | -0.4 / +2.0 / +0.7 | +2.0 / +2.7 / -0.4 | locked | 0.72 | frame rate | 0.23 |

## 3. Statistics (30 s window, normal light)
- **Frames:** 499; **face found in:** 99%; **mean quality:** 0.71
- **Mean frame rate:** 16.6 fps

| Metric (ms) | mean | p95 | max |
|---|---|---|---|
| Frame interval | 60 | 60 | 60 |
| Delivery (sample timestamp → callback) | 62 | 65 | 69 |
| Vision | 14 | 16 | 18 |
| Total (sample timestamp → pose ready) | 76 | 81 | 85 |

## 4. Tracking quality: which component limited it
Per group of phases: share of frames in which each component was the weakest ("none" = all components 1). "Low" = quality below the recovery threshold. Gate: lose below 0.40 for 0.10 s, recover at or above 0.60 for 0.20 s.

| Group | frames | mean | min | < loss | < recover | limiting component (share of frames) | limiting when low |
|---|---|---|---|---|---|---|---|
| statistics window (hold + rest) | 499 | 0.71 | 0.00 | 1% | 1% | frame rate 95%, size 4%, no face 1% | no face 100% |
| baseline | 33 | 0.72 | 0.69 | 0% | 0% | frame rate 97%, angular speed 3% | — |
| hold: turn LEFT | 99 | 0.68 | 0.00 | 5% | 5% | frame rate 95%, no face 5% | no face 100% |
| hold: look UP | 100 | 0.71 | 0.64 | 0% | 0% | frame rate 83%, size 17% | — |
| hold: tilt RIGHT EAR | 100 | 0.72 | 0.72 | 0% | 0% | frame rate 100% | — |
| rest | 200 | 0.72 | 0.66 | 0% | 0% | frame rate 98%, size 2% | — |
| loss test: turn (incl. waiting for lock) | 50 | 0.72 | 0.72 | 0% | 0% | frame rate 100% | — |
| loss test: cover | 84 | 0.27 | 0.00 | 62% | 62% | no face 62%, frame rate 38% | no face 100% |
| loss test: uncover | 66 | 0.59 | 0.00 | 18% | 18% | frame rate 82%, no face 18% | no face 100% |
| whole run | 781 | 0.65 | 0.00 | 9% | 9% | frame rate 88%, no face 9%, size 3%, angular speed 1% | no face 96%, angular speed 4% |

### Per phase, whole phase, in run order
Every phase on its own (the groups above pool the repetitions). Box h = face-box height as a fraction of the frame height (with the default quality settings the size score is 0 at 0.10 and 1 at 0.20; the settings in effect are not recorded). "< loss" / "< recover" = share of frames with quality strictly below the gate's thresholds. State seconds add up to the phase length: a frame's state is taken to hold until the next frame arrives.

| # | phase | t (s) | frames | box h min / med / max | quality min / med | < loss | < recover | limiting (top 2) | locked / holding / decaying / static (s) |
|---|---|---|---|---|---|---|---|---|---|
| 0 | get ready | 0.0–3.0 | 49 | 0.170 / 0.201 / 0.266 | 0.25 / 0.72 | 4% | 6% | frame rate 90%, angular speed 10% | 3.00 / 0.00 / 0.00 / 0.00 |
| 1 | baseline | 3.0–5.0 | 33 | 0.213 / 0.229 / 0.251 | 0.69 / 0.72 | 0% | 0% | frame rate 97%, angular speed 3% | 2.00 / 0.00 / 0.00 / 0.00 |
| 2 | hold: turn LEFT #1 | 5.0–8.0 | 50 | 0.186 / 0.215 / 0.259 | 0.00 / 0.72 | 10% | 10% | frame rate 90%, no face 10% | 2.64 / 0.36 / 0.00 / 0.00 |
| 3 | rest | 8.0–10.0 | 34 | 0.201 / 0.232 / 0.247 | 0.72 / 0.72 | 0% | 0% | frame rate 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 4 | hold: turn LEFT #2 | 10.0–13.0 | 49 | 0.179 / 0.205 / 0.275 | 0.72 / 0.72 | 0% | 0% | frame rate 100% | 3.00 / 0.00 / 0.00 / 0.00 |
| 5 | rest | 13.0–15.0 | 34 | 0.204 / 0.241 / 0.261 | 0.72 / 0.72 | 0% | 0% | frame rate 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 6 | hold: look UP #1 | 15.0–18.0 | 50 | 0.164 / 0.174 / 0.269 | 0.64 / 0.72 | 0% | 0% | frame rate 68%, size 32% | 3.00 / 0.00 / 0.00 / 0.00 |
| 7 | rest | 18.0–20.0 | 33 | 0.166 / 0.224 / 0.258 | 0.66 / 0.72 | 0% | 0% | frame rate 94%, size 6% | 2.00 / 0.00 / 0.00 / 0.00 |
| 8 | hold: look UP #2 | 20.0–23.0 | 50 | 0.171 / 0.179 / 0.272 | 0.71 / 0.72 | 0% | 0% | frame rate 98%, size 2% | 3.00 / 0.00 / 0.00 / 0.00 |
| 9 | rest | 23.0–25.0 | 33 | 0.170 / 0.212 / 0.254 | 0.70 / 0.72 | 0% | 0% | frame rate 97%, size 3% | 2.00 / 0.00 / 0.00 / 0.00 |
| 10 | hold: tilt RIGHT EAR #1 | 25.0–28.0 | 50 | 0.203 / 0.214 / 0.280 | 0.72 / 0.72 | 0% | 0% | frame rate 100% | 3.00 / 0.00 / 0.00 / 0.00 |
| 11 | rest | 28.0–30.0 | 33 | 0.202 / 0.242 / 0.255 | 0.72 / 0.72 | 0% | 0% | frame rate 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 12 | hold: tilt RIGHT EAR #2 | 30.0–33.0 | 50 | 0.191 / 0.198 / 0.277 | 0.72 / 0.72 | 0% | 0% | frame rate 100% | 3.00 / 0.00 / 0.00 / 0.00 |
| 13 | rest | 33.0–35.0 | 33 | 0.195 / 0.237 / 0.252 | 0.72 / 0.72 | 0% | 0% | frame rate 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 14 | loss test: turn | 35.0–38.0 | 50 | 0.210 / 0.218 / 0.270 | 0.72 / 0.72 | 0% | 0% | frame rate 100% | 3.03 / 0.00 / 0.00 / 0.00 |
| 15 | loss test: cover | 38.0–43.0 | 84 | 0.211 / 0.230 / 0.240 | 0.00 / 0.00 | 62% | 62% | no face 62%, frame rate 38% | 2.05 / 0.54 / 1.51 / 0.91 |
| 16 | loss test: uncover | 43.0–47.0 | 66 | 0.212 / 0.239 / 0.255 | 0.00 / 0.72 | 18% | 18% | frame rate 82%, no face 18% | 2.97 / 0.00 / 0.00 / 1.03 |

Per-frame series: 781 frames (seconds from run start, phase, raw Vision yaw / pitch / roll in degrees, face-box height, quality, tracker state, watchdog flag) are stored column by column in the JSON file under `frameSeries`; they are not repeated here.

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
