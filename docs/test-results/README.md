# Self-test results

The HUD's guided self-test writes two files per run here (the dev bundle from `scripts/make-app.sh debug` knows the repo path; a release build writes to `~/Library/Application Support/SpatialAudio/test-results` instead):

- `selftest-YYYYMMDD-HHMMSS-<normal-light|dim-room>.json` : full report, machine-readable.
- `selftest-YYYYMMDD-HHMMSS-<normal-light|dim-room>.md` : the same report in readable form (this is what **Copy report** puts on the clipboard).

The files are rewritten in place as the run completes (first the analysis, then the programmatic camera-release check, then your green-light answer, then "Apply" if you confirm it).

## What is in a report, and what is not
Numbers and short strings only: raw Vision yaw/pitch/roll medians and deltas per repetition, noise and leakage figures, the lose-face state sequence with timings and the largest pose step, fps / delivery / Vision / total latency (mean, p95, max), the thresholds used, the macOS version, the machine identifier (e.g. `Mac16,12`) and the camera name. **No camera frames, images or video are saved anywhere**, and the report types have no field that could hold one. There is no serial number, user name or other personal identifier, so a report is safe to commit.

## SIMULATED files are not hardware results
Runs made with the developer switch `--simulate` use a made-up person. Their file names end in `-SIMULATED`, the first lines of the report say so, and "Apply" is disabled for them. They exist only to rehearse the flow. **Delete them, and never read signs, latency or fps from them.**

## How to read a report
See "How to read the result" in `docs/MANUAL_TEST_STEP2.md`. In short: DETERMINED means both repetitions agreed and the data was strong; INCONCLUSIVE means it was weak or inconsistent and nothing was guessed; all thresholds are untuned proposals printed at the bottom of every report.
