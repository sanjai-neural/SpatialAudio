# Step 2 manual camera test (needs you, your face, and the camera)

Nothing below has been run by Claude. Every item is UNVERIFIED until you do it and report back.

## Setup
1. `scripts/make-app.sh debug` (or `release`), then `open build/SpatialAudio.app`.
2. Sit at your normal distance, face lit from the front, only your face in view.
3. Click **Start camera**. macOS should ask for camera permission (text: "SpatialAudio uses the camera …").
   - The app is ad-hoc signed, so macOS may ask again after every rebuild (expected; unverified).
   - If you denied it: System Settings > Privacy & Security > Camera.

## A. Basic operation
- [ ] Status becomes `running`; Camera shows "MacBook Air Camera"; the green camera light turns on.
- [ ] Frame rate shows roughly the camera rate (15–30 fps per the device formats). Note the number.
- [ ] State shows `LOCKED`, Faces = 1, and the arrow in the compass appears.
- [ ] "Frame mirrored / rotation" line: write down what it says (e.g. `false / 0°`).

## B. Sign convention (the main exit criterion). Look at the HUD "Pose" line and the arrow
Hold each position, then return to looking at the screen. Press **Recenter** first while looking at the screen.
- [ ] Turn head LEFT (about 30°, keep your eyes on the HUD via peripheral vision): **yaw goes positive**, arrow swings **left**.
- [ ] Turn head RIGHT: yaw negative, arrow swings right.
- [ ] Look UP (chin up): **pitch positive**.
- [ ] Look DOWN: pitch negative.
- [ ] Tilt head so your RIGHT ear goes down toward your right shoulder: **roll positive**.
- [ ] Tilt LEFT ear down: roll negative.

If any axis is backwards, tick that axis' **Invert** checkbox, repeat, and tell me which boxes had to be ticked and the "mirrored" value from section A. I will then hard-code the correct default (and remove the guess).

## C. Behavior
- [ ] Recenter while looking at the screen: pose goes to about 0/0/0 smoothly (no snap).
- [ ] Cover the camera or leave the frame: state goes `HOLDING` (pose frozen) → `DECAYING` (eases to 0) → `STATIC` (0/0/0). Pose must never jump.
- [ ] Come back into frame: state returns to `LOCKED` and the pose blends in without a snap.
- [ ] Turn your head far (≥60° each side): note the angle where tracking is lost.
- [ ] Look for jitter when holding still: note roughly how many degrees the numbers wander. (Filter parameters are untuned placeholders.)
- [ ] Dim the room or backlight yourself: note whether tracking degrades or confidence changes (confidence may stay 1.00; Apple says it may).

## D. Latency readout (a measurement, not a spec)
- [ ] Note "Capture→pose latency" and the delivery/vision split while idle and while moving. These exclude any delay before the sample timestamp; proper end-to-end measurement is Step 5.

## E. Camera release
- [ ] Click **Stop camera**: the green camera light goes off within about a second.
- [ ] Start again, then close the window (the app should quit): the light goes off.
- [ ] Start again, then Cmd+Q: the light goes off.
- [ ] After quitting, `ps aux | grep SpatialAudio` shows no leftover process.

## Report back
The sign results (and which Invert boxes you needed), the section A "mirrored/rotation" line, fps, latency numbers, wander in degrees, loss-of-tracking angle, and anything unexpected.
