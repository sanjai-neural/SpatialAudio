# Manual test — Step 6b-3a-2: the ring probe's recovery mode (the control-thread re-prime, at output gain 0)

**Status (2026-11-18): NOTHING in this manual has been run on hardware.** The re-prime (stop the engine, wait until it is quiet, `SARingPrime`, wait for T, restart the engine) is **IMPLEMENTED-UNVERIFIED**: it is unit-tested against a model of the ring, and against the real C ring behind an offline engine on a virtual clock (SIMULATED data, no device); no real tap, no real-time engine, no Bluetooth output and no real device has ever run it. How a real `AVAudioEngine` behaves when it is stopped and started again on a real output device is **not documented in the headers this project quotes and has not been observed**. These runs are how that gets observed.

The recovery mode is the same probe as `--ring-probe` (Step 6b-2: the real system-audio tap into the ring, a real-time engine whose two source nodes pull the ring, **output volume forced to 0**, read back, refused otherwise; **there is no option that raises it**), plus a controller that, when the ring starves or the two blocks diverge, **stops the engine, re-primes both readers together and starts the engine again**, and counts what it did. **Nothing audible is played by this app at any point** (digital silence at gain 0; the tap is unmuted, so whatever you play keeps playing as before). The 6b-1 gate stays in force: no listening build, no output gain above 0.

What the runs are for: (1) does a re-prime work on a real engine (does it stop, does the ring come back with at least T frames in both readers, does the engine restart, how long was it stopped); (2) on the Bluetooth path, where the earlier runs showed a drain (a constant 558-frame request against the tap's 48 kHz, starving the count-only ring after about 56 to 115 s [measured, Step 6b-2 runs]), does the run keep recovering, and how often; (3) anything the engine does that was not predicted (a configuration-change notification, a failed restart, a hang).

**A derived expectation, not a measurement and not a promise:** if the Bluetooth drain is still about 62 frames per second [measured in the earlier runs] and a re-prime leaves T = 4 callbacks x 512 = 2,048 frames [the code's default], the ring would run dry about 33 s after each re-prime [arithmetic], so a 600 s run would show on the order of 15 or more re-primes, well inside the storm limit (6 per 60 s). If your numbers differ, the numbers win.

## Run this on the right commit
The run must be on the commit whose message starts with **"Step 6b-3a-2:"** (or a later one). Before you start: `git log -1 --oneline` shows that commit, `git status --short` shows nothing except `.vscode/` and untracked `docs/test-results/` reports, and the bundle is rebuilt at that commit:

```
cd /Users/sanjais/ClaudeHome/SpatialAudio && scripts/make-app.sh debug
```

(That script runs `swift build` and wraps the executable in `build/SpatialAudio.app`; it embeds the repository path so the reports land in `docs/test-results/`. Quit any running SpatialAudio first, Cmd+Q, or `open` may bring an old instance forward.) A report from any other build says nothing about this commit; note the commit hash with each report you send.

## Before every run
- Use **non-protected audio** you can start and stop (a local file you own, or from Terminal `for i in $(seq 1 400); do afplay /System/Library/Sounds/Submarine.aiff; done`, system sounds, about 2 s each). **Do not use** DRM-protected audio (Apple Music subscription tracks, Netflix, TV+ ...): protected content may be silent in a tap, and we do not work around that.
- **Do not change any Sound setting during a run**: not the output device, not the input device, not the sample rate in Audio MIDI Setup, no Bluetooth connect / disconnect. If you do touch something, write down the time by the clock on your wrist.
- **Do not close the lid and do not let the Mac sleep** (plug in if the battery is low). `caffeinate -i` stops idle sleep only; **it does not stop sleep when the lid is closed** (a lid sleep killed a mutation run on 2026-11-17, docs/STATUS.md). A run that sleeps is flagged (a gap of more than 3 s between samples, a sleep flag) and its numbers are not comparable.
- The macOS "system audio recording" permission was granted to this bundle id on 2026-11-07. A rebuilt, ad-hoc signed bundle **may** ask again. If a prompt appears, write down its **exact text**, the button labels and which one you pressed.
- There is no window and no Dock icon: nothing shows progress. `open -W` waits until the app exits. The app exits by itself a moment after the requested seconds.
- **Note the wall-clock time you press Enter** (to the second). The report's times are seconds from the start of the run; with your start time you can place "the music glitched at about 14:07:30" against "re-prime 3 was triggered at 214.0 s".

## Run A: Bluetooth headphones, 600 s, music playing (the main run)
1. **Connect the Bluetooth headphones before the run and make them the output** (System Settings > Sound > Output). Start a **non-protected** playlist that lasts longer than 10 minutes, at a volume you can leave alone. Do not touch Sound settings or inputs for the whole run. **Keep the lid open; plug in.**
2. ```
   caffeinate -i open -n -W --stdout /tmp/ringrecovery-bt.out --stderr /tmp/ringrecovery-bt.err build/SpatialAudio.app --args --ring-probe-recovery 600
   ```
3. **Write down while it runs and after:** what was playing; **whether the original audio ever glitched, popped, dropped out or changed character, and roughly when** (a stop and start of the engine on a Bluetooth output could be audible in the original audio: that is exactly what this run looks for); whether the headphones' sound quality changed (a thinner, call-like sound would mean a Bluetooth profile switch; the probe never touches the input node); any setting you touched and when; any permission prompt; whether the Mac stayed awake; whether the app exited by itself after about 10 minutes.
4. **Where it lands:** `docs/test-results/ringrecovery-YYYYMMDD-HHMMSS.md` and `.json` (no `-SIMULATED` in the name; that suffix means the test source, never hardware). `/tmp/ringrecovery-bt.out` holds the same report as text; `/tmp/ringrecovery-bt.err` should be empty. **Numbers only: no device name, no UID, no path.**

## Run B: built-in speakers, 120 s, music playing
1. System Settings > Sound > Output: **MacBook Air Speakers**. Start music (non-protected).
2. ```
   open -n -W --stdout /tmp/ringrecovery-spk.out --stderr /tmp/ringrecovery-spk.err build/SpatialAudio.app --args --ring-probe-recovery 120
   ```
3. The 6b-2 speaker runs (48 kHz to 48 kHz) were clean for 780 s with zero underruns [measured]; **the expected result here is zero re-primes** (nothing to repair). A re-prime on a clean path would be a finding in itself (a trigger that should not have fired, or a drain that was not there before). Note the same observations as in Run A.

## The postponed run (not now)
**Sanjai has no wired headphones (2026-11-18); the wired-jack rate check (a 60 s count-only probe at gain 0, wired headphones plugged in and selected) is postponed until he has some.** It is the plain mode: `open -n -W ... build/SpatialAudio.app --args --ring-probe 60`. Nothing to do for it now.

## What to look at in each report
Everything in `docs/MANUAL_TEST_STEP6B2.md` ("What to look at in each report") still applies to sections 1 to 6 (the outcome, the gain line = `0.000` before the start, after the start and at the end, the rates, the fill, the counters, the teardown). Differences in this mode:
- **The counters in sections 2 to 4 are cumulative across the re-primes** (the ring zeroes them at every prime; the probe adds each finished epoch back). **The fill series jumps at every re-prime by design**, so its slope over the whole run is **not** a drift measurement here (a note in section 7 says so); use the plain `--ring-probe` runs for that.
- **Section 8 "Recovery"** (new):
  - the thresholds in force (**UNTUNED**: 4 underrun blocks, 8 divergence events, T = 4 callbacks, at least 5 s between re-primes, at most 6 per 60 s, 3 quiet polls after the engine reports stopped), and that the probe samples once per second, so a trigger is seen up to about a second late;
  - **Re-primes performed** (triggered / suppressed by the minimum interval / suppressed by the storm limit), and **GAVE UP: ...** if the controller could not complete one (the run then ends and the report says why);
  - the **start sequence** (the first prime and engine start go through the same states; it is **not** counted as a re-prime);
  - **per re-prime: the reason** (`underruns`, `divergence`, or the ring's own `needsReprimeFlag` / `divergedFlag`), **when it was triggered** (seconds from the run start), **seconds since the previous restart**, **underruns before**, **how long the engine was stopped** (measured from the stop request to the restart returning), **prime attempts** (more than 1 means the ring did not yet hold enough callbacks), **the fill of each reader at the restart** (both must be at least T and the cursors equal, or the controller gives up), and **underruns after** (in the epoch that re-prime started: 0 means the repair held until the next trigger or the end);
  - **per reader, summed over all epochs: the table of frame counts the block was asked for** (value x calls; the first measurement of per-call sizes on the real Bluetooth path: the earlier runs only had means), the overflow calls, min / max, the jump counters (overrun, divergence, refused, largest) and the sticky `diverged` / `needsReprime` flags; T at the end.
- **Outcomes to expect and what they mean:** `ok` with re-primes and a clean teardown = the mechanism worked on this path (it says nothing about sound). **`interrupted` (stopped by configurationChange)** right after a re-prime would mean the engine posted a configuration change when it was restarted: the run stops (it is never restarted automatically beyond what the controller does): **tell me, that is a design finding.** `invalid` or `never primed` = as in 6b-2. A **GAVE UP** line names the step that failed (the engine still running after the stop request, the readers still being called, the prime refused for too long, fills below T, the restart failing, the gain not reading 0).

## What counts as a pass (and what does not)
There is **no pass criterion for sound, latency or CPU: none of them is measured here**, and this manual does not decide whether the re-prime is good enough to listen to. A "pass" below means only "the mechanism did what it is documented to do on this path"; anything else is a **finding**, not a failure of you.

**Run B (built-in speakers, 120 s), pass =** all of: the report's outcome is `ok`, stopped by `timeout`; the output gain line reads `0.000` before the start, after the start and at the end; `Clean: YES` and the teardown list is the one in "What to look at"; section 8 is present, with **no `GAVE UP` line** and **0 re-primes performed** (the start sequence shown as succeeded). **A re-prime on this clean path is a finding**: write down its reason and time.

**Run A (Bluetooth, 600 s), pass of the mechanism =** all of: outcome `ok`, stopped by `timeout`; gain `0.000` three times; `Clean: YES`; section 8 with **no `GAVE UP` line**; **every re-prime row says `ok`**, its **fill at restart is at least T (2,048 for both readers)**, its **engine-stopped time is a finite number**, and the report's frame-count tables add up (the calls in a reader's table plus its overflow calls equal its call count). **How many re-primes there were, how long the engine was stopped, and whether "underruns after" stay near 0 are results to report, not pass/fail numbers** (no threshold for them has been set).

**Findings (tell me, do not retry silently):** outcome `interrupted` (a configuration change), `invalid`, `never primed`, `refused`, `failed at ...`; any `GAVE UP` or a row that says `FAILED`; any re-prime on Run B; a gain other than `0.000` (a bug); the app not exiting, a crash or a hang; a leftover aggregate device or tap; **any glitch, pop, dropout or change in the character of the music you were playing, and when** (a stop and start of the engine on a Bluetooth output might be audible in the original audio; that is exactly what Run A looks for); the output switching by itself; heat or fans.

## What to paste back
1. **The `.md` report of each run, pasted in full** (the file names are enough only if you say so; the `.json` stays on disk). A report with blanks or placeholders is not a result, and I will say so and change nothing.
2. **Next to each report, typed by you:** the wall-clock time you started it (to the second), what was playing, whether and when the original audio glitched, any setting you touched and when, any permission prompt (exact text and the button you pressed), and for Run A whether the headphones' sound changed. **Do not type report numbers from memory.**
3. The output of `build/SpatialAudio.app/Contents/MacOS/SpatialAudio --list-audio-devices` after each run, and `git log -1 --oneline` (the commit you ran).
4. Anything odd, even if it seems unrelated.

## If something goes wrong
- To stop a run early: `pkill -INT -x SpatialAudio` (the probe tears everything down on SIGINT / SIGTERM and writes a report with `stopped by: signal`). Ctrl-C in Terminal does not reach an `open`ed app.
- If you hear anything from this app (it should play nothing), if the original audio stutters in a way you did not hear in the plain `--ring-probe` runs, or if the Mac's audio output switches by itself: stop the run, write down what you heard and when, and send the report anyway.

## After a run: check for leftovers
```
build/SpatialAudio.app/Contents/MacOS/SpatialAudio --list-audio-devices
```
Expected: `aggregate devices: 0`, `devices named "SpatialAudio Tap Probe": 0`, `taps: 0` (the tap and the aggregate are private; the report's own lists are the stronger evidence).

## Report back
See "What to paste back" above. Real reports are committed on their own, by explicit path, only when you say so (CLAUDE.md, Git workflow rule 3), after a privacy grep. Simulated reports (`-SIMULATED`) are never committed.

## The simulated mode (for checking the plumbing, no hardware)
`--ring-probe-recovery-simulate <seconds>` runs the same flow on a made-up source (our own thread calls the real `SARingIOProc`; a manual-rendering engine with no device pulls the real source nodes), with the re-prime controller. Its report says **SIMULATED SOURCE** and its numbers say nothing about this Mac. Faults: `--ring-sim-underrun=<at>,<stall>` (the simulated producer stalls for `stall` s, `at` s after it started) and `--ring-sim-ppm=<n>`:
```
open -n -W --stdout /tmp/simrec.out --stderr /tmp/simrec.err build/SpatialAudio.app --args --ring-probe-recovery-simulate 30 --ring-sim-underrun=8,1 --results-dir=/tmp/simresults
```
There is no gain or volume option in any mode; naming one (`--gain=1`, `--volume=1`, ...) is refused with exit status 2.
