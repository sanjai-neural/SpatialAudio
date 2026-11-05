import AppKit
import SwiftUI

@main
struct SpatialAudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Command-line probes (Step 6a: --tap-probe, --list-audio-devices) run here and exit before any window exists.
        if let status = TapProbeLaunch.runIfRequested(LaunchOptions.current) { exit(status) }
    }

    var body: some Scene {
        Window("SpatialAudio — Head Tracking HUD", id: "hud") {
            HUDView(model: HeadTrackingModel.shared)
                .frame(minWidth: 760, minHeight: 640)
                .task {
                    // Developer switch (see LaunchOptions): start the self-test without clicking.
                    if LaunchOptions.current.audioTestSelfCheck {
                        await AudioTestModel.shared.runSilentSelfCheck()
                    } else if let dir = LaunchOptions.current.renderDirectory {
                        await UIRenderer.runSchedule(into: dir, model: HeadTrackingModel.shared)
                    } else if LaunchOptions.current.autorunSelfTest {
                        try? await Task.sleep(for: .milliseconds(600))
                        HeadTrackingModel.shared.selfTest.run()
                    }
                }
        }
        .defaultSize(width: 820, height: 760)
    }
}

/// Ensures the camera is released and the audio test stops when the window closes or the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            HeadTrackingModel.shared.stop()
            AudioTestModel.shared.stop()
        }
    }
}
