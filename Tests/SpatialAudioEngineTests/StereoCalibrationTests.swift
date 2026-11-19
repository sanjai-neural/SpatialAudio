import Testing
import Foundation
import SpatialAudioCore
@testable import SpatialAudioEngine

// Step 6b-3c-0: the offline calibration of the two-source HRTF graph. Manual offline rendering only: no audio device, nothing audible. The table print is opt-in (SA_PRINT_CALIBRATION=1) and asserts nothing; the
// asserted tests pin the directions and the arithmetic, not any level that was merely observed once.

@Suite struct StereoCalibrationPrintTests {
    @Test func printTheCalibrationTableWhenAsked() throws {
        guard ProcessInfo.processInfo.environment["SA_PRINT_CALIBRATION"] == "1" else { return }
        for rate in [44_100.0, 48_000.0] {
            var rows: [StereoCalibration.Row] = []
            for c in StereoCalibration.standardCases() { rows.append(try StereoCalibration.measure(c, sampleRate: rate)) }
            print("CALIBRATION \(Int(rate)) Hz\n" + StereoCalibration.table(rows))
            if let worst = StereoCalibration.worstFullScalePeakGain(rows) {
                print("worst full-scale peak gain at \(Int(rate)) Hz: \(String(format: "%.4f", worst)) = \(String(format: "%.2f", LevelMath.amplitudeDecibels(worst))) dB; proposed cap: \(GainCapProposal.propose(worstFullScalePeakGain: worst).map { String(format: "%.2f", $0) } ?? "none")")
            }
        }
    }
}
