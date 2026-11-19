# Manual test — Step 6b-3c-0: the mute-failure experiments of a process-specific tap (output gain 0)

**Status (2026-11-19): NOTHING in this manual has been run on hardware.** The process-specific tap mode, the mute option, the injected scenarios, the synthetic test file and the verdict tool are **IMPLEMENTED-UNVERIFIED**: unit-tested against fakes and a simulated source, mutation-checked (docs/STATUS.md, "Step 6b-3c-0"), and never run against a real Core Audio tap.

> ## WARNING: the test player's audio WILL go silent while the probe runs with a mute option, and it MUST come back afterwards.
> Only the TEST PLAYER is muted (the tap lists only that one process), not other apps and not the system. **Nothing is audible from our engine**: the probe's output gain is forced to 0, read back, and there is no gain option (naming one is refused). The headers say **nothing** about what happens to a muted process's audio if our process dies or the tap is destroyed: that is exactly what these experiments measure. If the player's audio does not come back, follow "If the audio does not come back" below and write down what restored it.

## The question and the pre-registered rule
With a tap on the test player only and a mute behaviour, does the player's audio come back, and how fast, when the tap goes away in each of five ways? **The criteria are "pre-registered GUESS, fixed before the run"** (version `6b-3c0-prereg-1`; code: `MuteExperimentCriteria` in `Sources/SpatialAudioCore/MuteExperiment.swift`, pinned by tests). If one is changed after a run, the version changes and docs/STATUS.md records what and why.

| scenario (id) | what happens | how it is done | t = 0 is |
|---|---|---|---|
| normal exit (`normal-exit`) | the probe ends by itself | the probe runs to its time | the moment the shell prompt returns (the last output line is `TEARDOWN COMPLETE`) |
| SIGINT (`sigint`) | the probe is interrupted | `kill -INT <probe pid>` | the moment you press Enter on the kill command |
| SIGKILL (`sigkill`) | the probe is killed without any cleanup | `kill -KILL <probe pid>` | the moment you press Enter on the kill command |
| tap destroyed while IO runs (`destroy-tap`) | the probe destroys its tap and keeps running | `--ring-probe-mute-scenario=destroy-tap@20` | the moment the line `SCENARIO destroy-tap performed` appears |
| IO stopped while the tap lives (`stop-io`) | the probe stops the IO and keeps the tap | `--ring-probe-mute-scenario=stop-io@20` | the moment the line `SCENARIO stop-io performed` appears |

**Rule (per mute behaviour): in every one of the five scenarios the test player's audio is audible again within 5 s of t = 0 (inclusive).** Verdict precedence: **no-go** (any scenario did not return within 5 s, or never) > **incomplete** (a scenario missing, given twice, or a number that is negative or not finite) > **inconclusive** (a scenario in which the audio never went silent, so the mute did not take effect and tested nothing) > **go**. **If any scenario is a no-go, muting is not shipped** (docs/ARCHITECTURE.md section 3). Not in this step: sleep and wake, other players, other devices, longer-lived failures. A `go` says nothing about sound, latency or anything audible from our engine.

## Before you start
1. **Rebuild the bundle at the commit whose message starts with "Step 6b-3c-0:"** (`scripts/make-app.sh debug` from the repository root; quit any running SpatialAudio first). The reports carry no commit hash: **write down `git log -1 --oneline` and when you rebuilt.**
2. **Output:** the Bluetooth headphones as the default output (the setup S2 measured), on your head. **System volume low** (the test file is quiet by design: -30 dBFS peak). Another output (the built-in speakers) must stay selectable in System Settings > Sound, in case you need it. Do not touch Sound settings during a run.
3. **Do not close the lid and do not let the Mac sleep** (plug in). **Note the wall-clock time you start each run, to the second.**
4. A rebuilt, ad-hoc signed bundle **may** ask for the system-audio recording permission again: write down the **exact text** and which button you pressed.

## Make the test file (one `afplay` process must play it for 15 minutes or more)
```
build/SpatialAudio.app/Contents/MacOS/SpatialAudio --make-channel-check-file=/tmp/sa-channel-check.wav --seconds=900
```
It writes a **generated** WAV (not recorded, no copyrighted audio): 44,100 Hz, 16-bit stereo, 900 s, about 159 MB, peak -30 dBFS: a 30 s cycle of 10 s with bursts in the LEFT channel only, 10 s RIGHT only, 10 s BOTH (0.5 s noise, 0.5 s silence). It refuses to overwrite an existing file and refuses fewer than 900 s. Delete it afterwards (`rm /tmp/sa-channel-check.wav`); `*.wav` is ignored by git.

## Start the player and find its PID
Terminal tab A:
```
afplay /tmp/sa-channel-check.wav
```
Terminal tab B (**exactly one line must come back; if more, quit the extra players first**):
```
pgrep -x afplay
```
That number is `<PID>` below. Check it: `ps -p <PID> -o pid,comm` shows `afplay`. **If the player stops (15 minutes) or you restart it, the PID changes: find it again.** You should hear the bursts, quietly.

## 1. Control: an UNMUTED process tap for 10 s
```
open -n -W --stdout /tmp/sa-pt-ctl.out --stderr /tmp/sa-pt-ctl.err build/SpatialAudio.app --args --ring-probe 10 --ring-probe-process-pid=<PID>
```
Expected: the player keeps playing the whole time (nothing is muted); the report says `Tap mode: process-specific (a tap on ONE process, PID <PID> ...; mute behaviour: unmuted`. A refusal `target PID is not a process the audio system knows (is the player running and playing?)` means the PID is wrong or the player is not playing. A `failed at tap rate` outcome is an informative result (the tap did not arrive at the output's rate): paste it back.

## 2. Does the mute take effect, and ONLY for the player? (10 s)
```
open -n -W --stdout /tmp/sa-pt-mute.out --stderr /tmp/sa-pt-mute.err build/SpatialAudio.app --args --ring-probe 10 --ring-probe-process-pid=<PID> --ring-probe-tap-mute=muted
```
While it runs (the report starts with `THE TARGET PROCESS'S AUDIO WAS MUTED BY THIS RUN`), in tab B play a **different** process: `afplay /System/Library/Sounds/Ping.aiff`. Expected: the channel-check audio goes **silent**, `Ping` stays **audible**, and the channel-check audio comes back after the probe ends. **Write down exactly what you heard.** Findings that stop the experiments: (a) the channel-check audio does NOT go silent (the mute did not take effect: the scenarios will be `unmuted`); (b) `Ping` is silent too (the mute reaches beyond the target: stop, paste back); (c) `Ping` is audible but the channel-check is silent AND stays silent after the probe ended: go to "If the audio does not come back".

## 3. The five scenarios (repeat the whole set with `--ring-probe-tap-mute=mutedwhentapped` only if `muted` is a go)
In every run: tab C shows the probe's events as they happen: `tail -f /tmp/sa-pt.out` (the probe prints `SAMPLING STARTED ...` and `SCENARIO ...` lines and flushes them). **Wait until the player's audio is audible again and the PID is still valid before each scenario.**

**normal-exit** (30 s):
```
open -n -W --stdout /tmp/sa-pt.out --stderr /tmp/sa-pt.err build/SpatialAudio.app --args --ring-probe 30 --ring-probe-process-pid=<PID> --ring-probe-tap-mute=muted
```
Seconds from the moment the prompt returns until the audio is audible again.

**sigint** (long run; you interrupt it): start
```
open -n -W --stdout /tmp/sa-pt.out --stderr /tmp/sa-pt.err build/SpatialAudio.app --args --ring-probe 120 --ring-probe-process-pid=<PID> --ring-probe-tap-mute=muted
```
wait for `SAMPLING STARTED` and a few seconds of silence, then in tab B: `kill -INT $(pgrep -n -f 'SpatialAudio.app/Contents/MacOS/SpatialAudio')` (the newest matching process is the probe; check with `pgrep -n -f ... ; ps -p <that> -o pid,comm` first if unsure).

**sigkill**: the same start, then `kill -KILL $(pgrep -n -f 'SpatialAudio.app/Contents/MacOS/SpatialAudio')`.

**destroy-tap** (60 s run, the tap is destroyed at 20 s while the probe keeps running):
```
open -n -W --stdout /tmp/sa-pt.out --stderr /tmp/sa-pt.err build/SpatialAudio.app --args --ring-probe 60 --ring-probe-process-pid=<PID> --ring-probe-tap-mute=muted --ring-probe-mute-scenario=destroy-tap@20
```
**stop-io** (the same with `--ring-probe-mute-scenario=stop-io@20`). In both, t = 0 is the line `SCENARIO ... performed at ... s` in tab C; the probe is still alive for about 40 s afterwards, so a return here happens while our process lives.

If a probe is still running when the audio is back, let it end by itself (or interrupt it) before the next scenario.

## What you write down, per run
- the **start time** (to the second), the **exact command**, and which scenario;
- whether the player's audio **went silent** when `SAMPLING STARTED` appeared (**yes / no**; "no" makes the scenario `unmuted`);
- the **seconds until the audio was audible again** after t = 0 (stopwatch, to about 0.5 s), or **none** (not back within 60 s);
- anything odd: a pop or click when it returned, the other app silent, a prompt (exact text), anything you touched;
- the commit and when you rebuilt.

Then apply the pre-registered rule to your numbers (a number = seconds, `none` = did not come back, `unmuted` = never went silent):
```
build/SpatialAudio.app/Contents/MacOS/SpatialAudio --mute-experiment-verdict normal-exit=<s|none|unmuted>,sigint=...,sigkill=...,destroy-tap=...,stop-io=...
```
It prints `GO`, `NO-GO`, `INCOMPLETE` or `INCONCLUSIVE` with the criteria version and the registration label.

## What to paste back
The **report file names** (`docs/test-results/ringprocesstap-YYYYMMDD-HHMMSS.md` and `.json`; no `-SIMULATED` in the name) **and your notes and the verdict line**. I read the numbers from disk. **Numbers only in the reports** (the target is a PID number, not a name; no device name, no UID, no path); real reports are committed on their own, by explicit path, after a privacy grep. Do not paste anything you did not write after the run: a blank template or my own instructions pasted back is not a result.

## If the audio does not come back
The headers do not say what restores it, so **write down each step and whether it helped**. In this order: (1) make sure the probe is gone (`pgrep -f SpatialAudio.app/Contents/MacOS`; `kill -KILL` it); (2) quit the player and start a new one (a new PID): does it play? (3) switch the default output to the built-in speakers and back; (4) if there is still no sound from that player after a minute, quit it and play something else (does other audio play?); (5) the last resort is logging out and in, then a restart. **Do not improvise beyond this list.** A scenario in which the audio did not come back is a **no-go for muting**, not a failure of yours.

## Not in this manual
Sleep and wake; any audible output from our engine (the 6b-1 gate: output gain stays 0); the offline calibration (no hardware, already recorded in docs/STATUS.md); the first audible run (3c-1, a separate explicit go).
