import AppKit
import Foundation
import Observation
import SpatialAudioCore
import SpatialAudioEngine
import SpatialAudioTracking

/// View model for head-tracked listening (Step 3b): ONE Start and ONE Stop for the camera and the audio together.
/// camera -> HeadTracker (default mapping, roll forced to 0) -> snapshot handler (capture / watchdog queue) -> `TrackedListeningSession.publish` -> PoseMailbox ->
/// pump -> `EnvironmentRenderer`. No CV and no DSP in this class; no report and no guided test (a later step). IMPLEMENTED-UNVERIFIED: how it sounds, and whether it
/// follows a real head, is unknown until Sanjai has listened.
@MainActor @Observable
final class TrackedListeningModel {
    static let shared = TrackedListeningModel()

    enum Stage: Equatable {
        case idle, starting, running
        case failed(String)
    }

    /// Everything the card shows while running, already numbers (the view formats them).
    struct Readout: Equatable {
        var sentYaw = 0.0, sentPitch = 0.0, sentRoll = 0.0       // degrees, the pose the pump last sent to the renderer
        var haveSent = false
        var state = "—"
        var facePresent = false
        var fps = 0.0
        var frameAge = 0.0
        var pumpTicks = 0
        var pumpMeanMs = 0.0
        var pumpMaxMs = 0.0
        var published = 0
        var rejected = 0
    }

    private(set) var stage: Stage = .idle
    private(set) var volume = TrackedListeningPolicy.defaultVolume
    private(set) var readout = Readout()
    /// Extremes seen since the start, for the silent self-check (and nothing else).
    private(set) var peaks = (yaw: 0.0, pitch: 0.0, roll: 0.0, rawRoll: 0.0)
    private(set) var statesSeen: [String] = []

    var isRunning: Bool { stage == .running }
    /// Starting or running: the exclusion rule treats both as "in use".
    var isActive: Bool { stage == .starting || stage == .running }

    @ObservationIgnored private var session: TrackedListeningSession?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private init() {}

    func setVolume(_ v: Double) {
        volume = TrackedListeningPolicy.clampedVolume(v)
        session?.setVolume(volume)
    }

    // MARK: control

    func start() async {
        guard !isActive else { return }
        let head = HeadTrackingModel.shared
        if let why = ListeningModes.conflict(requested: .cameraTracked) { stage = .failed(why); return }
        stage = .starting
        readout = Readout(); peaks = (0, 0, 0, 0); statesSeen = []

        // Audio first (nothing audible yet: the session only starts the engine later), so that a missing output fails before the camera opens.
        let created: TrackedListeningSession
        do {
            let renderer = try EnvironmentRenderer(mode: .live, loop: { SteadyNoise(sampleRate: $0).makeLoop() })
            created = TrackedListeningSession(output: renderer, sampleRate: renderer.sampleRate, volume: volume)
        } catch {
            stage = .failed(String(describing: error)); return
        }

        head.enterHeadTrackedListeningMode()
        guard await head.startAndWait() else {
            head.leaveHeadTrackedListeningMode()
            stage = .failed(head.statusText)
            return
        }
        do { try created.start() } catch {
            head.stop(); head.leaveHeadTrackedListeningMode()
            stage = .failed(String(describing: error)); return
        }
        session = created
        head.poseFeed.set { [created] snap in created.publish(pose: snap.pose, timestamp: snap.captureTime) }
        stage = .running
        refresh()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// The Stop button: audio off first, then the camera is stopped and its release is checked (the existing programmatic check; the green light is a visual check).
    func stopFromButton() {
        guard isActive else { return }
        stopAudioSide()
        let head = HeadTrackingModel.shared
        Task { @MainActor in
            await head.stopAndVerifyRelease()
            head.leaveHeadTrackedListeningMode()
        }
        stage = .idle
    }

    /// Synchronous: used when the app quits (and by a failed refresh). Releases the camera before returning.
    func stop() {
        guard isActive || session != nil else { return }
        stopAudioSide()
        let head = HeadTrackingModel.shared
        head.stop()
        head.leaveHeadTrackedListeningMode()
        if stage == .running || stage == .starting { stage = .idle }
    }

    private func stopAudioSide() {
        refreshTask?.cancel(); refreshTask = nil
        HeadTrackingModel.shared.poseFeed.set(nil)          // no pose reaches the session after this
        session?.stop(); session = nil
        readout = Readout()
    }

    func recenter() { HeadTrackingModel.shared.recenter() }

    // MARK: live readout

    private func refresh() {
        guard let session else { return }
        let head = HeadTrackingModel.shared
        let a = session.snapshot
        if !a.running {
            let why = a.notice ?? "The audio engine stopped."
            stop()
            stage = .failed(why)
            return
        }
        if head.status != .running {
            let why = head.statusText
            stop()
            stage = .failed("The camera stopped: \(why)")
            return
        }
        var r = Readout()
        if let e = a.sent {
            r.sentYaw = e.yawDegrees; r.sentPitch = e.pitchDegrees; r.sentRoll = e.rollDegrees; r.haveSent = true
        }
        if let s = head.snapshot {
            r.state = s.state.rawValue.uppercased()
            r.facePresent = s.facesDetected > 0 && !s.isWatchdogTick
            r.fps = s.framesPerSecond
            r.frameAge = s.frameAge
            peaks.rawRoll = max(peaks.rawRoll, abs(s.mappedRawEuler?.rollDegrees ?? 0))
            if statesSeen.last != r.state { statesSeen.append(r.state) }
        }
        r.pumpTicks = a.timing.ticks; r.pumpMeanMs = a.timing.meanPeriodMilliseconds; r.pumpMaxMs = a.timing.maxPeriodMilliseconds
        r.published = a.published; r.rejected = a.rejected
        if r.haveSent {
            peaks.yaw = max(peaks.yaw, abs(r.sentYaw)); peaks.pitch = max(peaks.pitch, abs(r.sentPitch)); peaks.roll = max(peaks.roll, abs(r.sentRoll))
        }
        readout = r
    }

    // MARK: developer self-check (--tracked-listening-selfcheck, needs --simulate)

    /// SILENT end-to-end check of this model's real start / feed / readout / stop path with the SIMULATED user (never the real camera; no sound: volume 0 before
    /// anything starts). Waits on counts and on the simulated user's own moves (a left turn read as yaw, a tilt seen in the raw roll), not on a clock; the deadline
    /// only stops it from hanging. Everything it sees is fabricated by the simulated user: it checks the wiring, not any head and not any ear.
    func runSilentSelfCheck() async {
        let head = HeadTrackingModel.shared
        guard head.isSimulated else {
            print("TRACKED SELFCHECK: refused. It needs --simulate (this check never opens the real camera).")
            NSApplication.shared.terminate(nil)
            return
        }
        setVolume(0)
        await start()
        guard isRunning, let session else {
            print("TRACKED SELFCHECK: could not start: \(stage)")
            NSApplication.shared.terminate(nil)
            return
        }
        head.beginSimulatedScript(at: HeadTracker.monotonicSeconds())
        let clock = SuspendingClock(), deadline = clock.now + .seconds(90)
        while clock.now < deadline {
            if (session.snapshot.applied?.steps ?? 0) >= 200, peaks.yaw >= 20, peaks.rawRoll >= 10 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let s = session.snapshot
        print("TRACKED SELFCHECK (SIMULATED user, volume \(volume)): running=\(s.running) pumpSteps=\(s.applied?.steps ?? 0) sinkWrites=\(s.applied?.sinkWrites ?? 0) published=\(s.published) rejected=\(s.rejected)")
        print(String(format: "TRACKED SELFCHECK card lines: sent yaw %+.1f pitch %+.1f roll %+.1f | state %@ | fps %.1f | pump %d ticks, mean %.2f ms, longest %.1f ms",
                     readout.sentYaw, readout.sentPitch, readout.sentRoll, readout.state, readout.fps, readout.pumpTicks, readout.pumpMeanMs, readout.pumpMaxMs))
        print(String(format: "TRACKED SELFCHECK peaks since start: |sent yaw| %.1f, |sent pitch| %.1f, |sent roll| %.3f, |raw roll shown by the tracker| %.1f; states seen: %@",
                     peaks.yaw, peaks.pitch, peaks.roll, peaks.rawRoll, statesSeen.joined(separator: " > ")))
        stop()
        print("TRACKED SELFCHECK stopped: stage=\(stage) cameraStatus=\(head.statusText)")
        NSApplication.shared.terminate(nil)
    }
}
