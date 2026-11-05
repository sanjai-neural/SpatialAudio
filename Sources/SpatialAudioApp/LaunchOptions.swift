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

    static let current = LaunchOptions(arguments: CommandLine.arguments)

    init(arguments: [String]) {
        for a in arguments.dropFirst() {
            switch a {
            case "--simulate": simulate = true
            case "--sim-mirrored": mirrored = true
            case "--autorun-selftest": autorunSelfTest = true
            case "--exit-after-selftest": exitAfterSelfTest = true
            case "--mute": muteCues = true
            case "--audio-test-selfcheck": audioTestSelfCheck = true
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
                } else if a.hasPrefix("--results-dir=") {
                    resultsDirectory = URL(fileURLWithPath: String(a.dropFirst("--results-dir=".count)))
                }
            }
        }
    }
}
