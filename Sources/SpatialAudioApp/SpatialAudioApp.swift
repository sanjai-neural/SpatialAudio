import AppKit
import SwiftUI

@main
struct SpatialAudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("SpatialAudio — Head Tracking HUD", id: "hud") {
            HUDView(model: HeadTrackingModel.shared)
                .frame(minWidth: 560, minHeight: 440)
        }
    }
}

/// Ensures the camera is released when the window closes or the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { HeadTrackingModel.shared.stop() }
    }
}
