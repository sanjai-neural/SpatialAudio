# Manual test — Step 6b-2: the ring probe (real tap into the ring, a real-time engine at output gain 0)

**Status (2026-11-08):** the manual has been run in part. Five real `--ring-probe` runs were made on one Mac (macOS 27.2): **Run 1** (built-in speakers, 120 s; report `193455`, started by Claude at Sanjai's request), **Run 3** (nothing playing, built-in speakers, 60 s; report `195133`) and **three Bluetooth runs of 120 s** (`160334`, `160349`, `160609`; the first two ran at the same time). All five are committed and recorded in docs/STATUS.md ("Step 6b-2 real runs"). **Run 2 (Bluetooth, 600 s, `caffeinate -i`) was NOT run**; the Bluetooth runs were three of 120 s instead. The operator observations this manual asks for (what was playing, glitches, the permission prompt text, settings touched, whether the headphone sound changed) are recorded only for Run 3 ("I didn't play any song or audio at the time"); for the other four they are **not recorded**. Everything the runs do not show stays **UNVERIFIED** (sound, latency, CPU, drift at ppm level, sleep / wake, device changes, the permission prompt, the denied path). The probe only MEASURES. It runs the real system-audio tap into the ring (Step 6b-1) and a real-time `AVAudioEngine` whose two source nodes pull the ring, with the engine's **output volume forced to 0** (set in code, read back, the run is refused otherwise; there is no option that raises it). The question it answers: do the tap's cadence and the engine's pull cadence differ, how fast does the ring's fill move, and do the two source blocks run in lockstep (valid timestamps, equal phases). It says **nothing** about sound, latency, CPU, or the product graph.

What you should and should not expect to hear: **this app plays nothing audible** (digital silence at gain 0). The tap is **unmuted**, so whatever you are playing keeps playing exactly as before. If you hear anything from this app, or the original audio glitches, stop the run (below) and tell me.

## Run this on the right commit
The run must be on the commit whose message starts with **"Step 6b-2:"** (or a later one). Before you start: `git log -1 --oneline` shows that commit, `git status --short` shows nothing except `.vscode/` and untracked `docs/test-results/` reports, and the bundle is rebuilt at that commit:

```
cd /Users/sanjais/ClaudeHome/SpatialAudio && scripts/make-app.sh debug
```

(That script runs `swift build` and wraps the executable in `build/SpatialAudio.app`; it embeds the repository path so the reports land in `docs/test-results/`. Quit any running SpatialAudio first, Cmd+Q, or `open` may bring an old instance forward.) A report from any other build says nothing about this commit; note the commit hash with each report you send.

## Before every run
- Use **non-protected audio** you can start and stop (a local file you own, or from Terminal `for i in $(seq 1 60); do afplay /System/Library/Sounds/Submarine.aiff; done`, system sounds, about 2 s each). **Do not use** DRM-protected audio (Apple Music subscription tracks, Netflix, TV+ ...): protected content may be silent in a tap, and we do not work around that.
- **Do not change any Sound setting during a run**: not the output device, not the input device, not the sample rate in Audio MIDI Setup, no Bluetooth connect / disconnect. (The 600 s run of Step 6a had an unexplained 16 kHz output reading at 220 s, probably from exactly that; if you do touch something, write down the time by the clock on your wrist.)
- **Do not let the Mac sleep** (no lid close; plug in if the battery is low). For anything over a minute, use `caffeinate -i` as in the commands below.
- The macOS "system audio recording" permission was granted to this bundle id on 2026-11-07. A rebuilt, ad-hoc signed bundle **may** ask again. If a prompt appears, write down its **exact text**, the button labels and which one you pressed (Step 6a did not record this).
- There is no window and no Dock icon: nothing shows progress. `open -W` waits until the app exits. The app exits by itself a moment after the requested seconds.

## Run 1: built-in speakers, 120 s, music playing
1. System Settings > Sound > Output: **MacBook Air Speakers**. Start music (non-protected) at a comfortable volume.
2. ```
   open -n -W --stdout /tmp/ringprobe-1.out --stderr /tmp/ringprobe-1.err build/SpatialAudio.app --args --ring-probe 120
   ```
3. **Note:** what was playing; whether the **original audio glitched or dropped** at any time (and roughly when); any setting you touched; any permission prompt (text, button); anything in the menu bar (a purple dot is the system-audio indicator); whether the Mac's sound output switched; heat or fans; whether the app exited by itself after about 2 minutes.
4. **Where it lands:** `docs/test-results/ringprobe-YYYYMMDD-HHMMSS.md` and `.json` (no `-SIMULATED` in the name; that suffix means the test source, never hardware). `/tmp/ringprobe-1.out` holds the same report as text; `/tmp/ringprobe-1.err` should be empty. The report holds **numbers only: no device name, no UID, no path**.

## Run 2: Bluetooth headphones, 600 s, music playing (only after Run 1 looks sane)
1. Connect the headphones **before** the run and make them the output. Start a **non-protected** playlist that lasts longer than 10 minutes. Do not touch Sound settings or inputs for the whole run.
2. ```
   caffeinate -i open -n -W --stdout /tmp/ringprobe-2.out --stderr /tmp/ringprobe-2.err build/SpatialAudio.app --args --ring-probe 600
   ```
3. **Note:** what was playing; whether the original audio glitched, **and especially whether the headphones' sound quality changes** (a thinner, call-like sound would mean a Bluetooth profile switch; the probe never touches the input node, but that is exactly what this run checks); any setting you touched and when; any permission prompt; whether the Mac stayed awake.
4. The Bluetooth output ran at 44.1 kHz against the tap's 48 kHz in the 6a runs, so the engine has a rate conversion between the source nodes and the output here. Whether the sample times stay valid and whether the pull sizes vary is what the report measures; no result is predicted.

## Run 3: 60 s with nothing playing
1. Stop all audio (quit music and browser tabs that play sound). Use whichever output you like and write it down.
2. ```
   open -n -W --stdout /tmp/ringprobe-3.out --stderr /tmp/ringprobe-3.err build/SpatialAudio.app --args --ring-probe 60
   ```
3. Expect the capture to be silent (the tap still delivers callbacks of zeros, as in the 6a runs); the readers' counters count regardless. This run tells whether the pull cadence depends on there being audio at all.

## What to look at in each report
- **Outcome**: `ok`, or `interrupted` (the engine posted a configuration change and the run stopped: not restarted), `invalid: ...` (a reader was never called: **if `calls` stay 0 the run is INVALID, not ok**), `never primed`, `refused: ...` (the gain guard), `failed at ...`. **Flags**: output-rate change, a gap of more than 3 s between samples, a sleep, a default-output-device change.
- **Output gain line**: must read `0.000` before the start, after the start and at the end. Anything else is a bug: tell me.
- **Section 1**: prime attempts and wait; **engine start to both readers called** and the **fill at the first pull** (a fill above 16,384 frames at the first pull means the engine took longer to start than the ring's slack, and the first blocks were overruns); the engine's source and output rates; the output device's transport type, nominal and actual rate.
- **Section 2**: the producer's and each reader's frames per **measured host second**, with the endpoint resolution printed next to the producer; the per-interval mean frames per call. **This is a mean over each one-second interval, not the per-call distribution** (the ring keeps only sums): a constant mean does not prove every call asked for the same frame count.
- **Section 3**: the fill (`w - cursor`) at the start and end and its least-squares slope in frames per second and ppm of the tap rate, and the **slopes of each complete minute and their spread**. The spread, not a formula standard error, is the honest uncertainty. A 120 s run has two complete minutes, a 60 s run has one (no spread), a 600 s run ten.
- **Section 4**: the per-reader counters. **Underruns are EXPECTED once they start**: the cursor advances by the frames asked for on every call, so a reader that went ahead of the producer stays starved at equal rates (count-only spike, no recovery). The lockstep line: `max |calls L - calls R|` (1 can appear from the non-atomic snapshot), phase self-changes, phase mismatches, weak-rule violations, and the share of calls with a valid timestamp.
- **Section 6**: every call and its status; the **teardown order that ran** (sampling timer off, engine stop, source nodes detached, IO stop, IOProc destroyed, aggregate destroyed, tap destroyed, ring retained); `Clean: YES`. The ring is **NOT freed** in a real run (the headers do not say stop / destroy wait for a running callback); the process exit reclaims it.

## If something goes wrong
- To stop a run early: `pkill -INT -x SpatialAudio` (the probe tears everything down on SIGINT / SIGTERM and writes a report with `stopped by: signal`). Ctrl-C in Terminal does not reach an `open`ed app.
- If you hear anything from this app, if the original audio stutters, or if the Mac's audio output switches by itself: stop the run, write down what you heard and when, and send the report anyway.

## After a run: check for leftovers
From a fresh process:
```
build/SpatialAudio.app/Contents/MacOS/SpatialAudio --list-audio-devices
```
Expected: `aggregate devices: 0`, `devices named "SpatialAudio Tap Probe": 0` (the probe's aggregate is named "SpatialAudio Tap Probe (ring)", so that count would include a leftover), `taps: 0`. **Limit:** the tap and the aggregate are private, so another process cannot see them whether or not they leaked; the report's own lists (read inside the process, before / during / after) are the stronger evidence.

## Report back
1. The pasted `.md` report of each run (the `.json` stays on disk). A report with blanks or placeholders is not a result.
2. For each run: what was playing, whether the original audio glitched (and when), any setting touched (and when), the permission prompt if one appeared, and for Run 2 whether the headphones' sound changed.
3. The `--list-audio-devices` output after a run.
4. Anything odd: a crash, a hang, heat, the output switching, a leftover device.

Real reports are committed on their own, by explicit path, only when you say so (CLAUDE.md, Git workflow rule 3). Simulated reports (`-SIMULATED`) are never committed.

## The simulated mode (for checking the plumbing, no hardware)
`--ring-probe-simulate <seconds>` runs the same flow on a made-up source (our own thread calls the real `SARingIOProc`; a manual-rendering engine with no device pulls the real source nodes). Its report says **SIMULATED SOURCE** and its numbers say nothing about this Mac. Optional faults: `--ring-sim-ppm=<n>` (the simulated producer runs n ppm fast or slow) and `--ring-sim-underrun=<at>,<stall>` (it stalls for `stall` s, `at` s after it started):
```
open -n -W --stdout /tmp/sim.out --stderr /tmp/sim.err build/SpatialAudio.app --args --ring-probe-simulate 20 --ring-sim-ppm=10000 --ring-sim-underrun=5,1 --results-dir=/tmp/simresults
```
There is no gain or volume option in any mode; naming one (`--gain=1`, `--volume=1`, ...) is refused with exit status 2.
