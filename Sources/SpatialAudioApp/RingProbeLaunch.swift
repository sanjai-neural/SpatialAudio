import AppKit
import Foundation
import SpatialAudioCore
import SpatialAudioEngine

/// Runs the Step 6b-2 ring probe from the command line and returns the process exit status, or nil if no ring probe was requested. Glue only: the argument parser and
/// the report are in SpatialAudioCore, the tap, the ring and the engine in SpatialAudioEngine. There is no gain option and the report path is never printed.
///
/// Exit status: 0 = the probe ran, the outcome is "ok" and teardown was verified clean; 1 = anything else (failed, refused, never primed, invalid, interrupted, unclean
/// teardown); 2 = bad usage.
enum RingProbeLaunch {
    static func runIfRequested(arguments: [String], resultsDirectory: URL?) -> Int32? {
        let request: RingProbeRequest
        switch RingProbeArguments.parse(arguments) {
        case .notRequested: return nil
        case .invalid(let why): fputs("--ring-probe: \(why)\n", stderr); return 2
        case .request(let r): request = r
        }

        // No window and no Dock icon: this process only measures and exits.
        MainActor.assumeIsolated { _ = NSApplication.shared.setActivationPolicy(.accessory) }      // App.init runs on the main thread

        let faults = SimulatedRingBackend.Faults(producerPPM: request.simulatedProducerPPM, underrunAtSeconds: request.simulatedUnderrunAtSeconds,
                                                 underrunStallSeconds: request.simulatedUnderrunStallSeconds)
        let report = RingProbeCommand.run(.init(seconds: request.seconds, simulate: request.simulate, simulatedFaults: faults,
                                                recovery: request.recovery ? RePrimeConfig() : nil, deviceTap: request.deviceTap))
        print(report.markdown())

        let stem = RingProbeReport.fileStem(date: Date(), simulated: report.isSimulated, recovery: request.recovery, deviceTap: request.deviceTap)
        do {
            let dir = ReportStore.resultsDirectory(override: resultsDirectory)
            let files = try ReportStore.writeRingProbe(report, stem: stem, to: dir)
            // File NAMES only: the directory is under the user's home and stays out of anything that gets pasted. (The 6a launcher prints the full path.)
            print("Report files (in the results directory): \(files.map(\.lastPathComponent).joined(separator: "  "))")
        } catch {
            fputs("Could not save the report: \(error.localizedDescription)\n", stderr)
            return 1
        }
        return report.outcome == "ok" && report.teardownClean ? 0 : 1
    }
}

extension ReportStore {
    /// Writes `<stem>.json` and `<stem>.md` for a ring probe (Step 6b-2). Numbers only.
    @discardableResult
    static func writeRingProbe(_ report: RingProbeReport, stem: String, to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = directory.appendingPathComponent(stem + ".json")
        let markdown = directory.appendingPathComponent(stem + ".md")
        try report.jsonData().write(to: json, options: .atomic)
        try Data(report.markdown().utf8).write(to: markdown, options: .atomic)
        return [json, markdown]
    }
}
