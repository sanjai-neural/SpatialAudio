import SwiftUI
import SpatialAudioCore
import SpatialAudioTracking

struct HUDView: View {
    var model: HeadTrackingModel

    var body: some View {
        ScrollView { HUDContent(model: model).padding(16) }
    }
}

/// The HUD without its scroll container (so it can also be rendered to an image for layout review).
struct HUDContent: View {
    var model: HeadTrackingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isSimulated {
                Text("SIMULATED INPUT — no camera is used; every number comes from a made-up person. Results are labeled SIMULATED and can not be applied.")
                    .font(.callout.bold()).foregroundStyle(.white)
                    .padding(8).frame(maxWidth: .infinity).background(Color.red, in: RoundedRectangle(cornerRadius: 8))
            }
            if model.selfTest.isBusy {
                SelfTestRunPanel(controller: model.selfTest, model: model)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    NoseCompass(pose: model.snapshot?.pose ?? .identity, active: model.snapshot != nil)
                        .frame(width: 170, height: 170)
                    stats
                }
                Divider()
                controls
                SelfTestLauncher(controller: model.selfTest, model: model)
                if model.selfTest.stage == .finished {
                    SelfTestResultView(controller: model.selfTest, model: model)
                }
                Text("Sign conventions: turn LEFT → yaw +, look UP → pitch +, tilt RIGHT ear down → roll +. Until a self-test has been run on the camera and applied they are UNVERIFIED.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: stats

    private var stats: some View {
        let s = model.snapshot
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            row("Status", model.statusText)
            row("Camera", model.deviceName ?? "—")
            GridRow {
                Text("State").foregroundStyle(.secondary)
                Text(s.map { $0.state.rawValue.uppercased() } ?? "—")
                    .bold().foregroundStyle(color(for: s?.state))
            }
            row("Pose yaw / pitch / roll", s.map { fmt3($0.euler) } ?? "—")
            row("Vision raw (radians→deg)", s?.visionAngles.map { a in
                fmt3(EulerAngles(yaw: a.yaw, pitch: a.pitch, roll: a.roll)) } ?? "no face")
            row("Mapped, pre-filter", s?.mappedRawEuler.map(fmt3) ?? "—")
            row("Quality (our gate)", s.map { qualityText($0.quality) } ?? "—")
            row("  size/edge/ctr/scl/ang/fps/conf", s.map { componentsText($0.quality) } ?? "—")
            row("Vision confidence (weak)", s?.confidence.map { String(format: "%.2f", $0) } ?? "—")
            row("Faces", s.map { "\($0.facesDetected)" } ?? "—")
            if let s, s.isWatchdogTick {
                GridRow {
                    Text("Frames").foregroundStyle(.secondary)
                    Text(String(format: "NONE for %.0f ms (watchdog)", s.frameAge * 1000)).bold().foregroundStyle(.red)
                }
            }
            row("Capture→pose latency", s.map { $0.isWatchdogTick ? "—" : ms($0.captureToPoseLatency) } ?? "—")
            row("  delivery / vision", s.map { "\(ms($0.deliveryLatency)) / \(ms($0.visionDuration))" } ?? "—")
            row("Frame rate", s.map { String(format: "%.1f fps", $0.framesPerSecond) } ?? "—")
            row("Frame mirrored / rotation", s.map { "\($0.frameMirrored) / \($0.videoRotationAngle.map { String(format: "%.0f°", $0) } ?? "?")" } ?? "—")
            if let err = s?.detectorError { row("Vision error", err) }
        }
        .font(.system(.body, design: .monospaced))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    // MARK: controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if model.status == .running || model.status == .starting {
                    Button("Stop camera") { Task { await model.stopAndVerifyRelease() } }
                } else {
                    Button("Start camera") { model.start() }.keyboardShortcut(.defaultAction)
                }
                Button("Recenter") { model.recenter() }.disabled(model.status != .running)
                if let m = model.recenterMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
            }
            releaseLine
            HStack {
                Text("Invert (manual sign override):").font(.caption)
                Toggle("yaw", isOn: Binding(get: { model.mapping.invertYaw }, set: { model.setInvert(yaw: $0) }))
                Toggle("pitch", isOn: Binding(get: { model.mapping.invertPitch }, set: { model.setInvert(pitch: $0) }))
                Toggle("roll", isOn: Binding(get: { model.mapping.invertRoll }, set: { model.setInvert(roll: $0) }))
                Button("Reset to documented defaults") { model.resetToDocumentedDefaults() }.font(.caption)
            }
            .toggleStyle(.checkbox)
            Text("Sign mapping source: \(model.mappingNote)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var releaseLine: some View {
        if model.releaseCheckPending {
            Text("Camera stopped; checking the capture session…").font(.caption).foregroundStyle(.secondary)
        } else if let r = model.releaseReport {
            Text((r.isClean ? "Release check (programmatic): CLEAN" : "Release check (programmatic): NOT CLEAN") +
                 " — isRunning=\(r.isRunningAfterStop), inputs=\(r.inputsAfterStop), outputs=\(r.outputsAfterStop), frames after stop=\(r.callbacksAfterStop). The green light is still a visual check.")
                .font(.caption).foregroundStyle(r.isClean ? .green : .red)
        }
    }

    // MARK: formatting

    private func fmt3(_ e: EulerAngles) -> String {
        String(format: "%+7.1f° %+7.1f° %+7.1f°", e.yawDegrees, e.pitchDegrees, e.rollDegrees)
    }

    private func ms(_ seconds: Double) -> String { String(format: "%.0f ms", seconds * 1000) }

    private func qualityText(_ q: QualityBreakdown) -> String {
        String(format: "%.2f  (limited by: %@)", q.overall, q.limiting)
    }

    private func componentsText(_ q: QualityBreakdown) -> String {
        guard q.facePresent else { return "—" }
        return String(format: "%.2f %.2f %.2f %.2f %.2f %.2f %.2f", q.size, q.edge, q.centerStability,
                      q.scaleStability, q.angularStability, q.frameRate, q.visionConfidence)
    }

    private func color(for state: TrackingState?) -> Color {
        switch state {
        case .locked: .green
        case .holding: .yellow
        case .decaying: .orange
        case .static, nil: .gray
        }
    }
}

/// Top-down view: the arrow points where the nose points (forward = up on screen).
/// Turning your head LEFT should swing the arrow LEFT if the sign convention is right.
struct NoseCompass: View {
    var pose: Quaternion
    var active: Bool

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 16          // leave room above the circle for the label
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(.secondary), lineWidth: 1)
            ctx.draw(Text("front").font(.caption2), at: CGPoint(x: c.x, y: c.y - r - 9), anchor: .center)
            let v = pose.rotate(.forward)           // +X right, -Z forward
            let tip = CGPoint(x: c.x + v.x * r, y: c.y + v.z * r)   // forward (-Z) maps to screen up
            var p = Path(); p.move(to: c); p.addLine(to: tip)
            ctx.stroke(p, with: .color(active ? .green : .gray), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
    }
}
