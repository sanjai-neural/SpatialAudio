# SpatialAudio self-test report

- **Date:** 2026-11-08T22:59:05+05:30
- **Lighting:** dim room
- **Input:** camera (MacBook Air Camera), capture preset 640x480 (AVCaptureSession.Preset.vga640x480), Vision request revision 3
- **Machine:** Mac16,12, macOS Version 27.2 (Build 26B123)
- **Frames mirrored (observed):** 0%; **rotation angle(s):** 0°
- **Invert flags in effect during the test:** yaw=off pitch=off roll=off

## 1. Sign detection
Target convention: turn LEFT = +yaw, look UP = +pitch, tilt RIGHT ear down = +roll. Raw Vision angles, degrees.

| Axis | Result | Raw Vision sign during move | Invert needed* | Repetition Δ (leakage ratio) | Reasons / notes |
|---|---|---|---|---|---|
| yaw | DETERMINED | + | no | rep1: +34.1° (0.57); rep2: +60.6° (0.34) | — |
| pitch | INCONCLUSIVE | — | — | rep1: -7.2° (1.72) ✗; rep2: -3.8° (2.86) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: face found in only 33% of hold frames (need 60%) / repetition 1: movement too small: 7.2° < required 10.0° (floor 10°, 5× noise 0.7°) / repetition 2: face found in only 35% of hold frames (need 60%) / repetition 2: movement too small: 3.8° < required 10.0° (floor 10°, 5× noise 1.0°) |
| roll | INCONCLUSIVE | — | — | rep1: +6.2° (9.39) ✗; rep2: +1.0° (56.87) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: movement too small: 6.2° < required 10.0° (floor 10°, 5× noise 0.5°) / repetition 2: movement too small: 1.0° < required 10.0° (floor 10°, 5× noise 0.4°) |

\* relative to the documented default mapping (all invert flags off, including its mirror compensation). LIKELY results are hints only and are never applied automatically.

### Baseline statistics of the instructed axis (raw Vision degrees)
σ is 1.4826 × the median absolute deviation (robust; this is the "noise" the 5× rule uses). Range (max − min) is shown only to contrast it. Drift is how far the medians of overlapping 10-sample sub-windows wander.

| Axis | Rep | Window | n | median | σ (MAD) | range | p10–p90 | drift | required move |
|---|---|---|---|---|---|---|---|---|---|
| yaw | 1 | reference | 45 | +0.1 | 0.78 | 2.9 | 1.8 | 1.6 | 15.0° |
| yaw | 1 | hold | 60 | +34.2 | 4.69 | 28.9 | 21.4 | 20.9 | — |
| yaw | 2 | reference | 30 | -2.6 | 0.81 | 5.2 | 3.4 | 2.8 | 15.0° |
| yaw | 2 | hold | 60 | +58.1 | 3.19 | 22.9 | 9.3 | 9.9 | — |
| pitch | 1 | reference | 30 | -4.6 | 0.75 | 2.9 | 2.4 | 1.4 | 10.0° |
| pitch | 1 | hold | 20 | -11.8 | 3.49 | 19.6 | 15.5 | 5.3 | — |
| pitch | 2 | reference | 30 | -11.2 | 1.04 | 6.4 | 5.4 | 4.7 | 10.0° |
| pitch | 2 | hold | 21 | -15.0 | 4.17 | 17.4 | 12.6 | 3.4 | — |
| roll | 1 | reference | 30 | +1.9 | 0.52 | 3.4 | 2.6 | 1.5 | 10.0° |
| roll | 1 | hold | 60 | +8.1 | 2.87 | 19.0 | 6.7 | 7.1 | — |
| roll | 2 | reference | 30 | +2.4 | 0.39 | 5.3 | 2.8 | 0.5 | 10.0° |
| roll | 2 | hold | 60 | +3.3 | 1.69 | 11.3 | 5.6 | 5.8 | — |

## 2. Loss test (turn ~25° left, cover camera, uncover)
- **Verdict:** PASS
- **Observed state sequence:** locked → holding → decaying → static → locked (expected locked → holding → decaying → static → locked)
- **Time in state:** locked-before-loss 3.04 s, holding 0.50 s (configured 0.50), decaying 1.50 s (configured 1.50), static 1.92 s
- **Holding → static:** 2.00 s; **reacquire after uncover cue:** 0.97 s (includes your reaction time)
- **Largest frame-to-frame pose step:** 7.36° (threshold 10.0°) → ok (in state locked, 0.52 s after the cover cue)
- **Held pose distance from neutral:** 11.5°
- note: 1 pose step(s) across frame gaps longer than 2.5× the median interval were not counted

### Evidence around the largest pose step (7.36° output step, state locked, 0.52 s after the cover cue)
- **Shape: multiFrameMovement**. The largest one-frame raw step was 8.7°, less than half of the 38.3° the raw orientation moved over 10 frames: a movement spread over several frames, consistent with a real fast turn.
- raw Vision step 8.7° (254°/s), raw displacement over 10 frames 38.3°
- shape thresholds are untuned: "back" = within 30% of the step, 5 frames; multi-frame = step < 50% of the 10-frame displacement
- the full ±15-frame window (raw, mapped, output, state, quality, limiting component, face box) is in the JSON file; ±8 frames are shown here:

| t (ms) | raw yaw/pitch/roll | mapped yaw/pitch/roll | output yaw/pitch/roll | state | quality | limiting | box h |
|---|---|---|---|---|---|---|---|
| -272 | +53.2 / -28.0 / -25.1 | +53.2 / +28.0 / -25.1 | +53.6 / +28.7 / -23.7 | locked | 0.42 | size | 0.14 |
| -236 | +53.7 / -28.4 / -25.0 | +53.7 / +28.4 / -25.0 | +53.6 / +28.6 / -23.9 | locked | 0.47 | size | 0.15 |
| -203 | +53.4 / -29.0 / -23.9 | +53.4 / +29.0 / -23.9 | +53.6 / +28.7 / -23.9 | locked | 0.44 | size | 0.14 |
| -167 | +53.4 / -29.1 / -23.9 | +53.4 / +29.1 / -23.9 | +53.5 / +28.8 / -23.9 | locked | 0.42 | size | 0.14 |
| -137 | +52.9 / -28.9 / -25.6 | +52.9 / +28.9 / -25.6 | +53.4 / +28.8 / -24.3 | locked | 0.44 | size | 0.14 |
| -99 | +46.3 / -25.4 / -33.8 | +46.3 / +25.4 / -33.8 | +51.5 / +27.7 / -26.9 | locked | 0.48 | size | 0.15 |
| -70 | +45.8 / -26.7 / -37.5 | +45.8 / +26.7 / -37.5 | +49.9 / +27.4 / -29.9 | locked | 0.51 | size | 0.15 |
| -33 | +41.6 / -26.5 / -38.4 | +41.6 / +26.5 / -38.4 | +47.5 / +27.0 / -32.4 | locked | 0.69 | size | 0.17 |
| +0 | +35.7 / -22.5 / -46.5 | +35.7 / +22.5 / -46.5 | +43.7 / +25.2 / -37.0 | locked | 0.54 | size | 0.15 |
| +30 | +35.6 / -22.9 / -26.6 | +35.6 / +22.9 / -26.6 | +40.5 / +24.5 / -32.9 | locked | 0.82 | size | 0.18 |
| +66 | +34.8 / -14.5 / -31.7 | +34.8 / +14.5 / -31.7 | +38.1 / +20.5 / -32.3 | locked | 0.95 | size | 0.19 |
| +100 | +30.1 / -22.0 / -20.8 | +30.1 / +22.0 / -20.8 | +34.9 / +21.3 / -27.6 | locked | 0.98 | size | 0.20 |
| +134 | +22.2 / -18.7 / -13.2 | +22.2 / +18.7 / -13.2 | +29.6 / +20.6 / -21.6 | locked | 1.00 | none | 0.21 |
| +166 | +22.9 / -24.7 / -8.1 | +22.9 / +24.7 / -8.1 | +27.0 / +22.4 / -16.1 | locked | 1.00 | none | 0.22 |
| +204 | +20.4 / -21.0 / -8.5 | +20.4 / +21.0 / -8.5 | +24.3 / +22.0 / -13.1 | locked | 1.00 | none | 0.23 |
| +238 | +16.2 / -20.7 / -7.7 | +16.2 / +20.7 / -7.7 | +21.2 / +21.6 / -11.0 | locked | 1.00 | none | 0.23 |
| +265 | +11.6 / -14.5 / -5.0 | +11.6 / +14.5 / -5.0 | +17.4 / +19.0 / -8.5 | locked | 1.00 | none | 0.23 |

## 3. Statistics (30 s window, dim room)
- **Frames:** 900; **face found in:** 89%; **mean quality:** 0.71
- **Mean frame rate:** 30.0 fps

| Metric (ms) | mean | p95 | max |
|---|---|---|---|
| Frame interval | 33 | 33 | 33 |
| Delivery (sample timestamp → callback) | 62 | 66 | 68 |
| Vision | 17 | 22 | 29 |
| Total (sample timestamp → pose ready) | 80 | 83 | 90 |

## 4. Tracking quality: which component limited it
Per group of phases: share of frames in which each component was the weakest ("none" = all components 1). "Low" = quality below the recovery threshold. Gate: lose below 0.40 for 0.10 s, recover at or above 0.60 for 0.20 s.

| Group | frames | mean | min | < loss | < recover | limiting component (share of frames) | limiting when low |
|---|---|---|---|---|---|---|---|
| statistics window (hold + rest) | 900 | 0.71 | 0.00 | 17% | 33% | none 46%, size 43%, no face 11% | size 67%, no face 33% |
| baseline | 60 | 1.00 | 1.00 | 0% | 0% | none 100% | — |
| hold: turn LEFT | 180 | 0.66 | 0.35 | 4% | 61% | size 70%, none 30% | size 100% |
| hold: look UP | 180 | 0.39 | 0.00 | 62% | 63% | no face 44%, none 34%, size 22% | no face 69%, size 31% |
| hold: tilt RIGHT EAR | 180 | 0.83 | 0.66 | 0% | 0% | size 67%, none 33% | — |
| rest | 360 | 0.83 | 0.00 | 10% | 19% | none 67%, size 28%, no face 5% | size 74%, no face 26% |
| loss test: turn (incl. waiting for lock) | 90 | 0.67 | 0.39 | 2% | 54% | size 69%, none 31% | size 100% |
| loss test: cover | 113 | 0.44 | 0.00 | 49% | 62% | no face 49%, none 35%, size 17% | no face 79%, size 21% |
| loss test: uncover | 108 | 0.88 | 0.00 | 11% | 11% | none 84%, no face 11%, frame rate 5% | no face 100% |
| whole run | 1361 | 0.73 | 0.00 | 16% | 31% | none 53%, size 34%, no face 12%, frame rate 0% | size 61%, no face 39% |

### Per phase, whole phase, in run order
Every phase on its own (the groups above pool the repetitions). Box h = face-box height as a fraction of the frame height (with the default quality settings the size score is 0 at 0.10 and 1 at 0.20; the settings in effect are not recorded). "< loss" / "< recover" = share of frames with quality strictly below the gate's thresholds. State seconds add up to the phase length: a frame's state is taken to hold until the next frame arrives.

| # | phase | t (s) | frames | box h min / med / max | quality min / med | < loss | < recover | limiting (top 2) | locked / holding / decaying / static (s) |
|---|---|---|---|---|---|---|---|---|---|
| 0 | get ready | 0.0–3.0 | 90 | 0.258 / 0.266 / 0.274 | 1.00 / 1.00 | 0% | 0% | none 100% | 3.00 / 0.00 / 0.00 / 0.00 |
| 1 | baseline | 3.0–5.0 | 60 | 0.252 / 0.259 / 0.264 | 1.00 / 1.00 | 0% | 0% | none 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 2 | hold: turn LEFT #1 | 5.0–8.0 | 90 | 0.135 / 0.153 / 0.258 | 0.35 / 0.53 | 4% | 61% | size 71%, none 29% | 3.00 / 0.00 / 0.00 / 0.00 |
| 3 | rest | 8.0–10.0 | 60 | 0.146 / 0.256 / 0.261 | 0.46 / 1.00 | 0% | 22% | none 72%, size 28% | 2.00 / 0.00 / 0.00 / 0.00 |
| 4 | hold: turn LEFT #2 | 10.0–13.0 | 90 | 0.139 / 0.152 / 0.264 | 0.39 / 0.52 | 3% | 61% | size 69%, none 31% | 3.00 / 0.00 / 0.00 / 0.00 |
| 5 | rest | 13.0–15.0 | 60 | 0.142 / 0.263 / 0.270 | 0.42 / 1.00 | 0% | 20% | none 72%, size 28% | 2.00 / 0.00 / 0.00 / 0.00 |
| 6 | hold: look UP #1 | 15.0–18.0 | 90 | 0.098 / 0.233 / 0.267 | 0.00 / 0.07 | 66% | 68% | no face 44%, none 31% | 1.13 / 0.50 / 1.38 / 0.00 |
| 7 | rest | 18.0–20.0 | 60 | 0.104 / 0.232 / 0.255 | 0.00 / 1.00 | 23% | 35% | none 60%, size 30% | 1.07 / 0.00 / 0.12 / 0.81 |
| 8 | hold: look UP #2 | 20.0–23.0 | 90 | 0.100 / 0.231 / 0.253 | 0.00 / 0.12 | 59% | 59% | no face 43%, none 38% | 1.36 / 0.50 / 1.14 / 0.00 |
| 9 | rest | 23.0–25.0 | 60 | 0.097 / 0.239 / 0.258 | 0.00 / 1.00 | 35% | 38% | none 58%, size 22% | 1.00 / 0.00 / 0.36 / 0.64 |
| 10 | hold: tilt RIGHT EAR #1 | 25.0–28.0 | 90 | 0.167 / 0.183 / 0.260 | 0.67 / 0.83 | 0% | 0% | size 62%, none 38% | 3.00 / 0.00 / 0.00 / 0.00 |
| 11 | rest | 28.0–30.0 | 60 | 0.174 / 0.266 / 0.276 | 0.74 / 1.00 | 0% | 0% | none 67%, size 33% | 2.00 / 0.00 / 0.00 / 0.00 |
| 12 | hold: tilt RIGHT EAR #2 | 30.0–33.0 | 90 | 0.166 / 0.173 / 0.269 | 0.66 / 0.73 | 0% | 0% | size 71%, none 29% | 3.00 / 0.00 / 0.00 / 0.00 |
| 13 | rest | 33.0–35.0 | 60 | 0.161 / 0.259 / 0.274 | 0.61 / 1.00 | 0% | 0% | none 72%, size 28% | 2.00 / 0.00 / 0.00 / 0.00 |
| 14 | loss test: turn | 35.0–38.0 | 90 | 0.139 / 0.153 / 0.259 | 0.39 / 0.53 | 2% | 54% | size 69%, none 31% | 3.01 / 0.00 / 0.00 / 0.00 |
| 15 | loss test: cover | 38.0–43.0 | 113 | 0.142 / 0.242 / 0.254 | 0.00 / 0.42 | 49% | 62% | no face 49%, none 35% | 2.05 / 0.50 / 1.50 / 0.95 |
| 16 | loss test: uncover | 43.0–47.0 | 108 | 0.206 / 0.259 / 0.270 | 0.00 / 1.00 | 11% | 11% | none 84%, no face 11% | 3.03 / 0.00 / 0.00 / 0.97 |

Per-frame series: 1361 frames (seconds from run start, phase, raw Vision yaw / pitch / roll in degrees, face-box height, quality, tracker state, watchdog flag) are stored column by column in the JSON file under `frameSeries`; they are not repeated here.

## 5. Camera release
- **Programmatic:** CLEAN — isRunning after stop=false, inputs=0, outputs=0, callbacks after stop=0, (informational: stop notifications seen=1, session object deallocated=true; both depend on the run loop and timing) — checked 1.2 s after stop
- **Green light (visual, user-reported):** NO — the light is STILL ON

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
