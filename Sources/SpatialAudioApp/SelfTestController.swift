import AppKit
import Foundation
import Observation
import SpatialAudioCore
import SpatialAudioTracking

/// Runs the guided self-test: plays the script against a monotonic clock, plays the cues, feeds frames to the
/// session, then hands everything to the pure analyzer in SpatialAudioCore. This type only does orchestration
/// and I/O (sounds, files, clipboard); it contains no analysis logic.
@MainActor @Observable
final class SelfTestController {
    enum Stage: Equatable { case idle, preparing, running, finished }

    private(set) var stage: Stage = .idle
    private(set) var status: SelfTestStatus?
    var lighting: LightingTag = LaunchOptions.current.lighting
    private(set) var report: SelfTestReport?
    private(set) var savedFiles: [URL] = []
    private(set) var saveError: String?
    private(set) var message: String?
    private(set) var confirmingApply = false
    private(set) var appliedNote: String?
    private(set) var releaseCheckRunning = false

    @ObservationIgnored private weak var model: HeadTrackingModel?
    @ObservationIgnored private var session: SelfTestSession?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var stem = ""

    func attach(model: HeadTrackingModel) {
        self.model = model
        CueSounds.muted = LaunchOptions.current.muteCues
    }

    var isBusy: Bool { stage == .preparing || stage == .running }

    // MARK: run

    func run() {
        guard !isBusy, let model else { return }
        if model.status == .starting {
            message = "The camera is still starting. Try again in a moment."
            return
        }
        resetResults()
        stage = .preparing
        message = model.status == .running ? nil : "Starting the camera… (macOS may ask for permission the first time)"
        Task { [weak self] in await self?.begin() }
    }

    private func begin() async {
        guard let model else { return }
        if model.status != .running {
            let started = await model.startAndWait()
            guard stage == .preparing else { return }            // aborted while the camera was starting
            guard started else {
                stage = .idle
                message = "Could not start: \(model.statusText)"
                return
            }
        }
        guard stage == .preparing else { return }
        let start = HeadTracker.monotonicSeconds()
        session = SelfTestSession(lighting: lighting, startTime: start)
        model.beginSimulatedScript(at: start)
        stage = .running
        message = nil
        status = session?.status(at: start)
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func abort() {
        guard isBusy else { return }
        session?.abort()
        session = nil
        tickTask?.cancel(); tickTask = nil
        stage = .idle
        status = nil
        message = "Self-test aborted. Nothing was saved."
    }

    private func tick() {
        guard stage == .running, var s = session else { return }
        let now = HeadTracker.monotonicSeconds()
        let events = s.advance(to: now)
        session = s
        status = s.status(at: now)
        var cue: SelfTestCue?
        var finished = false
        for e in events {
            switch e {
            case .phaseStarted(let i): cue = s.script.phases[i].cue
            case .finished: finished = true
            }
        }
        if finished { finish() } else if let cue { CueSounds.play(cue) }
    }

    /// Called by the model for every processed frame / watchdog tick.
    func ingest(_ snapshot: TrackingSnapshot, arrival: Double) {
        guard stage == .running else { return }
        session?.record(snapshot.selfTestFrame(arrival: arrival))
    }

    // MARK: finish

    private func finish() {
        tickTask?.cancel(); tickTask = nil
        guard let s = session, let model else { stage = .idle; return }
        let now = Date()
        let simulated = model.isSimulated
        let context = SelfTestContext(
            createdAt: SelfTestReport.timestamp(now),
            inputSource: simulated ? "simulated" : "camera",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: HardwareInfo.model,
            cameraName: model.deviceName,
            capturePreset: "640x480 (AVCaptureSession.Preset.vga640x480)",
            visionRevision: VisionFaceDetector.revisionInUse,
            mappingDuringTest: model.mapping,
            machine: model.trackerConfig.machine)
        report = SelfTestAnalyzer.analyze(s, context: context)
        stem = SelfTestReport.fileStem(date: now, lighting: s.lighting, simulated: simulated)
        let frames = s.framesByPhase.reduce(0) { $0 + $1.count }
        message = frames < 100 ? "Only \(frames) frames were received during the test; the results are not meaningful." : nil
        session = nil
        status = nil
        stage = .finished
        CueSounds.play(.done)
        persist()

        // Camera release: stop the camera, wait a moment, read back the capture session's state.
        releaseCheckRunning = true
        Task { [weak self] in
            let release = await model.stopAndVerifyRelease()
            self?.releaseCheckFinished(release)
        }
    }

    private func releaseCheckFinished(_ release: CameraReleaseReport?) {
        releaseCheckRunning = false
        report?.cameraRelease = release
        persist()
        if LaunchOptions.current.exitAfterSelfTest { NSApplication.shared.terminate(nil) }
    }

    private func persist() {
        guard let report else { return }
        do {
            let dir = ReportStore.resultsDirectory(override: LaunchOptions.current.resultsDirectory)
            savedFiles = try ReportStore.write(report, stem: stem, to: dir)
            saveError = nil
        } catch {
            saveError = "Could not save the report: \(error.localizedDescription)"
        }
    }

    private func resetResults() {
        report = nil; savedFiles = []; saveError = nil; message = nil
        confirmingApply = false; appliedNote = nil; releaseCheckRunning = false; status = nil
    }

    // MARK: results actions

    func dismissResults() {
        guard stage == .finished else { return }
        resetResults()
        stage = .idle
    }

    func copyReport() {
        guard let report else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report.markdown(), forType: .string)
        message = "Report copied to the clipboard."
    }

    func revealFiles() {
        guard !savedFiles.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(savedFiles)
    }

    func answerGreenLight(isOff: Bool) {
        report?.greenLight = isOff ? .off : .stillOn
        persist()
    }

    // MARK: apply detected signs (only after the user confirms)

    /// The mapping that applying would produce: determined axes take the detected flag, inconclusive axes keep
    /// their current setting.
    var detectedMapping: HeadAngleMapping? {
        guard let report, let model else { return nil }
        return report.signs.recommendedMapping(over: model.mapping)
    }

    var canApply: Bool {
        guard let report else { return false }
        return !report.isSimulated && !report.signs.determinedAxes.isEmpty
    }

    func requestApply() { if canApply { confirmingApply = true } }
    func cancelApply() { confirmingApply = false }

    func confirmApply() {
        guard canApply, let report, let model, let mapping = detectedMapping else { return }
        let mirrored = (report.environment.framesMirroredFraction ?? 0) >= 0.5
        model.applyDetectedMapping(mapping, cameraName: report.environment.cameraName ?? "unknown camera",
                                   framesMirrored: mirrored, timestamp: report.createdAt)
        self.report?.appliedMapping = mapping
        confirmingApply = false
        appliedNote = "Applied and saved as this app's sign defaults. Start the camera, look at the screen and press Recenter, then check: turn LEFT → the arrow points left and yaw is positive."
        persist()
    }
}
