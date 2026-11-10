# Step 3a manual listening test (needs you, headphones and your ears)

Nothing below has been heard by Claude. How the renderer **sounds** is **UNVERIFIED** until you listen. **No camera is used anywhere in this test**: the head is a scripted, synthetic one, so this checks only the audio side (the conversion from head pose to what `AVAudioEnvironmentNode` renders). It says nothing about the camera signs; that is the self-test in docs/MANUAL_TEST_STEP2.md.

**Step 3a-2 (2026-11-10): there is no typed report any more.** The main test is the **blind listening test** in the HUD: it plays 20 short tones in a random order, you answer each with a button, and the app writes a numbers-only report to `docs/test-results/` and shows you the path. Status of the blind test: **IMPLEMENTED-UNVERIFIED** (built, unit-tested on virtual time and mutation-checked; **nobody has run it with ears**). The old scripted card (tests A–E, with the visible "EXPECTED" line) is still there, as a **diagnostic you use after the blind test**, not before: it shows the answer, so it is not blind.

## What was already checked without ears (so you know what to expect)
By rendering offline (no sound, no hardware) through the same `AVAudioEnvironmentNode` the app uses:
- A source at the listener's right (+X) is louder in the right output channel by 7.7 dB (left by 7.7 dB for -X); straight ahead is within 0.3 dB. That is a measurement of the output channels, not of your headphones.
- Turning the listener left by 60° moves a straight-ahead source to the right channel (+7.5 dB), turning right to the left channel (-7.8 dB).
- Rotating the listener by R renders **identically** to leaving it alone and moving the source by the inverse rotation, for yaw, pitch, roll and combinations (a wrong-direction control differs by 48-140%).
- A whole scripted yaw sweep, run offline through the real mailbox → pump → conversion chain, produces a left/right level difference that follows the expected azimuth with correlation 0.9855.

What no program can tell is whether the left channel really reaches your **left ear** on your headphones, and how convincing the HRTF is for **your** ears. That is what this test is for.

## Before you start
1. **Quit any SpatialAudio app that is already running (Cmd+Q).** An older instance may still be open; `open` would then just bring that old window forward and you would not see the new card.
2. Put on headphones, the right way round (L on the left ear). Wired is simplest.
3. **AirPods / Beats:** turn their Spatial Audio / head tracking **off** in the system sound controls for this test (the end of the blind test asks you which it was). macOS has its own head tracking for those devices which would stack on top of ours and spoil the test; this app cannot switch it off, and the product must not depend on it.
4. **Volume low.** Set the system volume low (about 25%). The blind card's slider starts at **20%** (UNTUNED); raise slowly. The tone is noise bursts, which can be harsh. The slider is fixed once the test has started, because the volume is stated in the report.
5. A quiet room helps; closing your eyes helps more. Sit still: the head you hear moving is a scripted one, and your own head is not tracked.

## Part 1: the blind test (do this first)
```
cd /Users/sanjais/ClaudeHome/SpatialAudio
scripts/make-app.sh debug && open build/SpatialAudio.app
```
In the HUD window find the card **"Blind listening test — buttons only, NO camera"** (above the older "Audio listening test" card). Do **not** press Start camera or Run self-test.

1. Press **Start blind test**. Silence for about 2 s, then the first tone.
2. For each of the 20 tones, press where it seems to be: **Left ear**, **Right ear**, **Middle**, or **Can't tell**. The buttons switch on about 1.2 s after the tone starts (always the same delay, so the delay tells you nothing); after the head-turn trials this is also when the scripted head has stopped moving. Do not guess to please the test: **"Can't tell" is a good answer and says nothing bad about the code or your ears.** A tone you do not answer within 12 s is recorded as "not answered".
3. The card shows only "Tone n of 20" and "Listen…" / "Where does the tone seem to be?". It never shows what the right answer is.
4. **Stop** ends the run early (the tone fades out; the report then says "stopped early" and holds only the finished trials). Quitting the app mid-run writes **no** report.
5. At the end three questions: **clicks or crackling?** (Yes / No), **inside or outside your head?** (Inside / Outside), **AirPods Spatial Audio / head tracking** (Off / On / Not using AirPods). Skip any of them: it is recorded as "not answered". Then press **Save report**; the card shows the file path (the path is shown on screen only, it is not written into the report).

It should take roughly 1.5 to 3 minutes (a trial is at least 2.7 s: 1.5 s of silence plus the 1.2 s before the buttons work; the rest depends on you; not measured).

### What the 20 trials are (the report shows this after the run, never during it)
Five conditions, **4 of each**, in a random order from a seed that the report records, with no condition three times in a row:

| Condition | What is scripted | What a correct renderer puts in your ears |
|---|---|---|
| static LEFT | head still, tone 90° to the left | left ear |
| static RIGHT | head still, tone 90° to the right | right ear |
| static AHEAD | head still, tone straight ahead | middle |
| head 45° LEFT | tone fixed straight ahead in the room, the scripted head turns 45° left over 1 s and holds | right ear (like a real fixed loudspeaker) |
| head 45° RIGHT | the same, the head turns 45° right | left ear |

The expected position is computed from geometry (`ListenerGeometry`), and the tone is faded out (80 ms) before the scene changes and faded in after it, so a jump of the tone's position is never audible and cannot be mistaken for a click.

### What the report says
Written to `docs/test-results/listening-YYYYMMDD-HHMMSS.json` and `.md` (a SIMULATED rehearsal gets `-SIMULATED` in the name and is never committed). **Numbers only: no device name, no UID, no path, no headphone make or model, no camera data.** It holds:
- per trial: the condition, the truth, your answer, the time from tone onset to your press;
- per condition and a confusion table (rows = conditions, columns = left ear / right ear / middle / can't tell / not answered);
- **chance is 1 in 3** per definite answer (left ear / right ear / middle) *if you were guessing uniformly among those three buttons*; "can't tell" is an abstention, not a guess; the probability of at least your number correct by guessing alone is given as a rough guide only (the trial mix is not uniform);
- a **channel-swap flag**, from the static LEFT / RIGHT trials only: SUSPECTED if there are at least 6 definite answers and at least 75% of them are in the opposite ear. A second flag, **head-turn reversed**, is assessed only if the static answers were mostly right (at least 75% of at least 6): then at least 6 definite head-turn answers with at least 75% in the opposite ear says the tone moves the wrong way when the head turns. **Both thresholds are UNTUNED** (picked before any data existed) and the flags are hints for a human, not verdicts;
- the three end-of-test answers; the output device's transport type (a category such as Bluetooth or built-in), nominal rate, buffer size and output channel count; the pose pump's tick count, mean and longest period; the thermal state and Low Power Mode at the start and the end (`ProcessInfo`); start and end time; the seed; the output volume; the schema version.

### Report back
**The file name. Nothing typed.** (If you want the headphone make and model on record, write them next to the file name yourself: the app deliberately does not record them.) A real report is committed on its own, by explicit path, only when you say so; the privacy grep runs first.

### Known limits of the blind test (stated, not measured)
- **UNVERIFIED on a person:** the layout of the card, the buttons, the fade, the timing of the buttons, the file writing from the real button, and how any of it sounds.
- The fade is a volume ramp on the main mixer set from a 100 Hz control timer (about 8 steps over 80 ms). Whether that produces an audible zipper or click is **unknown**; if you hear clicks, the "clicks or crackling" answer includes that.
- The tone is the old noise-burst loop (0.3 s bursts every 0.5 s, -26 dBFS RMS inside the bursts, UNTUNED), still looping while the trial gaps are silent, so a trial can start in the middle of a burst.
- A tone straight ahead often sounds inside the head or slightly behind; front/back confusion is common with a generic HRTF (not a bug of this test). The static-AHEAD trials will therefore often get "middle" or "can't tell" or a wrong ear: that is what a generic HRTF may do, not evidence of a code error.
- 20 trials is a small sample; one run says little about the statistics.

## Part 2: the scripted card (diagnostic, after the blind test; NOT blind)
Only if the blind test shows something wrong, or you want to see the head move. In the card **"Audio listening test — scripted head, NO camera"** pick a test in the menu and press **Start listening test**. Press **Stop** (or quit) when done. While it runs the card shows `HEAD:` (what the scripted head is doing), `EXPECTED:` (where the tone should seem to be, computed from geometry; the flip switches do not change it), the vector sent to the engine, and the pose pump's tick spacing. The scripted card and the blind test cannot run at the same time (the second one to start refuses).

- **A · tone hard left / hard right / ahead (head still).** Every 3 s the tone jumps: LEFT, RIGHT, AHEAD, in a 9 s loop. If A is **swapped** (LEFT in the right ear), do **not** touch the flip switches: check the headphones are on the right way round. A swap in A is a headphones/channel problem, not a head-pose problem.
- **B · head sweeps left ↔ right.** The tone is fixed straight ahead; the scripted head turns LEFT first, back through the middle, then RIGHT, 12 s per cycle, up to 60°. When the head turns **left** the tone slides toward your **right** ear, and the reverse. Level differences saturate beyond about 50°.
- **C · head holds at 45° left, then 45° right** (14 s loop): tone clearly on your RIGHT, then clearly on your LEFT.
- **D · head nods (subtle).** Looking UP: tone below your line of sight; DOWN: above. With a generic HRTF up/down is much harder than left/right; "can't tell" is normal.
- **E · head tilts ear to ear (subtle).** The tone sits about 60° to your right. Right ear down → it should seem to rise above your ear level. Also subtle.

### If something sounds backwards: the flip switches
1. Test A right but test B or C **reversed** (the tone slides the same way the head turns): tick **yaw**, listen again. Tell me.
2. Test D reversed → **pitch**. Test E reversed → **roll**. (Only if you could tell by ear.)
3. **Reset flips** returns to the default.

The switches are for diagnosis. If you need one, the fix belongs in the conversion and its tests, not in a permanent switch; tell me which test and which switch.

## What this test deliberately does not do
- It does not open the camera or the microphone. The audio engine's input node is never created.
- It does not decide any camera sign. The camera link stays closed until you confirm signs from a real self-test report (yaw and pitch were confirmed on 2026-11-09 from run 215400, roll was not; see docs/STATUS.md).
- It does not measure latency or CPU; those are Step 5.
- It does not use the ring or the system-audio tap.

## Developer notes (no ears)
- `build/SpatialAudio.app/Contents/MacOS/SpatialAudio --audio-test-selfcheck` runs the scripted card's real start / readout / flip / stop path **at volume 0**, prints what the card would show, and quits. `SA_LIVE_AUDIO=1 swift test --filter LiveEngineSmokeTests` runs the live engine and timers silently.
- `--blind-listening-simulate[=perfect|swapped|reversed|guess|abstain|silent]` (with `--mute` and `--results-dir=PATH`) runs the blind test's **report path** with a **SIMULATED listener** (fabricated answers, no audio, no camera), writes `listening-...-SIMULATED.{json,md}`, prints where, and quits. It rehearses the plumbing; its numbers say nothing about any ear and decide nothing. Two runs in the same second overwrite each other.
- Mutation check of the blind test's logic: `caffeinate -i python3 -I scripts/mutate_blindlistening.py`.
