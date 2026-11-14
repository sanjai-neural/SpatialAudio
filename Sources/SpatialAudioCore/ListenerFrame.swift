import Foundation

/// Listener orientation in the form `AVAudioEnvironmentNode.listenerVectorOrientation` takes: where the listener's nose
/// points (`forward`) and where the top of the head points (`up`), both unit vectors in the room (world) frame.
///
/// Frame: right-handed, +X right, +Y up, forward = -Z. The neutral listener faces -Z with +Y up; the SDK header
/// (AVAudioEnvironmentNode.h) documents exactly that as the default (forward (0,0,-1), up (0,1,0)).
///
/// Why vectors and not `listenerAngularOrientation` (checked on 2026-11-05 by setting a vector orientation and reading
/// the angular one back): AVAudio's yaw is CLOCKWISE-positive ("turn right" = +), the opposite of this project's
/// yaw (+ = turn left); pitch (+ = up) and roll (+ = right ear down) agree with ours. Feeding our yaw to the angular
/// property would silently mirror left and right. The vector form has no sign conventions to get wrong.
public struct ListenerOrientation: Equatable, Sendable {
    public var forward: Vector3
    public var up: Vector3

    public init(forward: Vector3, up: Vector3) {
        self.forward = forward; self.up = up
    }

    public static let neutral = ListenerOrientation(forward: .forward, up: .up)

    /// forward x up: the listener's right-hand direction (+X for the neutral listener).
    public var right: Vector3 { forward.cross(up) }

    /// True if either vector differs from `other` by more than `tolerance` (Euclidean distance).
    public func differs(from other: ListenerOrientation, tolerance: Double = 1e-6) -> Bool {
        (forward - other.forward).length > tolerance || (up - other.up).length > tolerance
    }
}

/// Manual sign overrides on the AUDIO side of the chain (after the camera mapping, `HeadAngleMapping`, which has its
/// own flags). They exist for the listening test: if a scripted head turn sounds mirrored, flipping the axis shows
/// which sign would be right. They are never a substitute for fixing the conversion: the default is the identity and
/// stays that way unless a listening test says otherwise.
public struct ListenerMapping: Equatable, Sendable, Codable {
    public var invertYaw: Bool
    public var invertPitch: Bool
    public var invertRoll: Bool
    /// Step 3b: the roll angle of the pose is set to 0 AFTER any inversion (yaw and pitch unchanged). Head-tracked listening uses this at the pump's output, so
    /// the listener the renderer receives never has a roll, even when interpolating between two poses leaves a tiny one. Default off.
    public var zeroRoll: Bool

    public init(invertYaw: Bool = false, invertPitch: Bool = false, invertRoll: Bool = false, zeroRoll: Bool = false) {
        self.invertYaw = invertYaw; self.invertPitch = invertPitch; self.invertRoll = invertRoll; self.zeroRoll = zeroRoll
    }

    public var isIdentity: Bool { !(invertYaw || invertPitch || invertRoll || zeroRoll) }

    /// The pose with the flagged axes negated. Goes through Euler angles (an API-boundary operation) only when a flag
    /// is set; the identity mapping returns the normalized input untouched.
    public func apply(to pose: Quaternion) -> Quaternion {
        guard !isIdentity else { return pose.normalized() }
        var e = pose.euler
        if invertYaw { e.yaw = -e.yaw }
        if invertPitch { e.pitch = -e.pitch }
        if invertRoll { e.roll = -e.roll }
        if zeroRoll { e.roll = 0 }
        return Quaternion(euler: e)
    }
}

public enum ListenerFrame {
    /// Head pose (our convention, `Quaternion` rotating head-frame vectors into the room frame) to the listener
    /// orientation that `AVAudioEnvironmentNode` should be given. A non-finite or zero pose becomes neutral.
    ///
    /// Verified end to end by offline rendering (docs/STATUS.md, Step 3a): rendering with this orientation and a source
    /// at P is identical to rendering with the neutral listener and the source at pose^-1 * P, for yaw, pitch, roll and
    /// combinations, and differs by 55-150% when the rotation is applied in the wrong direction.
    public static func orientation(for pose: Quaternion, mapping: ListenerMapping = ListenerMapping()) -> ListenerOrientation {
        let q = mapping.apply(to: pose)
        return ListenerOrientation(forward: q.rotate(.forward), up: q.rotate(.up))
    }
}

/// Where a point in the room is, as seen from the listener's head. Audio-standard angles (like `Speaker`):
/// azimuth 0 = straight ahead, positive = to the listener's RIGHT, +-180 = behind; elevation positive = up.
public struct RelativeDirection: Equatable, Sendable {
    public var azimuthDegrees: Double
    public var elevationDegrees: Double
    public var distance: Double

    public init(azimuthDegrees: Double, elevationDegrees: Double, distance: Double) {
        self.azimuthDegrees = azimuthDegrees; self.elevationDegrees = elevationDegrees; self.distance = distance
    }

    /// Short plain-English description for the listening test ("to your RIGHT, 32° from straight ahead, ABOVE (12°)").
    public var plainEnglish: String {
        guard distance > 1e-9 else { return "at the centre of your head" }
        let a = abs(azimuthDegrees)
        var text: String
        if a < 8 {
            text = "straight ahead"
        } else if a > 172 {
            text = "directly behind you"
        } else {
            let side = azimuthDegrees > 0 ? "RIGHT" : "LEFT"
            text = "to your \(side), \(Int(a.rounded()))° from straight ahead"
            if a > 100 { text += " (behind you)" }
        }
        if abs(elevationDegrees) >= 8 {
            text += ", " + (elevationDegrees > 0 ? "ABOVE" : "BELOW") + " (\(Int(abs(elevationDegrees).rounded()))°)"
        }
        return text
    }
}

public enum ListenerGeometry {
    /// Direction of a world-fixed `source` from a listener at the origin with the given head pose. This is the
    /// physical truth the listening test compares against, so it uses the mapping only if you pass one explicitly
    /// (the default identity = "what a correct conversion must make you hear").
    public static func relativeDirection(of source: Vector3, listenerPose pose: Quaternion,
                                         mapping: ListenerMapping = ListenerMapping()) -> RelativeDirection {
        let q = mapping.apply(to: pose)
        let p = q.inverse().rotate(source)               // the source in head coordinates
        let d = p.length
        guard d > 1e-9 else { return RelativeDirection(azimuthDegrees: 0, elevationDegrees: 0, distance: 0) }
        return RelativeDirection(azimuthDegrees: atan2(p.x, -p.z) * 180 / .pi,
                                 elevationDegrees: asin(min(max(p.y / d, -1), 1)) * 180 / .pi,
                                 distance: d)
    }
}
