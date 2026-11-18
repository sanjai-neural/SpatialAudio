import Foundation

// Step 6b-3a-2: the DECISION LOGIC of the control-thread re-prime, as pure code (docs/ARCHITECTURE.md, "Reading the ring from two blocks": the Re-prime paragraph and the policy
// table; "Step 6b-3 plan", 6b-3a items 5 and 6). No clock, no engine, no ring and no sleep in here: the caller feeds it the time and what it measured, it answers with the next
// action, and every test drives it with made-up numbers. IMPLEMENTED-UNVERIFIED: never run against a real engine.
//
// What the design asks for: stop the engine (so that no render block can run), re-base both cursors together, wait until the ring holds at least T frames, start the engine.
// `SARingPrime` already does the re-basing (both cursors to w - depth, refusing until enough callbacks are in), so the steps here are:
//   idle -> stopping -> priming -> (waitingForT) -> restarting -> idle
// The first prime and engine start of a run use the SAME states (`beginStart`): a start is a re-prime that nobody had to ask for. It is not counted as a re-prime.
//
// What triggers a re-prime (all thresholds are PARAMETERS, UNTUNED, evaluated on the counters since the last prime): the ring's sticky `needsReprime` or `diverged` flag,
// underrun blocks at or above a threshold, or divergence jumps + refused jumps at or above a threshold. What limits it: a minimum interval since the last restart and a
// maximum number of re-primes per window, so that a cause no re-prime can fix (a producer that never delivers) cannot turn into a storm of gaps.

public struct RePrimeConfig: Codable, Equatable, Sendable {
    /// T in tap callbacks: the standing fill the readers are re-based to (SARingPrime's argument). The ring default is 4.
    public var primeCallbacks: UInt32
    /// Underrun blocks (the larger of the two readers', since the last prime) at which the controller asks for a re-prime. UNTUNED.
    public var underrunBlocksThreshold: UInt64
    /// Divergence jumps + refused jumps (the larger of the two readers', since the last prime) at which it asks. UNTUNED.
    public var divergenceThreshold: UInt64
    /// A trigger within this many seconds after the last restart is suppressed (counted). UNTUNED.
    public var minIntervalSeconds: Double
    /// At most this many re-primes within `windowSeconds`; a further trigger is suppressed (counted). UNTUNED.
    public var maxRePrimesPerWindow: Int
    public var windowSeconds: Double
    /// After the engine reports it is stopped, the readers' call counts must stay unchanged for this many consecutive observations before the cursors are touched: the headers
    /// do not say that `AVAudioEngine.stop` waits for a render block that is already running, so "not running" alone is not taken as proof.
    public var quietPollsRequired: Int
    /// Give up if the engine still runs, or the readers are still being called, this long after the stop request.
    public var stopTimeoutSeconds: Double
    /// Give up if `SARingPrime` keeps refusing (too few tap callbacks) this long after its first refusal.
    public var waitForTimeoutSeconds: Double

    public init(primeCallbacks: UInt32 = 4, underrunBlocksThreshold: UInt64 = 4, divergenceThreshold: UInt64 = 8, minIntervalSeconds: Double = 5,
                maxRePrimesPerWindow: Int = 6, windowSeconds: Double = 60, quietPollsRequired: Int = 3, stopTimeoutSeconds: Double = 5, waitForTimeoutSeconds: Double = 10) {
        self.primeCallbacks = primeCallbacks; self.underrunBlocksThreshold = underrunBlocksThreshold; self.divergenceThreshold = divergenceThreshold
        self.minIntervalSeconds = minIntervalSeconds; self.maxRePrimesPerWindow = maxRePrimesPerWindow; self.windowSeconds = windowSeconds
        self.quietPollsRequired = quietPollsRequired; self.stopTimeoutSeconds = stopTimeoutSeconds; self.waitForTimeoutSeconds = waitForTimeoutSeconds
    }

    /// A problem with the numbers, or nil.
    public var problem: String? {
        if primeCallbacks == 0 { return "primeCallbacks must be at least 1" }
        if underrunBlocksThreshold == 0 || divergenceThreshold == 0 { return "the thresholds must be at least 1" }
        if !(minIntervalSeconds.isFinite && minIntervalSeconds >= 0) { return "minIntervalSeconds must be a non-negative number" }
        if maxRePrimesPerWindow < 1 { return "maxRePrimesPerWindow must be at least 1" }
        if !(windowSeconds.isFinite && windowSeconds > 0) { return "windowSeconds must be positive" }
        if quietPollsRequired < 1 { return "quietPollsRequired must be at least 1" }
        if !(stopTimeoutSeconds.isFinite && stopTimeoutSeconds > 0) || !(waitForTimeoutSeconds.isFinite && waitForTimeoutSeconds > 0) { return "the timeouts must be positive" }
        return nil
    }
}

/// What the controller needs to know about the ring, in plain numbers (the engine layer builds it from the C snapshot). The per-reader arrays are [left, right].
public struct RingHealth: Equatable, Sendable {
    /// Counters since the last prime (SARingPrime zeroes them).
    public var underrunBlocks: [UInt64]
    /// divergenceJumps + refusedJumps per reader, since the last prime.
    public var divergenceEvents: [UInt64]
    public var diverged: [Bool]
    public var needsReprime: Bool
    public var calls: [UInt64]
    public var fills: [Int64]
    public var cursors: [Int64]
    /// T in frames, as the ring reports it (SARingPrime sets it to the depth it primed).
    public var standingFill: Int64

    public init(underrunBlocks: [UInt64], divergenceEvents: [UInt64], diverged: [Bool], needsReprime: Bool, calls: [UInt64], fills: [Int64], cursors: [Int64], standingFill: Int64) {
        self.underrunBlocks = underrunBlocks; self.divergenceEvents = divergenceEvents; self.diverged = diverged; self.needsReprime = needsReprime
        self.calls = calls; self.fills = fills; self.cursors = cursors; self.standingFill = standingFill
    }
}

public enum RePrimeState: String, Codable, Sendable { case idle, stopping, priming, waitingForT, restarting }

public enum RePrimeReason: String, Codable, Sendable {
    case start, needsReprimeFlag, divergedFlag, underruns, divergence
}

/// What the caller must do next. After performing an action it feeds the result back (see `RePrimeInput`).
public enum RePrimeAction: Equatable, Sendable {
    /// Nothing to do until the next ordinary observation.
    case none
    /// Stop the engine (idempotent), then observe again.
    case stopEngine
    /// Wait a short poll interval, then observe again.
    case waitAndObserve
    /// Call `SARingPrime` once (it never waits) and report the result.
    case prime
    /// Start the engine (its gain guard applies) and report the result.
    case restartEngine
    /// The re-prime cannot be completed: leave the engine as it is and end the run. The reason is for the report.
    case giveUp(String)
}

public enum RePrimeInput: Sendable {
    case observe(now: Double, health: RingHealth, engineRunning: Bool)
    case primeResult(now: Double, succeeded: Bool, health: RingHealth)
    case restartResult(now: Double, succeeded: Bool, health: RingHealth)
}

/// One re-prime (or the start sequence, reason `.start`). Numbers only.
public struct RePrimeRecord: Codable, Equatable, Sendable {
    public var index: Int
    public var reason: RePrimeReason
    public var triggeredAtSeconds: Double
    /// Seconds from the previous restart (or the start) to this trigger: how long the previous prime lasted. nil for the start.
    public var secondsSincePreviousRestart: Double?
    /// Underrun blocks (larger of the two readers') in the epoch this re-prime ended, at the moment it was triggered.
    public var underrunsBefore: UInt64
    public var needsReprimeAtTrigger: Bool
    public var divergedAtTrigger: [Bool]
    public var stopIssuedAtSeconds: Double
    public var restartedAtSeconds: Double?
    /// restartedAt - stopIssuedAt: how long the engine was not running. Measured by the caller's clock, not assumed.
    public var engineStoppedSeconds: Double?
    public var primeAttempts: Int
    /// Each reader's fill right after the prime succeeded (the fill the restarted engine starts with).
    public var fillAtRestart: [Int64]?
    /// Underrun blocks (larger of the two readers') in the epoch this prime started, as of the last observation before the next trigger or the end of the run.
    public var underrunsAfter: UInt64?
    public var succeeded: Bool
    public var failure: String?
}

public struct RePrimeController: Sendable {
    public let config: RePrimeConfig
    public private(set) var state: RePrimeState = .idle
    /// The re-primes in order (the start sequence is NOT in here: see `startRecord`).
    public private(set) var records: [RePrimeRecord] = []
    public private(set) var startRecord: RePrimeRecord?
    public private(set) var suppressedByMinimumInterval = 0
    public private(set) var suppressedByStormLimit = 0
    /// Set when a step gave up; nothing is triggered afterwards.
    public private(set) var failure: String?

    private var lastRestartAt: Double?
    private var recentRestarts: [Double] = []
    private var stateEnteredAt = 0.0
    private var quietCount = 0
    private var lastCalls: [UInt64]?
    private var attempts = 0
    private var inProgressIsStart = false
    /// Which record the current epoch belongs to: nil = no epoch yet, -1 = the start record, otherwise an index into `records`.
    private var epochOwner: Int?
    private var hasStarted = false

    public init(config: RePrimeConfig = RePrimeConfig()) { self.config = config }

    /// Re-primes that completed (the engine was restarted). Failed ones are in `records` with `succeeded == false` but not counted here.
    public var rePrimesPerformed: Int { records.filter(\.succeeded).count }

    /// The trigger rule. nil = healthy. Order: the ring's own requests first.
    public static func trigger(_ h: RingHealth, _ c: RePrimeConfig) -> RePrimeReason? {
        if h.needsReprime { return .needsReprimeFlag }
        if h.diverged.contains(true) { return .divergedFlag }
        if (h.underrunBlocks.max() ?? 0) >= c.underrunBlocksThreshold { return .underruns }
        if (h.divergenceEvents.max() ?? 0) >= c.divergenceThreshold { return .divergence }
        return nil
    }

    // MARK: start

    /// The first prime and engine start, through the same states as a re-prime. The engine is not running yet, so there is no stop and no quiet wait. Once only.
    public mutating func beginStart(now: Double) -> RePrimeAction {
        guard !hasStarted, state == .idle, failure == nil else { return .none }
        hasStarted = true
        inProgressIsStart = true
        startRecord = RePrimeRecord(index: 0, reason: .start, triggeredAtSeconds: now, secondsSincePreviousRestart: nil, underrunsBefore: 0, needsReprimeAtTrigger: false,
                                    divergedAtTrigger: [], stopIssuedAtSeconds: now, restartedAtSeconds: nil, engineStoppedSeconds: nil, primeAttempts: 0, fillAtRestart: nil,
                                    underrunsAfter: nil, succeeded: false, failure: nil)
        epochOwner = nil
        state = .priming; stateEnteredAt = now; attempts = 0
        return .prime
    }

    // MARK: stepping

    public mutating func step(_ input: RePrimeInput) -> RePrimeAction {
        switch input {
        case .observe(let now, let health, let running): return observe(now: now, health: health, engineRunning: running)
        case .primeResult(let now, let ok, let health): return primeResult(now: now, succeeded: ok, health: health)
        case .restartResult(let now, let ok, let health): return restartResult(now: now, succeeded: ok, health: health)
        }
    }

    private mutating func observe(now: Double, health: RingHealth, engineRunning: Bool) -> RePrimeAction {
        switch state {
        case .idle:
            guard failure == nil else { return .none }
            noteEpoch(health)
            guard let reason = Self.trigger(health, config) else { return .none }
            if let last = lastRestartAt, now - last < config.minIntervalSeconds { suppressedByMinimumInterval += 1; return .none }
            recentRestarts.removeAll { now - $0 >= config.windowSeconds }
            if recentRestarts.count >= config.maxRePrimesPerWindow { suppressedByStormLimit += 1; return .none }
            records.append(RePrimeRecord(index: records.count + 1, reason: reason, triggeredAtSeconds: now, secondsSincePreviousRestart: lastRestartAt.map { now - $0 },
                                         underrunsBefore: health.underrunBlocks.max() ?? 0, needsReprimeAtTrigger: health.needsReprime, divergedAtTrigger: health.diverged,
                                         stopIssuedAtSeconds: now, restartedAtSeconds: nil, engineStoppedSeconds: nil, primeAttempts: 0, fillAtRestart: nil, underrunsAfter: nil,
                                         succeeded: false, failure: nil))
            inProgressIsStart = false
            state = .stopping; stateEnteredAt = now; quietCount = 0; lastCalls = nil; attempts = 0
            return .stopEngine

        case .stopping:
            if engineRunning {
                if now - stateEnteredAt >= config.stopTimeoutSeconds { return fail("the engine still reported running \(config.stopTimeoutSeconds) s after the stop request") }
                return .stopEngine
            }
            if let last = lastCalls, last == health.calls { quietCount += 1 } else { quietCount = 0 }
            lastCalls = health.calls
            if quietCount >= config.quietPollsRequired { state = .priming; stateEnteredAt = now; attempts = 0; return .prime }
            if now - stateEnteredAt >= config.stopTimeoutSeconds { return fail("the readers were still being called \(config.stopTimeoutSeconds) s after the engine reported stopped") }
            return .waitAndObserve

        case .priming:
            return .prime          // a prime is outstanding; asking again is harmless

        case .waitingForT:
            if now - stateEnteredAt >= config.waitForTimeoutSeconds { return fail("SARingPrime kept refusing for \(config.waitForTimeoutSeconds) s (fewer than \(config.primeCallbacks) tap callbacks in the ring)") }
            return .prime

        case .restarting:
            return .restartEngine
        }
    }

    private mutating func primeResult(now: Double, succeeded: Bool, health: RingHealth) -> RePrimeAction {
        guard state == .priming || state == .waitingForT else { return .none }
        attempts += 1
        let attemptsNow = attempts
        setCurrent { $0.primeAttempts = attemptsNow }
        if !succeeded {
            if state == .priming { state = .waitingForT; stateEnteredAt = now }
            if now - stateEnteredAt >= config.waitForTimeoutSeconds { return fail("SARingPrime kept refusing for \(config.waitForTimeoutSeconds) s (fewer than \(config.primeCallbacks) tap callbacks in the ring)") }
            return .waitAndObserve
        }
        // The prime succeeded: the engine may only restart if BOTH readers now sit at the same frame with at least T frames in the ring.
        let t = health.standingFill
        let together = health.cursors.count == 2 && health.cursors[0] == health.cursors[1]
        let enough = t > 0 && health.fills.count == 2 && health.fills.allSatisfy { $0 >= t }
        guard together, enough else {
            return fail("the prime left the readers at cursors \(health.cursors) with fills \(health.fills) and T = \(t): not together, or fewer than T frames")
        }
        setCurrent { $0.fillAtRestart = health.fills }
        state = .restarting; stateEnteredAt = now
        return .restartEngine
    }

    private mutating func restartResult(now: Double, succeeded: Bool, health: RingHealth) -> RePrimeAction {
        guard state == .restarting else { return .none }
        guard succeeded else { return fail("the engine could not be restarted") }
        setCurrent {
            $0.restartedAtSeconds = now
            $0.engineStoppedSeconds = now - $0.stopIssuedAtSeconds
            $0.succeeded = true
        }
        if inProgressIsStart { epochOwner = -1 } else { recentRestarts.append(now); epochOwner = records.count - 1 }
        lastRestartAt = now
        inProgressIsStart = false
        state = .idle; quietCount = 0; lastCalls = nil
        return .none
    }

    // MARK: helpers

    private mutating func fail(_ why: String) -> RePrimeAction {
        failure = why
        setCurrent { $0.failure = why; $0.succeeded = false }
        state = .idle
        return .giveUp(why)
    }

    /// Edits the record of the sequence in progress (the start record or the last re-prime).
    private mutating func setCurrent(_ edit: (inout RePrimeRecord) -> Void) {
        if inProgressIsStart { if var r = startRecord { edit(&r); startRecord = r } }
        else if !records.isEmpty { edit(&records[records.count - 1]) }
    }

    /// Keeps "underruns after" of the record that owns the current epoch up to date.
    private mutating func noteEpoch(_ h: RingHealth) {
        guard let owner = epochOwner else { return }
        let u = h.underrunBlocks.max() ?? 0
        if owner == -1 { startRecord?.underrunsAfter = u }
        else if owner >= 0, owner < records.count { records[owner].underrunsAfter = u }
    }

    /// Call at the end of the run so the last epoch's underruns are recorded.
    public mutating func finish(health: RingHealth) { if state == .idle { noteEpoch(health) } }
}
