import SwiftUI
import SpatialAudioCore

/// The head-tracked listening card (Step 3b). One Start, one Stop, Recenter, a low capped volume and live readouts. No report, no guided test.
struct TrackedListeningCard: View {
    var model: TrackedListeningModel
    var head: HeadTrackingModel

    var body: some View {
        SectionCard(title: "Head-tracked listening — the CAMERA moves the sound (yaw and pitch; roll fixed at 0)") {
            VStack(alignment: .leading, spacing: 8) {
                if head.isSimulated {
                    Text("SIMULATED INPUT — no camera is used; the head is a made-up person.")
                        .font(.caption.bold()).foregroundStyle(.white).padding(6).frame(maxWidth: .infinity).background(Color.red, in: RoundedRectangle(cornerRadius: 6))
                }
                Text("A steady noise sits 2 m straight ahead, fixed in the room like a loudspeaker. Turn your head LEFT and it should move toward your RIGHT ear. Put HEADPHONES on, set the system volume LOW, and switch AirPods / Beats Spatial Audio OFF (the system would add its own head tracking). Start opens the camera and the sound together; Stop releases both. Do the two left/right checks of docs/MANUAL_TEST_STEP3B.md first.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 14) {
                    if model.isActive {
                        Button("Stop") { model.stopFromButton() }.buttonStyle(.borderedProminent).disabled(model.stage == .starting)
                    } else {
                        Button("Start head-tracked listening") { Task { await model.start() } }.buttonStyle(.borderedProminent)
                    }
                    Button("Recenter") { model.recenter() }.disabled(!model.isRunning)
                    Text("Volume").font(.caption)
                    Slider(value: Binding(get: { model.volume }, set: { model.setVolume($0) }), in: 0...TrackedListeningPolicy.maximumVolume).frame(width: 150)
                    Text(String(format: "%.0f%% (cap %.0f%%)", model.volume * 100, TrackedListeningPolicy.maximumVolume * 100)).font(.caption).monospacedDigit()
                }
                if let m = head.recenterMessage, model.isRunning { Text(m).font(.caption).foregroundStyle(.secondary) }

                switch model.stage {
                case .failed(let why): Text(why).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                case .starting: Text("Starting the camera and the sound…").font(.caption).foregroundStyle(.secondary)
                default: EmptyView()
                }
                if model.isRunning { readoutView }
                releaseLine
                Text("IMPLEMENTED-UNVERIFIED: whether the sound follows your head, and how it sounds, is unknown until you listen. Camera frame rate varies between sessions for an unknown reason; it is shown live and not compensated. No latency has been measured.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
    }

    private var readoutView: some View {
        let r = model.readout
        return VStack(alignment: .leading, spacing: 3) {
            Text(r.haveSent ? String(format: "SENT TO THE RENDERER:  yaw %+6.1f°   pitch %+6.1f°   roll %+6.1f° (fixed at 0)", r.sentYaw, r.sentPitch, r.sentRoll) : "SENT TO THE RENDERER:  —").bold()
            Text(String(format: "tracking: %@   face: %@   camera: %.1f fps%@", r.state, r.facePresent ? "yes" : "no", r.fps, r.frameAge > 0 ? String(format: "   (no frame for %.2f s)", r.frameAge) : ""))
            Text(r.pumpTicks > 0 ? String(format: "pose pump: %d ticks, mean %.2f ms, longest %.1f ms   poses published: %d%@", r.pumpTicks, r.pumpMeanMs, r.pumpMaxMs, r.published, r.rejected > 0 ? "   REFUSED (not finite): \(r.rejected)" : "") : "pose pump: starting…")
                .foregroundStyle(.secondary)
            Text("mapping: default, no invert (yaw and pitch confirmed by Sanjai).  Tracking state HOLDING / DECAYING / STATIC after the face is lost: the sound holds, eases back to the front, and stays there.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var releaseLine: some View {
        if head.releaseCheckPending {
            Text("Camera stopped; checking the capture session…").font(.caption).foregroundStyle(.secondary)
        } else if !model.isActive, let r = head.releaseReport {
            Text((r.isClean ? "Camera release check (programmatic): CLEAN" : "Camera release check (programmatic): NOT CLEAN") +
                 " — isRunning=\(r.isRunningAfterStop), inputs=\(r.inputsAfterStop), outputs=\(r.outputsAfterStop), frames after stop=\(r.callbacksAfterStop). The green light is still a visual check.")
                .font(.caption).foregroundStyle(r.isClean ? .green : .red)
        }
    }
}
