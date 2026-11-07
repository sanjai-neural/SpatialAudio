# Manual test — Step 6a: system-audio capture probe

Nothing below has been run against a real tap by Claude. Every item is **UNVERIFIED** until you run it and report back. The probe only MEASURES: it opens a Core Audio process tap (global, excluding this app, original audio left audible), counts the callbacks and levels for N seconds, writes a numbers-only report and tears everything down. No rendering, no camera, nothing muted, no audio stored.

## Run this on the right commit
The manual run must be on the commit whose message starts with **"Step 6a3:"** (or a later one): it carries the callback fix (a zero or wrapped frame divisor, found after `98f22d9`), the device / clock / rate facts and the long run described below, and (Step 6a3) the input-timestamp recording that makes the long run's drift data readable. **Not** on a "Step 6a2:" commit: its callback records only `inNow`, so its drift figures carry the full scheduling jitter and a 600 s run on it would waste the ten minutes. Not on `98f22d9` (incomplete zero-divisor guard) and not on `cc80ecb` (no device facts, schema 1). Before you start: `git log -1 --oneline` must show that "Step 6a3:" commit, `git status --short` must be empty, and the bundle must be rebuilt at that commit (`scripts/make-app.sh debug`, below). A report from any other build says nothing about this commit; note the commit hash with each report you send, and look at the report's `schemaVersion` (**3** = this step; 2 = Step 6a2, 1 = Step 6a).

## What you need
- The dev bundle, rebuilt **at that commit** (it carries the `NSAudioCaptureUsageDescription` key): `cd /Users/sanjais/ClaudeHome/SpatialAudio && scripts/make-app.sh debug`
- **Non-protected audio** you can start and stop: a local file you own in QuickTime Player (File > Open File), or from Terminal `for i in 1 2 3 4 5 6 7 8; do afplay /System/Library/Sounds/Submarine.aiff; done` (about 15 s, system sounds, not protected). **Do not use** Apple Music subscription tracks, Netflix, Disney+, TV+, or other DRM-protected audio: protected content may be silent in a tap, and we neither work around that nor want it to confuse this run. (A second, deliberate run in section 6 records what protected content does, if you want to see it.)
- Your usual output (speakers or headphones). The default composition does not touch the output device, so a Bluetooth headset is fine. Note which one you used.
- Quit any running SpatialAudio first (Cmd+Q), or `open` may bring an old instance forward.

## 1. First run: the permission flow (this is the important one)
1. Start the audio (above) at a comfortable volume.
2. Run (10 seconds of capture; the `--stdout` and `--stderr` files keep what the app prints):
   ```
   open -n -W --stdout /tmp/tapprobe.out --stderr /tmp/tapprobe.err build/SpatialAudio.app --args --tap-probe 10
   ```
   `open -W` waits until the app exits. There is no window and no Dock icon; if the macOS permission prompt appears, it appears on its own.
3. **Write down, exactly, while it happens:**
   - Did a permission prompt appear? **When** (the moment you launched, or after a pause)? Its **exact text** (including the app name it shows), the **button labels**, any extra detail (a menu-bar indicator, a Control Center entry, a Settings pane).
   - Did the audio you were playing **stay audible the whole time**, with no glitch or dropout?
   - Which button you pressed.
4. If the prompt was open, did the capture seem to wait for your answer? (The report says how long the run lasted and the status of each call.)
5. After `open` returns, the files are in `docs/test-results/`: `tapprobe-YYYYMMDD-HHMMSS.json` and `.md` (no `-SIMULATED` in the name: that suffix means the test source, never hardware). Look at `/tmp/tapprobe.out` (the same report) and `/tmp/tapprobe.err` (should be empty).

## 2. What to look at in the report
- **Outcome** line: `ok`, or `failed at <call>` / `refused: ...`. The call table lists every Core Audio call with its OSStatus (a four-character code such as `'!hog'` when printable, and the SDK constant name only where the header names it).
- **Format of the tap**: sample format, channels, sample rate.
- **Callbacks**: count, frames per callback (min / median / max), callback interval (min / median / max), implied frames per second against the declared rate, per-second peak and RMS, silent seconds.
- **Teardown**: `Clean: YES` means every created object was destroyed and neither was listed any more within the polling bound.
- **Notes**: it says out loud if the capture was SILENT (nothing playing, protected content, or a permission refusal that gave no error), if this process had no audio process object, or if anything was flagged.

### New in Step 6a2: device, clock and rate facts (section 4 of the report)
The report now also carries read-only facts, numbers only, in its **section 4**: for the default output device (read BEFORE the tap exists) and for the tap's aggregate device (read WHILE it runs): name, transport type, nominal and actual sample rate, buffer size, device / stream latency and safety offset (frames), clock domain, and whether a clock device is named. Every read's status is kept; a value the system would not give is left empty, never guessed. Also: the output device's and the aggregate device's `ActualSampleRate` read at the start and after every 10 s, the tap's callback cadence per 10 s window (implied frames per second, parts per million against the declared rate, and the cumulative frame offset), and a side-by-side rate comparison. The report always ends section 4 with **"What this does and does not show"**: read it. In short, a tap-only aggregate device has no declared time source, the cadence is measured against the HOST clock, and nothing here supports a drift claim without a long measured series.
**Privacy:** the **device name** is recorded as the system reports it, and a Bluetooth device's name can contain your own name ("Sanjai's AirPods"). Device UIDs are never recorded. Look at the name before you ever agree to commit a real report; I will not edit a real report.
**What to note about the tap aggregate's clock:** if its `clock domain` is 0 the header says to treat it as separate from every other device; if it is non-zero and equal to the output device's, the header says only that they are "able to be synchronized in hardware".

### New in Step 6a3: input timestamps and two estimators side by side (section 4 of the report)
The callback now also records `inInputTime` (the header: "the time at which the first frame in the data was acquired from the hardware", zeroed out if the device has no input streams) next to `inNow` ("the IO cycle started ... includes any scheduling latency"), with whether its host time and sample time were marked valid. Section 4 then shows:
- **The window table, side by side.** The same callbacks in each 10 s window, measured two ways: `inNow` columns and `input` columns (implied frames/s, ppm against the declared rate, cumulative frame offset), plus how many callbacks of the window had a usable input host time.
- **"Input timestamps and the two estimators"**: how many callbacks had a valid input host time / sample time or no input timestamp at all; `inNow` minus input host time (ms, min / median / max); sample-time continuity (did the HAL's sample counter advance by exactly the frames delivered); and a table with, per estimator, the fitted drift (ppm) with its standard error, the offset's scatter (SD and peak-to-peak, in frames) and **the resolution floor**: the smallest drift that cannot be told from that scatter, over the whole run and within one 10 s window. Then sentences in words, with the numbers of this run.
- **"What each estimator can and cannot resolve"**: printed in every report.
**How to read it (before you send it):**
- If the **input columns are all "—"**, the tap's `inInputTime` was not usable on this Mac; that itself is the finding. The `inNow` columns still stand.
- **A very straight input line** (peak-to-peak near 0.0 frames) is not evidence of a steady clock: the header does not say what the input time refers to for a tap-only aggregate, and the HAL may smooth it with its own model (UNVERIFIED). Compare it with the `inNow` scatter, and note the `inNow - input` figure.
- **A drift figure smaller than its resolution floor is not a drift.** The report says so in words ("NOT larger than the jitter"). A 10 s window has a floor about 60 times larger than the whole 600 s run's (600 s / 10 s: the time is in the denominator of the formula).
- Both estimators compare the tap with the HOST clock only. Neither says anything about the output device's clock. Nothing here proves or disproves that the tap and the output device drift apart.
- Sample-time **mismatches** (non-zero count) mean the HAL's counter skipped or repeated frames somewhere in the run: write down roughly when anything audible happened.

## 3. Check the teardown from outside
Right after the run, from a fresh process:
```
build/SpatialAudio.app/Contents/MacOS/SpatialAudio --list-audio-devices
```
Expected: `aggregate devices: 0`, `devices named "SpatialAudio Tap Probe": 0`, `taps: 0`. Also glance at System Settings > Sound for any odd extra device. **Limit:** the probe's tap and aggregate device are private, so another process cannot see them whether or not they leaked; this check only proves nothing *visible* is left. The report's own "after teardown" lists (read inside the process) are the stronger evidence.

## 4. The denied path
1. Make the app lose the permission: answer **Don't Allow** at a first prompt, or switch SpatialAudio's access off in System Settings > Privacy & Security (the pane's name for system audio capture is whatever your macOS calls it; write it down). If you want a clean slate, `tccutil reset All dev.spatialaudio.SpatialAudio` resets EVERY permission of this app, including the camera one (you will be asked for the camera again later).
2. Run the same command again with audio playing.
3. Record: did a prompt appear again? Which call failed, with which status? Or did everything succeed and the report show **silence** (a denied tap that delivers zeros without an error)? What does the report's Notes section say?

## 4b. The long run (Step 6a2, revised in Step 6a3): drift needs a series
A short run cannot say anything about drift. One 600-second run (the maximum) gives sixty 10-second windows.
```
caffeinate -i open -n -W --stdout /tmp/tapprobe600.out --stderr /tmp/tapprobe600.err build/SpatialAudio.app --args --tap-probe 600
```
**What it costs you:** ten-plus minutes during which (1) audio must be playing the WHOLE time (a long non-protected file, or a playlist of your own files; the capture of silence tells us nothing about the clock) at a comfortable volume; (2) the Mac must stay awake: `caffeinate -i` (above) stops idle sleep, but closing the lid, a low battery or a manual sleep ends the run and shows up as a gap in the windows (note it if it happens); (3) do NOT change the output device, connect or disconnect Bluetooth, or change the sample rate in Audio MIDI Setup unless you are deliberately testing that (then write down when, by the clock on your wrist, so it can be matched to the windows); (4) there is no window and no Dock icon, so nothing shows you progress; Ctrl-C does not reach an `open`ed app (the probe stops itself at 600 s). The probe's own cost is small: the callback does arithmetic and one 48-byte write (32 bytes before Step 6a3); the record buffer is sized for the run (about 600,000 records of 48 bytes, about 29 MB, from the sizes in the code, not measured). The permission prompt appears as in section 1 if it has not been answered before.
**Look at:** section 4 of the report: the `implied frames/s` and `vs declared (ppm)` columns across the windows (steady, or trending?) for BOTH the `inNow` and the `input` columns, the `cumulative frame offset` of each (does it grow in one direction, or stay inside the scatter the estimator table measured?), the estimator table's drift against its resolution floor (Step 6a3: this is what says whether a drift is visible at all), and the `ActualSampleRate` rows (do the output and aggregate readings move, and do they differ from each other?). A trend larger than the floor, in a measured series, would be a result; one window, one reading, or a figure inside the floor would not.

## 5. Optional: without the Info.plist key
This tells us whether `NSAudioCaptureUsageDescription` is really needed.
1. `SA_OMIT_AUDIO_KEY=1 scripts/make-app.sh debug`, then `tccutil reset All dev.spatialaudio.SpatialAudio`.
2. Run the probe as in section 1 and record whether a prompt appears (text?), and the statuses / outcome.
3. Rebuild normally afterwards: `scripts/make-app.sh debug`.

## 6. Optional: other situations (each is one run, 5 seconds is enough)
- **Nothing playing:** expect silent seconds. This shows the silence detection works on real data.
- **Protected content** (only if you want to see it; do not try to get around anything): play something DRM-protected and run. Record whether the report shows silence.
- **If section 1 fails at the aggregate device or at start:** try the other composition, once: `open -n -W --stdout /tmp/tapprobe2.out --stderr /tmp/tapprobe2.err build/SpatialAudio.app --args --tap-probe 5 --tap-probe-with-output-device`. It adds your default output device to the aggregate device and REFUSES (and says why) if that device has input channels (for example a Bluetooth headset with a microphone) unless you add `--allow-device-inputs`; with that flag a headset's microphone could be opened or its profile switched, so use it only if you accept that.

## Report back
1. The pasted `.md` report of each run (the `.json` stays on disk). A report with blanks or placeholders is not a result.
2. The permission observations from section 1 (and for the long run, the exact audio you played and anything that interrupted it): prompt text and buttons, when it appeared, what you pressed, the app name it showed, anything in the menu bar or Settings. For the 600 s run also: whether the input columns were populated, and the estimator table (pasted as is; I will not interpret numbers you have not sent).
3. The denied-path observations (section 4) and, if you did it, the no-key observation (section 5).
4. Whether the original audio stayed audible and glitch-free during the runs.
5. The `--list-audio-devices` output after a run.
6. Anything odd: a crash, a hang, heat, the Mac's audio output switching, a leftover device.

Real reports are committed on their own, by explicit path, only when you say so (CLAUDE.md, Git workflow rule 3). Simulated reports (`-SIMULATED`) are never committed.

## What the simulated mode is for
`--tap-probe-simulate <seconds>` runs the same flow on a made-up source (a test thread calling the real C callback). Its report says **SIMULATED SOURCE** and its numbers are meaningless as hardware results; it exists to check that the launch path, the report files and the teardown logic work: `open -n -W --stdout /tmp/sim.out --stderr /tmp/sim.err build/SpatialAudio.app --args --tap-probe-simulate 3 --results-dir=/tmp/simresults`.
