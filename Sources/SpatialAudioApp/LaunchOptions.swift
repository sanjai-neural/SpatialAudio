import Foundation
import SpatialAudioCore

/// Developer / test launch switches. None are needed for normal use; they exist so the self-test flow can
/// be rehearsed and verified without a camera. Documented in docs/MANUAL_TEST_STEP2.md.
///
///   --simulate              use the SIMULATED user instead of the camera (everything is labeled SIMULATED)
///   --sim-flip=yaw,pitch,roll   make the simulated camera use the opposite sign convention on those axes
///   --sim-mirrored          make the simulated frames horizontally mirrored
///   --autorun-selftest      start the self-test automatically after launch
///   --lighting=normal|dim   lighting tag for an autorun
///   --exit-after-selftest   quit when the self-test and its release check are done
///   --mute                  no cue sounds
///   --results-dir=PATH      write reports there instead of docs/test-results
///   --render-ui=PATH        (with --simulate --autorun-selftest) render the HUD screens to PNG files there, then quit
///   --audio-test-selfcheck  SILENT (volume 0) run of the audio listening test's real start/readout/stop path inside the
///                           app, prints what the card would show, then quits. Opens no camera.
///   --tap-probe <seconds>   Step 6a: open a Core Audio process tap (global, excluding this process, original audio left audible)
///                           for that long, write a numbers-only report to docs/test-results/, tear everything down, exit.
///                           No window, no camera, no rendering. Needs the system-audio permission (docs/MANUAL_TEST_STEP6A.md).
///   --tap-probe-simulate <seconds>   the same flow on a SIMULATED source (no Core Audio); the report says SIMULATED
///   --tap-probe-with-output-device   (with --tap-probe) also put the default output device in the aggregate device
///   --allow-device-inputs            (with the above) allow it even if that device has input channels
///   --list-audio-devices    print counts of the audio devices and taps this process can see, then exit
struct LaunchOptions: Sendable {
    var simulate = false
    var conventions = SimulatedUser.Conventions()
    var mirrored = false
    var autorunSelfTest = false
    var lighting: LightingTag = .normalLight
    var exitAfterSelfTest = false
    var muteCues = false
    var resultsDirectory: URL?
    var renderDirectory: URL?
    var audioTestSelfCheck = false
    var tapProbeSeconds: Double?
    var tapProbeSimulate = false
    var tapProbeWithOutputDevice = false
    var allowDeviceInputs = false
    var listAudioDevices = false
    /// A `--tap-probe` value that is not a number (reported by the launcher, which exits with status 2).
    var tapProbeBadValue: String?

    static let current = LaunchOptions(arguments: CommandLine.arguments)

    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let a = iterator.next() {
            switch a {
            case "--simulate": simulate = true
            case "--sim-mirrored": mirrored = true
            case "--autorun-selftest": autorunSelfTest = true
            case "--exit-after-selftest": exitAfterSelfTest = true
            case "--mute": muteCues = true
            case "--audio-test-selfcheck": audioTestSelfCheck = true
            case "--tap-probe-with-output-device": tapProbeWithOutputDevice = true
            case "--allow-device-inputs": allowDeviceInputs = true
            case "--list-audio-devices": listAudioDevices = true
            case "--tap-probe", "--tap-probe-simulate":
                if a == "--tap-probe-simulate" { tapProbeSimulate = true }
                let value = iterator.next()
                if let value, let seconds = Double(value) { tapProbeSeconds = seconds } else { tapProbeBadValue = value ?? "(missing)"; tapProbeSeconds = nil }
            default:
                if a.hasPrefix("--sim-flip=") {
                    for axis in a.dropFirst("--sim-flip=".count).split(separator: ",") {
                        switch axis {
                        case "yaw": conventions.yawPerLeft = -1
                        case "pitch": conventions.pitchPerUp = 1
                        case "roll": conventions.rollPerRightEar = -1
                        default: break
                        }
                    }
                } else if a.hasPrefix("--lighting=") {
                    lighting = a.hasSuffix("dim") ? .dimRoom : .normalLight
                } else if a.hasPrefix("--render-ui=") {
                    renderDirectory = URL(fileURLWithPath: String(a.dropFirst("--render-ui=".count)))
                } else if a.hasPrefix("--tap-probe=") || a.hasPrefix("--tap-probe-simulate=") {
                    if a.hasPrefix("--tap-probe-simulate=") { tapProbeSimulate = true }
                    let value = String(a.drop { $0 != "=" }.dropFirst())
                    if let seconds = Double(value) { tapProbeSeconds = seconds } else { tapProbeBadValue = value }
                } else if a.hasPrefix("--results-dir=") {
                    resultsDirectory = URL(fileURLWithPath: String(a.dropFirst("--results-dir=".count)))
                }
            }
        }
    }
}
