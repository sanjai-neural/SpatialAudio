import AppKit
import Foundation
import Observation
import SpatialAudioCore
import SpatialAudioEngine

/// View model for the audio-only listening test (Step 3a). It owns a `ListeningTestSession` and republishes its state to
/// the UI. No camera, no tracking and no DSP live here: the scripted head, the pose pump and the renderer are in
/// SpatialAudioCore / SpatialAudioEngine.
@MainActor @Observable
final class AudioTestModel {
    static let shared = AudioTestModel()

    enum State: Equatable {
        case idle, running
        case failed(String)
    }

    /// Everything the card shows while a test runs, already formatted.
    struct Readout: Equatable {
        var scriptTime = ""
        var head = ""
        var expected = ""
        var sent = ""
        var timing = ""
    }

    private(set) var state: State = .idle
    private(set) var selected: ListeningTest = .headSweepYaw
    private(set) var flips = ListenerMapping()
    private(set) var volume = 0.30
    private(set) var readout = Readout()

    var isRunning: Bool { state == .running }

    @ObservationIgnored private var session: ListeningTestSession?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?

    private init() {}

    // MARK: control

    func start() {
        guard !isRunning else { return }
        do {
            let renderer = try EnvironmentRenderer(mode: .live)
            renderer.outputVolume = Float(volume)                  // the slider level is in place before any sound exists
            let s = ListeningTestSession(renderer: renderer, test: selected, mapping: flips)
            try s.start()
            session = s
            state = .running
            beginActivity()
            refresh()
            refreshTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.refresh()
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        } catch {
            session = nil
            state = .failed(String(describing: error))
        }
    }

    /// Synchronous; also called when the app quits.
    func stop() {
        refreshTask?.cancel(); refreshTask = nil
        session?.stop(); session = nil
        endActivity()
        if state == .running { state = .idle }
        readout = Readout()
    }

    func select(_ test: ListeningTest) {
        selected = test
        session?.select(test)
    }

    func setFlip(yaw: Bool? = nil, pitch: Bool? = nil, roll: Bool? = nil) {
        if let yaw { flips.invertYaw = yaw }
        if let pitch { flips.invertPitch = pitch }
        if let roll { flips.invertRoll = roll }
        session?.setMapping(flips)
    }

    func resetFlips() {
        flips = ListenerMapping()
        session?.setMapping(flips)
    }

    func setVolume(_ v: Double) {
        volume = min(max(v, 0), 1)
        session?.renderer.outputVolume = Float(volume)
    }

    // MARK: developer self-check (--audio-test-selfcheck)

    /// SILENT end-to-end check of this model's own code path: volume 0 before anything starts, start, wait for the pose
    /// pump to have ticked, print what the card would show, stop, quit. Waits on a count of ticks, not a time; the
    /// deadline only stops it from hanging. Opens no camera and makes no sound.
    func runSilentSelfCheck() async {
        setVolume(0)
        select(.headSweepYaw)
        start()
        guard isRunning, let session else {
            print("AUDIO SELFCHECK: could not start: \(state)")
            NSApplication.shared.terminate(nil)
            return
        }
        let clock = SuspendingClock(), deadline = clock.now + .seconds(60)
        while clock.now < deadline, (session.snapshot.applied?.steps ?? 0) < 200 { try? await Task.sleep(for: .milliseconds(20)) }
        refresh()
        let s = session.snapshot
        print("AUDIO SELFCHECK (silent, volume \(volume)): running=\(s.running) steps=\(s.applied?.steps ?? 0) sinkWrites=\(s.applied?.sinkWrites ?? 0) mailboxSequence=\(s.applied?.mailboxSequence ?? 0)")
        print("AUDIO SELFCHECK card lines:\n  \(readout.scriptTime)\n  HEAD:  \(readout.head)\n  EXPECTED:  \(readout.expected)\n  \(readout.sent)\n  \(readout.timing)")
        setFlip(yaw: true)
        try? await Task.sleep(for: .milliseconds(100))
        refresh()
        print("AUDIO SELFCHECK after flipping yaw: \(readout.sent)")
        stop()
        print("AUDIO SELFCHECK stopped: state=\(state) running=\(isRunning)")
        NSApplication.shared.terminate(nil)
    }

    // MARK: live readout

    private func refresh() {
        guard let session else { return }
        let s = session.snapshot
        if !s.running {
            // The engine stopped by itself (for example the output device changed).
            let why = s.notice ?? "The audio engine stopped."
            stop()
            state = .failed(why)
            return
        }
        let e = s.scene.headPose.euler
        readout = Readout(
            scriptTime: String(format: "script time %4.1f s of a %.0f s loop", s.scriptTime.truncatingRemainder(dividingBy: s.test.loopDuration), s.test.loopDuration),
            head: "\(s.scene.caption)   (yaw \(signed(e.yawDegrees))°  pitch \(signed(e.pitchDegrees))°  roll \(signed(e.rollDegrees))°)",
            expected: "The tone should seem \(s.expected.plainEnglish).",
            sent: sentLine(s),
            timing: timingLine(s))
    }

    private func sentLine(_ s: ListeningTestSession.Snapshot) -> String {
        let f = s.applied?.orientation.forward ?? Vector3.forward
        let flipped = [s.mapping.invertYaw ? "yaw" : nil, s.mapping.invertPitch ? "pitch" : nil, s.mapping.invertRoll ? "roll" : nil].compactMap { $0 }
        return String(format: "Engine listener forward = (%+.2f, %+.2f, %+.2f)   flipped axes: %@", f.x, f.y, f.z, flipped.isEmpty ? "none" : flipped.joined(separator: ", "))
    }

    private func timingLine(_ s: ListeningTestSession.Snapshot) -> String {
        guard s.timing.ticks > 0 else { return "pose pump: starting…" }
        return String(format: "pose pump: %d ticks, mean %.2f ms, longest %.1f ms between ticks", s.timing.ticks, s.timing.meanPeriodMilliseconds, s.timing.maxPeriodMilliseconds)
    }

    private func signed(_ v: Double) -> String { String(format: "%+.0f", v) }

    // MARK: App Nap

    /// Same reason as head tracking: an occluded GUI app gets its timers coalesced, which would make the pump jittery.
    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Audio listening test needs regular timer delivery")
    }

    private func endActivity() {
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }
}
