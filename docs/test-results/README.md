# Self-test results

The HUD's guided self-test writes two files per run here (the dev bundle from `scripts/make-app.sh debug` knows the repo path; a release build writes to `~/Library/Application Support/SpatialAudio/test-results` instead):

- `selftest-YYYYMMDD-HHMMSS-<normal-light|dim-room>.json` : full report, machine-readable.
- `selftest-YYYYMMDD-HHMMSS-<normal-light|dim-room>.md` : the same report in readable form (this is what **Copy report** puts on the clipboard).

The files are rewritten in place as the run completes (first the analysis, then the programmatic camera-release check, then your green-light answer, then "Apply" if you confirm it).

## What is in a report, and what is not
Numbers and short strings only: raw Vision yaw/pitch/roll medians and deltas per repetition, noise and leakage figures, baseline statistics of the reference and hold windows (n, median, robust σ, range, p10-p90, drift), the lose-face state sequence with timings and the largest pose step, a ±15-frame window around that step (raw Vision angles, mapped angles, output pose, state, quality, limiting component, face-box centre and height), per-phase-group tracking quality with the share of frames each quality component limited, fps / delivery / Vision / total latency (mean, p95, max), the thresholds and gate settings used, the macOS version, the machine identifier (e.g. `Mac16,12`) and the camera name. Since Step 2d (schema 2) a `.json` is about 46 KB; reports written before that (schema 1, the two committed on 2026-11-05) still load. **No camera frames, images or video are saved anywhere**, and the report types have no field that could hold one. There is no serial number, user name or other personal identifier, so a report is safe to commit.

## SIMULATED files are not hardware results
Runs made with the developer switch `--simulate` use a made-up person. Their file names end in `-SIMULATED`, the first lines of the report say so, and "Apply" is disabled for them. They exist only to rehearse the flow. **Delete them, and never read signs, latency or fps from them.**

## Committing reports
- **Real** reports (non-simulated, numbers only) are committed together with the step they belong to, in that step's commit. Stage them by explicit path.
- **Simulated** reports are never committed: `.gitignore` excludes `docs/test-results/*-SIMULATED.*`, and they should be deleted.
- A result Sanjai pastes back is only a result if it is the real, filled-in report; a blank template, placeholders or text that is just an earlier reply of Claude's is not a result and changes nothing. Pushing follows the rules in CLAUDE.md ("Git workflow").

## The green-light answer
The report records the visual camera-light question as "yes — the light went OFF", "NO — the light is STILL ON", **"not answered"** (the question was shown, nobody clicked) or "not asked" (simulated input has no camera light). The two reports of 2026-11-05 say "not asked" because that was the only default then.

## How to read a report
See "How to read the result" in `docs/MANUAL_TEST_STEP2.md`. In short: DETERMINED means both repetitions agreed and the data was strong; INCONCLUSIVE means it was weak or inconsistent and nothing was guessed; all thresholds are untuned proposals printed at the bottom of every report.
