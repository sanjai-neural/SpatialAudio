import Foundation

// Step 6b-3a-2: drives `RePrimeController` against a `RingProbeBackend`: the control-thread part of the re-prime (stop the engine, wait until it is quiet, `SARingPrime`, wait for T,
// restart). It lives in Core because it only needs the backend protocol and a clock (the same seam as `RingProbeRunner`), so it is unit-tested with a fake backend and a virtual
// clock; the engine-specific calls (`AVAudioEngine.stop`, `SARingPrime`, the snapshot mapping) are in the backends. IMPLEMENTED-UNVERIFIED: never run on a real engine.
//
// Control thread only. Nothing here runs on a render thread. It never sets or raises the gain: before every (re)start it reads the output gain back and refuses unless it is exactly 0
// (the engine's own start guard is the second check).

extension RingHealth {
    /// Builds the controller's view from one raw sample (the counters of ONE epoch, i.e. since the last prime). nil when the sample does not have two readers.
    /// Without `raw.recovery` (a backend that does not provide it) the flags read as clear and T as 0, so a re-prime would be refused by the controller rather than guessed.
    public init?(raw: RingProbeRawSample) {
        guard raw.readers.count == 2 else { return nil }
        let rec = raw.recovery
        self.init(underrunBlocks: raw.readers.map(\.underrunBlocks),
                  divergenceEvents: (rec?.readers ?? []).map { $0.divergenceJumps + $0.refusedJumps },
                  diverged: (rec?.readers ?? []).map(\.diverged),
                  needsReprime: rec?.needsReprime ?? false,
                  calls: raw.readers.map(\.calls), fills: raw.readers.map(\.fill), cursors: raw.readers.map(\.cursor),
                  standingFill: Int64(rec?.standingFill ?? 0))
    }
}

extension RingReaderCounters {
    /// The counters of an earlier epoch plus this one. The cursor and the fill are gauges, not counts: they are this epoch's.
    func adding(_ earlier: RingReaderCounters) -> RingReaderCounters {
        var s = self
        s.calls += earlier.calls; s.framesRequested += earlier.framesRequested; s.servedBlocks += earlier.servedBlocks; s.servedFrames += earlier.servedFrames
        s.underrunBlocks += earlier.underrunBlocks; s.overrunBlocks += earlier.overrunBlocks; s.tornBlocks += earlier.tornBlocks; s.oversizeBlocks += earlier.oversizeBlocks
        s.badBufferBlocks += earlier.badBufferBlocks; s.silentFrames += earlier.silentFrames; s.phaseValidCalls += earlier.phaseValidCalls
        s.phaseInvalidCalls += earlier.phaseInvalidCalls; s.phaseSelfChanges += earlier.phaseSelfChanges; s.phaseMismatches += earlier.phaseMismatches
        s.weakRuleViolations += earlier.weakRuleViolations
        return s
    }
}

public final class RingRecoveryOrchestrator: RingProbeRecovery, @unchecked Sendable {
    /// A backstop against a controller that never returns `.none` / `.giveUp` (a bug): a COUNT of loop turns, not a time. Far above what a real sequence takes.
    static let iterationCap = 100_000

    private let backend: RingProbeBackend
    private var controller: RePrimeController
    private let pollSeconds: Double
    private let config: RePrimeConfig

    /// Earlier epochs, summed (the ring zeroes its counters at every prime). Producer: the reject record is zeroed by the prime too.
    private var baseReaders: [RingReaderCounters] = [RingReaderCounters(), RingReaderCounters()]
    private var baseRejected: UInt64 = 0
    private var baseRejectFlags: UInt32 = 0
    private var baseRecovery: [RingReaderRecovery] = [RingReaderRecovery(name: "left (reader 0)"), RingReaderRecovery(name: "right (reader 1)")]

    private var busy = false
    private var gaveUpReason: String?
    private var startPrimed = false
    private var startPrimeWaitSeconds = 0.0
    private var lastStartDetail: String?
    private var startedAt = 0.0
    /// Test seam: how many ticks were refused because a re-prime was already being driven (the reentrancy guard).
    public private(set) var reentrantTicksRefused = 0

    public init(backend: RingProbeBackend, config: RePrimeConfig = RePrimeConfig(), pollSeconds: Double = RingProbeRunner.pollIntervalSeconds) {
        self.backend = backend; self.config = config; self.controller = RePrimeController(config: config); self.pollSeconds = pollSeconds
    }

    public var gaveUp: String? { gaveUpReason }
    public var rePrimesPerformed: Int { controller.rePrimesPerformed }
    public var records: [RePrimeRecord] { controller.records }

    // MARK: RingProbeRecovery

    public func performStart(clock: TapProbeClock) -> RingRecoveryStartOutcome {
        busy = true; defer { busy = false }
        let t0 = clock.now()
        startedAt = t0
        let first = controller.beginStart(now: t0)
        drive(first, clock: clock, startTime: t0)
        let rec = controller.startRecord
        let started = rec?.succeeded ?? false
        return RingRecoveryStartOutcome(primed: startPrimed, primeAttempts: rec?.primeAttempts ?? 0, primeWaitSeconds: startPrimeWaitSeconds, started: started,
                                        startDetail: gaveUpReason ?? lastStartDetail, engineStartedAtSeconds: rec?.restartedAtSeconds ?? clock.now())
    }

    public func cumulative(_ raw: RingProbeRawSample) -> RingProbeRawSample {
        var out = raw
        if raw.readers.count == 2 { out.readers = [raw.readers[0].adding(baseReaders[0]), raw.readers[1].adding(baseReaders[1])] }
        out.producer.rejectedCommits += baseRejected
        out.producer.rejectFlags |= baseRejectFlags
        return out
    }

    public func tick(raw: RingProbeRawSample, clock: TapProbeClock) {
        guard !busy else { reentrantTicksRefused += 1; return }
        guard gaveUpReason == nil, let health = RingHealth(raw: raw) else { return }
        busy = true; defer { busy = false }
        let action = controller.step(.observe(now: clock.now(), health: health, engineRunning: backend.isEngineRunning))
        drive(action, clock: clock, startTime: nil)
    }

    public func finish(raw: RingProbeRawSample?) -> RingRecoveryReport {
        var readers = baseRecovery
        if let rec = raw?.recovery, rec.readers.count == 2 { for i in 0..<2 { readers[i].merge(rec.readers[i]) } }
        if let raw, let health = RingHealth(raw: raw) { controller.finish(health: health) }
        var notes: [String] = []
        if raw?.recovery == nil { notes.append("The backend gave no recovery snapshot: the frame-count table, the jump counters and the flags are not available.") }
        return RingRecoveryReport(config: config, start: controller.startRecord, rePrimes: controller.records, suppressedByMinimumInterval: controller.suppressedByMinimumInterval,
                                  suppressedByStormLimit: controller.suppressedByStormLimit, gaveUp: gaveUpReason ?? controller.failure, readers: readers,
                                  standingFillAtEnd: raw?.recovery?.standingFill, notes: notes)
    }

    // MARK: the driver

    /// Folds the epoch that the next prime will zero into the sums. Called only when the prime succeeded.
    private func absorb(_ pre: RingProbeRawSample) {
        guard pre.readers.count == 2 else { return }
        for i in 0..<2 { baseReaders[i] = pre.readers[i].adding(baseReaders[i]) }
        baseRejected += pre.producer.rejectedCommits
        baseRejectFlags |= pre.producer.rejectFlags
        if let rec = pre.recovery, rec.readers.count == 2 { for i in 0..<2 { baseRecovery[i].merge(rec.readers[i]) } }
    }

    private func observeAgain(clock: TapProbeClock) -> RePrimeAction {
        clock.sleep(pollSeconds)
        guard let raw = backend.snapshot(), let health = RingHealth(raw: raw) else { return .giveUp("no ring snapshot while re-priming") }
        return controller.step(.observe(now: clock.now(), health: health, engineRunning: backend.isEngineRunning))
    }

    private func drive(_ first: RePrimeAction, clock: TapProbeClock, startTime: Double?) {
        var action = first
        var turns = 0
        while true {
            turns += 1
            if turns > Self.iterationCap { gaveUpReason = "the re-prime did not finish within \(Self.iterationCap) steps (a controller bug)"; return }
            switch action {
            case .none:
                return
            case .giveUp(let why):
                gaveUpReason = why
                return
            case .stopEngine:
                backend.pauseEngine()
                action = observeAgain(clock: clock)
            case .waitAndObserve:
                action = observeAgain(clock: clock)
            case .prime:
                guard let pre = backend.snapshot() else { gaveUpReason = "no ring snapshot before the prime"; return }
                let ok = backend.prime(callbacks: config.primeCallbacks)
                if ok { absorb(pre) }
                guard let post = backend.snapshot(), let health = RingHealth(raw: post) else { gaveUpReason = "no ring snapshot after the prime"; return }
                let now = clock.now()
                if ok, let t0 = startTime { startPrimed = true; startPrimeWaitSeconds = now - t0 }
                action = controller.step(.primeResult(now: now, succeeded: ok, health: health))
            case .restartEngine:
                guard backend.engineOutputGain() == 0 else {
                    gaveUpReason = "the output gain does not read back as 0 before the restart: refusing to start the engine"
                    return
                }
                let r = backend.startEngine()
                lastStartDetail = r.detail
                guard let raw = backend.snapshot(), let health = RingHealth(raw: raw) else { gaveUpReason = "no ring snapshot after the restart"; return }
                action = controller.step(.restartResult(now: clock.now(), succeeded: r.ok, health: health))
            }
        }
    }
}
