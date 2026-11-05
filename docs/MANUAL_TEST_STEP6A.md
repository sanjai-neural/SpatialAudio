# Manual test — Step 6a: system-audio capture probe

Nothing below has been run against a real tap by Claude. Every item is **UNVERIFIED** until you run it and report back. The probe only MEASURES: it opens a Core Audio process tap (global, excluding this app, original audio left audible), counts the callbacks and levels for N seconds, writes a numbers-only report and tears everything down. No rendering, no camera, nothing muted, no audio stored.

## Run this on the right commit
The manual run must be on the commit that carries the callback fix (message starts with **"Step 6a fix:"**), not on `98f22d9`, whose capture callback still had an incomplete zero-divisor guard. Before you start: `git log -1 --oneline` must show that "Step 6a fix:" commit, `git status --short` must be empty, and the bundle must be rebuilt at that commit (`scripts/make-app.sh debug`, below). A report from any other build says nothing about this commit; note the commit hash with each report you send.

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
2. The permission observations from section 1: prompt text and buttons, when it appeared, what you pressed, the app name it showed, anything in the menu bar or Settings.
3. The denied-path observations (section 4) and, if you did it, the no-key observation (section 5).
4. Whether the original audio stayed audible and glitch-free during the runs.
5. The `--list-audio-devices` output after a run.
6. Anything odd: a crash, a hang, heat, the Mac's audio output switching, a leftover device.

Real reports are committed on their own, by explicit path, only when you say so (CLAUDE.md, Git workflow rule 3). Simulated reports (`-SIMULATED`) are never committed.

## What the simulated mode is for
`--tap-probe-simulate <seconds>` runs the same flow on a made-up source (a test thread calling the real C callback). Its report says **SIMULATED SOURCE** and its numbers are meaningless as hardware results; it exists to check that the launch path, the report files and the teardown logic work: `open -n -W --stdout /tmp/sim.out --stderr /tmp/sim.err build/SpatialAudio.app --args --tap-probe-simulate 3 --results-dir=/tmp/simresults`.
