# SpatialAudio self-test report

- **Date:** 2026-11-08T22:36:38+05:30
- **Lighting:** normal light
- **Input:** camera (MacBook Air Camera), capture preset 640x480 (AVCaptureSession.Preset.vga640x480), Vision request revision 3
- **Machine:** Mac16,12, macOS Version 27.2 (Build 26B123)
- **Frames mirrored (observed):** 0%; **rotation angle(s):** 0°
- **Invert flags in effect during the test:** yaw=off pitch=off roll=off

## 1. Sign detection
Target convention: turn LEFT = +yaw, look UP = +pitch, tilt RIGHT ear down = +roll. Raw Vision angles, degrees.

| Axis | Result | Raw Vision sign during move | Invert needed* | Repetition Δ (leakage ratio) | Reasons / notes |
|---|---|---|---|---|---|
| yaw | DETERMINED | + | no | rep1: +33.8° (0.47); rep2: +57.3° (0.21) | — |
| pitch | INCONCLUSIVE | — | — | rep1: +7.7° (3.31) ✗; rep2: +18.5° (2.08) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: movement too small: 7.7° < required 10.0° (floor 10°, 5× noise 1.8°) / repetition 2: wrong axis dominates: roll changed 38.4° vs 18.5° on pitch (limit 0.6×) |
| roll | INCONCLUSIVE | — | — | rep1: +2.9° (12.88) ✗; rep2: +4.8° (7.92) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: movement too small: 2.9° < required 10.0° (floor 10°, 5× noise 0.9°) / repetition 2: movement too small: 4.8° < required 10.0° (floor 10°, 5× noise 1.2°) |

\* relative to the documented default mapping (all invert flags off, including its mirror compensation). LIKELY results are hints only and are never applied automatically.

### Baseline statistics of the instructed axis (raw Vision degrees)
σ is 1.4826 × the median absolute deviation (robust; this is the "noise" the 5× rule uses). Range (max − min) is shown only to contrast it. Drift is how far the medians of overlapping 10-sample sub-windows wander.

| Axis | Rep | Window | n | median | σ (MAD) | range | p10–p90 | drift | required move |
|---|---|---|---|---|---|---|---|---|---|
| yaw | 1 | reference | 44 | -1.3 | 0.33 | 2.8 | 1.1 | 0.9 | 15.0° |
| yaw | 1 | hold | 60 | +32.5 | 3.65 | 47.3 | 43.2 | 40.4 | — |
| yaw | 2 | reference | 30 | +2.1 | 0.65 | 6.2 | 3.4 | 1.1 | 15.0° |
| yaw | 2 | hold | 60 | +59.4 | 8.08 | 43.1 | 21.5 | 15.6 | — |
| pitch | 1 | reference | 30 | -6.5 | 1.79 | 5.3 | 3.7 | 2.6 | 10.0° |
| pitch | 1 | hold | 60 | +1.3 | 0.98 | 27.8 | 3.2 | 2.5 | — |
| pitch | 2 | reference | 30 | -10.2 | 0.65 | 11.7 | 10.4 | 3.2 | 10.0° |
| pitch | 2 | hold | 60 | +8.3 | 1.11 | 36.3 | 25.4 | 25.9 | — |
| roll | 1 | reference | 30 | +5.9 | 0.91 | 4.4 | 2.3 | 1.8 | 10.0° |
| roll | 1 | hold | 60 | +8.8 | 1.04 | 10.7 | 4.7 | 4.6 | — |
| roll | 2 | reference | 30 | +4.0 | 1.17 | 4.7 | 3.0 | 2.5 | 10.0° |
| roll | 2 | hold | 60 | +8.8 | 0.91 | 5.6 | 3.3 | 3.0 | — |

**Applied by the user:** invert yaw=off pitch=off roll=off

## 2. Loss test (turn ~25° left, cover camera, uncover)
- **Verdict:** INVALID
- **INVALID because:** tracking was not LOCKED for 1.0 s in a row within 10 s after the turn phase, so the cover cue was never given and the loss test was skipped
- **Observed state sequence:** decaying → static → locked → holding → decaying → locked → holding → decaying → static (expected locked → holding → decaying → static → locked)
- **Time in state:** locked-before-loss 0.00 s, holding 0.99 s (configured 0.50), decaying 3.96 s (configured 1.50), static 3.30 s
- **Holding → static:** -2.17 s; **reacquire after uncover cue:** -3.56 s (includes your reaction time)
- **Largest frame-to-frame pose step:** 4.19° (threshold 10.0°) → ok (in state locked, 4.27 s after the cover cue)
- **Held pose distance from neutral:** 33.1°
- note: INVALID: tracking was not LOCKED for 1.0 s in a row within 10 s after the turn phase, so the cover cue was never given and the loss test was skipped
- note: decaying lasted 1.03 s, configured 1.50 s
- note: the face reappeared before the uncover cue

### Evidence around the largest pose step (4.19° output step, state locked, 4.27 s after the cover cue)
- **Shape: outputOnly**. The raw Vision angles moved only 0.5° across the step while the output pose moved 4.2°: the filter, calibration or a state blend produced it, not the camera.
- raw Vision step 0.5° (15°/s)
- shape thresholds are untuned: "back" = within 30% of the step, 5 frames; multi-frame = step < 50% of the 10-frame displacement
- the full ±15-frame window (raw, mapped, output, state, quality, limiting component, face box) is in the JSON file; ±8 frames are shown here:

| t (ms) | raw yaw/pitch/roll | mapped yaw/pitch/roll | output yaw/pitch/roll | state | quality | limiting | box h |
|---|---|---|---|---|---|---|---|
| -267 | +20.1 / -6.3 / -4.0 | +20.1 / +6.3 / -4.0 | +1.6 / +0.4 / +0.0 | decaying | 0.63 | size | 0.16 |
| -235 | +21.2 / -6.4 / -4.0 | +21.2 / +6.4 / -4.0 | +1.1 / +0.3 / +0.0 | decaying | 0.62 | size | 0.16 |
| -206 | +21.4 / -7.2 / -3.9 | +21.4 / +7.2 / -3.9 | +0.7 / +0.2 / +0.0 | decaying | 0.62 | size | 0.16 |
| -167 | +21.7 / -6.9 / -3.6 | +21.7 / +6.9 / -3.6 | +0.4 / +0.1 / +0.0 | decaying | 0.62 | size | 0.16 |
| -136 | +21.4 / -6.8 / -3.3 | +21.4 / +6.8 / -3.3 | +0.4 / +0.1 / +0.0 | locked | 0.62 | size | 0.16 |
| -104 | +21.0 / -6.3 / -3.2 | +21.0 / +6.3 / -3.2 | +1.4 / +0.4 / -0.1 | locked | 0.62 | size | 0.16 |
| -68 | +20.7 / -6.2 / -2.4 | +20.7 / +6.2 / -2.4 | +4.0 / +1.3 / -0.4 | locked | 0.62 | size | 0.16 |
| -36 | +20.5 / -6.7 / -2.2 | +20.5 / +6.7 / -2.2 | +7.6 / +2.5 / -0.8 | locked | 0.60 | size | 0.16 |
| +0 | +20.0 / -6.8 / -2.5 | +20.0 / +6.8 / -2.5 | +11.6 / +3.8 / -1.3 | locked | 0.64 | size | 0.16 |
| +34 | +20.0 / -6.5 / -2.4 | +20.0 / +6.5 / -2.4 | +15.4 / +5.0 / -1.8 | locked | 0.63 | size | 0.16 |
| +65 | +20.5 / -6.4 / -2.8 | +20.5 / +6.4 / -2.8 | +18.5 / +6.0 / -2.4 | locked | 0.62 | size | 0.16 |
| +100 | +20.5 / -5.9 / -3.1 | +20.5 / +5.9 / -3.1 | +20.4 / +6.4 / -2.8 | locked | 0.64 | size | 0.16 |
| +129 | +21.0 / -6.5 / -3.0 | +21.0 / +6.5 / -3.0 | +20.7 / +6.5 / -2.9 | locked | 0.64 | size | 0.16 |
| +165 | +21.2 / -7.4 / -3.5 | +21.2 / +7.4 / -3.5 | +20.8 / +6.6 / -3.0 | locked | 0.63 | size | 0.16 |
| +199 | +21.6 / -8.1 / -3.5 | +21.6 / +8.1 / -3.5 | +21.0 / +6.9 / -3.1 | locked | 0.64 | size | 0.16 |
| +232 | +21.1 / -8.2 / -3.4 | +21.1 / +8.2 / -3.4 | +21.0 / +7.2 / -3.2 | locked | 0.65 | size | 0.16 |
| +268 | +20.7 / -6.8 / -3.3 | +20.7 / +6.8 / -3.3 | +20.9 / +7.1 / -3.2 | locked | 0.66 | size | 0.17 |

## 3. Statistics (30 s window, normal light)
- **Frames:** 900; **face found in:** 100%; **mean quality:** 0.41
- **Mean frame rate:** 30.0 fps

| Metric (ms) | mean | p95 | max |
|---|---|---|---|
| Frame interval | 33 | 33 | 33 |
| Delivery (sample timestamp → callback) | 63 | 65 | 67 |
| Vision | 20 | 24 | 28 |
| Total (sample timestamp → pose ready) | 83 | 86 | 89 |

## 4. Tracking quality: which component limited it
Per group of phases: share of frames in which each component was the weakest ("none" = all components 1). "Low" = quality below the recovery threshold. Gate: lose below 0.40 for 0.10 s, recover at or above 0.60 for 0.20 s.

| Group | frames | mean | min | < loss | < recover | limiting component (share of frames) | limiting when low |
|---|---|---|---|---|---|---|---|
| statistics window (hold + rest) | 900 | 0.41 | 0.00 | 50% | 65% | size 97%, center jump 3% | size 95%, center jump 5% |
| baseline | 60 | 0.50 | 0.39 | 2% | 93% | size 100% | size 100% |
| hold: turn LEFT | 180 | 0.35 | 0.00 | 67% | 70% | size 94%, center jump 6% | size 91%, center jump 9% |
| hold: look UP | 180 | 0.30 | 0.00 | 67% | 71% | size 97%, center jump 3% | size 95%, center jump 5% |
| hold: tilt RIGHT EAR | 180 | 0.45 | 0.28 | 49% | 76% | size 100% | size 100% |
| rest | 360 | 0.49 | 0.00 | 33% | 54% | size 97%, center jump 3% | size 94%, center jump 6% |
| loss test: turn (incl. waiting for lock) | 390 | 0.41 | 0.00 | 49% | 80% | size 83%, edge 15%, center jump 2% | size 79%, edge 19%, center jump 3% |
| whole run | 1439 | 0.43 | 0.00 | 45% | 69% | size 93%, edge 4%, center jump 3% | size 90%, edge 6%, center jump 4% |

### Per phase, whole phase, in run order
Every phase on its own (the groups above pool the repetitions). Box h = face-box height as a fraction of the frame height (with the default quality settings the size score is 0 at 0.10 and 1 at 0.20; the settings in effect are not recorded). "< loss" / "< recover" = share of frames with quality strictly below the gate's thresholds. State seconds add up to the phase length: a frame's state is taken to hold until the next frame arrives.

| # | phase | t (s) | frames | box h min / med / max | quality min / med | < loss | < recover | limiting (top 2) | locked / holding / decaying / static (s) |
|---|---|---|---|---|---|---|---|---|---|
| 0 | get ready | 0.0–3.0 | 89 | 0.142 / 0.161 / 0.173 | 0.42 / 0.61 | 0% | 39% | size 100% | 3.00 / 0.00 / 0.00 / 0.00 |
| 1 | baseline | 3.0–5.0 | 60 | 0.139 / 0.149 / 0.163 | 0.39 / 0.49 | 2% | 93% | size 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 2 | hold: turn LEFT #1 | 5.0–8.0 | 90 | 0.108 / 0.118 / 0.177 | 0.00 / 0.18 | 69% | 71% | size 92%, center jump 8% | 1.04 / 0.50 / 1.46 / 0.00 |
| 3 | rest | 8.0–10.0 | 60 | 0.118 / 0.167 / 0.174 | 0.00 / 0.67 | 32% | 35% | size 98%, center jump 2% | 1.10 / 0.00 / 0.04 / 0.86 |
| 4 | hold: turn LEFT #2 | 10.0–13.0 | 90 | 0.112 / 0.127 / 0.174 | 0.00 / 0.27 | 64% | 69% | size 96%, center jump 4% | 1.17 / 0.50 / 1.33 / 0.00 |
| 5 | rest | 13.0–15.0 | 60 | 0.118 / 0.167 / 0.172 | 0.18 / 0.67 | 30% | 38% | size 100% | 1.03 / 0.00 / 0.17 / 0.80 |
| 6 | hold: look UP #1 | 15.0–18.0 | 90 | 0.110 / 0.117 / 0.173 | 0.00 / 0.17 | 64% | 69% | size 97%, center jump 3% | 1.17 / 0.51 / 1.33 / 0.00 |
| 7 | rest | 18.0–20.0 | 60 | 0.114 / 0.145 / 0.166 | 0.00 / 0.45 | 45% | 77% | size 88%, center jump 12% | 0.10 / 0.00 / 0.17 / 1.73 |
| 8 | hold: look UP #2 | 20.0–23.0 | 90 | 0.097 / 0.115 / 0.166 | 0.00 / 0.15 | 69% | 73% | size 97%, center jump 3% | 1.04 / 0.50 / 1.46 / 0.00 |
| 9 | rest | 23.0–25.0 | 60 | 0.094 / 0.147 / 0.164 | 0.00 / 0.47 | 47% | 70% | size 93%, center jump 7% | 0.60 / 0.00 / 0.04 / 1.37 |
| 10 | hold: tilt RIGHT EAR #1 | 25.0–28.0 | 90 | 0.130 / 0.140 / 0.165 | 0.30 / 0.40 | 51% | 73% | size 100% | 1.31 / 0.50 / 1.19 / 0.00 |
| 11 | rest | 28.0–30.0 | 60 | 0.133 / 0.163 / 0.172 | 0.33 / 0.63 | 20% | 47% | size 100% | 0.86 / 0.00 / 0.30 / 0.83 |
| 12 | hold: tilt RIGHT EAR #2 | 30.0–33.0 | 90 | 0.128 / 0.140 / 0.171 | 0.28 / 0.40 | 48% | 79% | size 100% | 0.97 / 0.50 / 1.50 / 0.02 |
| 13 | rest | 33.0–35.0 | 60 | 0.134 / 0.154 / 0.173 | 0.34 / 0.54 | 23% | 57% | size 100% | 0.63 / 0.00 / 0.00 / 1.37 |
| 14 | loss test: turn | 35.0–38.0 | 390 | 0.119 / 0.141 / 0.173 | 0.00 / 0.41 | 49% | 80% | size 83%, edge 15% | 1.04 / 0.50 / 1.46 / 0.00 |

Per-frame series: 1439 frames (seconds from run start, phase, raw Vision yaw / pitch / roll in degrees, face-box height, quality, tracker state, watchdog flag) are stored column by column in the JSON file under `frameSeries`; they are not repeated here.

## 5. Camera release
- **Programmatic:** CLEAN — isRunning after stop=false, inputs=0, outputs=0, callbacks after stop=0, (informational: stop notifications seen=1, session object deallocated=true; both depend on the run loop and timing) — checked 1.3 s after stop
- **Green light (visual, user-reported):** yes — the light went OFF

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
