# Step 2 manual camera test (needs you, your face, and the camera)

Nothing below has been run on a real camera by Claude. Every item is **UNVERIFIED** until you run it and report back.

## 0. Recommended: the guided self-test (real camera)

It replaces most of sections B, C and D below: it walks you through the moves with on-screen instructions, countdowns, a sound and a flash at each step, **coaches you live while you hold each move**, works out the sign each axis needs, checks the lose-face behavior, measures fps and latency, and saves a numbers-only report. **No camera images are saved anywhere.** Everything in it is **UNVERIFIED on hardware until a clean real run** (the two earlier real runs, 07:45 and 08:12, were not clean: see docs/STATUS.md, "Step 2d findings").

### What changed since the first real runs (Step 2d)
- **Smaller, single-axis moves with a target:** about **30° turn left, 20° chin up, 20° right-ear tilt**, 25° for the turn before the cover test. The first runs gave no target and produced 37-63° turns with other axes moving by up to the same amount.
- **Live coaching bars** under the countdown: one bar per axis (yaw / pitch / roll) showing how far you are from your starting pose, a green band for the target range, and one line of feedback: "A bit more", "Good", "Too far", or (Step 2e) a wrong-motion warning such as "You are turning your head (58°) instead of just tilting it. Tilt only: …". During the "back to center" and "stay still" phases it says "Steady", "Still moving" or "Not back at the centre". The bars show how FAR you moved, never which direction (the test is not allowed to know the sign).
- **The camera-cover test waits for a steady tracker.** After the turn, the screen says "WAITING FOR STEADY TRACKING" until tracking has been LOCKED for 1 second in a row (at most 10 s). If that never happens the run ends and the loss test is reported **INVALID** (not FAIL): it needs a locked start.
- **The green-light question is the first thing in the results** (yellow box at the top). Answer it right away: the app has already stopped the camera by itself. It is recorded as yes / no / **not answered**.

### Run it (real camera)
1. **Quit any SpatialAudio app that is already running (Cmd+Q).** An older instance (a build from before Step 2d) may still be open, and `open` would just bring that old window forward.
2. ```
   cd /Users/sanjais/ClaudeHome/SpatialAudio
   scripts/make-app.sh debug && open build/SpatialAudio.app
   ```
3. Plug in power, keep the lid open and the window in front (this Mac sleeps even with `caffeinate -i`; a sleep mid-test ruins the run).
4. In the "Guided self-test" card choose the lighting tag (**normal light** first; later repeat with **dim room**).
5. Click **Run self-test**. The first time, macOS asks for camera permission: click Allow (the test starts right after; "get ready" gives you 3 s).
6. Follow the screen and the sounds, and **watch the bars**: you will be looking away from the screen during the holds, so listen for the sounds, but a glance shows whether the bar is in the green band. About 47 s plus any wait:

| Seconds | Screen says | You do | Sound |
|---|---|---|---|
| 0–3 | GET READY | sit as you normally do, facing the screen | Glass |
| 3–5 | LOOK STRAIGHT AHEAD | look at the middle of the screen and stay completely still (this is the reference for the first moves) | Tink |
| 5–8, 10–13 | TURN LEFT — HOLD (1 of 2, 2 of 2) | turn your head toward YOUR left shoulder (the side of your left hand), about 30°, nothing else | Pop |
| 15–18, 20–23 | LOOK UP — HOLD (1 of 2, 2 of 2) | tilt your head back, chin up, about 20° (moving only your eyes does not count) | Pop |
| 25–28, 30–33 | TILT RIGHT EAR — HOLD (1 of 2, 2 of 2) | tilt your head so YOUR right ear goes down toward YOUR right shoulder, about 20°; face still points at the screen | Pop |
| 8–10, 13–15, 18–20, 23–25, 28–30, 33–35 | BACK TO CENTER | look straight at the screen, stay completely still: the NEXT hold is measured against this pose | Tink |
| 35–38 (+ wait) | TURN LEFT ABOUT 25° AND KEEP STILL | turn about 25° (a quarter of the way, not more) and hold still, even when the next sound plays; if it says WAITING FOR STEADY TRACKING keep still until it clears | Pop |
| next 5 s | COVER THE CAMERA NOW | put your hand flat over the camera lens; keep your head turned and still | Basso |
| next 4 s | UNCOVER THE CAMERA | take your hand away; keep your head turned and still | Ping |
| end | results appear | answer the yellow green-light question at the top | Hero |

   Why turn left during the cover test: if your head is at neutral when tracking is lost there is nothing for the pose to jump from, so "never jumps" would pass trivially. The report says when the held pose was too small to mean anything.
7. When it finishes, the app **stops the camera by itself** and shows the results. **Look at the green camera light now** and click **"Yes, the light is OFF"** or **"No, it is still ON"** in the yellow box at the top (the visual check no code can make). If you skip it the report says "not answered".
8. Click **Copy report** and paste it to Claude. Two files (`.json` and `.md`, numbers only) are also written to `docs/test-results/`; the HUD shows the exact path and **Show saved files** opens it. (Copy after answering the green-light question; if you copy first the copy says "NOT ANSWERED".)
9. Optional, after you have read the result: **Apply detected signs…** → confirm. This sets the invert flags for the axes that were **DETERMINED** (a LIKELY axis is never applied), saves them for next launch, and resets the filter and calibration. Then click **Start camera**, look at the screen, click **Recenter**, and verify by eye: turn LEFT → the arrow points left and yaw goes positive. The invert checkboxes stay available for manual override, and "Reset to documented defaults" undoes it.

### What changed in Step 2e (UNVERIFIED on hardware)
- **The coach warns about a wrong axis at any time.** Any axis you were NOT asked to move that is more than **15°** (an untuned placeholder) away from your starting pose is flagged, even before the asked-for axis has moved at all. The message names the motion: "You are turning your head (58°) instead of just tilting it", "You are nodding (27°) instead of just turning it", and so on. The wrong axis' bar, label and number turn **orange**; every axis over the limit is flagged, not only the worst one. Before this, the warning waited until your move was half done, so a tilt that was really a turn and a nod (real run, 14:58) got no warning.
- **The report is richer.** The `.md` (what Copy report gives) has a new **per phase** table under section 4: for every phase (baseline, each hold, each rest, and the loss-test phases) the face-box height (min / median / max), the quality (min / median), the share of frames below 0.40 and below 0.60, the limiting component, and the seconds the tracker spent LOCKED / HOLDING / DECAYING / STATIC. The `.json` (schema 3, about 210 KB) also holds a **per-frame series** of the whole run (time, raw Vision yaw / pitch / roll, box height, quality, tracker state): numbers only, no images. You do not need to paste the JSON; it is written next to the `.md` in `docs/test-results/`.

### How to read the result
- **DETERMINED** for an axis: both repetitions were large enough, steady, in the same direction, and did not leak into other axes. It reports the raw Vision sign during your move and whether that axis needs **invert ON**.
- **LIKELY (not applied)**: at least two repetitions had enough, steady movement and agree on the direction, but another axis moved too much. A hint only; repeat with a smaller, single-axis move.
- **INCONCLUSIVE**: the data was weak or inconsistent and it says why (movement too small, **reference window not steady**, hold not steady, repetitions disagree, wrong axis dominated, face lost during the hold, mirroring changed). Nothing is guessed; just repeat with a smaller, steadier move.
- The test cannot see which way you actually moved. If you tilted your LEFT ear by mistake, the roll result will be silently inverted. Read the prompts carefully ("YOUR left", "YOUR right ear").
- **Baseline statistics** table: for every repetition, the reference and hold windows (n, median, σ from the median absolute deviation, range, p10-p90, drift). A large σ or drift in a "stay still" window means you were still moving.
- Loss test: **PASS** = locked → holding → decaying → static → locked, once, with no pose step above the threshold. **FAIL** = a pose jump above the threshold or an impossible state transition. **INCOMPLETE** = the sequence was not completed (cover too short, partial cover, never reacquired). **INVALID** = tracking was not LOCKED before the cover cue (or never became locked), so the run says nothing about a clean loss: repeat it. "jump check is WEAK" means the held pose was too close to neutral.
- **Evidence around the largest pose step**: ±8 frames shown (±15 in the JSON) of raw Vision angles, mapped angles, output pose, state, quality, limiting component, with a description of the SHAPE (spike / multi-frame movement / abrupt and sustained / face appeared or vanished / output-only).
- **Per phase** table (section 4): one row per phase, whole phase (not just its analysis window). "Box h" is the face-box height as a fraction of the frame height; with the default quality settings the size score is 0 at 0.10 and 1 at 0.20, so a box under 0.20 lowers quality. The state seconds add up to the phase length. Use it to see, for example, whether the tracker left LOCKED during a hold.
- **Tracking quality: which component limited it**: for each group of phases, the share of frames in which each component (size, edge, center jump, scale jump, angular speed, frame rate, vision confidence, "no face") was the weakest, and which were limiting when quality was low.
- Latency is "sample timestamp → pose ready" and excludes any delay before the camera stamps the frame. Frame-interval, delivery, Vision and total are shown as mean / p95 / max over a 30 s window (the 12 hold and rest phases).
- All thresholds are untuned proposals; they are printed at the bottom of every report.
- The "Camera release" check proves our capture session stopped (`isRunning` false, no inputs or outputs, no frames after stop). The stop-notification and "session object freed" lines are **informational** (they depend on the run loop and timing). The green light is your visual answer.

### Do NOT use `--simulate` for the real test
The app has developer switches so the flow can be rehearsed with no camera (`--simulate`, `--sim-flip=yaw,pitch,roll`, `--sim-mirrored`, `--autorun-selftest`, `--exit-after-selftest`, `--mute`, `--lighting=normal|dim`, `--results-dir=PATH`, `--render-ui=PATH`). In `--simulate` mode a made-up person plays the script: **every number is fabricated**, a red "SIMULATED INPUT" banner is shown, the report and file name say SIMULATED, "Apply" is disabled, and saved signs are never loaded. If you see that banner you are not testing your camera: quit and launch without arguments (`open build/SpatialAudio.app`). Simulated report files are never committed (`.gitignore` excludes them).

### What the guided self-test does not cover (do these by hand, section E)
Camera light after closing the window and after Cmd+Q (the app is gone, so it cannot check itself), what the permission prompt does after a rebuild, and anything odd you notice (crash, lag, heat).

## Report back
1. The pasted report (Copy report, after answering the green-light question), for each lighting tag you ran. A report with blanks or placeholders is not a result. (The `.json` with the per-frame series stays on disk in `docs/test-results/`; the `.md` is enough to paste.)
2. Permission prompt: appeared once / appeared again after a rebuild / never.
3. Green light after the self-test ended: yes it went off / no it stayed on (the answer is also in the report; "not answered" means you did not click).
4. Window close and Cmd+Q: light off? (section E)
5. How the coaching felt: did the bars and the messages match what you were doing? Anything confusing or in the way?
6. Anything odd: crashes, lag, heat, a prompt that did not make sense.

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
