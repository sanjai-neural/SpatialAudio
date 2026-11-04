import Foundation
@testable import SpatialAudioCore

let deg = Double.pi / 180

func yawQ(_ degrees: Double) -> Quaternion { Quaternion(axis: .up, angle: degrees * deg) }
func pitchQ(_ degrees: Double) -> Quaternion { Quaternion(axis: .right, angle: degrees * deg) }
func eulerQ(_ y: Double, _ p: Double, _ r: Double) -> Quaternion {
    Quaternion(euler: EulerAngles(yawDegrees: y, pitchDegrees: p, rollDegrees: r))
}
/// Angle between two orientations in degrees.
func angleDeg(_ a: Quaternion, _ b: Quaternion) -> Double { a.angle(to: b) / deg }

func near(_ a: Vector3, _ b: Vector3, _ tol: Double = 1e-9) -> Bool { (a - b).length < tol }

/// Deterministic pseudo-random in [-1, 1] (LCG) so noise tests are reproducible.
struct DeterministicNoise {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53) * 2 - 1
    }
}
