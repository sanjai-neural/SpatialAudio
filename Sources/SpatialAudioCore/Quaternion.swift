import Foundation

/// Head/listener orientation expressed as Euler angles. Use ONLY at API
/// boundaries (HUD display, Vision input, AVAudioEnvironmentNode output).
/// Internally the project uses `Quaternion`.
///
/// Conventions (right-handed, +X right, +Y up, forward = -Z):
/// - yaw:   rotation about +Y.       Positive = turn LEFT (counter-clockwise from above).
/// - pitch: rotation about +X.       Positive = look UP.
/// - roll:  rotation about forward.  Positive = tilt head to the RIGHT (right ear down).
/// Composition order: yaw, then pitch, then roll (intrinsic Y-X-Z).
public struct EulerAngles: Equatable, Sendable {
    /// Radians.
    public var yaw: Double
    public var pitch: Double
    public var roll: Double

    public init(yaw: Double, pitch: Double, roll: Double) {
        self.yaw = yaw; self.pitch = pitch; self.roll = roll
    }

    public init(yawDegrees: Double, pitchDegrees: Double, rollDegrees: Double) {
        self.init(yaw: yawDegrees * .pi / 180, pitch: pitchDegrees * .pi / 180, roll: rollDegrees * .pi / 180)
    }

    public var yawDegrees: Double { yaw * 180 / .pi }
    public var pitchDegrees: Double { pitch * 180 / .pi }
    public var rollDegrees: Double { roll * 180 / .pi }
}

/// Unit quaternion (Hamilton convention, w + xi + yj + zk) describing a rotation.
public struct Quaternion: Equatable, Sendable {
    public var w: Double
    public var x: Double
    public var y: Double
    public var z: Double

    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w; self.x = x; self.y = y; self.z = z
    }

    public static let identity = Quaternion(w: 1, x: 0, y: 0, z: 0)

    /// Rotation of `angle` radians about `axis` (right-hand rule). A zero/invalid axis gives identity.
    public init(axis: Vector3, angle: Double) {
        let a = axis.normalized()
        guard a.length > 0, angle.isFinite else { self = .identity; return }
        let h = angle / 2
        let s = sin(h)
        self.init(w: cos(h), x: a.x * s, y: a.y * s, z: a.z * s)
    }

    /// Build from Euler angles (radians). See `EulerAngles` for conventions.
    public init(euler: EulerAngles) {
        let qYaw = Quaternion(axis: .up, angle: euler.yaw)
        let qPitch = Quaternion(axis: .right, angle: euler.pitch)
        let qRoll = Quaternion(axis: .forward, angle: euler.roll)
        self = (qYaw * qPitch * qRoll).normalized()
    }

    // MARK: - Basic algebra

    public var conjugate: Quaternion { Quaternion(w: w, x: -x, y: -y, z: -z) }

    public var norm: Double { (w * w + x * x + y * y + z * z).squareRoot() }

    public var isFinite: Bool { w.isFinite && x.isFinite && y.isFinite && z.isFinite }

    /// Unit-length copy. A zero-length or non-finite quaternion becomes `.identity`
    /// (so a bad sample can never poison downstream state with NaN).
    public func normalized() -> Quaternion {
        let n = norm
        guard n.isFinite, n > 1e-12 else { return .identity }
        return Quaternion(w: w / n, x: x / n, y: y / n, z: z / n)
    }

    /// Inverse rotation (for a unit quaternion this is the conjugate).
    public func inverse() -> Quaternion {
        let n2 = w * w + x * x + y * y + z * z
        guard n2.isFinite, n2 > 1e-24 else { return .identity }
        return Quaternion(w: w / n2, x: -x / n2, y: -y / n2, z: -z / n2)
    }

    /// Hamilton product. `(a * b).rotate(v) == a.rotate(b.rotate(v))`.
    public static func * (a: Quaternion, b: Quaternion) -> Quaternion {
        Quaternion(
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w
        )
    }

    public func dot(_ o: Quaternion) -> Double { w * o.w + x * o.x + y * o.y + z * o.z }

    /// Rotate a vector by this (unit) quaternion.
    public func rotate(_ v: Vector3) -> Vector3 {
        let u = Vector3(x, y, z)
        let t = u.cross(v) * 2
        return v + t * w + u.cross(t)
    }

    /// Smallest rotation angle (radians, 0...π) taking `self` to `other`.
    /// Treats q and -q as the same rotation.
    public func angle(to other: Quaternion) -> Double {
        let d = (self.inverse() * other)
        let vec = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
        return 2 * atan2(vec, abs(d.w))
    }

    // MARK: - Interpolation

    /// Spherical interpolation along the shortest path. `t` is clamped to 0...1.
    /// Falls back to normalized lerp for nearly-parallel inputs.
    public static func slerp(_ a: Quaternion, _ b: Quaternion, _ t: Double) -> Quaternion {
        let t = min(max(t.isFinite ? t : 0, 0), 1)
        var b = b
        var d = a.dot(b)
        if d < 0 { b = Quaternion(w: -b.w, x: -b.x, y: -b.y, z: -b.z); d = -d }
        if d > 0.9995 {
            let r = Quaternion(
                w: a.w + (b.w - a.w) * t, x: a.x + (b.x - a.x) * t,
                y: a.y + (b.y - a.y) * t, z: a.z + (b.z - a.z) * t)
            return r.normalized()
        }
        let theta = acos(min(d, 1))
        let s = sin(theta)
        let wa = sin((1 - t) * theta) / s
        let wb = sin(t * theta) / s
        return Quaternion(
            w: a.w * wa + b.w * wb, x: a.x * wa + b.x * wb,
            y: a.y * wa + b.y * wb, z: a.z * wa + b.z * wb
        ).normalized()
    }

    /// Mean orientation of nearby samples (sign-aligned sum, normalized). Suitable for
    /// averaging many tightly-clustered samples (e.g. calibration), not widely spread ones.
    /// Returns nil for an empty input.
    public static func average(_ samples: [Quaternion]) -> Quaternion? {
        guard let first = samples.first else { return nil }
        var sw = 0.0, sx = 0.0, sy = 0.0, sz = 0.0
        for q in samples where q.isFinite {
            let s: Double = q.dot(first) < 0 ? -1 : 1
            sw += s * q.w; sx += s * q.x; sy += s * q.y; sz += s * q.z
        }
        return Quaternion(w: sw, x: sx, y: sy, z: sz).normalized()
    }

    // MARK: - Euler boundary

    /// Euler angles for display/API boundaries. See `EulerAngles` for conventions.
    /// At pitch = ±90° (gimbal lock) roll is reported as 0 and yaw carries the remainder.
    public var euler: EulerAngles {
        let q = normalized()
        let r00 = 1 - 2 * (q.y * q.y + q.z * q.z)
        let r02 = 2 * (q.x * q.z + q.w * q.y)
        let r10 = 2 * (q.x * q.y + q.w * q.z)
        let r11 = 1 - 2 * (q.x * q.x + q.z * q.z)
        let r12 = 2 * (q.y * q.z - q.w * q.x)
        let r20 = 2 * (q.x * q.z - q.w * q.y)
        let r22 = 1 - 2 * (q.x * q.x + q.y * q.y)

        let pitch = asin(min(max(-r12, -1), 1))
        let yaw: Double
        let zRot: Double  // rotation about +Z; roll is about -Z so roll = -zRot
        if abs(r12) < 0.999_999 {
            yaw = atan2(r02, r22)
            zRot = atan2(r10, r11)
        } else {
            yaw = atan2(-r20, r00)
            zRot = 0
        }
        return EulerAngles(yaw: yaw, pitch: pitch, roll: -zRot)
    }
}
