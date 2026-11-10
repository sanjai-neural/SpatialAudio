import AppKit
import Foundation
import Observation
import SpatialAudioCore
import SpatialAudioEngine

/// View model for the blind listening test (Step 3a-2). It owns a `BlindListeningSession` and turns button presses into answers. No DSP, no camera, no tracker.
/// The truth of a trial is not available here while the test runs: `BlindFrame` has no such field and `BlindRunner.results` is nil until the run is over.
/// IMPLEMENTED-UNVERIFIED until Sanjai has run it.
@MainActor @Observable
final class BlindListeningModel {
    static let shared = BlindListeningModel()

    enum Stage: Equatable {
        case idle, running
        /// The run is over (finished or stopped); the three end-of-test questions are open.
        case questions
        case saved
        case failed(String)
    }

    private(set) var stage: Stage = .idle
    /// Low by default; fixed while a run is going (the volume is part of what the report states).
    private(set) var volume = 0.20
    private(set) var frame: BlindFrame?
    var endAnswers = BlindEndAnswers()
    /// Where the report went (shown here only; the report itself holds no path).
    private(set) var savedPaths: [String] = []
    private(set) var summary: [String] = []
    private(set) var completed = true

    var isRunning: Bool { stage == .running }

    @ObservationIgnored private var session: BlindListeningSession?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var endedAt = Date()
    @ObservationIgnored private var device: ListeningDeviceFacts?
    @ObservationIgnored private var facts: BlindRunFacts?
    @ObservationIgnored private var seed: UInt64 = 0
    @ObservationIgnored private var heldResults: BlindRunResults?

    private init() {}

    func setVolume(_ v: Double) { if !isRunning { volume = min(max(v, 0), 1) } }

    // MARK: control

    func start() {
        guard !isRunning else { return }
        guard !AudioTestModel.shared.isRunning else { stage = .failed("The scripted audio test is running. Stop it first: two engines at once would confuse the test."); return }
        do {
            let renderer = try EnvironmentRenderer(mode: .live)
            renderer.outputVolume = 0                                   // silent until the session's first (silent) set-up has run
            seed = UInt64.random(in: 0..<(1 << 32))
            let s = BlindListeningSession(output: renderer, sampleRate: renderer.sampleRate, seed: seed, baseVolume: volume)
            endAnswers = BlindEndAnswers(); savedPaths = []; summary = []; heldResults = nil; facts = nil; completed = true
            startedAt = Date()
            try s.start()
            device = BlindListeningSession.readDefaultOutputFacts()    // after the engine is up: the device is in its running state
            session = s
            stage = .running
            beginActivity()
            refresh()
            refreshTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.refresh()
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        } catch {
            session = nil
            stage = .failed(String(describing: error))
        }
    }

    /// The Stop button: the tone fades out, then the questions open (a partial run is a partial report, marked as such).
    func requestStop() { session?.abort() }

    /// Synchronous; also called when the app quits. A run stopped this way is discarded (no report).
    func stop() {
        refreshTask?.cancel(); refreshTask = nil
        session?.stop(); session = nil
        endActivity()
        if stage == .running { stage = .idle }
        frame = nil
    }

    func answer(_ a: BlindAnswer) { _ = session?.answer(a) }

    /// The end-of-test buttons.
    func setClicks(_ v: BlindYesNo) { endAnswers.clicksOrCrackling = v }
    func setLocation(_ v: BlindHeadLocation) { endAnswers.soundLocation = v }
    func setAirPods(_ v: BlindAirPodsState) { endAnswers.airPodsSpatialAudio = v }

    func reset() { if stage != .running { stage = .idle; savedPaths = []; summary = []; heldResults = nil; frame = nil } }

    // MARK: finishing

    private func refresh() {
        guard let session else { return }
        let snap = session.snapshot
        frame = snap.frame
        if snap.silentAndFinished {
            // The last fade has reached zero: stop the engine (no click), collect what was measured, open the questions.
            endedAt = Date()
            facts = session.runFacts()
            heldResults = session.results
            refreshTask?.cancel(); refreshTask = nil
            session.stop(); self.session = nil
            endActivity()
            completed = heldResults?.completed ?? false
            stage = .questions
            summary = Self.summaryLines(heldResults)
        } else if !snap.running {
            let why = snap.notice ?? "The audio engine stopped."
            stop()
            stage = .failed(why)
        }
    }

    /// Writes the report (numbers only) and remembers where it went.
    func saveReport(resultsDirectory: URL?) {
        guard stage == .questions, let results = heldResults else { return }
        let params = BlindParameters.current(runner: BlindRunnerConfig(), outputVolume: volume)
        let report = BlindListeningReport.make(seed: seed, results: results, parameters: params, endAnswers: endAnswers, device: device, run: facts,
                                               startedAt: SelfTestReport.timestamp(startedAt), endedAt: SelfTestReport.timestamp(endedAt))
        let stem = BlindListeningReport.fileStem(date: startedAt, simulated: false)
        do {
            let urls = try ReportStore.writeListening(report, stem: stem, to: ReportStore.resultsDirectory(override: resultsDirectory))
            savedPaths = urls.map(\.path)
            stage = .saved
        } catch {
            stage = .failed("The report could not be written: \(error)")
        }
    }

    /// After the run (never during it): how many definite answers, how many right.
    private static func summaryLines(_ results: BlindRunResults?) -> [String] {
        guard let results else { return [] }
        let s = BlindScoring.score(results.records)
        var lines = ["\(results.records.count) of \(results.plannedTrials) trials recorded; \(s.answeredDefinite) definite answers (left ear / right ear / middle), \(s.correct) matching the expected position."]
        lines.append("Chance is 1 in 3 per definite answer if you were guessing among the three position buttons.")
        if s.channelSwap.status == .suspected { lines.append("Channel-swap flag: SUSPECTED (an untuned hint, see the report).") }
        if s.headTurnReversed.status == .suspected { lines.append("Head-turn-reversed flag: SUSPECTED (an untuned hint, see the report).") }
        return lines
    }

    // MARK: simulated rehearsal (--blind-listening-simulate): FABRICATED answers, no audio

    func runSimulatedRehearsal(behavior name: String, resultsDirectory: URL?) {
        let behavior: SimulatedBlindListener.Behavior
        switch name {
        case "perfect": behavior = .perfect
        case "swapped": behavior = .swappedChannels
        case "reversed": behavior = .reversedHeadTurn
        case "guess": behavior = .guessing(seed: 1)
        case "abstain": behavior = .abstain
        case "silent": behavior = .silent
        default:
            print("BLIND LISTENING SIMULATE: unknown behavior \"\(name)\" (perfect, swapped, reversed, guess, abstain, silent)")
            NSApplication.shared.terminate(nil)
            return
        }
        let listener = SimulatedBlindListener(behavior)
        let seed: UInt64 = 12345
        let results = BlindSimulation.run(seed: seed, listener: listener)
        let now = Date()
        // Nothing is measured in a rehearsal, so there are no device or run facts: the fields are nil, not invented.
        let report = BlindListeningReport.make(seed: seed, results: results, parameters: BlindParameters.current(runner: BlindRunnerConfig(), outputVolume: 0),
                                               endAnswers: BlindEndAnswers(), device: nil, run: nil, startedAt: SelfTestReport.timestamp(now),
                                               endedAt: SelfTestReport.timestamp(now), simulatedListener: listener.name)
        do {
            let urls = try ReportStore.writeListening(report, stem: BlindListeningReport.fileStem(date: now, simulated: true),
                                                      to: ReportStore.resultsDirectory(override: resultsDirectory))
            print("BLIND LISTENING SIMULATE (\(listener.name)): SIMULATED report written: \(urls.map(\.path).joined(separator: ", "))")
        } catch {
            print("BLIND LISTENING SIMULATE: could not write the report: \(error)")
        }
        NSApplication.shared.terminate(nil)
    }

    // MARK: App Nap

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                         reason: "Blind listening test needs regular timer delivery")
    }

    private func endActivity() {
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }
}
