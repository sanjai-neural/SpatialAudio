import Foundation

public enum SpeakerID: String, CaseIterable, Sendable {
    case L, R, C, LFE
    case Lss, Rss   // side surround
    case Lrs, Rrs   // rear surround
    case Ltf, Rtf   // top front (height)
    case Ltr, Rtr   // top rear (height)
}

public enum SpeakerGroup: Sendable {
    case earLevel, lfe, height
}

/// A virtual speaker. Angles use the audio-standard convention, NOT the pose convention:
/// azimuth 0 = straight ahead, positive = to the RIGHT (clockwise seen from above), ±180 = behind;
/// elevation 0 = ear level, positive = up. LFE has no direction: it is not spatialized.
public struct Speaker: Equatable, Sendable {
    public let id: SpeakerID
    public let group: SpeakerGroup
    public let azimuthDegrees: Double?
    public let elevationDegrees: Double?

    public var isSpatialized: Bool { group != .lfe }

    /// Position on a sphere of radius `distance` around the listener in the project's
    /// coordinate frame (+X right, +Y up, forward = -Z). nil for LFE.
    public func position(distance: Double = 1) -> Vector3? {
        guard let az = azimuthDegrees, let el = elevationDegrees else { return nil }
        let a = az * .pi / 180, e = el * .pi / 180
        return Vector3(sin(a) * cos(e), sin(e), -cos(a) * cos(e)) * distance
    }
}

public struct SpeakerLayout: Equatable, Sendable {
    public let name: String
    public let speakers: [Speaker]

    public var spatialized: [Speaker] { speakers.filter(\.isSpatialized) }
    public var lfe: Speaker? { speakers.first { $0.group == .lfe } }
    public func speaker(_ id: SpeakerID) -> Speaker? { speakers.first { $0.id == id } }

    /// 7.1.4 reference layout (7 ear-level + LFE + 4 height). Order here is internal only;
    /// it is NOT guaranteed to match any file/stream channel order.
    ///
    /// Source: Dolby Atmos Home Theater Installation Guidelines (text extracted 2026-11-04):
    /// - L/R ±30° ........................ stated (also the reference for overhead width)
    /// - Rear surround ≈135° ............. stated
    /// - Heights elevation 45° (30–55° allowed) ... stated
    /// - Top front ±30° az (ceiling case: 45° elevation) ... stated
    /// - Top rear ≈135° az (ceiling case) ... stated
    /// - Side surround ±90° .............. NOT verified: the value is only in a figure we could not
    ///   read; 90° is a common choice (practice is 90–110°). Treat as an assumption.
    /// Sound at 45° elevation with a generic HRTF will localize weakly; expect that in Step 4.
    public static let dolby714 = SpeakerLayout(name: "7.1.4", speakers: [
        Speaker(id: .L,   group: .earLevel, azimuthDegrees: -30,  elevationDegrees: 0),
        Speaker(id: .R,   group: .earLevel, azimuthDegrees: 30,   elevationDegrees: 0),
        Speaker(id: .C,   group: .earLevel, azimuthDegrees: 0,    elevationDegrees: 0),
        Speaker(id: .LFE, group: .lfe,      azimuthDegrees: nil,  elevationDegrees: nil),
        Speaker(id: .Lss, group: .earLevel, azimuthDegrees: -90,  elevationDegrees: 0),
        Speaker(id: .Rss, group: .earLevel, azimuthDegrees: 90,   elevationDegrees: 0),
        Speaker(id: .Lrs, group: .earLevel, azimuthDegrees: -135, elevationDegrees: 0),
        Speaker(id: .Rrs, group: .earLevel, azimuthDegrees: 135,  elevationDegrees: 0),
        Speaker(id: .Ltf, group: .height,   azimuthDegrees: -30,  elevationDegrees: 45),
        Speaker(id: .Rtf, group: .height,   azimuthDegrees: 30,   elevationDegrees: 45),
        Speaker(id: .Ltr, group: .height,   azimuthDegrees: -135, elevationDegrees: 45),
        Speaker(id: .Rtr, group: .height,   azimuthDegrees: 135,  elevationDegrees: 45),
    ])
}
