# Step 3b manual test: head-tracked listening (the camera moves the sound)

**Status: IMPLEMENTED-UNVERIFIED.** Built, unit-tested on virtual time, mutation-checked, and wiring-checked silently with the SIMULATED user. **Nobody has heard it, and the real camera has not been run through this card.** Whether the sound follows your head, how it sounds, and how long it lags are all unknown until you do this. This build moves the sound with **yaw (turn) and pitch (nod) only; roll is fixed at 0**. No report, no guided test, no position tracking, no ring or system audio.

## First: the two 1-minute checks (PENDING, not done; do them before the first head-tracked listening)
Your earlier Test A answer ("left, middle, right") did not match the loop order (LEFT, RIGHT, AHEAD), so a left/right swap is neither confirmed nor excluded. If the headphones or the output route are swapped, every judgement below ("moves toward the right ear") would be misleading.
1. **A stereo left/right voice test outside our app** (any source you trust that says "left" and "right" in the matching channel): which ear hears the word "left"? About 1 minute.
2. **Test A in the scripted card** (docs/MANUAL_TEST_STEP3A.md, Part 2): which ear gets the first sound of the loop? It should be hard **LEFT**. About 1 minute.

If either check is swapped or unclear, **stop here and tell me**: do not use the tracked card until we know whether it is the headphones, the route, or the app.

## Before you start
1. **Quit any running SpatialAudio (Cmd+Q).** `open` would otherwise bring an old window forward.
2. Headphones on, the right way round. **AirPods / Beats: switch Spatial Audio / head tracking OFF** (the system would add its own head tracking on top of ours).
3. **System volume low** (about 25%). The card's slider starts at **15%** and is capped at **40%** (both UNTUNED guesses; there is no loudness measurement and no limiter, so the cap is only a guard against a slider slip). The sound is a **steady noise**: raise slowly.
4. Sit the way you normally do, facing the screen, with your face well lit. Camera frame rate varied between 16.6 and 30 fps in earlier runs for an unknown reason; the card shows it live and does not compensate.

```
cd /Users/sanjais/ClaudeHome/SpatialAudio
scripts/make-app.sh debug && open build/SpatialAudio.app
```
In the HUD window find the card **"Head-tracked listening — the CAMERA moves the sound"** (above the blind test card). Do **not** press the HUD's own Start camera or Run self-test: this card starts and stops the camera itself, and refuses to start while the camera, the self-test, the scripted card or the blind test is in use.

## The steps
1. **Start.** Press **Start head-tracked listening**. The macOS camera light comes on (permission was granted earlier; if a prompt appears, write its text down). Wait until the card says `tracking: LOCKED` and `face: yes`. A steady noise plays, fixed 2 m straight ahead like a loudspeaker.
2. **Face the screen and press Recenter** (it only works while LOCKED). The sound should be in the middle or slightly in front.
3. **Turn your head LEFT, slowly, about 45°.** The noise should **move toward your RIGHT ear** (a fixed speaker, which now is on your right side). The readout `SENT TO THE RENDERER: yaw` should go **positive** while you turn left. Turn back: it returns to the middle. **Turn RIGHT**: it moves toward your LEFT ear, yaw negative.
4. **Look up, then down.** Pitch goes positive looking up. By ear this is much weaker than left/right with a generic HRTF (the tone should seem a little lower when you look up, higher when you look down); "I can't tell" is a normal answer.
5. **Cover the camera with your hand for about 5 seconds, then uncover.** **Nothing should jump.** Expected on the card: `HOLDING` (the sound freezes where it was, 0.5 s), `DECAYING` (it glides back to the front over about 1.5 s), `STATIC` (it stays in front). On uncover: once the camera has a good face again and the quality gate has recovered (the real self-test runs re-acquired 0.8 to 1.3 s after the uncover cue, hand movement included), the sound glides to where your head is over about a quarter of a second. Try it while looking left: the sound should drift from the right ear to the middle over about 2 s, not snap.
6. **Tilt your head (ear toward shoulder), both sides.** Roll is fixed at 0, so **nothing should tilt or change** and `roll` in the readout stays `+0.0`. **Caution, from real data:** in three of the four 2026-11-10 self-test runs the camera read a right-ear tilt mainly as a change of **yaw** (raw yaw about −41° to −55°), so the sound **may still shift left/right when you tilt**. If it does, that is the camera's yaw estimate leaking, not roll being sent. Tell me which way and roughly how far it moved.
7. **Stop.** Press **Stop**. The sound stops and the camera is released: the camera light should go off within about 1 to 2 seconds, and the card shows the programmatic release check (`CLEAN` = isRunning false, 0 inputs, 0 outputs, 0 frames after stop). Also try **Cmd+Q while running**; the light should go off too.

## What to tell me (no typed form; this step has no report code)
- Did the sound move the way a fixed speaker should in steps 3 and 5, or the wrong way, or not at all?
- Did it lag your head, jitter, or jump at any moment (when, doing what)? Any clicks or crackling?
- The numbers on the card during a steady turn: fps, pump line, tracking state.
- Step 6: what the sound did when you tilted.
- Step 7: the light, the release line, any prompt text, heat.

## What the numbers on the card are
- `SENT TO THE RENDERER`: the head pose the pump last handed to the engine (yaw, pitch, roll in degrees, after the roll has been zeroed).
- `tracking`: LOCKED (following you), HOLDING (face lost, pose frozen), DECAYING (easing back to the front), STATIC (at the front, no tracking).
- `camera: N fps`: frames per second as measured by the app; `(no frame for X s)` appears when frames stop (the watchdog is feeding the state machine then).
- `pose pump`: ticks, mean and longest period of the control timer that moves the listener (nominal block 10.67 ms). Diagnostic only.
- `poses published` / `REFUSED (not finite)`: how many poses went to the audio side; the second one should never appear.

## What this build does and does not do
- **Yaw and pitch only.** The mapping is forced to the default with **no invert** (what you confirmed from run 215400) for as long as this card runs; any saved or manual mapping is set aside and restored when you stop. **Roll is forced to 0 in three places**: before the camera filter, at the mailbox, and at the pump's output (the tested conversion, not the Invert checkbox).
- A fixed noise source; 2 m ahead; no distance or room model.
- No latency measurement (a camera-to-ear delay certainly exists; its size is unknown). Interpolation (20 ms time constant), hold 0.5 s, decay 1.5 s and the 0.25 s re-acquire blend are UNTUNED placeholders.
- A spike in the camera's raw yaw or pitch while LOCKED (like the 16.2° step of run 153425) is not filtered out specially; it can move the sound.
- The scripted card and the blind test cannot run at the same time as this card.

## Developer notes (no ears, no real camera)
- `build/SpatialAudio.app/Contents/MacOS/SpatialAudio --simulate --tracked-listening-selfcheck --mute` runs this card's real Start / feed / readout / Stop path **at volume 0** with the **SIMULATED user** (never the real camera), prints what the card would show, and quits. Everything it sees is fabricated: it checks the wiring only.
- Tests: `swift test --filter 'Tracked|RollRemoval|SteadyNoise|ListeningMode|zeroRoll'`. Mutation check: `caffeinate -i python3 -I scripts/mutate_trackedlistening.py`.
