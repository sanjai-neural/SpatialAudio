# Manual test — Step 6b-3b (a2): a tap bound to the output device's stream (stages S0 to S3, at output gain 0)

**Status (2026-11-19): NOTHING in this manual has been run on hardware.** The device-bound tap mode, the rate-equality guard, the pre-registered verdict and the per-epoch slopes are **IMPLEMENTED-UNVERIFIED**: unit-tested against fakes and a simulated source, mutation-checked (docs/STATUS.md, "Step 6b-3b"), and never run against a real Core Audio device-bound tap. **Nothing here claims that the device-bound tap arrives at 44.1 kHz, or at any rate.** That is what these runs measure.

It is the same probe as `--ring-probe` (Step 6b-2): the real system-audio tap into the ring, a real-time engine whose two source nodes pull the ring, **output volume forced to 0, read back, refused otherwise; there is no option that raises it** (naming a gain or volume option is refused). Nothing is audible from the probe. The tap is **unmuted**: the original audio plays as usual. The only new thing is `--ring-probe-device-tap`: the tap is created with `CATapDescription initExcludingProcesses:andDeviceUID:withStream:` for the **default output device's stream 0** (our own process excluded) instead of the global stereo mixdown. The header says: "The format of the tap will match the format of this stream." Whether it does, at what rate, and whether the ring then stops draining, is the question.

## The question and the pre-registered answer
**Question:** does a tap bound to the output device's stream arrive at the **output device's rate** (G0), so that the engine asks exactly one device buffer per call (G1), the ring does not drain (G2) and the run is stable (G3)? The three real Bluetooth runs of 2026-11-18 (global tap at 48 kHz, output at 44.1 kHz) asked a constant 558 frames per call and drained about 55 to 64 frames/s (docs/STATUS.md, "Step 6b-3a-2 real runs").

**The criteria below are "pre-registered GUESS, fixed before the run"** (approved by Sanjai on 2026-11-19 as written in the plan; criteria version `6b-3b-prereg-1`). They are code (`RateFixCriteria` and `RateFixEvaluator` in `Sources/SpatialAudioCore/RateFixVerdict.swift`), pinned by tests, and the report prints the verdict they produce. **If one is ever changed after a run: the version string changes, docs/STATUS.md records what changed and why, and verdicts are only compared within one version.** None has been changed. The reasons are GUESSES, not measurements.

| id | criterion (pre-registered GUESS, fixed before the run) | why this number (GUESS) |
|---|---|---|
| **G0** | The tap is Float32, interleaved, stereo, and its rate equals the output device's nominal rate (within 0.5 Hz). | The ring accepts only that format; at unequal rates the engine converts and over-asks (the +1,294 ppm of the 558-frame calls). |
| **G1** | In **every one-second interval**, for **both readers**, the mean frames per call is `device buffer x (tap rate / output rate)` (512.00 at equal rates and a 512-frame buffer): min **and** max within **0.005** frame. | One call that differs by one frame moves an interval mean (at most about 100 calls) by more than 0.01, so any single deviating call fails; the speakers' 48 to 48 kHz runs were 512.00 in every interval [measured]. |
| **G2** | The worst **absolute** fill slope of the two readers, ppm of the tap rate: **go** at or below **100**; **gray** above 100 up to and including **300** (a clock-level term that needs a servo); **no-go** above **300**. Not evaluated if re-primes happened (the fill jumps at each one) and not judged in S3. | 100 ppm is about 4.4 frames/s at 44.1 kHz and resolvable (+/- 19 ppm over 600 s, one 512-frame call); 300 ppm is 3x that and 4x below the measured +1,294 ppm failure signature. The speaker run read -12.7 ppm [measured]. |
| **G3a** | **No re-prime** after the start sequence (S2). Any re-prime is a **no-go**. | A re-prime means the ring starved or diverged. |
| **G3b** | No overrun block, and no overrun / divergence / refused jump. | The recovery rules fire only on trouble. |
| **G3c** | No underrun block after the first sample, in either reader. | "0 steady-state underruns". |
| **G3d** | No phase mismatch, in either reader. | Measured baseline: 0. |
| **G3e** | The valid-timestamp share is **100 %** for both readers. | Measured baseline: 100 % on every real run. |
| G4 | **Recorded, not gated:** the fill at the first pull and the engine-start-to-first-pull time. | After a rate fix the fill no longer drains, so a large start-up fill (13,266 and about 26,600 frames were seen) becomes standing latency. A separate design item. |

**How a stage turns the criteria into a verdict** (also pre-registered; the stage is recognised from the mode and the requested seconds, exactly, with no extra switch: anything else is `unclassified` and gets no verdict):

| stage | run | verdict kinds |
|---|---|---|
| **S0** | plain, **5 s** | `proceedToS1` if G0 passes; `noGo` (for arm A) if it does not; `incomplete` if the run did not finish. |
| **S1** | plain, **180 s** | `noGo` on G0, G1, a slope above 300 ppm, or any underrun after the first sample; `incomplete` if G1 or G2 could not be evaluated; else `continueToS2`. **Never a go**: 180 s cannot resolve 100 ppm. |
| **S2** | recovery mode, **600 s** | `noGo` on G0, G1, a slope above 300 ppm, or any re-prime; else `gray` if the slope is above 100 ppm; else `go` if every one of G0 to G3 passed; else `inconclusive` (not a go, no no-go signal). |
| **S3** | plain, **120 s**, built-in speakers | `controlOK` if G0, G1 and G3b to G3e pass (the slope is not judged: 120 s cannot resolve 100 ppm); else `controlFailed`. |

Anything that is not `outcome ok` and `stopped by timeout` in S1 to S3 is `incomplete` (no verdict). A run on a **48 kHz output** says in the report that it **cannot tell the device-bound tap from the global one** (every global tap so far was 48,000 Hz): that is a control, not a test.

## Run this on the right commit
The commit whose message starts with **"Step 6b-3b (a2):"** (or a later one). Before you start: `git log -1 --oneline` shows it, `git status --short` shows nothing except `.vscode/` and untracked `docs/test-results/` reports, and the bundle is rebuilt at that commit:

```
scripts/make-app.sh debug        # from the repository root (the same as in the 3a manual, without the account path)
```

(Quit any running SpatialAudio first, Cmd+Q. A report from any other build says nothing about this commit; the reports carry no commit hash, so **write down `git log -1 --oneline` and the time you rebuilt**.)

## Before every run
- **Non-protected audio** you can start and stop (a local file you own, or from Terminal `for i in $(seq 1 400); do afplay /System/Library/Sounds/Submarine.aiff; done`). **No DRM-protected audio.**
- **Do not change any Sound setting during a run** (output device, input device, sample rate in Audio MIDI Setup, Bluetooth connect / disconnect). A device-bound tap is tied to the device that was the default when it was created: if the output changes mid-run the engine posts a configuration change, the probe stops with `interrupted` and does not restart (the tap is not recreated: docs/ARCHITECTURE.md, "6b-3b (a2) ... open requirements"). If you touch something, write down the time.
- **Do not close the lid and do not let the Mac sleep** (plug in if the battery is low; `caffeinate -i` does not stop a lid sleep).
- A rebuilt, ad-hoc signed bundle **may** ask for the system-audio recording permission again. If a prompt appears, write down its **exact text**, the button labels and which one you pressed.
- There is no window and no Dock icon; `open -W` waits until the app exits, a moment after the requested seconds.
- **Note the wall-clock time you press Enter** (to the second).

## The order, and the gate between stages
S0 on Bluetooth first. **Only if its verdict is `proceedToS1`, run S1; only if S1 is `continueToS2`, run S2.** S0 on the speakers and S3 are controls and can be done any time after S0 on Bluetooth. If S0 on Bluetooth is `noGo`, **stop and paste back**: arm B ((e), the mixer at the tap's rate) is built only on Sanjai's go after S0 shows that the tap does not arrive at the output rate.

## S0 — the tap's format and rate (5 s), Bluetooth, then the speakers
1. Bluetooth headphones connected and selected (System Settings > Sound > Output), music playing.
2. ```
   open -n -W --stdout /tmp/ringdevtap-s0-bt.out --stderr /tmp/ringdevtap-s0-bt.err build/SpatialAudio.app --args --ring-probe-device-tap --ring-probe 5
   ```
3. Then select **MacBook Air Speakers** and run the same with `s0-spk` in the two file names (a control: 48 kHz output).
4. **An exit status of 1 with `failed at tap rate: ...` is a valid, informative result** (the guard stopped the run before the ring was created, with the tap's format recorded). So is `failed at create tap` (the device-bound tap could not be created; the status is in the call table). Paste it back; do not retry in a loop.

## S1 — the fast fail (180 s), Bluetooth
```
open -n -W --stdout /tmp/ringdevtap-s1-bt.out --stderr /tmp/ringdevtap-s1-bt.err build/SpatialAudio.app --args --ring-probe-device-tap --ring-probe 180
```
Plain mode: nothing ends a starvation (no re-prime), so a drain shows as underruns and a steep fill slope within a few minutes.

## S2 — the decision (600 s), Bluetooth
```
caffeinate -i open -n -W --stdout /tmp/ringdevtap-s2-bt.out --stderr /tmp/ringdevtap-s2-bt.err build/SpatialAudio.app --args --ring-probe-device-tap --ring-probe-recovery 600
```
Recovery mode (the control-thread re-prime of Step 6b-3a-2, untuned thresholds) is the safety net and also what makes a re-prime visible. **Every other note in docs/MANUAL_TEST_STEP6B3A.md about recovery runs applies** (the engine is stopped and restarted for each re-prime: a stop and start on a Bluetooth output could be audible in the original audio, which is what you listen for).

## S3 — the speaker control (120 s)
Speakers selected, music playing:
```
open -n -W --stdout /tmp/ringdevtap-s3-spk.out --stderr /tmp/ringdevtap-s3-spk.err build/SpatialAudio.app --args --ring-probe-device-tap --ring-probe 120
```

## What you write down for each run
- the **start time** (to the second) and which output was selected;
- **anything audible in the ORIGINAL audio** (the probe itself is silent): a glitch, a dropout, a pop, a change of character or volume, **including at the very start** (does creating a device-bound tap change what you hear?), and roughly when; if nothing, write "nothing noticed";
- **any permission prompt**: its exact text, the button labels, which one you pressed;
- **anything you touched** (Sound settings, volume keys, another app's audio, the lid, a cable, a Bluetooth reconnect);
- the commit (`git log -1 --oneline`) and when you rebuilt the bundle.

## What to paste back
The **report file names** (they land in `docs/test-results/ringdevicetap-YYYYMMDD-HHMMSS.md` and `.json`; no `-SIMULATED` in the name; the file stem is `ringdevicetap-` for every device-bound run, so the S0 to S3 runs are told apart by their start time) **and your notes**. I read the numbers from the files on disk; do not copy numbers by hand. `/tmp/ringdevtap-*.out` holds the same report as text, `/tmp/ringdevtap-*.err` should be empty. Do not paste anything that was not written by you after the run: a blank template, or my own instructions pasted back, is not a result.

**Numbers only in the reports: no device name, no UID, no path.** (The device's UID is read to create the tap and used in that one call; it is never stored or printed. The output device is reported as a transport type, rates, a buffer size and channel counts.) Real reports are committed on their own, by explicit path, after a privacy grep; a `-SIMULATED` report is never committed.

## What each verdict means, and what it does not
- **`proceedToS1`** (S0): the tap arrived as Float32 interleaved stereo at the output's nominal rate **in that one 5 s run**. It says nothing about the drain.
- **`noGo`** (S0): the device-bound tap does not arrive in the form the ring needs at the output rate (or could not be created). Arm A is dead for this setup; the report says which part of G0 failed.
- **`continueToS2`** (S1): no fast-fail signal. Not a go.
- **`go`** (S2): G0 to G3 passed in one 600 s run on one output. It is **not** a claim about sound, latency, CPU, sleep and wake, other Bluetooth devices, the HRTF / environment-node graph, or what the start-up fill does to latency; those stay UNVERIFIED.
- **`gray`** (S2): the drain is a small clock-level term (100 to 300 ppm): the rounding signature is gone, a servo is still needed.
- **`inconclusive`** (S2): no no-go signal, but a G3 item failed or could not be evaluated. **A start-up event counts as written** (G3b and G3d count the whole run, and the report notes when an overrun block or a phase mismatch was already in the first sample, as in the interrupted run of 2026-11-18): repeat the run once and **record both results**; do not reinterpret the first.
- **`noGo`** (S2): a re-prime, a G1 failure or a slope above 300 ppm. The per-epoch table says whether the drain inside each epoch is still near the +1,294 ppm rounding rate or smaller; the verdict does not use it.
- **`controlOK` / `controlFailed`** (S3): the 48 to 48 kHz baseline still holds with the device-bound tap (or does not).
- **`incomplete`**: the run did not finish normally (a signal, an interruption, a failure): no verdict; the notes in the report say why.

## Changes to the pre-registered criteria after a run
None so far. (Format: date, the old and new value, the report that prompted it, why, and the new version string.)

## Not in this manual
Arm B ((e), the mixer's output at the tap's rate); the start-up fill / standing-latency item; the product graph with the environment node; any listening (the 6b-1 gate: nothing audible, no output gain above 0).
