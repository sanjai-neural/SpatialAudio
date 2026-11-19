import Foundation
import SpatialAudioCore
import SpatialAudioEngine

/// Step 6b-3c-0: two small command-line tools that make no sound and open no device. Glue only: the logic is in SpatialAudioCore (`ChannelCheckPattern`, `MuteExperimentEvaluator`) and SpatialAudioEngine (`ChannelCheckFileTool`).
///
///   --make-channel-check-file=<path> [--seconds=<900...3600>]   writes the synthetic channel-check WAV (never overwrites); prints its size and levels
///   --mute-experiment-verdict normal-exit=<s|none|unmuted>,sigint=...,sigkill=...,destroy-tap=...,stop-io=...   applies the pre-registered rule to Sanjai's observations
///
/// Exit status: 0 = done (a verdict of any kind counts as done), 2 = bad usage, 1 = the file could not be written.
enum ToolsLaunch {
    static func runIfRequested(arguments: [String]) -> Int32? {
        switch MuteExperimentArguments.parse(arguments) {
        case .notRequested: break
        case .invalid(let why): fputs("--mute-experiment-verdict: \(why)\n", stderr); return 2
        case .request(let observations):
            let v = MuteExperimentEvaluator.evaluate(observations)
            print("\(v.kind.rawValue.uppercased()): \(v.text)")
            return 0
        }
        guard let pathArgument = arguments.dropFirst().first(where: { $0.hasPrefix("--make-channel-check-file=") }) else { return nil }
        let path = String(pathArgument.dropFirst("--make-channel-check-file=".count))
        guard !path.isEmpty else { fputs("--make-channel-check-file=<path> needs a path\n", stderr); return 2 }
        var seconds = ChannelCheckPattern.minimumSeconds
        if let s = arguments.dropFirst().first(where: { $0.hasPrefix("--seconds=") }) {
            guard let n = Int(s.dropFirst("--seconds=".count)) else { fputs("--seconds=<whole seconds>\n", stderr); return 2 }
            seconds = n
        }
        do {
            let summary = try ChannelCheckFileTool.write(to: URL(fileURLWithPath: path), seconds: seconds)
            print("Wrote a synthetic channel-check file (generated, not recorded): \(Int(summary.seconds)) s, \(summary.frames) frames, \(summary.bytes) bytes, 44100 Hz, 16-bit stereo.")
            print(String(format: "Peak %.1f dBFS; left channel RMS %.1f dBFS and right channel RMS %.1f dBFS over one 30 s cycle (the inactive channel is exactly 0 in the first two segments).", summary.peakDecibelsFullScale, summary.leftChannelRMSDecibels, summary.rightChannelRMSDecibels))
            return 0
        } catch let e as ChannelCheckFileTool.ToolError {
            fputs("\(e)\n", stderr)
            if case .invalidDuration = e { return 2 }
            return e == .fileExists ? 2 : 1
        } catch {
            fputs("\(error)\n", stderr); return 1
        }
    }
}
