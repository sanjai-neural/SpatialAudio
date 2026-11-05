import SwiftUI
import SpatialAudioCore

/// The audio-only listening test card (Step 3a). Nothing here touches the camera.
struct AudioTestCard: View {
    var model: AudioTestModel

    var body: some View {
        SectionCard(title: "Audio listening test — scripted head, NO camera") {
            VStack(alignment: .leading, spacing: 8) {
                Text("A fixed virtual tone is rendered with HRTF while a scripted, synthetic head moves. Put HEADPHONES on and set the system volume LOW first (start with the slider low, too). With AirPods or Beats, switch their Spatial Audio / head tracking OFF for this test, or the system will add its own head tracking on top.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Test", selection: Binding(get: { model.selected }, set: { model.select($0) })) {
                    ForEach(ListeningTest.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)

                Text(model.selected.whatYouShouldHear)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 14) {
                    if model.isRunning {
                        Button("Stop") { model.stop() }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Start listening test") { model.start() }.buttonStyle(.borderedProminent)
                    }
                    Text("Volume").font(.caption)
                    Slider(value: Binding(get: { model.volume }, set: { model.setVolume($0) }), in: 0...1)
                        .frame(width: 180)
                    Text(String(format: "%.0f%%", model.volume * 100)).font(.caption).monospacedDigit()
                }

                HStack(spacing: 12) {
                    Text("Sounds mirrored or backwards? Flip:").font(.caption)
                    Toggle("yaw (left ↔ right)", isOn: Binding(get: { model.flips.invertYaw }, set: { model.setFlip(yaw: $0) }))
                    Toggle("pitch (up ↔ down)", isOn: Binding(get: { model.flips.invertPitch }, set: { model.setFlip(pitch: $0) }))
                    Toggle("roll", isOn: Binding(get: { model.flips.invertRoll }, set: { model.setFlip(roll: $0) }))
                    Button("Reset flips") { model.resetFlips() }.font(.caption)
                }
                .toggleStyle(.checkbox)

                if case .failed(let why) = model.state {
                    Text(why).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if model.isRunning { readoutView }
                Text("Everything here is UNVERIFIED until you have listened. The flips are for diagnosis: if you need one, tell Claude which, and the fix goes into the conversion and its tests, not into this switch.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
    }

    private var readoutView: some View {
        let r = model.readout
        return VStack(alignment: .leading, spacing: 3) {
            Text(r.scriptTime).foregroundStyle(.secondary)
            Text("HEAD:  \(r.head)").bold()
            Text("EXPECTED:  \(r.expected)").foregroundStyle(.green)
            Text(r.sent).foregroundStyle(.secondary)
            Text(r.timing).foregroundStyle(.secondary)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
