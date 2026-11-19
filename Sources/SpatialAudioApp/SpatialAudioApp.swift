import AppKit
import SwiftUI

@main
struct SpatialAudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Step 6b-3c-0: two small silent tools (the synthetic channel-check file, the mute-experiment verdict): no device, no window.
        if let status = ToolsLaunch.runIfRequested(arguments: CommandLine.arguments) { exit(status) }
        // Command-line probes (Step 6a: --tap-probe, --list-audio-devices) run here and exit before any window exists.
        if let status = TapProbeLaunch.runIfRequested(LaunchOptions.current) { exit(status) }
        // Step 6b-2: --ring-probe / --ring-probe-simulate (the real tap into the ring and a real-time engine at output gain 0, measurement only).
        if let status = RingProbeLaunch.runIfRequested(arguments: CommandLine.arguments, resultsDirectory: LaunchOptions.current.resultsDirectory) { exit(status) }
    }

    var body: some Scene {
        Window("SpatialAudio — Head Tracking HUD", id: "hud") {
            HUDView(model: HeadTrackingModel.shared)
                .frame(minWidth: 760, minHeight: 640)
                .task {
                    // Developer switch (see LaunchOptions): start the self-test without clicking.
                    if LaunchOptions.current.audioTestSelfCheck {
                        await AudioTestModel.shared.runSilentSelfCheck()
                    } else if LaunchOptions.current.trackedListeningSelfCheck {
                        await TrackedListeningModel.shared.runSilentSelfCheck()
                    } else if let behavior = LaunchOptions.current.blindListeningSimulate {
                        BlindListeningModel.shared.runSimulatedRehearsal(behavior: behavior, resultsDirectory: LaunchOptions.current.resultsDirectory)
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
            BlindListeningModel.shared.stop()
            TrackedListeningModel.shared.stop()
        }
    }
}
