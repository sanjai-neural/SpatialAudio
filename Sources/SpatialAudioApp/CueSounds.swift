import AppKit
import SpatialAudioCore

/// Short system sounds at each self-test phase, so you can follow the test while looking away from the
/// screen. The sound files are the macOS system sounds (verified present on this Mac); if one is ever
/// missing the system beep is used instead.
@MainActor
enum CueSounds {
    static var muted = false
    private static var cache: [String: NSSound] = [:]

    static func play(_ cue: SelfTestCue) {
        guard !muted else { return }
        let name: String
        switch cue {
        case .begin: name = "Glass"      // test starting
        case .hold: name = "Pop"         // move now and hold
        case .rest: name = "Tink"        // go back to the centre
        case .cover: name = "Basso"      // cover the camera
        case .uncover: name = "Ping"     // uncover the camera
        case .done: name = "Hero"        // finished
        }
        if let sound = cache[name] ?? NSSound(named: NSSound.Name(name)) {
            cache[name] = sound
            sound.stop()
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}
