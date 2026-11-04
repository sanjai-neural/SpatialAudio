import AppKit
import SwiftUI

/// Developer tool: renders the HUD to PNG files in-process (no screen-recording permission needed) so the
/// layout can be reviewed without clicking through the app. Used only with `--render-ui=PATH` on the
/// SIMULATED input; the images contain no camera content.
@MainActor
enum UIRenderer {
    static func render(model: HeadTrackingModel, to url: URL, height: CGFloat) {
        let content = HUDContent(model: model)
            .padding(16)
            .frame(width: 820, height: height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed: \(url.lastPathComponent)\n".utf8))
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: url)
    }

    /// Idle screen, then the self-test run (mid-hold and during the cover), then the results; then quits.
    static func runSchedule(into dir: URL, model: HeadTrackingModel) async {
        func shot(_ name: String, height: CGFloat) { render(model: model, to: dir.appendingPathComponent(name), height: height) }
        try? await Task.sleep(for: .milliseconds(400))
        shot("1-idle.png", height: 760)
        model.selfTest.run()
        // Script phase 2 (first "turn left" hold) spans 5–8 s of the run; phase 15 (cover) spans 38–43 s.
        try? await Task.sleep(for: .seconds(7.0))
        shot("2-run-hold-left.png", height: 560)
        try? await Task.sleep(for: .seconds(32.5))
        shot("3-run-cover.png", height: 560)
        // Wait for the analysis + release check (up to 30 s).
        for _ in 0..<150 {
            if model.selfTest.stage == .finished && !model.selfTest.releaseCheckRunning { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        try? await Task.sleep(for: .milliseconds(300))
        shot("4-results.png", height: 1500)
        NSApplication.shared.terminate(nil)
    }
}
