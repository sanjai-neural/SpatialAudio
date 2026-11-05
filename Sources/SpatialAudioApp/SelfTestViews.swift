import SwiftUI
import SpatialAudioCore
import SpatialAudioTracking

// MARK: - Small building blocks (plain SwiftUI so they also render in layout reviews)

struct SectionCard<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ProgressBar: View {
    var value: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule().fill(tint).frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 10)
    }
}

// MARK: - Launcher

struct SelfTestLauncher: View {
    @Bindable var controller: SelfTestController
    var model: HeadTrackingModel

    var body: some View {
        SectionCard(title: "Guided self-test") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Walks you through about 50 seconds: look ahead, turn left, look up and tilt your right ear (twice each), then turn slightly left and cover the camera. It works out the sign each axis needs, measures latency and frame rate, and saves a numbers-only report. No camera images are saved anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("Lighting", selection: $controller.lighting) {
                        ForEach(LightingTag.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                    .disabled(controller.isBusy)
                    Button(model.isSimulated ? "Run self-test (SIMULATED)" : "Run self-test") { controller.run() }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.isBusy)
                }
                if let m = controller.message {
                    Text(m).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }
}

// MARK: - Run panel (big, readable from the side)

struct SelfTestRunPanel: View {
    var controller: SelfTestController
    var model: HeadTrackingModel

    var body: some View {
        VStack(spacing: 14) {
            if let st = controller.status {
                Text("Step \(st.phaseIndex + 1) of \(st.phaseCount)").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Text(symbol(for: st.phase)).font(.system(size: 54))
                    Text(st.phase.title)
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .multilineTextAlignment(.leading)
                }
                Text(st.phase.instruction)
                    .font(.title3).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if st.isWaitingForLock {
                    VStack(spacing: 6) {
                        Text("WAITING FOR STEADY TRACKING").font(.title.bold()).foregroundStyle(.orange)
                        Text(String(format: "Keep your head turned and still. The camera test starts once tracking has been LOCKED for %.0f s in a row.", st.lockSecondsNeeded))
                            .font(.callout).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        ProgressBar(value: st.lockSecondsNeeded > 0 ? st.lockedSeconds / st.lockSecondsNeeded : 0, tint: .green)
                        Text(String(format: "locked for %.1f of %.0f s   ·   waiting %.0f of at most %.0f s", st.lockedSeconds, st.lockSecondsNeeded, st.waitedSeconds, st.waitSecondsAllowed))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(Int(st.secondsRemainingInPhase.rounded(.up)))")
                        .font(.system(size: 96, weight: .bold, design: .rounded)).monospacedDigit()
                    ProgressBar(value: st.phaseProgress, tint: color)
                }
                HStack(spacing: 8) {
                    Text("overall").font(.caption).foregroundStyle(.secondary)
                    ProgressBar(value: st.overallProgress, tint: .secondary)
                }
                if let fb = controller.coach { CoachBars(feedback: fb) }
            } else {
                Text("Starting…").font(.title2)
                if let m = controller.message { Text(m).font(.caption).foregroundStyle(.secondary) }
            }
            liveLine
            Button("Abort self-test") { controller.abort() }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.22), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            // Brief white flash at the start of every phase: a visual cue in addition to the sound.
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(flashOpacity))
                .allowsHitTesting(false)
        }
    }

    private var flashOpacity: Double {
        guard let el = controller.status?.phaseElapsed else { return 0 }
        return max(0, 0.65 - el / 0.45)
    }

    private var color: Color {
        switch controller.status?.phase.kind {
        case .getReady, nil: .gray
        case .baseline, .uncover: .green
        case .hold, .lossTurn: .orange
        case .rest: .blue
        case .cover: .red
        }
    }

    private func symbol(for phase: SelfTestPhase) -> String {
        switch phase.kind {
        case .getReady: "⏳"
        case .baseline, .rest: "●"
        case .hold:
            switch phase.move { case .turnLeft?: "⬅︎"; case .lookUp?: "⬆︎"; case .tiltRightEar?: "↘︎"; case nil: "●" }
        case .lossTurn: "⬅︎"
        case .cover: "✋"
        case .uncover: "👁"
        }
    }

    private var liveLine: some View {
        let s = model.snapshot
        return HStack(spacing: 12) {
            Text("tracking:").foregroundStyle(.secondary)
            Text(s.map { $0.state.rawValue.uppercased() } ?? "—").bold()
            Text(s.map { String(format: "quality %.2f (%@)", $0.quality.overall, $0.quality.limiting) } ?? "")
            Text(s.map { $0.facesDetected > 0 ? "face found" : "no face" } ?? "")
        }
        .font(.system(.caption, design: .monospaced))
    }
}

// MARK: - Results

struct SelfTestResultView: View {
    @Bindable var controller: SelfTestController
    var model: HeadTrackingModel

    var body: some View {
        if let r = controller.report {
            VStack(alignment: .leading, spacing: 12) {
                greenLightBanner(r)
                header(r)
                signsSection(r)
                applySection(r)
                lossSection(r)
                statsSection(r)
                qualitySection(r)
                releaseSection(r)
                actions(r)
            }
        }
    }

    // MARK: sections

    private func header(_ r: SelfTestReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Self-test result — \(r.lighting.rawValue)").font(.title2.bold())
            if r.isSimulated {
                Text("SIMULATED INPUT — not camera data. These numbers say nothing about your hardware.")
                    .font(.callout.bold()).foregroundStyle(.red)
            }
            Text(r.createdAt).font(.caption).foregroundStyle(.secondary)
            if let err = controller.saveError {
                Text(err).font(.caption).foregroundStyle(.red)
            } else if let dir = controller.savedFiles.first?.deletingLastPathComponent().path {
                Text("Saved (numbers only): \(dir)/\(controller.savedFiles.map(\.lastPathComponent).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let m = controller.message { Text(m).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func signsSection(_ r: SelfTestReport) -> some View {
        SectionCard(title: "1. Signs — target: turn LEFT = +yaw, look UP = +pitch, tilt RIGHT ear down = +roll") {
            VStack(alignment: .leading, spacing: 8) {
                axisRow("YAW  (turn left)", r.signs.yaw)
                axisRow("PITCH  (look up)", r.signs.pitch)
                axisRow("ROLL  (right ear down)", r.signs.roll)
                Text("Assumes you moved in the instructed direction; the test cannot see which way you actually went.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private func axisRow(_ label: String, _ x: AxisSignResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(label).bold().frame(width: 170, alignment: .leading)
                if x.outcome == .determined, let sign = x.rawVisionSign, let invert = x.invertNeeded {
                    Text("DETERMINED").bold().foregroundStyle(.green)
                    Text("raw Vision sign during the move: \(sign > 0 ? "+" : "−")  →  invert: \(invert ? "ON" : "off")")
                } else if x.outcome == .likely, let sign = x.rawVisionSign {
                    Text("LIKELY — not applied").bold().foregroundStyle(.yellow)
                    Text("raw sign \(sign > 0 ? "+" : "−") in every repetition with enough movement, but other axes moved too")
                } else {
                    Text("INCONCLUSIVE").bold().foregroundStyle(.orange)
                }
            }
            Text(x.repetitions.enumerated().map { (i, rep) in
                rep.referenceSamples == 0 && rep.holdSamples == 0
                    ? "rep \(i + 1): no data"
                    : String(format: "rep %d: %+.1f°  (leak %.2f)%@", i + 1, rep.intendedDeltaDegrees, rep.leakageRatio, rep.usable ? "" : "  ✗")
            }.joined(separator: "     "))
            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            ForEach(x.reasons, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func applySection(_ r: SelfTestReport) -> some View {
        SectionCard(title: "2. Apply the detected signs?") {
            VStack(alignment: .leading, spacing: 8) {
                if r.isSimulated {
                    Text("Simulated run: signs can not be applied.").font(.callout)
                } else if r.signs.determinedAxes.isEmpty {
                    Text("No axis was DETERMINED, so there is nothing to apply. Nothing was guessed" + (r.signs.likelyAxes.isEmpty ? "." : "; LIKELY results are hints and are never applied.")).font(.callout)
                } else if let detected = controller.detectedMapping {
                    Text("Detected invert flags: " + flags(detected) + "   (inconclusive axes keep their current setting)")
                        .font(.system(.callout, design: .monospaced))
                    Text("In effect now:         " + flags(model.mapping))
                        .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    if detected == model.mapping {
                        Text("These are already in effect. You can still apply them to save them as the defaults.").font(.caption)
                    }
                    if controller.confirmingApply {
                        Text("Apply these as the app's sign defaults and remember them for next time? This resets the filter and calibration; afterwards press Recenter.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Yes, apply") { controller.confirmApply() }.buttonStyle(.borderedProminent)
                            Button("Cancel") { controller.cancelApply() }
                        }
                    } else {
                        Button("Apply detected signs…") { controller.requestApply() }
                    }
                }
                if let note = controller.appliedNote { Text(note).font(.callout).foregroundStyle(.green) }
                Text("The invert checkboxes above stay available for manual override.").font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private func lossSection(_ r: SelfTestReport) -> some View {
        let l = r.loss
        return SectionCard(title: "3. Loss test (turn ~25° left, cover the camera, uncover)") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(l.verdict.rawValue.uppercased()).bold().foregroundStyle(verdictColor(l.verdict))
                    Text(l.observedSequence.joined(separator: " → ")).font(.system(.callout, design: .monospaced))
                }
                if let why = l.invalidReason {
                    Text("INVALID: " + why).font(.caption.bold()).foregroundStyle(.purple).fixedSize(horizontal: false, vertical: true)
                }
                Text(String(format: "time in state: holding %.2f s (configured %.2f), decaying %.2f s (configured %.2f), static %.2f s",
                            l.secondsInState.holding, l.expectedHoldSeconds, l.secondsInState.decaying, l.expectedDecaySeconds,
                            l.secondsInState.staticState)).font(.caption)
                Text("holding → static: \(l.timeToStaticSeconds.map { String(format: "%.2f s", $0) } ?? "n/a");  reacquire after the uncover cue: \(l.reacquireSecondsAfterUncoverCue.map { String(format: "%.2f s (includes your reaction time)", $0) } ?? "n/a")")
                    .font(.caption)
                Text(String(format: "largest frame-to-frame pose step: %.2f° (threshold %.1f°) → %@", l.maxFrameJumpDegrees,
                            l.jumpThresholdDegrees, l.jumpFlagged ? "JUMP FLAGGED" : "no jump"))
                    .font(.caption.bold()).foregroundStyle(l.jumpFlagged ? .red : .primary)
                Text("held pose was \(l.heldPoseTravelDegrees.map { String(format: "%.1f°", $0) } ?? "n/a") from neutral" + (l.jumpCheckMeaningful ? "" : "  — jump check is WEAK"))
                    .font(.caption).foregroundStyle(l.jumpCheckMeaningful ? Color.secondary : Color.orange)
                ForEach(l.notes, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let ev = l.stepEvidence {
                    Text("largest step — shape: \(ev.classification.kind.rawValue). \(ev.classification.explanation) (the full window of raw / mapped / output angles is in the saved JSON)")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private func qualitySection(_ r: SelfTestReport) -> some View {
        SectionCard(title: "5. Tracking quality — which component limited it") {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(r.qualityByPhase ?? [], id: \.name) { g in
                    let top = g.limitingFractions.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3)
                        .map { String(format: "%@ %.0f%%", $0.key, $0.value * 100) }.joined(separator: ", ")
                    Text(String(format: "%@: mean %.2f, min %.2f, below loss threshold %.0f%% — %@", g.name, g.meanQuality, g.minQuality, g.fractionBelowLossThreshold * 100, top))
                        .font(.system(.caption, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                }
                Text("Component names: size, edge, center jump, scale jump, angular speed, frame rate, vision confidence; \"none\" = all fine, \"no face\" = nothing detected.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private func statsSection(_ r: SelfTestReport) -> some View {
        let s = r.stats
        return SectionCard(title: "4. Statistics — \(String(format: "%.0f", s.windowSeconds)) s window, \(r.lighting.rawValue)") {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "frames %d · face found in %.0f%% · mean quality %.2f · mean fps %@", s.frameCount,
                            s.facePresentFraction * 100, s.meanQuality, s.fpsMean.map { String(format: "%.1f", $0) } ?? "n/a"))
                    .font(.caption)
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 2) {
                    GridRow { Text(""); Text("mean"); Text("p95"); Text("max") }.foregroundStyle(.secondary)
                    seriesRow("frame interval ms", s.frameIntervalMs)
                    seriesRow("delivery ms", s.deliveryMs)
                    seriesRow("vision ms", s.visionMs)
                    seriesRow("total ms", s.totalMs)
                }
                .font(.system(.caption, design: .monospaced))
                ForEach(s.notes, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.orange) }
                Text("total = sample timestamp → pose ready; excludes any delay before the camera stamps the frame.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private func seriesRow(_ label: String, _ s: SeriesSummary?) -> some View {
        GridRow {
            Text(label).frame(width: 150, alignment: .leading)
            Text(s.map { String(format: "%.1f", $0.mean) } ?? "—")
            Text(s.map { String(format: "%.1f", $0.p95) } ?? "—")
            Text(s.map { String(format: "%.1f", $0.max) } ?? "—")
        }
    }

    private func releaseSection(_ r: SelfTestReport) -> some View {
        SectionCard(title: "6. Camera release") {
            VStack(alignment: .leading, spacing: 6) {
                if r.isSimulated {
                    Text("Simulated run: there is no camera hardware to release.").font(.caption)
                } else if controller.releaseCheckRunning {
                    Text("The camera was stopped; checking the capture session…").font(.caption)
                } else if let rel = r.cameraRelease {
                    Text((rel.isClean ? "PROGRAMMATIC CHECK: CLEAN" : "PROGRAMMATIC CHECK: NOT CLEAN") +
                         " — session isRunning after stop = \(rel.isRunningAfterStop), inputs = \(rel.inputsAfterStop), outputs = \(rel.outputsAfterStop), frames after stop = \(rel.callbacksAfterStop)  (informational: session object freed = \(rel.sessionObjectDeallocated), stop notifications = \(rel.stopNotificationsObserved))")
                        .font(.caption.bold()).foregroundStyle(rel.isClean ? .green : .red)
                    greenLightQuestion(r)
                } else {
                    Text("No release report available.").font(.caption)
                }
                Text("This proves the app's capture session stopped. Whether the physical green camera light is off is a visual check no code can make.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    @ViewBuilder
    private func greenLightQuestion(_ r: SelfTestReport) -> some View {
        switch r.greenLight {
        case .notAsked: Text("Green light: not asked.").font(.callout).foregroundStyle(.secondary)
        case .notAnswered: Text("Green light: NOT ANSWERED yet — see the question at the top.").font(.callout.bold()).foregroundStyle(.orange)
        case .off: Text("You reported: green light OFF ✓").font(.callout).foregroundStyle(.green)
        case .stillOn: Text("You reported: green light STILL ON ✗ — tell Claude").font(.callout.bold()).foregroundStyle(.red)
        }
    }

    /// The question comes first, as soon as the results appear: the app has already stopped the camera by itself at this point, so
    /// the light should be going off right now. (In the two real reports of 2026-11-05 this sat at the bottom of the screen and
    /// went unanswered.)
    @ViewBuilder
    private func greenLightBanner(_ r: SelfTestReport) -> some View {
        if !r.isSimulated {
            switch r.greenLight {
            case .notAsked, .notAnswered:
                VStack(alignment: .leading, spacing: 6) {
                    Text("LOOK AT THE CAMERA LIGHT NOW").font(.title3.bold())
                    Text("The app stopped the camera when the test ended. Is the green light next to the camera OFF (it may take about a second)?")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Yes, the light is OFF") { controller.answerGreenLight(isOff: true) }.buttonStyle(.borderedProminent)
                        Button("No, it is still ON") { controller.answerGreenLight(isOff: false) }
                        Text("Unanswered is recorded as \"not answered\".").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
            case .off:
                Text("Green light: you reported OFF ✓").font(.callout.bold()).foregroundStyle(.green)
            case .stillOn:
                Text("Green light: you reported STILL ON ✗ — tell Claude").font(.callout.bold()).foregroundStyle(.red)
            }
        }
    }

    private func actions(_ r: SelfTestReport) -> some View {
        HStack {
            Button("Copy report") { controller.copyReport() }.buttonStyle(.borderedProminent)
            Button("Show saved files") { controller.revealFiles() }.disabled(controller.savedFiles.isEmpty)
            Button("Dismiss") { controller.dismissResults() }
        }
    }

    // MARK: helpers

    private func flags(_ m: HeadAngleMapping) -> String {
        "yaw \(m.invertYaw ? "ON " : "off") · pitch \(m.invertPitch ? "ON " : "off") · roll \(m.invertRoll ? "ON " : "off")"
    }

    private func verdictColor(_ v: LossVerdict) -> Color {
        switch v { case .pass: .green; case .fail: .red; case .incomplete: .orange; case .invalid: .purple }
    }
}


// MARK: - Live coaching bars

/// Per-axis deviation from the starting pose with the target band, plus one line of feedback. Plain SwiftUI shapes (no AppKit-backed
/// controls) so the layout can also be reviewed with the in-process renderer.
struct CoachBars: View {
    var feedback: CoachFeedback

    private let scaleDegrees = 60.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let dev = feedback.deviationDegrees {
                ForEach(RotationAxis.allCases, id: \.self) { axis in row(axis, dev[axis]) }
            }
            Text(feedback.message)
                .font(.title3.bold()).foregroundStyle(color(for: feedback.verdict))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ axis: RotationAxis, _ value: Double) -> some View {
        let instructed = feedback.instructedAxis == axis
        let flagged = feedback.flaggedAxes.contains(axis)          // every wrong axis over its limit, not only the worst one
        return HStack(spacing: 8) {
            Text(axis.rawValue.uppercased()).font(.system(.caption, design: .monospaced).bold()).frame(width: 44, alignment: .leading)
                .foregroundStyle(flagged ? Color.orange : Color.primary)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.15))
                    if instructed, let t = feedback.targetDegrees {
                        let lo = CoachConfig().goodFromFraction * t / scaleDegrees, hi = min(1, CoachConfig().tooFarFraction * t / scaleDegrees)
                        Rectangle().fill(Color.green.opacity(0.30)).frame(width: w * (hi - lo)).offset(x: w * lo)
                        Rectangle().fill(Color.green).frame(width: 2).offset(x: w * min(1, t / scaleDegrees))
                    }
                    Capsule().fill(instructed ? color(for: feedback.verdict) : (flagged ? Color.orange : Color.gray))
                        .frame(width: w * min(max(value / scaleDegrees, 0), 1))
                }
            }
            .frame(height: 12)
            Text(String(format: "%3.0f°", value)).font(.system(.caption, design: .monospaced).weight(flagged ? .bold : .regular))
                .foregroundStyle(flagged ? Color.orange : Color.primary).frame(width: 40, alignment: .trailing)
        }
    }

    private func color(for v: CoachVerdict) -> Color {
        switch v {
        case .good, .steady: .green
        case .tooSmall, .notCentered: .yellow
        case .tooFar: .red
        case .otherAxisMoving, .stillMoving: .orange
        case .noFace: .gray
        }
    }
}
