import SwiftUI
import SpatialAudioCore

/// The blind listening test card (Step 3a-2). You answer with buttons only; the app records the answers and writes the report. Nothing here shows what the
/// right answer is while the test runs, and nothing touches the camera.
struct BlindListeningCard: View {
    var model: BlindListeningModel

    var body: some View {
        SectionCard(title: "Blind listening test — buttons only, NO camera") {
            VStack(alignment: .leading, spacing: 10) {
                switch model.stage {
                case .idle, .failed: intro
                case .running: running
                case .questions: questions
                case .saved: saved
                }
                if case .failed(let why) = model.stage {
                    Text(why).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Text("IMPLEMENTED-UNVERIFIED: not yet run by a person. The report holds numbers only (no device names, no paths); its fade steps and timing are measured on your Mac only when you run it.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("20 short tones, one at a time, in a random order. After each one press where it seems to be: Left ear, Right ear, Middle, or Can't tell. Do not guess to please the test: \"Can't tell\" is a good answer. Put HEADPHONES on first and set the system volume LOW. With AirPods or Beats, switch Spatial Audio / head tracking OFF. It takes about 2 minutes. Sit still: the head you hear moving is a scripted one.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button("Start blind test") { model.start() }.buttonStyle(.borderedProminent)
                Text("Volume").font(.caption)
                Slider(value: Binding(get: { model.volume }, set: { model.setVolume($0) }), in: 0...1).frame(width: 180)
                Text(String(format: "%.0f%%", model.volume * 100)).font(.caption).monospacedDigit()
            }
        }
    }

    private var running: some View {
        let f = model.frame
        let n = (f?.completedTrials ?? 0) + ((f?.inTrial ?? false) ? 1 : 0)
        let total = f?.totalTrials ?? 20
        return VStack(alignment: .leading, spacing: 8) {
            Text("Tone \(min(max(n, 1), total)) of \(total)").font(.headline).monospacedDigit()
            Text((f?.answerEnabled ?? false) ? "Where does the tone seem to be?" : "Listen…")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(BlindAnswer.buttons, id: \.self) { a in
                    Button(label(a)) { model.answer(a) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!(f?.answerEnabled ?? false))
                }
                Spacer()
                Button("Stop") { model.requestStop() }
            }
        }
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.completed ? "Done. Three last questions (any you skip are recorded as “not answered”):" : "Stopped early. Three last questions (any you skip are recorded as “not answered”):")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            ForEach(model.summary, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            questionRow("Did you hear clicks or crackling?", options: BlindYesNo.allCases.filter { $0 != .notAnswered },
                        selected: model.endAnswers.clicksOrCrackling, label: { $0 == .yes ? "Yes" : "No" }, set: model.setClicks)
            questionRow("Did the tone seem inside your head or outside it?", options: BlindHeadLocation.allCases.filter { $0 != .notAnswered },
                        selected: model.endAnswers.soundLocation, label: { $0 == .inside ? "Inside" : "Outside" }, set: model.setLocation)
            questionRow("Were AirPods' Spatial Audio / head tracking…", options: BlindAirPodsState.allCases.filter { $0 != .notAnswered },
                        selected: model.endAnswers.airPodsSpatialAudio, label: { $0 == .off ? "Off" : $0 == .on ? "On" : "Not using AirPods" }, set: model.setAirPods)
            Button("Save report") { model.saveReport(resultsDirectory: LaunchOptions.current.resultsDirectory) }.buttonStyle(.borderedProminent)
        }
    }

    private var saved: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Report written:").font(.callout.bold())
            ForEach(model.savedPaths, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            Text("Tell Claude the file name. Headphone make and model are not recorded: note them yourself if you want them.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Run again") { model.reset() }
        }
    }

    private func label(_ a: BlindAnswer) -> String {
        switch a { case .leftEar: "Left ear"; case .rightEar: "Right ear"; case .middle: "Middle"; case .cantTell: "Can't tell"; case .notAnswered: "" }
    }

    private func questionRow<T: Hashable>(_ title: String, options: [T], selected: T, label: @escaping (T) -> String, set: @escaping (T) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 300, alignment: .leading)
            ForEach(options, id: \.self) { o in
                Button(label(o)) { set(o) }
                    .buttonStyle(.bordered)
                    .tint(o == selected ? .accentColor : nil)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(o == selected ? Color.accentColor : .clear, lineWidth: 2))
            }
        }
    }
}
