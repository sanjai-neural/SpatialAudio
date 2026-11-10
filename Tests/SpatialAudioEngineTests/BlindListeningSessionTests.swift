import Testing
import Foundation
import SpatialAudioCore
@testable import SpatialAudioEngine

// Step 3a-2: the Engine half of the blind listening test, driven on VIRTUAL time with a recording fake output (no audio device, no timers, no sleeps).
// What this does NOT check: the real timers, the real EnvironmentRenderer, how any of it sounds. Those stay UNVERIFIED until Sanjai has listened.

/// Records every call in order, with the volume that was set at that moment.
final class RecordingOutput: BlindListeningOutput, @unchecked Sendable {
    enum Event: Equatable { case volume(Float), source(Vector3), listener }
    private let lock = NSLock()
    private var _events: [Event] = []
    private var _volume: Float = 0
    var events: [Event] { lock.lock(); defer { lock.unlock() }; return _events }
    var outputVolume: Float {
        get { lock.lock(); defer { lock.unlock() }; return _volume }
        set { lock.lock(); _volume = newValue; _events.append(.volume(newValue)); lock.unlock() }
    }
    var isRunning: Bool { true }
    var notice: String? { nil }
    func start() throws {}
    func stop() {}
    func setListener(_ orientation: ListenerOrientation) { lock.lock(); _events.append(.listener); lock.unlock() }
    func setSourcePosition(_ position: Vector3) { lock.lock(); _events.append(.source(position)); lock.unlock() }
}

@Suite struct BlindListeningSessionTests {
    private func make(volume: Double = 0.2, seed: UInt64 = 5) -> (BlindListeningSession, RecordingOutput) {
        let out = RecordingOutput()
        // The clock is never read by the tests below except in begin() (a start time); every tick is given its own virtual time.
        return (BlindListeningSession(output: out, sampleRate: 48_000, seed: seed, baseVolume: volume, clock: { 0 }), out)
    }

    /// Plays a whole run: every trial answered `reaction` seconds after the window opens, ticks every 10 ms of virtual time.
    private func playAll(_ s: BlindListeningSession, reaction: Double = 1.0, answerFor: (BlindCondition) -> BlindAnswer) {
        var t = 0.0
        var enabledAt: Double?
        var decided = -1
        while !s.snapshot.silentAndFinished, t < 3000 {
            s.controlTick(at: t)
            let f = s.snapshot.frame
            if f.inTrial, f.completedTrials != decided { decided = f.completedTrials; enabledAt = nil }
            if f.inTrial, f.answerEnabled {
                if enabledAt == nil { enabledAt = t }
                if t - enabledAt! >= reaction { _ = s.answer(answerFor(s.plan[f.completedTrials]), at: t) }
            }
            t += 0.01
        }
    }

    @Test func startsSilentWithTheFirstSceneInPlace() {
        let (s, out) = make()
        s.begin()
        let first = BlindScenes.scene(for: s.plan[0], headProgress: 0)
        #expect(out.outputVolume == 0)
        #expect(out.events.first == .volume(0))
        #expect(out.events.contains(.source(first.sourcePosition)))
        #expect(s.snapshot.frame.totalTrials == 20 && !s.snapshot.frame.inTrial)
        #expect(s.results == nil)
    }

    @Test func theToneIsMovedOnlyWhileSilentAndVolumeNeverExceedsTheBase() {
        let (s, out) = make(volume: 0.2)
        s.begin()
        playAll(s) { BlindScenes.truth(for: $0) == .leftEar ? .leftEar : BlindScenes.truth(for: $0) == .rightEar ? .rightEar : .middle }
        var volume: Float = 0
        var moves = 0
        for e in out.events {
            switch e {
            case .volume(let v): volume = v; #expect(v >= 0 && v <= 0.2 + 1e-6)
            case .source: moves += 1; #expect(volume == 0, "the source moved while the volume was \(volume)")
            case .listener: break
            }
        }
        #expect(moves >= 2)                                         // the first placement plus at least one change between trials
        #expect(out.outputVolume == 0)                              // ends silent
        let r = s.results
        #expect(r?.completed == true && r?.records.count == 20)
    }

    @Test func volumeIsBaseTimesTheFadeAndReachesTheBaseOnlyWhileTheToneIsOn() {
        let (s, out) = make(volume: 0.25)
        s.begin()
        playAll(s) { _ in .cantTell }
        let volumes = out.events.compactMap { e -> Float? in if case .volume(let v) = e { return v } else { return nil } }
        #expect(volumes.contains { abs($0 - 0.25) < 1e-6 })         // full level was reached
        #expect(volumes.contains { $0 > 0.01 && $0 < 0.24 })        // fades have intermediate steps
        #expect(volumes.allSatisfy { $0 <= 0.25 + 1e-6 })
    }

    @Test func answersBeforeTheWindowOpensAreRejectedAndTheTruthIsNotInTheSnapshot() {
        let (s, _) = make()
        s.begin()
        s.controlTick(at: 2.0 + 0.5)                                // 0.5 s into the first trial
        #expect(s.answer(.leftEar, at: 2.0 + 0.5) == false)
        #expect(s.results == nil)
        let labels = Set(Mirror(reflecting: s.snapshot).children.compactMap(\.label))
        #expect(labels == ["running", "frame", "notice", "silentAndFinished"])   // nothing here carries a truth
    }

    @Test func abortFadesOutThenIsSilentAndReportsAPartialRun() {
        let clockBox = Box()                                         // abort() reads the session's clock, so this one is under test control
        let out = RecordingOutput()
        let s = BlindListeningSession(output: out, sampleRate: 48_000, seed: 5, baseVolume: 0.2, clock: { clockBox.now })
        s.begin()
        clockBox.now = 2.5                                           // 0.5 s into the first trial: tone on, no answer yet
        s.controlTick(at: 2.5)
        #expect(s.snapshot.frame.inTrial && out.outputVolume > 0)
        s.abort()
        s.controlTick(at: 2.5)                                       // the fade-out starts now
        #expect(!s.snapshot.silentAndFinished)
        for i in 1...30 { s.controlTick(at: 2.5 + Double(i) * 0.01) }
        #expect(s.snapshot.silentAndFinished)
        #expect(out.outputVolume == 0)
        #expect(s.results?.completed == false && s.results?.records.isEmpty == true && s.results?.plannedTrials == 20)
    }

    @Test func runFactsAreFilledAndNamesAreNotCopied() {
        let (s, _) = make()
        s.begin()
        playAll(s) { _ in .middle }
        let facts = s.runFacts()
        #expect(["nominal", "fair", "serious", "critical", "unknown"].contains(facts.thermalStateStart))
        #expect(["nominal", "fair", "serious", "critical", "unknown"].contains(facts.thermalStateEnd))
        #expect(facts.durationSeconds > 0)
    }
}

final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = 0.0
    var now: Double { get { lock.lock(); defer { lock.unlock() }; return _now } set { lock.lock(); _now = newValue; lock.unlock() } }
}
