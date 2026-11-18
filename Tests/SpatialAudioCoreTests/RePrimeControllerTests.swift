import Testing
import Foundation
@testable import SpatialAudioCore

// Step 6b-3a-2: the decision logic of the control-thread re-prime, driven with MADE-UP numbers and a made-up clock. No engine, no ring, no sleep and no wall clock: every time
// below is a number the test hands in, so no verdict depends on how fast or slow this Mac is. (Mutation-checked: scripts/mutate_reprime.py.)

private let cfg = RePrimeConfig(primeCallbacks: 4, underrunBlocksThreshold: 4, divergenceThreshold: 8, minIntervalSeconds: 5, maxRePrimesPerWindow: 3, windowSeconds: 60,
                                quietPollsRequired: 3, stopTimeoutSeconds: 5, waitForTimeoutSeconds: 10)

private func health(u: [UInt64] = [0, 0], d: [UInt64] = [0, 0], diverged: [Bool] = [false, false], needs: Bool = false, calls: [UInt64] = [100, 100],
                    fills: [Int64] = [2048, 2048], cursors: [Int64] = [1000, 1000], t: Int64 = 2048) -> RingHealth {
    RingHealth(underrunBlocks: u, divergenceEvents: d, diverged: diverged, needsReprime: needs, calls: calls, fills: fills, cursors: cursors, standingFill: t)
}

private func observe(_ c: inout RePrimeController, _ now: Double, _ h: RingHealth, running: Bool = true) -> RePrimeAction {
    c.step(.observe(now: now, health: h, engineRunning: running))
}

/// Runs one complete re-prime with healthy numbers and returns the time of the restart. `poll` is the made-up time between two steps.
@discardableResult
private func completeRePrime(_ c: inout RePrimeController, triggerAt t: Double, with trigger: RingHealth, poll: Double = 0.05) -> Double {
    var now = t
    var a = observe(&c, now, trigger, running: true)
    #expect(a == .stopEngine, "the trigger at \(t) must start a re-prime")
    var primed = false
    for _ in 0..<20 {
        now += poll
        a = observe(&c, now, health(), running: false)
        if a == .prime { primed = true; break }
    }
    #expect(primed)
    now += poll
    a = c.step(.primeResult(now: now, succeeded: true, health: health()))
    #expect(a == .restartEngine)
    now += poll
    a = c.step(.restartResult(now: now, succeeded: true, health: health()))
    #expect(a == .none)
    return now
}

@Suite struct RePrimeTriggerTests {
    @Test func theUnderrunThresholdIsExactForEitherReader() {
        for (u, fires) in [(UInt64(3), false), (4, true), (5, true)] {
            for reader in 0..<2 {
                var c = RePrimeController(config: cfg)
                var counts: [UInt64] = [0, 0]; counts[reader] = u
                let a = observe(&c, 10, health(u: counts))
                #expect((a == .stopEngine) == fires, "reader \(reader) with \(u) underrun blocks (threshold 4): \(a)")
            }
        }
    }

    @Test func theTwoReadersUnderrunsAreNotAddedUp() {
        var c = RePrimeController(config: cfg)
        #expect(observe(&c, 10, health(u: [3, 3])) == .none, "3 + 3 is 6, but each reader is below the threshold of 4")
    }

    @Test func theDivergenceThresholdIsExactForEitherReader() {
        for (d, fires) in [(UInt64(7), false), (8, true), (9, true)] {
            for reader in 0..<2 {
                var c = RePrimeController(config: cfg)
                var ev: [UInt64] = [0, 0]; ev[reader] = d
                #expect((observe(&c, 10, health(d: ev)) == .stopEngine) == fires, "reader \(reader), \(d) divergence events (threshold 8)")
            }
        }
    }

    @Test func theRingsOwnFlagsTriggerAloneAndAreRecordedAsTheReason() {
        var a = RePrimeController(config: cfg)
        #expect(observe(&a, 10, health(needs: true)) == .stopEngine)
        #expect(a.records.last?.reason == .needsReprimeFlag && a.records.last?.needsReprimeAtTrigger == true)
        for reader in 0..<2 {
            var c = RePrimeController(config: cfg)
            var flags = [false, false]; flags[reader] = true
            #expect(observe(&c, 10, health(diverged: flags)) == .stopEngine, "the diverged flag of reader \(reader) alone")
            #expect(c.records.last?.reason == .divergedFlag && c.records.last?.divergedAtTrigger == flags)
        }
        var b = RePrimeController(config: cfg)
        #expect(observe(&b, 10, health(u: [4, 0])) == .stopEngine && b.records.last?.reason == .underruns)
        var d = RePrimeController(config: cfg)
        #expect(observe(&d, 10, health(d: [0, 8])) == .stopEngine && d.records.last?.reason == .divergence)
    }

    @Test func aHealthyRingNeverTriggersAndLeavesNoRecord() {
        var c = RePrimeController(config: cfg)
        for i in 0..<50 { #expect(observe(&c, Double(i), health()) == .none) }
        #expect(c.records.isEmpty && c.suppressedByMinimumInterval == 0 && c.suppressedByStormLimit == 0 && c.state == .idle)
    }
}

@Suite struct RePrimeSequenceTests {
    @Test func theWholeSequenceInOrderWithEveryRecordFieldFromTheNumbersHandedIn() {
        var c = RePrimeController(config: cfg)
        #expect(observe(&c, 100.00, health(u: [5, 2], needs: false)) == .stopEngine && c.state == .stopping)
        #expect(observe(&c, 100.05, health(), running: true) == .stopEngine, "still running: ask again")
        #expect(observe(&c, 100.10, health(calls: [100, 100]), running: false) == .waitAndObserve, "first quiet observation only sets the reference")
        #expect(observe(&c, 100.15, health(calls: [100, 100]), running: false) == .waitAndObserve)
        #expect(observe(&c, 100.20, health(calls: [100, 100]), running: false) == .waitAndObserve)
        #expect(observe(&c, 100.25, health(calls: [100, 100]), running: false) == .prime && c.state == .priming, "three consecutive unchanged observations")
        #expect(c.step(.primeResult(now: 100.30, succeeded: false, health: health())) == .waitAndObserve && c.state == .waitingForT)
        #expect(observe(&c, 100.35, health(), running: false) == .prime)
        #expect(c.step(.primeResult(now: 100.40, succeeded: true, health: health(fills: [2048, 2050], cursors: [900, 900], t: 2048))) == .restartEngine && c.state == .restarting)
        #expect(c.step(.restartResult(now: 100.50, succeeded: true, health: health())) == .none && c.state == .idle)
        let r = c.records[0]
        #expect(r.index == 1 && r.reason == .underruns && r.triggeredAtSeconds == 100 && r.secondsSincePreviousRestart == nil && r.underrunsBefore == 5)
        #expect(r.stopIssuedAtSeconds == 100 && r.restartedAtSeconds == 100.5 && abs((r.engineStoppedSeconds ?? .nan) - 0.5) < 1e-9, "stopped time = restart - stop request")
        #expect(r.primeAttempts == 2 && r.fillAtRestart == [2048, 2050] && r.succeeded && r.failure == nil)
        #expect(c.rePrimesPerformed == 1)
        // underruns AFTER: the epoch the prime started, kept up to date by later observations and by finish
        #expect(observe(&c, 101, health(u: [0, 2])) == .none && c.records[0].underrunsAfter == 2)
        c.finish(health: health(u: [1, 3]))
        #expect(c.records[0].underrunsAfter == 3)
    }

    @Test func theEngineIsNeverPrimedWhileItStillReportsRunning() {
        var c = RePrimeController(config: cfg)
        _ = observe(&c, 0, health(needs: true))
        for i in 1..<40 {
            let a = observe(&c, Double(i) * 0.1, health(calls: [100, 100]), running: true)
            #expect(a == .stopEngine, "running with unchanged calls must not lead to a prime (observation \(i))")
        }
    }

    @Test func aChangeInEitherReadersCallCountRestartsTheQuietCount() {
        var c = RePrimeController(config: cfg)
        _ = observe(&c, 0, health(needs: true))
        var actions: [RePrimeAction] = []
        for (i, calls) in [[1, 1], [1, 1], [1, 2], [1, 2], [1, 2], [1, 2]].enumerated() {
            actions.append(observe(&c, Double(i + 1) * 0.1, health(calls: calls.map { UInt64($0) }), running: false))
        }
        #expect(actions == [.waitAndObserve, .waitAndObserve, .waitAndObserve, .waitAndObserve, .waitAndObserve, .prime],
                "only the right reader's count changed at the third observation, and that must reset the count: \(actions)")
    }

    @Test func theStopTimeoutIsExactAndNamesWhatWasStillHappening() {
        var running = RePrimeController(config: cfg)
        _ = observe(&running, 100, health(needs: true))
        #expect(observe(&running, 104.99, health(), running: true) == .stopEngine)
        guard case .giveUp(let why) = observe(&running, 105, health(), running: true) else { Issue.record("no give up at the timeout"); return }
        #expect(why.contains("still reported running"))
        #expect(running.failure != nil && running.records[0].succeeded == false && running.records[0].failure == why)

        var called = RePrimeController(config: cfg)
        _ = observe(&called, 100, health(needs: true))
        for i in 1...49 { #expect(observe(&called, 100 + Double(i) * 0.1, health(calls: [UInt64(i), UInt64(i)]), running: false) == .waitAndObserve) }
        guard case .giveUp(let why2) = observe(&called, 105, health(calls: [500, 500]), running: false) else { Issue.record("no give up"); return }
        #expect(why2.contains("still being called"))
    }

    @Test func aRefusedPrimeNeverLeadsToARestartAndTheWaitTimeoutIsExact() {
        var c = RePrimeController(config: cfg)
        _ = observe(&c, 0, health(needs: true))
        var now = 0.0
        for _ in 0..<4 { now += 0.05; _ = observe(&c, now, health(), running: false) }
        #expect(c.state == .priming)
        // refusals: the first one at 50.0 starts the wait; 59.99 is still inside the 10 s, 60.0 is not
        #expect(c.step(.primeResult(now: 50.0, succeeded: false, health: health())) == .waitAndObserve)
        for t in [51.0, 55.0, 59.99] {
            #expect(observe(&c, t, health(), running: false) == .prime, "waiting for T at \(t): ask for another prime")
            #expect(c.step(.primeResult(now: t, succeeded: false, health: health())) == .waitAndObserve, "refused again at \(t)")
        }
        guard case .giveUp(let why) = c.step(.primeResult(now: 60.0, succeeded: false, health: health())) else { Issue.record("no give up at 10 s"); return }
        #expect(why.contains("kept refusing") && c.rePrimesPerformed == 0)

        // the same boundary on the observe path
        var o = RePrimeController(config: cfg)
        _ = observe(&o, 0, health(needs: true))
        for i in 1...4 { _ = observe(&o, Double(i) * 0.05, health(), running: false) }
        _ = o.step(.primeResult(now: 50, succeeded: false, health: health()))
        #expect(observe(&o, 59.99, health(), running: false) == .prime)
        if case .giveUp = observe(&o, 60, health(), running: false) {} else { Issue.record("observe path: no give up at 10 s") }
    }

    @Test func theEngineRestartsOnlyWhenBothReadersSitAtTheSameFrameWithAtLeastTFrames() {
        func attempt(_ h: RingHealth) -> RePrimeAction {
            var c = RePrimeController(config: cfg)
            _ = observe(&c, 0, health(needs: true))
            for i in 1...4 { _ = observe(&c, Double(i) * 0.05, health(), running: false) }
            return c.step(.primeResult(now: 1, succeeded: true, health: h))
        }
        #expect(attempt(health(fills: [2048, 2048], cursors: [7, 7], t: 2048)) == .restartEngine, "exactly T in both: enough")
        #expect(attempt(health(fills: [4096, 2048], cursors: [7, 7], t: 2048)) == .restartEngine)
        for bad in [health(fills: [2047, 2048], cursors: [7, 7], t: 2048), health(fills: [2048, 2047], cursors: [7, 7], t: 2048),
                    health(fills: [2048, 2048], cursors: [7, 8], t: 2048), health(fills: [2048, 2048], cursors: [8, 7], t: 2048),
                    health(fills: [2048, 2048], cursors: [7, 7], t: 0), health(fills: [2048], cursors: [7, 7], t: 2048),
                    health(fills: [2048, 2048], cursors: [7], t: 2048)] {
            if case .giveUp = attempt(bad) {} else { Issue.record("restarted with fills \(bad.fills), cursors \(bad.cursors), T \(bad.standingFill)") }
        }
    }

    @Test func afterAFailureNothingIsTriggeredAndTheRecordSaysWhy() {
        var c = RePrimeController(config: cfg)
        _ = observe(&c, 0, health(needs: true))
        _ = observe(&c, 105, health(), running: true)
        let n = c.records.count
        for t in [200.0, 300] { #expect(observe(&c, t, health(u: [99, 99], needs: true)) == .none) }
        #expect(c.records.count == n && c.state == .idle && c.rePrimesPerformed == 0)
    }

    @Test func aTriggerWhileASequenceIsRunningCreatesNoSecondRePrime() {
        var c = RePrimeController(config: cfg)
        _ = observe(&c, 100, health(needs: true))
        for s in [0.1, 0.2] { _ = observe(&c, 100 + s, health(u: [50, 50], needs: true), running: true) }
        #expect(c.records.count == 1, "still one record while stopping")
        for i in 1...4 { _ = observe(&c, 101 + Double(i) * 0.05, health(needs: true), running: false) }
        #expect(c.state == .priming)
        _ = observe(&c, 102, health(u: [50, 50], needs: true), running: false)          // a stray observation in `priming`
        _ = c.step(.primeResult(now: 102.1, succeeded: true, health: health()))
        _ = observe(&c, 102.2, health(u: [50, 50], needs: true), running: false)        // a stray observation in `restarting`
        #expect(c.records.count == 1 && c.state == .restarting)
    }
}

@Suite struct RePrimeStartPathTests {
    @Test func theStartIsTheSamePrimeWaitStartSequenceButIsNotCountedAsARePrimeAndNeverStopsAnything() {
        var c = RePrimeController(config: cfg)
        var seen: [RePrimeAction] = []
        seen.append(c.beginStart(now: 0))
        seen.append(c.step(.primeResult(now: 0.05, succeeded: false, health: health())))
        seen.append(observe(&c, 0.10, health(), running: false))
        seen.append(c.step(.primeResult(now: 0.15, succeeded: true, health: health(fills: [2048, 2048], cursors: [3, 3]))))
        seen.append(c.step(.restartResult(now: 0.20, succeeded: true, health: health())))
        #expect(seen == [.prime, .waitAndObserve, .prime, .restartEngine, .none], "no stop, no quiet wait: the engine is not running yet")
        #expect(c.records.isEmpty && c.rePrimesPerformed == 0 && c.startRecord?.succeeded == true && c.startRecord?.reason == .start && c.startRecord?.primeAttempts == 2)
        #expect(c.beginStart(now: 5) == .none, "once only")
    }

    @Test func theStartPathChecksTheSameFillAndCursorConditionsAsARePrime() {
        var c = RePrimeController(config: cfg)
        _ = c.beginStart(now: 0)
        if case .giveUp = c.step(.primeResult(now: 1, succeeded: true, health: health(fills: [100, 2048], cursors: [3, 3]))) {} else { Issue.record("the start restarted with a fill below T") }
        #expect(c.startRecord?.succeeded == false && c.failure != nil)
    }

    @Test func theStartCountsAsTheLastRestartForTheMinimumInterval() {
        var c = RePrimeController(config: cfg)
        _ = c.beginStart(now: 0)
        _ = c.step(.primeResult(now: 0.05, succeeded: true, health: health()))
        _ = c.step(.restartResult(now: 0.10, succeeded: true, health: health()))
        #expect(observe(&c, 1, health(needs: true)) == .none && c.suppressedByMinimumInterval == 1)
        #expect(observe(&c, 5.09, health(needs: true)) == .none && c.suppressedByMinimumInterval == 2)
        #expect(observe(&c, 5.10, health(needs: true)) == .stopEngine, "exactly the minimum interval after the restart")
    }
}

@Suite struct RePrimeLimitTests {
    @Test func theMinimumIntervalIsMeasuredFromTheRestartAndTheBoundaryIsExact() {
        var c = RePrimeController(config: cfg)
        let restart = completeRePrime(&c, triggerAt: 100, with: health(needs: true), poll: 1.0)        // trigger 100, restart 106 (the engine was stopped for 6 s)
        #expect(restart == 106)
        #expect(observe(&c, 107, health(needs: true)) == .none, "1 s after the restart (7 s after the earlier trigger): suppressed")
        #expect(c.suppressedByMinimumInterval == 1)
        #expect(observe(&c, 110.99, health(needs: true)) == .none && c.suppressedByMinimumInterval == 2)
        #expect(observe(&c, 111, health(needs: true)) == .stopEngine, "5 s after the restart: allowed")
        #expect(c.records.count == 2 && c.records[1].secondsSincePreviousRestart == 5)
    }

    @Test func theStormLimitCapsRePrimesPerWindowAndTheWindowExpires() {
        var c = RePrimeController(config: RePrimeConfig(minIntervalSeconds: 0, maxRePrimesPerWindow: 3, windowSeconds: 60))
        // poll 0.25 (a power of two): every time below is exactly representable, so "exactly one window old" is an exact 60.0 and not 59.999999999 or 60.00000001
        let r1 = completeRePrime(&c, triggerAt: 10, with: health(needs: true), poll: 0.25)
        let r2 = completeRePrime(&c, triggerAt: 20, with: health(needs: true), poll: 0.25)
        let r3 = completeRePrime(&c, triggerAt: 30, with: health(needs: true), poll: 0.25)
        #expect(c.rePrimesPerformed == 3)
        #expect(observe(&c, 40, health(needs: true)) == .none, "a fourth within 60 s of the first: suppressed")
        #expect(c.suppressedByStormLimit == 1 && c.suppressedByMinimumInterval == 0 && c.records.count == 3)
        #expect(observe(&c, r1 + 59.99, health(needs: true)) == .none && c.suppressedByStormLimit == 2)
        #expect(observe(&c, r1 + 60, health(needs: true)) == .stopEngine, "the first restart is exactly one window old: it no longer counts")
        _ = (r2, r3)
    }

    @Test func aStormLimitOfOneAndAWindowThatExpiresAreExactAtTheBoundary() {
        var c = RePrimeController(config: RePrimeConfig(minIntervalSeconds: 0, maxRePrimesPerWindow: 1, windowSeconds: 60))
        let r = completeRePrime(&c, triggerAt: 10, with: health(needs: true), poll: 0.25)
        #expect(observe(&c, r + 1, health(needs: true)) == .none && c.suppressedByStormLimit == 1, "limit 1 means the second is suppressed")
        #expect(observe(&c, r + 59.75, health(needs: true)) == .none && c.suppressedByStormLimit == 2, "a quarter second short of the window: still counted")
        #expect(observe(&c, r + 60, health(needs: true)) == .stopEngine)
    }

    @Test func aPerformedRePrimeIsCountedAndAFailedOneIsNot() {
        var c = RePrimeController(config: RePrimeConfig(minIntervalSeconds: 0, maxRePrimesPerWindow: 9, windowSeconds: 60))
        completeRePrime(&c, triggerAt: 10, with: health(needs: true))
        completeRePrime(&c, triggerAt: 20, with: health(needs: true))
        #expect(observe(&c, 30, health(needs: true)) == .stopEngine)
        for i in 1...4 { _ = observe(&c, 30 + Double(i) * 0.05, health(), running: false) }
        if case .giveUp = c.step(.primeResult(now: 31, succeeded: true, health: health(fills: [1, 1]))) {} else { Issue.record("a bad fill was accepted") }
        #expect(c.records.count == 3 && c.rePrimesPerformed == 2 && c.records[2].succeeded == false)
    }

    @Test func aRestartThatFailsIsRecordedAsAFailureNotASuccess() {
        var c = RePrimeController(config: cfg)
        _ = observe(&c, 0, health(needs: true))
        for i in 1...4 { _ = observe(&c, Double(i) * 0.05, health(), running: false) }
        _ = c.step(.primeResult(now: 1, succeeded: true, health: health()))
        if case .giveUp = c.step(.restartResult(now: 2, succeeded: false, health: health())) {} else { Issue.record("a failed restart was not a give-up") }
        #expect(c.records[0].succeeded == false && c.records[0].restartedAtSeconds == nil && c.rePrimesPerformed == 0)
    }
}

@Suite struct RePrimeConfigTests {
    @Test func everyNumberIsChecked() {
        #expect(RePrimeConfig().problem == nil)
        #expect(RePrimeConfig(minIntervalSeconds: 0).problem == nil, "no minimum interval is allowed (the tests use it)")
        #expect(RePrimeConfig(primeCallbacks: 1, underrunBlocksThreshold: 1, divergenceThreshold: 1, maxRePrimesPerWindow: 1, quietPollsRequired: 1).problem == nil)
        var bad: [RePrimeConfig] = []
        var c = RePrimeConfig(); c.primeCallbacks = 0; bad.append(c)
        c = RePrimeConfig(); c.underrunBlocksThreshold = 0; bad.append(c)
        c = RePrimeConfig(); c.divergenceThreshold = 0; bad.append(c)
        c = RePrimeConfig(); c.minIntervalSeconds = -1; bad.append(c)
        c = RePrimeConfig(); c.minIntervalSeconds = .nan; bad.append(c)
        c = RePrimeConfig(); c.maxRePrimesPerWindow = 0; bad.append(c)
        c = RePrimeConfig(); c.windowSeconds = 0; bad.append(c)
        c = RePrimeConfig(); c.quietPollsRequired = 0; bad.append(c)
        c = RePrimeConfig(); c.stopTimeoutSeconds = 0; bad.append(c)
        c = RePrimeConfig(); c.waitForTimeoutSeconds = .infinity; bad.append(c)
        for b in bad { #expect(b.problem != nil, "\(b)") }
    }
}
