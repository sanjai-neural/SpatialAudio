import AppKit
import Foundation
import SpatialAudioCore
import SpatialAudioEngine

/// Runs the Step 6a probe from the command line and returns the process exit status, or nil if no probe was requested. This is only
/// glue: the capture code is in SpatialAudioEngine, the statistics and the report in SpatialAudioCore.
///
/// Exit status: 0 = the probe ran and teardown was verified clean; 1 = it failed, was refused or teardown was not clean; 2 = bad usage.
enum TapProbeLaunch {
    static func runIfRequested(_ options: LaunchOptions) -> Int32? {
        if options.listAudioDevices {
            print(TapProbeCommand.listAudioObjects())
            return 0
        }
        if let bad = options.tapProbeBadValue {
            fputs("--tap-probe needs a number of seconds, got: \(bad)\n", stderr)
            return 2
        }
        guard let seconds = options.tapProbeSeconds else { return nil }
        if let problem = TapProbeCommand.validate(seconds: seconds) {
            fputs("--tap-probe: \(problem)\n", stderr)
            return 2
        }

        // No window and no Dock icon: this process only measures and exits.
        MainActor.assumeIsolated { _ = NSApplication.shared.setActivationPolicy(.accessory) }      // App.init runs on the main thread

        let report = TapProbeCommand.run(.init(seconds: seconds, simulate: options.tapProbeSimulate,
                                               withOutputDevice: options.tapProbeWithOutputDevice,
                                               allowDeviceInputs: options.allowDeviceInputs))
        print(report.markdown())

        let stem = TapProbeReport.fileStem(date: Date(), simulated: report.isSimulated)
        do {
            let dir = ReportStore.resultsDirectory(override: options.resultsDirectory)
            let files = try ReportStore.writeTapProbe(report, stem: stem, to: dir)
            print("Report files: \(files.map(\.path).joined(separator: "  "))")
        } catch {
            fputs("Could not save the report: \(error.localizedDescription)\n", stderr)
            return 1
        }
        return report.outcome == "ok" && report.teardownClean ? 0 : 1
    }
}
