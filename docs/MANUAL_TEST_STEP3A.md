# Step 3a manual listening test (needs you, headphones and your ears)

Nothing below has been heard by Claude. How the renderer **sounds** is **UNVERIFIED** until you listen and report back. **No camera is used anywhere in this test**: the head is a scripted, synthetic one, so this checks only the audio side (the conversion from head pose to what `AVAudioEnvironmentNode` renders). It says nothing about the camera signs; that is the self-test in docs/MANUAL_TEST_STEP2.md.

## What was already checked without ears (so you know what to expect)
By rendering offline (no sound, no hardware) through the same `AVAudioEnvironmentNode` the app uses:
- A source at the listener's right (+X) is louder in the right output channel by 7.7 dB (left by 7.7 dB for -X); straight ahead is within 0.3 dB. That is a measurement of the output channels, not of your headphones.
- Turning the listener left by 60° moves a straight-ahead source to the right channel (+7.5 dB), turning right to the left channel (-7.8 dB).
- Rotating the listener by R renders **identically** to leaving it alone and moving the source by the inverse rotation, for yaw, pitch, roll and combinations (a wrong-direction control differs by 48-140%).
- A whole scripted yaw sweep, run offline through the real mailbox → pump → conversion chain, produces a left/right level difference that follows the expected azimuth with correlation 0.9855.

What no program can tell is whether the left channel really reaches your **left ear** on your headphones, and how convincing the HRTF is for **your** ears. That is what this test is for.

## Before you start
1. **Quit any SpatialAudio app that is already running (Cmd+Q).** An older instance (a build from before this step) may still be open; `open` would then just bring that old window forward and you would not see the new card.
2. Put on headphones, the right way round (L on the left ear). Wired is simplest.
3. **AirPods / Beats:** turn their Spatial Audio / head tracking **off** in the system sound controls for this test. macOS has its own head tracking for those devices which would stack on top of ours and spoil the test (this app cannot switch it off). Also remember the product must not depend on it.
4. **Volume low.** Set the system volume low (about 25%), and note the card's own volume slider starts at 30%. Raise slowly. The tone is noise bursts, which can be harsh.
5. A quiet room helps; closing your eyes helps more.

## Run it
```
cd /Users/sanjais/ClaudeHome/SpatialAudio
scripts/make-app.sh debug && open build/SpatialAudio.app
```
In the HUD window find the card **"Audio listening test — scripted head, NO camera"** (right under the Guided self-test card). Pick a test in the menu, press **Start listening test**. Do **not** press Start camera or Run self-test. Press **Stop** (or quit the app) when done. While it runs the card shows:
- `HEAD:` what the scripted head is doing now,
- `EXPECTED:` where the tone should seem to be, **computed from geometry** (this is the truth to compare your ears with; the flip switches do not change it),
- the vector actually sent to the engine, and the pose pump's measured tick spacing.

## The tests, what you should hear, and how to tell left from right
**Use test A first.** It involves no head motion at all.

- **A · tone hard left / hard right / ahead (head still).** Every 3 s the tone jumps: LEFT, then RIGHT, then straight AHEAD, in a 9 s loop. You should hear it in your left ear, then your right ear, then in the middle. *How to tell:* rest your right hand lightly on your right ear cup while listening: the second phase should be where your hand is. If A is **swapped** (LEFT phase in the right ear), do **not** touch the flip switches: check the headphones are on the right way round and try any stereo left/right test you trust. A swap in A is a headphones/channel problem, not a head-pose problem.
- **B · head sweeps left ↔ right.** The tone is fixed straight ahead in the room; the scripted head turns LEFT first, back through the middle, then RIGHT, 12 s per cycle, up to 60°. Like a real fixed loudspeaker: when the head turns **left** the tone slides toward your **right** ear, when the head turns **right** it slides toward your **left** ear. The card prints the expected side every moment (`EXPECTED: ... to your RIGHT, 55° ...`). Level differences saturate beyond about 50°, so near the extremes it sits mostly in one ear.
- **C · head holds at 45° left, then 45° right.** Easiest for judging by ear: the head turns 45° LEFT and holds 3 s (tone clearly on your RIGHT), returns, turns 45° RIGHT and holds 3 s (tone clearly on your LEFT), 14 s loop.
- **D · head nods up ↔ down (subtle).** When the head looks UP the tone should seem to be BELOW your line of sight; when it looks DOWN, ABOVE. With a generic HRTF, up/down is much harder to hear than left/right. "I can't tell" is a normal answer and says nothing about the code.
- **E · head tilts ear to ear (subtle).** The tone sits about 60° to your right. Right ear down → it should seem to rise above your ear level; left ear down → drop below. Also subtle.

Expected limits of this kind of rendering (not bugs): a tone straight ahead often sounds inside the head or slightly behind; front/back confusion is common; a moving scene (B, C) helps a lot. Report them, but they are not what we are testing.

## If something sounds backwards: the flip switches
Order of checks:
1. Test A right but test B or C **reversed** (tone slides the same way the head turns instead of the opposite): tick **yaw** while the test runs, listen again. Tell me.
2. Test D reversed → tick **pitch**. Test E reversed → tick **roll**. (Only if you could tell by ear.)
3. Press **Reset flips** to return to the default.

The switches are for diagnosis. If you need one, the fix belongs in the conversion and its tests, not in a permanent switch; tell me which test, which switch, and I will change `ListenerFrame` and its tests accordingly (the offline measurements say the current default is geometrically consistent, so a needed flip would point at the physical side: channel order or headphones).

## Report back
1. Test A: did LEFT / RIGHT / AHEAD come in the left ear / right ear / middle? (yes / swapped / unclear)
2. Test B and C: does the tone move the opposite way to the head turn, as expected? (yes / reversed / unclear). Which flips, if any, fixed it?
3. Tests D and E, if you could tell (or "could not tell").
4. How it sounds: outside the head or inside, front/back confusion, anything harsh or clicking at the loop point or when the tone jumps (A), dropouts or crackling.
5. The pose-pump line on the card (`ticks, mean ... ms, longest ... ms`) after a minute of running, and whether the Mac gets warm (fanless Air).
6. Output device you used (wired/Bluetooth, make and model) and whether AirPods-style Spatial Audio was off.

## What this test deliberately does not do
- It does not open the camera or the microphone. The audio engine's input node is never created.
- It does not decide any camera sign. The camera link stays closed until you confirm signs from a real self-test report.
- It does not measure latency or CPU; those are Step 5.

## Developer note (silent check, no ears)
`build/SpatialAudio.app/Contents/MacOS/SpatialAudio --audio-test-selfcheck` runs this card's real start / readout / flip / stop path **at volume 0**, prints what the card would show, and quits. `SA_LIVE_AUDIO=1 swift test --filter LiveEngineSmokeTests` runs the live engine and timers silently (volume 0, asserted before start).
