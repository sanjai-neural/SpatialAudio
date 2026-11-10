# SpatialAudio self-test report

- **Date:** 2026-11-10T10:06:55+05:30
- **Lighting:** normal light
- **Input:** camera (MacBook Air Camera), capture preset 640x480 (AVCaptureSession.Preset.vga640x480), Vision request revision 3
- **Machine:** Mac16,12, macOS Version 27.2 (Build 26B123)
- **Frames mirrored (observed):** 0%; **rotation angle(s):** 0°
- **Invert flags in effect during the test:** yaw=off pitch=off roll=off

## 1. Sign detection
Target convention: turn LEFT = +yaw, look UP = +pitch, tilt RIGHT ear down = +roll. Raw Vision angles, degrees.

| Axis | Result | Raw Vision sign during move | Invert needed* | Repetition Δ (leakage ratio) | Reasons / notes |
|---|---|---|---|---|---|
| yaw | LIKELY (not applied) | + | no | rep1: +25.4° (1.71) ✗; rep2: +31.6° (0.94) ✗ | LIKELY, not DETERMINED: the direction agrees in every repetition that had enough movement, but cross-axis leakage failed (repetition 1: wrong axis dominates: roll changed 43.4° vs 25.4° on yaw (limit 0.6×); repetition 2: wrong axis dominates: roll changed 29.9° vs 31.6° on yaw (limit 0.6×)). It is NEVER applied automatically; repeat with a smaller, single-axis move. |
| pitch | DETERMINED | − | no | rep1: -44.3° (0.06); rep2: -41.8° (0.09) | — |
| roll | INCONCLUSIVE | — | — | rep1: -4.8° (11.81) ✗; rep2: -7.8° (6.82) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: movement too small: 4.8° < required 10.0° (floor 10°, 5× noise 1.6°) / repetition 2: movement too small: 7.8° < required 10.0° (floor 10°, 5× noise 1.0°) |

\* relative to the documented default mapping (all invert flags off, including its mirror compensation). LIKELY results are hints only and are never applied automatically.

### Baseline statistics of the instructed axis (raw Vision degrees)
σ is 1.4826 × the median absolute deviation (robust; this is the "noise" the 5× rule uses). Range (max − min) is shown only to contrast it. Drift is how far the medians of overlapping 10-sample sub-windows wander.

| Axis | Rep | Window | n | median | σ (MAD) | range | p10–p90 | drift | required move |
|---|---|---|---|---|---|---|---|---|---|
| yaw | 1 | reference | 38 | +3.7 | 1.30 | 5.9 | 4.6 | 4.0 | 15.0° |
| yaw | 1 | hold | 56 | +29.1 | 7.04 | 20.6 | 17.4 | 16.5 | — |
| yaw | 2 | reference | 29 | +2.9 | 0.52 | 9.3 | 3.9 | 1.2 | 15.0° |
| yaw | 2 | hold | 58 | +34.5 | 3.78 | 18.0 | 9.5 | 7.5 | — |
| pitch | 1 | reference | 29 | +22.2 | 1.30 | 7.1 | 3.8 | 1.8 | 10.0° |
| pitch | 1 | hold | 50 | -22.1 | 3.94 | 32.3 | 17.5 | 18.0 | — |
| pitch | 2 | reference | 24 | +25.8 | 6.39 | 24.2 | 21.4 | 12.7 | 31.9° |
| pitch | 2 | hold | 50 | -16.0 | 5.93 | 42.6 | 23.9 | 23.8 | — |
| roll | 1 | reference | 25 | +2.6 | 1.56 | 4.9 | 4.2 | 1.4 | 10.0° |
| roll | 1 | hold | 50 | -2.2 | 1.89 | 9.5 | 4.7 | 3.5 | — |
| roll | 2 | reference | 24 | +3.3 | 1.04 | 5.1 | 3.9 | 1.2 | 10.0° |
| roll | 2 | hold | 50 | -4.5 | 1.82 | 13.2 | 10.5 | 9.3 | — |

## 2. Loss test (turn ~25° left, cover camera, uncover)
- **Verdict:** INCOMPLETE
- **Observed state sequence:** locked → holding → decaying → locked → holding → decaying → static → locked (expected locked → holding → decaying → static → locked)
- **Time in state:** locked-before-loss 1.38 s, holding 1.05 s (configured 0.50), decaying 1.60 s (configured 1.50), static 2.29 s
- **Holding → static:** 3.66 s; **reacquire after uncover cue:** 1.35 s (includes your reaction time)
- **Largest frame-to-frame pose step:** 6.23° (threshold 10.0°) → ok (in state locked, 6.51 s after the cover cue)
- **Held pose distance from neutral:** 46.9°
- note: decaying lasted 0.08 s, configured 1.50 s
- note: state flapped: holding was entered more than once (partial cover?)

### Evidence around the largest pose step (6.23° output step, state locked, 6.51 s after the cover cue)
- **Shape: multiFrameMovement**. The largest one-frame raw step was 3.6°, less than half of the 8.3° the raw orientation moved over 10 frames: a movement spread over several frames, consistent with a real fast turn.
- raw Vision step 3.6° (89°/s), raw displacement over 10 frames 8.3°
- shape thresholds are untuned: "back" = within 30% of the step, 5 frames; multi-frame = step < 50% of the 10-frame displacement
- the full ±15-frame window (raw, mapped, output, state, quality, limiting component, face box) is in the JSON file; ±8 frames are shown here:

| t (ms) | raw yaw/pitch/roll | mapped yaw/pitch/roll | output yaw/pitch/roll | state | quality | limiting | box h |
|---|---|---|---|---|---|---|---|
| -274 | +13.0 / +24.3 / +3.9 | +13.0 / -24.3 / +3.9 | +0.0 / -0.0 / -0.0 | static | 0.80 | size | 0.18 |
| -236 | +15.1 / +26.3 / +4.4 | +15.1 / -26.3 / +4.4 | +0.0 / -0.0 / -0.0 | static | 0.79 | size | 0.18 |
| -197 | +12.8 / +26.9 / +6.3 | +12.8 / -26.9 / +6.3 | +0.0 / -0.0 / -0.0 | static | 0.80 | size | 0.18 |
| -165 | +16.3 / +26.5 / +3.3 | +16.3 / -26.5 / +3.3 | +0.0 / -0.0 / -0.0 | locked | 0.81 | size | 0.18 |
| -130 | +15.8 / +27.1 / +4.4 | +15.8 / -27.1 / +4.4 | +1.0 / -1.9 / -0.0 | locked | 0.85 | size | 0.18 |
| -97 | +16.4 / +25.8 / +6.5 | +16.4 / -25.8 / +6.5 | +2.6 / -4.7 / +0.1 | locked | 0.83 | size | 0.18 |
| -65 | +14.4 / +29.7 / +6.2 | +14.4 / -29.7 / +6.2 | +5.2 / -9.7 / +0.7 | locked | 0.81 | size | 0.18 |
| -31 | +12.2 / +27.8 / +4.2 | +12.2 / -27.8 / +4.2 | +7.8 / -15.2 / +1.5 | locked | 0.84 | size | 0.18 |
| +0 | +12.2 / +30.7 / +2.1 | +12.2 / -30.7 / +2.1 | +10.2 / -21.0 / +2.1 | locked | 0.86 | size | 0.19 |
| +33 | +9.3 / +29.4 / +6.5 | +9.3 / -29.4 / +6.5 | +11.5 / -25.6 / +3.7 | locked | 0.78 | size | 0.18 |
| +68 | +5.4 / +28.4 / +5.4 | +5.4 / -28.4 / +5.4 | +10.8 / -28.1 / +4.7 | locked | 0.78 | size | 0.18 |
| +102 | +5.6 / +31.6 / +3.5 | +5.6 / -31.6 / +3.5 | +9.5 / -29.3 / +4.5 | locked | 0.86 | size | 0.19 |
| +134 | +7.6 / +28.6 / +5.1 | +7.6 / -28.6 / +5.1 | +9.0 / -29.1 / +4.7 | locked | 0.81 | size | 0.18 |
| +168 | +2.9 / +26.5 / +5.8 | +2.9 / -26.5 / +5.8 | +7.3 / -28.3 / +5.0 | locked | 0.88 | size | 0.19 |
| +203 | +3.3 / +28.0 / +5.8 | +3.3 / -28.0 / +5.8 | +6.1 / -28.2 / +5.2 | locked | 0.89 | size | 0.19 |
| +238 | +3.6 / +27.6 / +3.2 | +3.6 / -27.6 / +3.2 | +5.4 / -28.1 / +4.6 | locked | 0.92 | size | 0.19 |
| +267 | +1.6 / +24.7 / +4.0 | +1.6 / -24.7 / +4.0 | +4.3 / -27.1 / +4.4 | locked | 0.91 | size | 0.19 |

## 3. Statistics (30 s window, normal light)
- **Frames:** 779; **face found in:** 100%; **mean quality:** 0.60
- **Mean frame rate:** 26.0 fps

| Metric (ms) | mean | p95 | max |
|---|---|---|---|
| Frame interval | 39 | 40 | 47 |
| Delivery (sample timestamp → callback) | 62 | 64 | 68 |
| Vision | 25 | 29 | 32 |
| Total (sample timestamp → pose ready) | 87 | 91 | 95 |

## 4. Tracking quality: which component limited it
Per group of phases: share of frames in which each component was the weakest ("none" = all components 1). "Low" = quality below the recovery threshold. Gate: lose below 0.40 for 0.10 s, recover at or above 0.60 for 0.20 s.

| Group | frames | mean | min | < loss | < recover | limiting component (share of frames) | limiting when low |
|---|---|---|---|---|---|---|---|
| statistics window (hold + rest) | 779 | 0.60 | 0.08 | 27% | 50% | size 100% | size 100% |
| baseline | 50 | 0.90 | 0.84 | 0% | 0% | size 100% | — |
| hold: turn LEFT | 163 | 0.54 | 0.20 | 25% | 72% | size 100% | size 100% |
| hold: look UP | 150 | 0.62 | 0.23 | 25% | 53% | size 100% | size 100% |
| hold: tilt RIGHT EAR | 150 | 0.43 | 0.08 | 57% | 62% | size 100% | size 100% |
| rest | 316 | 0.70 | 0.10 | 15% | 31% | size 100% | size 100% |
| loss test: turn (incl. waiting for lock) | 144 | 0.53 | 0.25 | 48% | 56% | size 100% | size 100% |
| loss test: cover | 106 | 0.29 | 0.00 | 64% | 73% | no face 56%, size 43%, none 1% | no face 77%, size 23% |
| loss test: uncover | 99 | 0.65 | 0.00 | 25% | 25% | size 75%, no face 25% | no face 100% |
| whole run | 1252 | 0.60 | 0.00 | 30% | 46% | size 93%, no face 7%, none 0% | size 85%, no face 15% |

### Per phase, whole phase, in run order
Every phase on its own (the groups above pool the repetitions). Box h = face-box height as a fraction of the frame height (with the default quality settings the size score is 0 at 0.10 and 1 at 0.20; the settings in effect are not recorded). "< loss" / "< recover" = share of frames with quality strictly below the gate's thresholds. State seconds add up to the phase length: a frame's state is taken to hold until the next frame arrives.

| # | phase | t (s) | frames | box h min / med / max | quality min / med | < loss | < recover | limiting (top 2) | locked / holding / decaying / static (s) |
|---|---|---|---|---|---|---|---|---|---|
| 0 | get ready | 0.0–3.0 | 74 | 0.181 / 0.189 / 0.201 | 0.81 / 0.89 | 0% | 0% | size 99%, none 1% | 3.00 / 0.00 / 0.00 / 0.00 |
| 1 | baseline | 3.0–5.0 | 50 | 0.184 / 0.190 / 0.198 | 0.84 / 0.90 | 0% | 0% | size 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 2 | hold: turn LEFT #1 | 5.0–8.0 | 81 | 0.120 / 0.140 / 0.199 | 0.20 / 0.40 | 49% | 70% | size 100% | 1.31 / 0.51 / 1.17 / 0.00 |
| 3 | rest | 8.0–10.0 | 59 | 0.127 / 0.184 / 0.192 | 0.27 / 0.84 | 7% | 29% | size 100% | 1.20 / 0.00 / 0.33 / 0.47 |
| 4 | hold: turn LEFT #2 | 10.0–13.0 | 82 | 0.144 / 0.150 / 0.195 | 0.44 / 0.50 | 0% | 73% | size 100% | 3.00 / 0.00 / 0.00 / 0.00 |
| 5 | rest | 13.0–15.0 | 59 | 0.148 / 0.187 / 0.198 | 0.48 / 0.87 | 0% | 25% | size 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 6 | hold: look UP #1 | 15.0–18.0 | 75 | 0.123 / 0.138 / 0.197 | 0.23 / 0.38 | 51% | 57% | size 100% | 1.62 / 0.52 / 0.85 / 0.00 |
| 7 | rest | 18.0–20.0 | 49 | 0.128 / 0.179 / 0.197 | 0.28 / 0.79 | 22% | 33% | size 100% | 1.12 / 0.00 / 0.64 / 0.24 |
| 8 | hold: look UP #2 | 20.0–23.0 | 75 | 0.145 / 0.166 / 0.193 | 0.45 / 0.66 | 0% | 48% | size 100% | 3.00 / 0.00 / 0.00 / 0.00 |
| 9 | rest | 23.0–25.0 | 50 | 0.154 / 0.184 / 0.198 | 0.54 / 0.84 | 0% | 28% | size 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 10 | hold: tilt RIGHT EAR #1 | 25.0–28.0 | 75 | 0.108 / 0.118 / 0.192 | 0.08 / 0.18 | 65% | 69% | size 100% | 1.19 / 0.52 / 1.29 / 0.00 |
| 11 | rest | 28.0–30.0 | 49 | 0.110 / 0.178 / 0.188 | 0.10 / 0.78 | 35% | 41% | size 100% | 0.96 / 0.00 / 0.20 / 0.84 |
| 12 | hold: tilt RIGHT EAR #2 | 30.0–33.0 | 75 | 0.109 / 0.144 / 0.190 | 0.09 / 0.44 | 49% | 55% | size 100% | 1.65 / 0.51 / 0.84 / 0.00 |
| 13 | rest | 33.0–35.0 | 50 | 0.115 / 0.180 / 0.191 | 0.15 / 0.80 | 28% | 32% | size 100% | 1.14 / 0.00 / 0.66 / 0.20 |
| 14 | loss test: turn | 35.0–40.1 | 144 | 0.125 / 0.145 / 0.192 | 0.25 / 0.45 | 48% | 56% | size 100% | 2.36 / 0.52 / 1.50 / 0.77 |
| 15 | loss test: cover | 40.1–45.1 | 106 | 0.133 / 0.171 / 0.200 | 0.00 / 0.00 | 64% | 73% | no face 56%, size 43% | 1.41 / 1.05 / 1.60 / 0.94 |
| 16 | loss test: uncover | 45.1–49.1 | 99 | 0.175 / 0.187 / 0.197 | 0.00 / 0.85 | 25% | 25% | size 75%, no face 25% | 2.65 / 0.00 / 0.00 / 1.35 |

Per-frame series: 1252 frames (seconds from run start, phase, raw Vision yaw / pitch / roll in degrees, face-box height, quality, tracker state, watchdog flag) are stored column by column in the JSON file under `frameSeries`; they are not repeated here.

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
