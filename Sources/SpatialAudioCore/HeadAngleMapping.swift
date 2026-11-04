/// Face angles exactly as reported by Vision (`VNFaceObservation.yaw/pitch/roll`), in
/// radians, in Vision's own sign conventions. Do not use these as pose; map them first.
///
/// From the macOS SDK header (VNObservation.h), verified 2026-11-04:
/// - yaw:   "positive angle corresponds to counterclockwise direction", range [-π/2, π/2]
/// - pitch: "positive angle corresponds to nodding head down direction", range [-π/2, π/2]
/// - roll:  "positive angle corresponds to counterclockwise direction", range [-π, π)
/// The header does not say from which viewpoint "counterclockwise" is measured, which is
/// why yaw and roll signs below are UNVERIFIED until checked on a real camera.
public struct VisionFaceAngles: Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double

    public init(yaw: Double, pitch: Double, roll: Double) {
        self.yaw = yaw; self.pitch = pitch; self.roll = roll
    }

    public var isFinite: Bool { yaw.isFinite && pitch.isFinite && roll.isFinite }
}

/// Converts Vision's face angles into our head orientation (see `EulerAngles` for the
/// project's conventions: yaw+ = turn left, pitch+ = look up, roll+ = right ear down).
///
/// Sign decisions:
/// - pitch: negated. Vision's positive pitch is "head down"; ours is "look up". (From the header.)
/// - yaw:   assumed identity, i.e. Vision "counterclockwise" = counterclockwise seen from above =
///          turning toward the person's own left. UNVERIFIED: confirm with the manual camera test.
/// - roll:  assumed identity for an UNMIRRORED frame. Reasoning: with an unmirrored camera image,
///          the person's right is on the image's left, so tilting the right ear down rotates the
///          face counterclockwise in the image. UNVERIFIED: confirm with the manual camera test.
/// - A horizontally mirrored frame flips the sign of yaw and roll (not pitch).
/// - `invert*` flags are manual overrides, applied last, for use while verifying on hardware.
public struct HeadAngleMapping: Equatable, Sendable, Codable {
    public var invertYaw: Bool
    public var invertPitch: Bool
    public var invertRoll: Bool

    public init(invertYaw: Bool = false, invertPitch: Bool = false, invertRoll: Bool = false) {
        self.invertYaw = invertYaw; self.invertPitch = invertPitch; self.invertRoll = invertRoll
    }

    /// Mapped angles in our convention (radians), before quaternion conversion.
    public func euler(from a: VisionFaceAngles, frameMirrored: Bool) -> EulerAngles {
        var yaw = a.yaw
        var pitch = -a.pitch
        var roll = a.roll
        if frameMirrored { yaw = -yaw; roll = -roll }
        if invertYaw { yaw = -yaw }
        if invertPitch { pitch = -pitch }
        if invertRoll { roll = -roll }
        return EulerAngles(yaw: yaw, pitch: pitch, roll: roll)
    }

    public func orientation(from a: VisionFaceAngles, frameMirrored: Bool) -> Quaternion {
        Quaternion(euler: euler(from: a, frameMirrored: frameMirrored))
    }
}
