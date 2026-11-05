import Testing
import Foundation
@testable import SpatialAudioCore

/// Step 2g: offline characterization of the smoothing in the REAL `HeadPosePipeline` (default One-Euro parameters, default gate,
/// 30 fps), driven by synthetic heads. EVERYTHING HERE IS SYNTHETIC: exact orientations, a perfectly steady frame rate, no
/// camera. It makes no hardware claim and says nothing about how a real face behaves.
///
/// What it measures:
/// - steady-state lag of the output behind the input for a constant turn (degrees, and the same as time = degrees / speed);
/// - settle time after the head stops (time until the output stays within a tolerance of the final orientation);
/// - jitter gain for a still head with seeded Gaussian noise (output standard deviation / input standard deviation).
///
/// What it asserts: PROPERTIES only (finite numbers; the output trails the input; the lag converged; angular lag grows with speed
/// and time lag does not; the tighter settle tolerance never settles earlier; the filter never amplifies jitter; the noise
/// generator really has the sigma it claims), plus one cross-check of the harness against the filter's own cutoff law computed
/// from the parameters in use. It deliberately asserts NO tuning target (no "lag below X ms"): the numbers are recorded in
/// docs/STATUS.md ("Step 2g findings") for people to judge. To print the tables:
///   SA_PRINT_FILTER_TABLE=1 swift test --filter FilterCharacterization
enum FilterCharacterization {
    static let fps = 30.0
    static let stillSeconds = 1.0                 // the head sits still first, so the gate locks (first lock needs 0.2 s)
    static let turnSeconds = 4.0
    static let measureSeconds = 1.0               // the lag is read over the LAST second of the turn
    static let afterStopSeconds = 3.0             // observed after the head stops
    static let speeds: [Double] = [45, 90, 180, 360]          // degrees per second
    static let sigmas: [Double] = [0.5, 1, 2, 4]              // degrees, per axis
    static let settleTolerances: [Double] = [1.0, 0.1]        // degrees
    static let noiseFrames = 3000                  // 100 s at 30 fps
    static let noiseDiscard = 90                   // the first 3 s are the lock-in transient
    static let seed: UInt64 = 20_261_105

    // MARK: constant turn and stop

    struct Turn {
        var speed: Double
        /// Mean over the last second of the turn of how far the output is behind the input, degrees (positive = behind).
        var lagDegrees: Double
        /// Largest minus smallest lag in that second: close to 0 means the lag had converged.
        var lagSpreadDegrees: Double
        /// lag / speed.
        var timeLagMs: Double
        /// Lag predicted from the parameters in use: a first-order smoother with the One-Euro cutoff at this speed has a steady
        /// lag of step x (1 - a) / a per frame.
        var predictedLagDegrees: Double
        /// Milliseconds after the stop until the output stays within each tolerance of the final input; nil = did not within the window.
        var settleMs: [Double: Double?]
        var states: Set<TrackingState>
    }

    /// Signed rotation angle about the up axis (radians, wrapped to (-pi, pi]) of a yaw-only orientation.
    static func yawAngle(_ q: Quaternion) -> Double {
        let a = 2 * atan2(q.y, q.w)
        return atan2(sin(a), cos(a))
    }

    static func constantTurn(speed: Double) -> Turn {
        var p = HeadPosePipeline()
        let still = Int(stillSeconds * fps), turn = Int(turnSeconds * fps), after = Int(afterStopSeconds * fps)
        let window = Int(measureSeconds * fps)
        let final = yawQ(speed * turnSeconds)
        var lags: [Double] = [], errors: [Double] = []
        var states = Set<TrackingState>()
        for k in 0..<(still + turn + after) {
            let t = Double(k) / fps
            let head = yawQ(speed * min(max(t - stillSeconds, 0), turnSeconds))
            let out = p.process(HeadPoseSample(orientation: head, confidence: 1, timestamp: t), now: t)
            let j = k - still                                           // frame index since the turn started; j == turn is the stop frame
            if j >= 0 { states.insert(out.state) }
            if j >= turn - window && j < turn {
                let behind = atan2(sin(yawAngle(head) - yawAngle(out.pose)), cos(yawAngle(head) - yawAngle(out.pose))) * 180 / .pi
                lags.append(behind)
            }
            if j >= turn { errors.append(out.pose.angle(to: final) * 180 / .pi) }
        }
        let mean = lags.reduce(0, +) / Double(lags.count)
        var settle: [Double: Double?] = [:]
        for tol in settleTolerances {
            if let lastBad = errors.lastIndex(where: { $0 > tol }) {
                settle[tol] = lastBad == errors.count - 1 ? .some(nil) : .some(Double(lastBad + 1) * 1000 / fps)
            } else { settle[tol] = .some(0) }
        }
        let prm = OneEuroParameters()
        let cutoff = prm.minCutoff + prm.beta * speed * .pi / 180
        let a = OneEuroMath.alpha(cutoff: cutoff, dt: 1 / fps)
        return Turn(speed: speed, lagDegrees: mean, lagSpreadDegrees: (lags.max() ?? 0) - (lags.min() ?? 0),
                    timeLagMs: mean / speed * 1000, predictedLagDegrees: speed / fps * (1 - a) / a,
                    settleMs: settle.mapValues { $0 }, states: states)
    }

    // MARK: jitter

    /// Standard normal numbers (Box-Muller) from the seeded test generator.
    struct Gaussian {
        private var u: DeterministicNoise
        init(seed: UInt64) { u = DeterministicNoise(seed: seed) }
        mutating func next() -> Double {
            let u1 = max((u.next() + 1) / 2, 1e-12), u2 = (u.next() + 1) / 2
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    static func std(_ xs: [Double]) -> Double {
        let m = xs.reduce(0, +) / Double(xs.count)
        return (xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)).squareRoot()
    }

    struct Jitter {
        var sigma: Double
        var inputStd: [Double]            // yaw, pitch, roll (degrees), measured on the generated numbers
        var outputStd: [Double]           // the same for the pipeline output, from its Euler angles
        var gain: [Double] { zip(outputStd, inputStd).map { $0 / $1 } }
        var meanGain: Double { gain.reduce(0, +) / 3 }
        var inputMean: [Double]
        var states: Set<TrackingState>
    }

    static func jitter(sigma: Double) -> Jitter {
        var p = HeadPosePipeline()
        var g = Gaussian(seed: seed)
        var input: [[Double]] = [[], [], []], output: [[Double]] = [[], [], []]
        var states = Set<TrackingState>()
        for k in 0..<noiseFrames {
            let t = Double(k) / fps
            let n = [g.next() * sigma, g.next() * sigma, g.next() * sigma]       // yaw, pitch, roll
            let out = p.process(HeadPoseSample(orientation: eulerQ(n[0], n[1], n[2]), confidence: 1, timestamp: t), now: t)
            if k >= noiseDiscard {
                let e = out.pose.euler
                for i in 0..<3 { input[i].append(n[i]) }
                output[0].append(e.yawDegrees); output[1].append(e.pitchDegrees); output[2].append(e.rollDegrees)
                states.insert(out.state)
            }
        }
        return Jitter(sigma: sigma, inputStd: input.map(std), outputStd: output.map(std),
                      inputMean: input.map { $0.reduce(0, +) / Double($0.count) }, states: states)
    }

    // MARK: results (computed once, shared by the tests and the table)

    static let turns: [Turn] = speeds.map(constantTurn)
    static let jitters: [Jitter] = sigmas.map(jitter)

    static func markdown() -> String {
        func ms(_ v: Double??) -> String { if let v, let v { return String(format: "%.0f", v) }; return "not within \(Int(afterStopSeconds)) s" }
        var L: [String] = []
        L.append("| turn speed (deg/s) | head per frame (deg) | steady-state lag (deg) | time lag (ms) | lag spread in the last second (deg) | lag predicted from the cutoff law (deg) | settle to 1° (ms) | settle to 0.1° (ms) |")
        L.append("|---|---|---|---|---|---|---|---|")
        for t in turns {
            L.append(String(format: "| %.0f | %.2f | %.2f | %.0f | %.4f | %.2f | %@ | %@ |", t.speed, t.speed / fps, t.lagDegrees, t.timeLagMs, t.lagSpreadDegrees,
                            t.predictedLagDegrees, ms(t.settleMs[1.0]), ms(t.settleMs[0.1])))
        }
        L.append("")
        L.append("| noise sigma (deg, per axis) | input std yaw / pitch / roll (deg) | output std yaw / pitch / roll (deg) | jitter gain yaw / pitch / roll | mean gain |")
        L.append("|---|---|---|---|---|")
        for j in jitters {
            L.append(String(format: "| %.1f | %.3f / %.3f / %.3f | %.3f / %.3f / %.3f | %.3f / %.3f / %.3f | %.3f |", j.sigma,
                            j.inputStd[0], j.inputStd[1], j.inputStd[2], j.outputStd[0], j.outputStd[1], j.outputStd[2],
                            j.gain[0], j.gain[1], j.gain[2], j.meanGain))
        }
        return L.joined(separator: "\n")
    }
}

@Suite struct FilterCharacterizationTests {
    typealias F = FilterCharacterization

    @Test func everyNumberIsFinite() {
        for t in F.turns {
            #expect(t.lagDegrees.isFinite && t.lagSpreadDegrees.isFinite && t.timeLagMs.isFinite && t.predictedLagDegrees.isFinite, "speed \(t.speed)")
        }
        for j in F.jitters {
            #expect((j.inputStd + j.outputStd + j.gain + [j.meanGain]).allSatisfy { $0.isFinite }, "sigma \(j.sigma)")
        }
    }

    @Test func theTrackerStaysLockedWhileMeasuring() {
        #expect(F.turns.allSatisfy { $0.states == [.locked] })
        #expect(F.jitters.allSatisfy { $0.states == [.locked] })
    }

    @Test func theOutputTrailsTheInputAtEverySpeedAndTheLagHadConverged() {
        for t in F.turns {
            #expect(t.lagDegrees > 0, "output is not behind the input at \(t.speed) deg/s: \(t.lagDegrees)")
            #expect(t.lagDegrees < 90, "lag \(t.lagDegrees) at \(t.speed) deg/s is not a plausible filter lag")
            #expect(t.lagSpreadDegrees <= 0.02 * t.lagDegrees + 0.01, "lag still moving at \(t.speed) deg/s: spread \(t.lagSpreadDegrees) on \(t.lagDegrees)")
        }
    }

    @Test func angularLagGrowsWithSpeedAndTimeLagNeverGrowsWithSpeed() {
        let lags = F.turns.map(\.lagDegrees), times = F.turns.map(\.timeLagMs)
        for i in 1..<lags.count {
            #expect(lags[i] > lags[i - 1], "angular lag \(lags[i]) at \(F.speeds[i]) deg/s is not above \(lags[i - 1]) at \(F.speeds[i - 1])")
            #expect(times[i] <= times[i - 1] + 0.5, "time lag \(times[i]) ms at \(F.speeds[i]) deg/s grew from \(times[i - 1]) ms at \(F.speeds[i - 1])")
        }
    }

    @Test func theMeasuredLagMatchesTheCutoffLawOfTheParametersInUse() {
        // Not a tuning target: the expectation is computed from `OneEuroParameters()` itself, so it holds for any parameters and
        // fails when the harness (or the filter) does something other than "first-order smoother with the One-Euro cutoff".
        for t in F.turns {
            #expect(abs(t.lagDegrees - t.predictedLagDegrees) <= 0.005 * t.predictedLagDegrees,
                    "measured \(t.lagDegrees) vs predicted \(t.predictedLagDegrees) at \(t.speed) deg/s")
            let predictedMs = t.predictedLagDegrees / t.speed * 1000                       // the time lag, computed independently of the harness
            #expect(abs(t.timeLagMs - predictedMs) <= 0.005 * predictedMs, "time lag \(t.timeLagMs) ms vs predicted \(predictedMs) ms at \(t.speed) deg/s")
        }
    }

    @Test func settleTimesAreFiniteAndTheTighterToleranceNeverSettlesEarlier() throws {
        for t in F.turns {
            let loose = try #require(t.settleMs[1.0] ?? nil, "did not settle to 1° within the window at \(t.speed) deg/s")
            let tight = try #require(t.settleMs[0.1] ?? nil, "did not settle to 0.1° within the window at \(t.speed) deg/s")
            #expect(loose.isFinite && tight.isFinite && loose >= 0 && tight >= loose, "speed \(t.speed): 1° at \(loose) ms, 0.1° at \(tight) ms")
        }
    }

    @Test func theFilterNeverAmplifiesJitter() {
        for j in F.jitters {
            #expect(j.gain.allSatisfy { $0 > 0 && $0 < 1 }, "sigma \(j.sigma): gains \(j.gain)")
        }
    }

    @Test func jitterGainDoesNotFallAsTheNoiseGrows() {
        // The cutoff rises with the (noise-driven) speed estimate, so more noise gets through a little more, never less.
        let g = F.jitters.map(\.meanGain)
        for i in 1..<g.count { #expect(g[i] >= g[i - 1] - 0.005, "mean gain \(g[i]) at sigma \(F.sigmas[i]) fell below \(g[i - 1]) at sigma \(F.sigmas[i - 1])") }
    }

    @Test func theNoiseGeneratorHasTheSigmaItClaims() {
        // Harness sanity: if the "input" were not N(0, sigma) the gains above would mean nothing.
        for j in F.jitters {
            for i in 0..<3 {
                #expect(abs(j.inputStd[i] / j.sigma - 1) < 0.05, "sigma \(j.sigma) axis \(i): measured std \(j.inputStd[i])")
                #expect(abs(j.inputMean[i]) < 0.1 * j.sigma, "sigma \(j.sigma) axis \(i): mean \(j.inputMean[i])")
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SA_PRINT_FILTER_TABLE"] != nil, "set SA_PRINT_FILTER_TABLE=1 to print the Step 2g tables"))
    func printTheTables() {
        print("STEP2G-TABLE-BEGIN\n" + F.markdown() + "\nSTEP2G-TABLE-END")
    }
}
