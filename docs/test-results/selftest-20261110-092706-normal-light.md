# SpatialAudio self-test report

- **Date:** 2026-11-10T09:27:06+05:30
- **Lighting:** normal light
- **Input:** camera (MacBook Air Camera), capture preset 640x480 (AVCaptureSession.Preset.vga640x480), Vision request revision 3
- **Machine:** Mac16,12, macOS Version 27.2 (Build 26B123)
- **Frames mirrored (observed):** 0%; **rotation angle(s):** 0°
- **Invert flags in effect during the test:** yaw=off pitch=off roll=off

## 1. Sign detection
Target convention: turn LEFT = +yaw, look UP = +pitch, tilt RIGHT ear down = +roll. Raw Vision angles, degrees.

| Axis | Result | Raw Vision sign during move | Invert needed* | Repetition Δ (leakage ratio) | Reasons / notes |
|---|---|---|---|---|---|
| yaw | INCONCLUSIVE | — | — | rep1: -0.5° (1.45) ✗; rep2: +1.6° (0.49) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: movement too small: 0.5° < required 15.0° (floor 15°, 5× noise 1.0°) / repetition 2: movement too small: 1.6° < required 15.0° (floor 15°, 5× noise 0.3°) |
| pitch | INCONCLUSIVE | — | — | rep1: +0.7° (0.75) ✗; rep2: -0.1° (6.67) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: movement too small: 0.7° < required 10.0° (floor 10°, 5× noise 1.0°) / repetition 2: movement too small: 0.1° < required 10.0° (floor 10°, 5× noise 0.7°) |
| roll | INCONCLUSIVE | — | — | rep1: -0.2° (4.00) ✗; rep2: -0.9° (2.65) ✗ | only 0 of 2 repetitions usable (need 2) / repetition 1: movement too small: 0.2° < required 10.0° (floor 10°, 5× noise 0.3°) / repetition 2: movement too small: 0.9° < required 10.0° (floor 10°, 5× noise 0.3°) |

\* relative to the documented default mapping (all invert flags off, including its mirror compensation). LIKELY results are hints only and are never applied automatically.

### Baseline statistics of the instructed axis (raw Vision degrees)
σ is 1.4826 × the median absolute deviation (robust; this is the "noise" the 5× rule uses). Range (max − min) is shown only to contrast it. Drift is how far the medians of overlapping 10-sample sub-windows wander.

| Axis | Rep | Window | n | median | σ (MAD) | range | p10–p90 | drift | required move |
|---|---|---|---|---|---|---|---|---|---|
| yaw | 1 | reference | 45 | -0.8 | 1.04 | 6.0 | 4.2 | 4.0 | 15.0° |
| yaw | 1 | hold | 60 | -1.3 | 0.59 | 1.8 | 1.3 | 1.0 | — |
| yaw | 2 | reference | 30 | -3.3 | 0.29 | 2.8 | 2.2 | 1.6 | 15.0° |
| yaw | 2 | hold | 60 | -1.7 | 0.75 | 2.3 | 1.5 | 1.6 | — |
| pitch | 1 | reference | 30 | +2.9 | 1.04 | 3.9 | 2.6 | 2.0 | 10.0° |
| pitch | 1 | hold | 60 | +3.6 | 0.85 | 3.2 | 2.6 | 2.3 | — |
| pitch | 2 | reference | 30 | +2.3 | 0.72 | 3.8 | 2.7 | 2.3 | 10.0° |
| pitch | 2 | hold | 60 | +2.2 | 1.95 | 4.9 | 3.6 | 3.2 | — |
| roll | 1 | reference | 30 | +3.9 | 0.26 | 1.2 | 1.1 | 0.6 | 10.0° |
| roll | 1 | hold | 60 | +3.7 | 0.26 | 1.1 | 0.7 | 0.6 | — |
| roll | 2 | reference | 30 | +3.7 | 0.26 | 1.6 | 0.9 | 0.5 | 10.0° |
| roll | 2 | hold | 60 | +2.8 | 0.26 | 2.3 | 0.7 | 0.4 | — |

## 2. Loss test (turn ~25° left, cover camera, uncover)
- **Verdict:** INCOMPLETE
- **Observed state sequence:** locked (expected locked → holding → decaying → static → locked)
- **Time in state:** locked-before-loss 9.98 s, holding 0.00 s (configured 0.50), decaying 0.00 s (configured 1.50), static 0.00 s
- **Holding → static:** n/a; **reacquire after uncover cue:** n/a
- **Largest frame-to-frame pose step:** 0.52° (threshold 10.0°) → ok (in state locked, 2.04 s after the cover cue)
- **Held pose distance from neutral:** n/a — jump check is WEAK
- note: jump check is weak: the held pose was only 0.0° from neutral (need ≥ 10° for a meaningful test)
- note: static was never reached (cover too short, or only partly covered?)

### Evidence around the largest pose step (0.52° output step, state locked, 2.04 s after the cover cue)
- **Shape: abruptAndSustained**. The raw Vision orientation jumped 1.5° in one frame (45.1°/s) and stayed there for the next frames: either a very fast real movement or a tracking mode switch; the data alone does not say which.
- raw Vision step 1.5° (45°/s), raw displacement over 10 frames 0.8°
- shape thresholds are untuned: "back" = within 30% of the step, 5 frames; multi-frame = step < 50% of the 10-frame displacement
- the full ±15-frame window (raw, mapped, output, state, quality, limiting component, face box) is in the JSON file; ±8 frames are shown here:

| t (ms) | raw yaw/pitch/roll | mapped yaw/pitch/roll | output yaw/pitch/roll | state | quality | limiting | box h |
|---|---|---|---|---|---|---|---|
| -260 | -2.2 / +3.0 / +2.6 | -2.2 / -3.0 / +2.6 | -2.1 / -2.0 / +2.8 | locked | 1.00 | none | 0.22 |
| -226 | -2.2 / +3.2 / +2.6 | -2.2 / -3.2 / +2.6 | -2.1 / -2.2 / +2.8 | locked | 1.00 | none | 0.22 |
| -197 | -2.6 / +2.2 / +2.8 | -2.6 / -2.2 / +2.8 | -2.2 / -2.2 / +2.8 | locked | 1.00 | none | 0.22 |
| -165 | -2.8 / +0.5 / +3.5 | -2.8 / -0.5 / +3.5 | -2.3 / -1.9 / +3.0 | locked | 1.00 | none | 0.22 |
| -131 | -3.0 / +0.4 / +3.9 | -3.0 / -0.4 / +3.9 | -2.4 / -1.5 / +3.1 | locked | 1.00 | none | 0.22 |
| -99 | -2.7 / +0.8 / +3.2 | -2.7 / -0.8 / +3.2 | -2.5 / -1.4 / +3.1 | locked | 1.00 | none | 0.22 |
| -63 | -2.9 / +0.4 / +3.2 | -2.9 / -0.4 / +3.2 | -2.6 / -1.2 / +3.1 | locked | 1.00 | none | 0.22 |
| -33 | -3.2 / -0.2 / +2.8 | -3.2 / +0.2 / +2.8 | -2.7 / -0.9 / +3.1 | locked | 1.00 | none | 0.22 |
| +0 | -2.9 / -1.6 / +3.0 | -2.9 / +1.6 / +3.0 | -2.7 / -0.4 / +3.1 | locked | 1.00 | none | 0.22 |
| +33 | -2.5 / -0.4 / +3.0 | -2.5 / +0.4 / +3.0 | -2.7 / -0.2 / +3.0 | locked | 1.00 | none | 0.22 |
| +70 | -2.5 / +0.9 / +2.6 | -2.5 / -0.9 / +2.6 | -2.7 / -0.4 / +3.0 | locked | 1.00 | none | 0.22 |
| +102 | -3.0 / +0.9 / +2.6 | -3.0 / -0.9 / +2.6 | -2.7 / -0.5 / +2.9 | locked | 1.00 | none | 0.22 |
| +132 | -2.8 / +0.3 / +2.8 | -2.8 / -0.3 / +2.8 | -2.7 / -0.4 / +2.9 | locked | 1.00 | none | 0.22 |
| +163 | -2.5 / -0.0 / +3.0 | -2.5 / +0.0 / +3.0 | -2.7 / -0.3 / +2.9 | locked | 1.00 | none | 0.22 |
| +197 | -2.3 / +0.2 / +3.2 | -2.3 / -0.2 / +3.2 | -2.6 / -0.3 / +3.0 | locked | 1.00 | none | 0.22 |
| +231 | -2.4 / +0.0 / +3.0 | -2.4 / -0.0 / +3.0 | -2.6 / -0.2 / +3.0 | locked | 1.00 | none | 0.22 |
| +266 | -2.4 / -0.2 / +2.8 | -2.4 / +0.2 / +2.8 | -2.5 / -0.2 / +2.9 | locked | 1.00 | none | 0.22 |

## 3. Statistics (30 s window, normal light)
- **Frames:** 900; **face found in:** 100%; **mean quality:** 1.00
- **Mean frame rate:** 30.0 fps

| Metric (ms) | mean | p95 | max |
|---|---|---|---|
| Frame interval | 33 | 33 | 33 |
| Delivery (sample timestamp → callback) | 62 | 64 | 66 |
| Vision | 19 | 21 | 28 |
| Total (sample timestamp → pose ready) | 81 | 83 | 84 |

## 4. Tracking quality: which component limited it
Per group of phases: share of frames in which each component was the weakest ("none" = all components 1). "Low" = quality below the recovery threshold. Gate: lose below 0.40 for 0.10 s, recover at or above 0.60 for 0.20 s.

| Group | frames | mean | min | < loss | < recover | limiting component (share of frames) | limiting when low |
|---|---|---|---|---|---|---|---|
| statistics window (hold + rest) | 900 | 1.00 | 1.00 | 0% | 0% | none 100% | — |
| baseline | 60 | 1.00 | 1.00 | 0% | 0% | none 100% | — |
| hold: turn LEFT | 180 | 1.00 | 1.00 | 0% | 0% | none 100% | — |
| hold: look UP | 180 | 1.00 | 1.00 | 0% | 0% | none 100% | — |
| hold: tilt RIGHT EAR | 180 | 1.00 | 1.00 | 0% | 0% | none 100% | — |
| rest | 360 | 1.00 | 1.00 | 0% | 0% | none 100% | — |
| loss test: turn (incl. waiting for lock) | 91 | 1.00 | 1.00 | 0% | 0% | none 100% | — |
| loss test: cover | 150 | 1.00 | 1.00 | 0% | 0% | none 100% | — |
| loss test: uncover | 120 | 1.00 | 1.00 | 0% | 0% | none 100% | — |
| whole run | 1397 | 1.00 | 0.00 | 0% | 0% | none 100%, no face 0% | no face 100% |

### Per phase, whole phase, in run order
Every phase on its own (the groups above pool the repetitions). Box h = face-box height as a fraction of the frame height (with the default quality settings the size score is 0 at 0.10 and 1 at 0.20; the settings in effect are not recorded). "< loss" / "< recover" = share of frames with quality strictly below the gate's thresholds. State seconds add up to the phase length: a frame's state is taken to hold until the next frame arrives.

| # | phase | t (s) | frames | box h min / med / max | quality min / med | < loss | < recover | limiting (top 2) | locked / holding / decaying / static (s) |
|---|---|---|---|---|---|---|---|---|---|
| 0 | get ready | 0.0–3.0 | 76 | 0.203 / 0.226 / 0.234 | 0.00 / 1.00 | 4% | 4% | none 96%, no face 4% | 2.26 / 0.00 / 0.00 / 0.74 |
| 1 | baseline | 3.0–5.0 | 60 | 0.225 / 0.231 / 0.236 | 1.00 / 1.00 | 0% | 0% | none 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 2 | hold: turn LEFT #1 | 5.0–8.0 | 90 | 0.228 / 0.231 / 0.235 | 1.00 / 1.00 | 0% | 0% | none 100% | 3.00 / 0.00 / 0.00 / 0.00 |
| 3 | rest | 8.0–10.0 | 60 | 0.225 / 0.231 / 0.235 | 1.00 / 1.00 | 0% | 0% | none 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 4 | hold: turn LEFT #2 | 10.0–13.0 | 90 | 0.225 / 0.231 / 0.234 | 1.00 / 1.00 | 0% | 0% | none 100% | 3.00 / 0.00 / 0.00 / 0.00 |
| 5 | rest | 13.0–15.0 | 60 | 0.222 / 0.227 / 0.232 | 1.00 / 1.00 | 0% | 0% | none 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 6 | hold: look UP #1 | 15.0–18.0 | 90 | 0.220 / 0.228 / 0.232 | 1.00 / 1.00 | 0% | 0% | none 100% | 3.00 / 0.00 / 0.00 / 0.00 |
| 7 | rest | 18.0–20.0 | 60 | 0.225 / 0.228 / 0.231 | 1.00 / 1.00 | 0% | 0% | none 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 8 | hold: look UP #2 | 20.0–23.0 | 90 | 0.220 / 0.227 / 0.232 | 1.00 / 1.00 | 0% | 0% | none 100% | 3.00 / 0.00 / 0.00 / 0.00 |
| 9 | rest | 23.0–25.0 | 60 | 0.224 / 0.227 / 0.232 | 1.00 / 1.00 | 0% | 0% | none 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 10 | hold: tilt RIGHT EAR #1 | 25.0–28.0 | 90 | 0.225 / 0.228 / 0.231 | 1.00 / 1.00 | 0% | 0% | none 100% | 3.00 / 0.00 / 0.00 / 0.00 |
| 11 | rest | 28.0–30.0 | 60 | 0.220 / 0.226 / 0.232 | 1.00 / 1.00 | 0% | 0% | none 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 12 | hold: tilt RIGHT EAR #2 | 30.0–33.0 | 90 | 0.219 / 0.226 / 0.230 | 1.00 / 1.00 | 0% | 0% | none 100% | 3.00 / 0.00 / 0.00 / 0.00 |
| 13 | rest | 33.0–35.0 | 60 | 0.218 / 0.224 / 0.227 | 1.00 / 1.00 | 0% | 0% | none 100% | 2.00 / 0.00 / 0.00 / 0.00 |
| 14 | loss test: turn | 35.0–38.0 | 91 | 0.219 / 0.224 / 0.229 | 1.00 / 1.00 | 0% | 0% | none 100% | 3.03 / 0.00 / 0.00 / 0.00 |
| 15 | loss test: cover | 38.0–43.0 | 150 | 0.217 / 0.224 / 0.228 | 1.00 / 1.00 | 0% | 0% | none 100% | 5.00 / 0.00 / 0.00 / 0.00 |
| 16 | loss test: uncover | 43.0–47.0 | 120 | 0.219 / 0.224 / 0.228 | 1.00 / 1.00 | 0% | 0% | none 100% | 4.00 / 0.00 / 0.00 / 0.00 |

Per-frame series: 1397 frames (seconds from run start, phase, raw Vision yaw / pitch / roll in degrees, face-box height, quality, tracker state, watchdog flag) are stored column by column in the JSON file under `frameSeries`; they are not repeated here.

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
