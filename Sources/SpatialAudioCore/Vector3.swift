import Foundation

/// Minimal 3-vector. Coordinate convention for the whole project (matches
/// AVAudioEnvironmentNode): right-handed, +X right, +Y up, forward = -Z.
public struct Vector3: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x; self.y = y; self.z = z
    }

    public static let zero = Vector3(0, 0, 0)
    /// Direction the listener faces when the pose is identity.
    public static let forward = Vector3(0, 0, -1)
    public static let up = Vector3(0, 1, 0)
    public static let right = Vector3(1, 0, 0)

    /// Point at `distance` in the audio-standard direction `azimuthDegrees` (0 = straight ahead, positive = to
    /// the RIGHT, +-180 = behind) and `elevationDegrees` (positive = up), in this frame. Also used by `Speaker`.
    public static func direction(azimuthDegrees: Double, elevationDegrees: Double, distance: Double = 1) -> Vector3 {
        let a = azimuthDegrees * .pi / 180, e = elevationDegrees * .pi / 180
        return Vector3(sin(a) * cos(e), sin(e), -cos(a) * cos(e)) * distance
    }

    public var length: Double { (x * x + y * y + z * z).squareRoot() }

    public func dot(_ o: Vector3) -> Double { x * o.x + y * o.y + z * o.z }

    public func cross(_ o: Vector3) -> Vector3 {
        Vector3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    }

    /// Unit vector, or `.zero` if the length is (near) zero or not finite.
    public func normalized() -> Vector3 {
        let l = length
        guard l.isFinite, l > 1e-12 else { return .zero }
        return Vector3(x / l, y / l, z / l)
    }

    public static func + (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vector3, s: Double) -> Vector3 { Vector3(a.x * s, a.y * s, a.z * s) }
}
