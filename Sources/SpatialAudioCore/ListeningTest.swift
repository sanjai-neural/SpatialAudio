import Foundation

/// One instant of a scripted listening test: where the synthetic head points and where the tone sits in the room.
public struct ListeningScene: Equatable, Sendable {
    public var headPose: Quaternion
    /// Fixed position of the test tone in the room frame (+X right, +Y up, forward = -Z), meters from the listener.
    public var sourcePosition: Vector3
    /// What is happening, in words ("Head turned LEFT 31°").
    public var caption: String

    public init(headPose: Quaternion, sourcePosition: Vector3, caption: String) {
        self.headPose = headPose; self.sourcePosition = sourcePosition; self.caption = caption
    }
}

/// Audio-only listening tests (Step 3a): a scripted SYNTHETIC head and a fixed virtual tone, no camera anywhere.
/// Each test is a pure function of time that loops, so it is fully unit-testable; the "what you should hear" text is
/// derived from the same geometry the renderer is checked against (`ListenerGeometry`), not typed in by hand.
public enum ListeningTest: String, CaseIterable, Sendable, Identifiable {
    /// Head still; the tone is placed hard left, hard right, then straight ahead. Checks the source-side
    /// convention (+X = right) and your headphones, without involving any head rotation.
    case sourceSides
    /// Tone fixed straight ahead; the head slowly turns left, through centre, right, and back (+-60 degrees, 12 s).
    case headSweepYaw
    /// Tone fixed straight ahead; the head turns 45 degrees left and holds, returns, turns 45 degrees right and holds.
    case headHoldsYaw
    /// Tone fixed straight ahead; the head nods up and down (+-40 degrees, 12 s). Vertical cues are weak with a generic HRTF.
    case headSweepPitch
    /// Tone fixed 60 degrees to the right; the head tilts ear to ear (+-40 degrees, 12 s). Subtle by ear.
    case headSweepRoll

    public var id: String { rawValue }

    public static let sourceDistance = 2.0
    public static let yawSweepAmplitudeDegrees = 60.0
    public static let yawHoldDegrees = 45.0
    public static let pitchSweepAmplitudeDegrees = 40.0
    public static let rollSweepAmplitudeDegrees = 40.0
    public static let sweepPeriodSeconds = 12.0
    /// Where the roll test puts the tone (audio-standard azimuth, positive = right).
    public static let rollTestSourceAzimuthDegrees = 60.0

    public var title: String {
        switch self {
        case .sourceSides: "A · Tone moves hard left / hard right / ahead (head still)"
        case .headSweepYaw: "B · Head sweeps left ↔ right (yaw)"
        case .headHoldsYaw: "C · Head turns 45° left, then 45° right, holding each"
        case .headSweepPitch: "D · Head nods up ↔ down (pitch, subtle)"
        case .headSweepRoll: "E · Head tilts ear to ear (roll, subtle)"
        }
    }

    /// What a correct pipeline sounds like. Short on purpose.
    public var whatYouShouldHear: String {
        switch self {
        case .sourceSides:
            "Your head stays still. The tone jumps every 3 s: hard LEFT, hard RIGHT, then straight AHEAD. You should hear it in your LEFT ear, then your RIGHT ear, then in the middle. This checks which side is which without any head motion."
        case .headSweepYaw:
            "The tone is fixed in the room straight ahead of you while a scripted head slowly turns. When the head turns LEFT the tone should slide toward your RIGHT ear, and when it turns RIGHT the tone should slide toward your LEFT ear (like a real fixed speaker). One cycle takes 12 s."
        case .headHoldsYaw:
            "Same fixed tone straight ahead. The head turns 45° LEFT and holds for 3 s (tone clearly on your RIGHT), returns to centre, turns 45° RIGHT and holds (tone clearly on your LEFT), then returns."
        case .headSweepPitch:
            "Tone fixed straight ahead. When the head looks UP the tone should seem to drop BELOW your line of sight, and when it looks DOWN it should seem ABOVE. With a generic HRTF up/down is much harder to hear than left/right; if you cannot tell, that is normal and says nothing about the code."
        case .headSweepRoll:
            "Tone fixed about 60° to your right. When the head tilts RIGHT ear down the tone should seem to rise ABOVE your ear level, and when it tilts LEFT ear down it should seem to drop BELOW. This is subtle by ear."
        }
    }

    /// Seconds after which the script repeats.
    public var loopDuration: Double {
        switch self {
        case .sourceSides: 9
        case .headSweepYaw, .headSweepPitch, .headSweepRoll: Self.sweepPeriodSeconds
        case .headHoldsYaw: 14
        }
    }

    /// The scene at `time` seconds from the start (any real number; the script loops).
    public func scene(at time: Double) -> ListeningScene {
        let t = wrapped(time)
        let ahead = Vector3.direction(azimuthDegrees: 0, elevationDegrees: 0, distance: Self.sourceDistance)
        switch self {
        case .sourceSides:
            let azimuth: Double = t < 3 ? -90 : (t < 6 ? 90 : 0)
            let words = azimuth < 0 ? "hard LEFT" : (azimuth > 0 ? "hard RIGHT" : "straight AHEAD")
            return ListeningScene(
                headPose: .identity,
                sourcePosition: .direction(azimuthDegrees: azimuth, elevationDegrees: 0, distance: Self.sourceDistance),
                caption: "Head still. Tone placed \(words).")
        case .headSweepYaw:
            let yaw = Self.yawSweepAmplitudeDegrees * sin(2 * .pi * t / Self.sweepPeriodSeconds)
            return ListeningScene(headPose: Self.pose(yaw: yaw), sourcePosition: ahead, caption: Self.yawCaption(yaw))
        case .headHoldsYaw:
            let yaw = Self.holdsYawDegrees(at: t)
            return ListeningScene(headPose: Self.pose(yaw: yaw), sourcePosition: ahead, caption: Self.yawCaption(yaw))
        case .headSweepPitch:
            let pitch = Self.pitchSweepAmplitudeDegrees * sin(2 * .pi * t / Self.sweepPeriodSeconds)
            let words = abs(pitch) < 3 ? "Head level." : "Head looking \(pitch > 0 ? "UP" : "DOWN") \(Int(abs(pitch).rounded()))°."
            return ListeningScene(headPose: Self.pose(pitch: pitch), sourcePosition: ahead, caption: words)
        case .headSweepRoll:
            let roll = Self.rollSweepAmplitudeDegrees * sin(2 * .pi * t / Self.sweepPeriodSeconds)
            let words = abs(roll) < 3 ? "Head upright." : "Head tilted, \(roll > 0 ? "RIGHT" : "LEFT") ear down \(Int(abs(roll).rounded()))°."
            return ListeningScene(
                headPose: Self.pose(roll: roll),
                sourcePosition: .direction(azimuthDegrees: Self.rollTestSourceAzimuthDegrees, elevationDegrees: 0,
                                           distance: Self.sourceDistance),
                caption: words)
        }
    }

    /// Where the tone SHOULD seem to be, relative to the head, at `time`. Pure geometry with the identity mapping:
    /// the truth a correct pipeline has to reproduce, independent of any flip switches.
    public func expectedDirection(at time: Double) -> RelativeDirection {
        let s = scene(at: time)
        return ListenerGeometry.relativeDirection(of: s.sourcePosition, listenerPose: s.headPose)
    }

    // MARK: - Helpers

    private func wrapped(_ time: Double) -> Double {
        guard time.isFinite, loopDuration > 0 else { return 0 }
        let r = time.truncatingRemainder(dividingBy: loopDuration)
        return r < 0 ? r + loopDuration : r
    }

    private static func pose(yaw: Double = 0, pitch: Double = 0, roll: Double = 0) -> Quaternion {
        Quaternion(euler: EulerAngles(yawDegrees: yaw, pitchDegrees: pitch, rollDegrees: roll))
    }

    private static func yawCaption(_ yaw: Double) -> String {
        abs(yaw) < 3 ? "Head facing straight ahead." : "Head turned \(yaw > 0 ? "LEFT" : "RIGHT") \(Int(abs(yaw).rounded()))°."
    }

    /// 0 for 2 s, ease to +45 (left) over 1 s, hold 3 s, ease to 0, hold 2 s, ease to -45 (right), hold 3 s, ease to 0. Total 14 s.
    private static func holdsYawDegrees(at t: Double) -> Double {
        let h = yawHoldDegrees
        let segments: [(start: Double, end: Double, from: Double, to: Double)] = [
            (0, 2, 0, 0), (2, 3, 0, h), (3, 6, h, h), (6, 7, h, 0),
            (7, 9, 0, 0), (9, 10, 0, -h), (10, 13, -h, -h), (13, 14, -h, 0),
        ]
        for s in segments where t >= s.start && t < s.end {
            let u = (t - s.start) / (s.end - s.start)
            let eased = u * u * (3 - 2 * u)              // smoothstep: zero speed at both ends
            return s.from + (s.to - s.from) * eased
        }
        return 0
    }
}
