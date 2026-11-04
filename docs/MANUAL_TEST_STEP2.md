# Step 2 manual camera test (needs you, your face, and the camera)

Nothing below has been run on a real camera by Claude. Every item is **UNVERIFIED** until you run it and report back.

## 0. Recommended: the guided self-test (real camera)

It replaces most of sections B, C and D below: it walks you through the moves with on-screen instructions, countdowns, a sound and a flash at each step, works out the sign each axis needs, checks the lose-face behavior, measures fps and latency, and saves a numbers-only report. **No camera images are saved anywhere.**

### Run it (real camera)
```
cd /Users/sanjais/ClaudeHome/SpatialAudio
scripts/make-app.sh debug && open build/SpatialAudio.app
```
1. In the "Guided self-test" card choose the lighting tag (**normal light** first; later repeat with **dim room**).
2. Click **Run self-test**. The first time, macOS asks for camera permission: click Allow (the test starts right after; "get ready" gives you 3 s).
3. Follow the screen and the sounds (you will be looking away from the screen during the holds, so listen for the sounds). Total about 47 s:

| Seconds | Screen says | You do | Sound |
|---|---|---|---|
| 0–3 | GET READY | sit as you normally do, facing the screen | Glass |
| 3–5 | LOOK STRAIGHT AHEAD | look at the middle of the screen, stay still | Tink |
| 5–8, 10–13 | TURN LEFT — HOLD (1 of 2, 2 of 2) | turn your head toward YOUR left shoulder (the side of your left hand) and keep it there | Pop |
| 15–18, 20–23 | LOOK UP — HOLD (1 of 2, 2 of 2) | tilt your head back, chin up, face toward the ceiling (moving only your eyes does not count) | Pop |
| 25–28, 30–33 | TILT RIGHT EAR — HOLD (1 of 2, 2 of 2) | tilt your head so YOUR right ear goes down toward YOUR right shoulder; face still points at the screen | Pop |
| 8–10, 13–15, 18–20, 23–25, 28–30, 33–35 | BACK TO CENTER | look straight at the screen, stay still | Tink |
| 35–38 | TURN LEFT ABOUT 25° AND KEEP STILL | turn a quarter of the way toward your left shoulder and hold still, even when the next sound plays | Pop |
| 38–43 | COVER THE CAMERA NOW | put your hand flat over the camera lens; keep your head turned and still | Basso |
| 43–47 | UNCOVER THE CAMERA | take your hand away; keep your head turned and still | Ping |
| 47 | results appear | | Hero |

   Why turn left during the cover test: if your head is at neutral when tracking is lost there is nothing for the pose to jump from, so "never jumps" would pass trivially. The report says when the held pose was too small to mean anything.
4. When it finishes, the app **stops the camera by itself** and shows the results. Look at the green camera light: it should go off within about a second. Click the button that matches what you see (this is the visual check no code can make).
5. Click **Copy report** and paste it to Claude. Two files (`.json` and `.md`, numbers only) are also written to `docs/test-results/`; the HUD shows the exact path and **Show saved files** opens it.
6. Optional, after you have read the result: **Apply detected signs…** → confirm. This sets the invert flags for the axes that were DETERMINED, saves them for next launch, and resets the filter and calibration. Then click **Start camera**, look at the screen, click **Recenter**, and verify by eye: turn LEFT → the arrow points left and yaw goes positive. The invert checkboxes stay available for manual override, and "Reset to documented defaults" undoes it.

### How to read the result
- **DETERMINED** for an axis: both repetitions were large enough, steady, in the same direction, and did not leak into other axes. It reports the raw Vision sign during your move and whether that axis needs **invert ON**.
- **INCONCLUSIVE**: the data was weak or inconsistent and it says why (movement too small, not steady, repetitions disagree, wrong axis dominated, face lost during the hold, mirroring changed). Nothing is guessed; just repeat with a bigger, steadier move.
- The test cannot see which way you actually moved. If you tilted your LEFT ear by mistake, the roll result will be silently inverted. Read the prompts carefully ("YOUR left", "YOUR right ear").
- Loss test: **PASS** = locked → holding → decaying → static → locked, once, with no pose step above the threshold. **FAIL** = a pose jump above the threshold or an impossible state transition. **INCOMPLETE** = the sequence was not completed (cover too short, partial cover, never reacquired). "jump check is WEAK" means the held pose was too close to neutral.
- Latency is "sample timestamp → pose ready" and excludes any delay before the camera stamps the frame. Frame-interval, delivery, Vision and total are shown as mean / p95 / max over a 30 s window (the 12 hold and rest phases).
- All thresholds are untuned proposals; they are printed at the bottom of every report.
- The "Camera release" check proves our capture session stopped (`isRunning` false, no inputs or outputs, no frames after stop). The stop-notification and "session object freed" lines are **informational** (they depend on the run loop and timing). The green light is your visual answer.

### Do NOT use `--simulate` for the real test
The app has developer switches so the flow can be rehearsed with no camera (`--simulate`, `--sim-flip=yaw,pitch,roll`, `--sim-mirrored`, `--autorun-selftest`, `--exit-after-selftest`, `--mute`, `--lighting=normal|dim`, `--results-dir=PATH`, `--render-ui=PATH`). In `--simulate` mode a made-up person plays the script: **every number is fabricated**, a red "SIMULATED INPUT" banner is shown, the report and file name say SIMULATED, "Apply" is disabled, and saved signs are never loaded. If you see that banner you are not testing your camera: quit and launch without arguments (`open build/SpatialAudio.app`).

### What the guided self-test does not cover (do these by hand, section E)
Camera light after closing the window and after Cmd+Q (the app is gone, so it cannot check itself), what the permission prompt does after a rebuild, and anything odd you notice (crash, lag, heat).

## Report back
1. The pasted report (Copy report), for each lighting tag you ran.
2. Permission prompt: appeared once / appeared again after a rebuild / never.
3. Green light after the self-test ended: off / still on (the button you clicked is also in the report).
4. Window close and Cmd+Q: light off? (section E)
5. Anything odd: crashes, lag, heat, a prompt that did not make sense.

---

## Manual checklist (fallback; also what the self-test does not automate)

### Setup (manual route)
1. `scripts/make-app.sh debug` (or `release`), then `open build/SpatialAudio.app`.
2. Sit at your normal distance, face lit from the front, only your face in view.
3. Click **Start camera**. macOS should ask for camera permission (text: "SpatialAudio uses the camera …").
   - The app is ad-hoc signed, so macOS may ask again after every rebuild (expected; unverified).
   - If you denied it: System Settings > Privacy & Security > Camera.

### A. Basic operation
- [ ] Status becomes `running`; Camera shows "MacBook Air Camera"; the green camera light turns on.
- [ ] Frame rate shows roughly the camera rate (15–30 fps per the device formats). Note the number.
- [ ] State shows `LOCKED`, Faces = 1, and the arrow in the compass appears.
- [ ] "Frame mirrored / rotation" line: write down what it says (e.g. `false / 0°`).

### B. Sign convention (manual version of the self-test's sign check)
Hold each position, then return to looking at the screen. Press **Recenter** first while looking at the screen.
- [ ] Turn head LEFT (about 30°): **yaw goes positive**, arrow swings **left**.
- [ ] Turn head RIGHT: yaw negative, arrow swings right.
- [ ] Look UP (chin up): **pitch positive**. Look DOWN: pitch negative.
- [ ] Tilt head so your RIGHT ear goes down toward your right shoulder: **roll positive**. LEFT ear down: roll negative.

If any axis is backwards, tick that axis' **Invert** checkbox, repeat, and tell me which boxes had to be ticked and the "mirrored" value from section A.

### C. Behavior (manual version of the loss test)
- [ ] Recenter while looking at the screen: pose goes to about 0/0/0 smoothly (no snap).
- [ ] Cover the camera or leave the frame: state goes `HOLDING` (pose frozen) → `DECAYING` (eases to 0) → `STATIC` (0/0/0). Pose must never jump.
- [ ] Come back into frame: state returns to `LOCKED` and the pose blends in without a snap.
- [ ] Turn your head far (≥60° each side): note the angle where tracking is lost.
- [ ] Hold still: note roughly how many degrees the numbers wander. (Filter parameters are untuned placeholders.)
- [ ] Dim the room or backlight yourself: note whether tracking degrades or confidence changes.

### D. Latency readout
- [ ] Note "Capture→pose latency" and the delivery/vision split while idle and while moving.

### E. Camera release (the self-test checks the session in code; the light and the quit paths are yours)
- [ ] Click **Stop camera**: the green camera light goes off within about a second, and the HUD shows "Release check (programmatic)".
- [ ] Start again, then close the window (the app should quit): the light goes off.
- [ ] Start again, then Cmd+Q: the light goes off.
- [ ] After quitting, `ps aux | grep SpatialAudio` shows no leftover process.

### F. Quality signal and watchdog (optional)
- [ ] The HUD shows "Quality (our gate)" near 1.00 with "limited by: none" in normal use; note what it reads at your normal distance.
- [ ] Move your face to the very edge of the frame: quality drops, limiting factor `edge`; the pose holds instead of following.
- [ ] Lean far back so the face is small: limiting factor `size`.
- [ ] Shake your head very fast: does quality dip (`angular speed`/`center jump`)? Note whether tracking drops out too easily (thresholds are guesses).
- [ ] (Hard to trigger) If frames stop arriving entirely, the HUD should show "Frames NONE for … ms (watchdog)" in red and the pose should decay to neutral.
