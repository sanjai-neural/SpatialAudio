#!/usr/bin/env python3
"""Step 6b-3a-2 mutation check of the control-thread re-prime and the recovery mode of the ring probe (test-the-test; CLAUDE.md).

The mutant list (ids C, S, E, R) was written BEFORE any 3a-2 code existed; the additions (ids Q) were written after the code and the tests but before any mutant was run. Both
are copied into docs/STATUS.md. Ids here follow those lists; where one patch serves two ids the description says so.

Each mutant is one or more (file, old, new) edits; every `old` must occur EXACTLY ONCE in its file or the run stops for that mutant (PATCH-ERROR). Every mutant is run against the
new and the related existing suites with `swift test --filter`. Verdicts:
  KILLED          the test run failed cleanly (a test failed, or the build of the tests failed AFTER the patch applied: reported as DID-NOT-COMPILE, which is not counted as killed)
  HANG            the run did not finish within the timeout (detected, but reported SEPARATELY from a clean fail: a hang is not a verdict of a test)
  SURVIVED        the tests passed with the mutant in place (a hole, or an equivalent mutant that must then be argued by hand)
  DID-NOT-COMPILE the patch does not build (not counted as killed)
The original of every file is restored in a `finally` and compared byte for byte. The script records the SHA-256 of every touched file before and after the run and of itself.

  python3 -I scripts/mutate_reprime.py [--only C01,S03] [--results FILE.json] [--timeout 600]

Run it under `caffeinate -i` (a run takes a long while; this Mac sleeps) and do not touch the working tree while it runs. Does not push, commit or change anything else.
"""
import argparse
import hashlib
import json
import os
import signal
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CTRL = "Sources/SpatialAudioCore/RePrimeController.swift"
ORCH = "Sources/SpatialAudioCore/RingRecoveryOrchestrator.swift"
RREP = "Sources/SpatialAudioCore/RingRecoveryReport.swift"
RUNNER = "Sources/SpatialAudioCore/RingProbeRunner.swift"
PREP = "Sources/SpatialAudioCore/RingProbeReport.swift"
ARGS = "Sources/SpatialAudioCore/RingProbeArguments.swift"
ENGINE = "Sources/SpatialAudioEngine/RingProbeEngine.swift"
SIM = "Sources/SpatialAudioEngine/SimulatedRingBackend.swift"

FILTER = "RePrime|RingRecovery|RingProbe|DispatchRingTicker"

ONE = lambda f, o, n: [(f, o, n)]  # noqa: E731

MUTANTS = {
    # ---- trigger thresholds (Core) ----
    "C01": ("underrun threshold off by one: fires at count > U", ONE(CTRL, "if (h.underrunBlocks.max() ?? 0) >= c.underrunBlocksThreshold {", "if (h.underrunBlocks.max() ?? 0) > c.underrunBlocksThreshold {")),
    "C02": ("underrun threshold off by one the other way: fires at count >= U - 1", ONE(CTRL, "if (h.underrunBlocks.max() ?? 0) >= c.underrunBlocksThreshold {", "if (h.underrunBlocks.max() ?? 0) >= c.underrunBlocksThreshold - 1 {")),
    "C03a": ("divergence threshold off by one: fires at count > D", ONE(CTRL, "if (h.divergenceEvents.max() ?? 0) >= c.divergenceThreshold {", "if (h.divergenceEvents.max() ?? 0) > c.divergenceThreshold {")),
    "C03b": ("divergence threshold off by one the other way: fires at count >= D - 1", ONE(CTRL, "if (h.divergenceEvents.max() ?? 0) >= c.divergenceThreshold {", "if (h.divergenceEvents.max() ?? 0) >= c.divergenceThreshold - 1 {")),
    "C04": ("the needsReprime flag is ignored", ONE(CTRL, "if h.needsReprime { return .needsReprimeFlag }", "if false && h.needsReprime { return .needsReprimeFlag }")),
    "C05": ("the diverged flag is ignored", ONE(CTRL, "if h.diverged.contains(true) { return .divergedFlag }", "if false && h.diverged.contains(true) { return .divergedFlag }")),
    "C06a": ("only reader 0's underruns are looked at", ONE(CTRL, "if (h.underrunBlocks.max() ?? 0) >= c.underrunBlocksThreshold {", "if (h.underrunBlocks.first ?? 0) >= c.underrunBlocksThreshold {")),
    "C06b": ("only reader 0's divergence events are looked at", ONE(CTRL, "if (h.divergenceEvents.max() ?? 0) >= c.divergenceThreshold {", "if (h.divergenceEvents.first ?? 0) >= c.divergenceThreshold {")),
    "C07": ("the two readers' underruns are SUMMED instead of the maximum", ONE(CTRL, "if (h.underrunBlocks.max() ?? 0) >= c.underrunBlocksThreshold {", "if h.underrunBlocks.reduce(0, +) >= c.underrunBlocksThreshold {")),
    "C08a": ("reentrancy: a trigger is accepted while the controller is restarting (Q06)",
             ONE(CTRL, "        switch state {\n        case .idle:\n            guard failure == nil else { return .none }", "        switch (state == .restarting ? RePrimeState.idle : state) {\n        case .idle:\n            guard failure == nil else { return .none }")),
    "C08b": ("reentrancy: a trigger is accepted while the controller is stopping (Q06)",
             ONE(CTRL, "        switch state {\n        case .idle:\n            guard failure == nil else { return .none }", "        switch (state == .stopping ? RePrimeState.idle : state) {\n        case .idle:\n            guard failure == nil else { return .none }")),
    "C09a": ("the minimum interval is ignored (a storm)", ONE(CTRL, "if let last = lastRestartAt, now - last < config.minIntervalSeconds {", "if let last = lastRestartAt, false, now - last < config.minIntervalSeconds {")),
    "C09b": ("the minimum interval boundary: suppressed at <= instead of <", ONE(CTRL, "if let last = lastRestartAt, now - last < config.minIntervalSeconds {", "if let last = lastRestartAt, now - last <= config.minIntervalSeconds {")),
    "C10a": ("storm limit off by one: suppressed only above the limit", ONE(CTRL, "if recentRestarts.count >= config.maxRePrimesPerWindow {", "if recentRestarts.count > config.maxRePrimesPerWindow {")),
    "C10b": ("storm limit off by one the other way: suppressed one early", ONE(CTRL, "if recentRestarts.count >= config.maxRePrimesPerWindow {", "if recentRestarts.count >= config.maxRePrimesPerWindow - 1 {")),
    "C11a": ("the storm window never expires", ONE(CTRL, "recentRestarts.removeAll { now - $0 >= config.windowSeconds }", "recentRestarts.removeAll { _ in false }")),
    "C11b": ("the storm window boundary: expires at > instead of >=", ONE(CTRL, "recentRestarts.removeAll { now - $0 >= config.windowSeconds }", "recentRestarts.removeAll { now - $0 > config.windowSeconds }")),
    "C12": ("the cooldown is measured from the trigger instead of from the restart", ONE(CTRL, "        lastRestartAt = now\n        inProgressIsStart = false", "        lastRestartAt = records.last?.triggeredAtSeconds ?? now\n        inProgressIsStart = false")),
    "C13a": ("a performed re-prime is not counted", ONE(CTRL, "public var rePrimesPerformed: Int { records.filter(\\.succeeded).count }", "public var rePrimesPerformed: Int { 0 }")),
    "C13b": ("a failed re-prime is counted as performed", ONE(CTRL, "public var rePrimesPerformed: Int { records.filter(\\.succeeded).count }", "public var rePrimesPerformed: Int { records.count }")),
    "C14a": ("a trigger suppressed by the storm limit is not counted", ONE(CTRL, "{ suppressedByStormLimit += 1; return .none }", "{ return .none }")),
    "C14b": ("a trigger suppressed by the minimum interval is not counted", ONE(CTRL, "{ suppressedByMinimumInterval += 1; return .none }", "{ return .none }")),
    # ---- state machine (Core) ----
    "S01": ("stopping -> priming without the engine being confirmed stopped", ONE(CTRL, "            if engineRunning {\n", "            if false && engineRunning {\n")),
    "S02": ("priming -> restarting after a REFUSED prime (no waiting for data)", ONE(CTRL, "            return .waitAndObserve\n        }\n        // The prime succeeded", "            return .restartEngine\n        }\n        // The prime succeeded")),
    "S03": ("waitingForT: restart at fill >= T - 1 (boundary)", ONE(CTRL, "health.fills.allSatisfy { $0 >= t }", "health.fills.allSatisfy { $0 >= t - 1 }")),
    "S04": ("waitingForT: restart only at fill > T (boundary the other way)", ONE(CTRL, "health.fills.allSatisfy { $0 >= t }", "health.fills.allSatisfy { $0 > t }")),
    "S05a": ("the wait-for-T timeout is ignored on the observe path (waits for ever)", ONE(CTRL, "        case .waitingForT:\n            if now - stateEnteredAt >= config.waitForTimeoutSeconds {", "        case .waitingForT:\n            if false && now - stateEnteredAt >= config.waitForTimeoutSeconds {")),
    "S05b": ("the wait-for-T timeout is ignored on the prime-result path", ONE(CTRL, "            if state == .priming { state = .waitingForT; stateEnteredAt = now }\n            if now - stateEnteredAt >= config.waitForTimeoutSeconds {", "            if state == .priming { state = .waitingForT; stateEnteredAt = now }\n            if false && now - stateEnteredAt >= config.waitForTimeoutSeconds {")),
    "S06a": ("the wait-for-T timeout fires early (half) on the observe path", ONE(CTRL, "        case .waitingForT:\n            if now - stateEnteredAt >= config.waitForTimeoutSeconds {", "        case .waitingForT:\n            if now - stateEnteredAt >= config.waitForTimeoutSeconds / 2 {")),
    "S06b": ("the wait-for-T timeout fires early (half) on the prime-result path", ONE(CTRL, "            if state == .priming { state = .waitingForT; stateEnteredAt = now }\n            if now - stateEnteredAt >= config.waitForTimeoutSeconds {", "            if state == .priming { state = .waitingForT; stateEnteredAt = now }\n            if now - stateEnteredAt >= config.waitForTimeoutSeconds / 2 {")),
    "S07": ("after the restart the state does not return to idle", ONE(CTRL, "        state = .idle; quietCount = 0; lastCalls = nil\n        return .none", "        state = .restarting; quietCount = 0; lastCalls = nil\n        return .none")),
    "S08": ("the start path is counted as a re-prime (Q45)", ONE(CTRL, "public var rePrimesPerformed: Int { records.filter(\\.succeeded).count }", "public var rePrimesPerformed: Int { records.filter(\\.succeeded).count + (startRecord?.succeeded == true ? 1 : 0) }")),
    "S09": ("the start path does not go through prime / wait: it restarts at once (Q47)", ONE(CTRL, "        state = .priming; stateEnteredAt = now; attempts = 0\n        return .prime\n    }", "        state = .restarting; stateEnteredAt = now; attempts = 0\n        return .restartEngine\n    }")),
    # ---- orchestrator ----
    "E01": ("the engine is not stopped before the prime", ONE(ORCH, "            case .stopEngine:\n                backend.pauseEngine()\n", "            case .stopEngine:\n")),
    "E02": ("the controller is told the engine is not running whatever the backend says (Q07)", ONE(ORCH, "        return controller.step(.observe(now: clock.now(), health: health, engineRunning: backend.isEngineRunning))", "        return controller.step(.observe(now: clock.now(), health: health, engineRunning: false))")),
    "E03": ("the prime is reported as succeeded whatever SARingPrime returned (Q15)", ONE(ORCH, "action = controller.step(.primeResult(now: now, succeeded: ok, health: health))", "action = controller.step(.primeResult(now: now, succeeded: true, health: health))")),
    "E04": ("cursors not verified equal after the prime", ONE(CTRL, "let together = health.cursors.count == 2 && health.cursors[0] == health.cursors[1]", "let together = true")),
    "E05": ("restart when only reader 0 holds >= T frames", ONE(CTRL, "health.fills.count == 2 && health.fills.allSatisfy { $0 >= t }", "health.fills.count == 2 && (health.fills.first ?? 0) >= t")),
    "E06": ("the reentrancy guard's RETURN is removed (the nested tick runs; the counter still counts). EQUIVALENT by trace: see docs/STATUS.md", ONE(ORCH, "guard !busy else { reentrantTicksRefused += 1; return }", "if busy { reentrantTicksRefused += 1 }")),
    "E06b": ("the reentrancy guard AND its counter are removed (ADDED after the first run, when E06 turned out to be observably equivalent)", ONE(ORCH, "guard !busy else { reentrantTicksRefused += 1; return }", "reentrantTicksRefused += 0")),
    "E07a": ("the gain is not read back before the restart", ONE(ORCH, "guard backend.engineOutputGain() == 0 else {", "guard true || backend.engineOutputGain() == 0 else {")),
    "E07b": ("an unreadable gain is accepted before the restart (Q17)", ONE(ORCH, "guard backend.engineOutputGain() == 0 else {", "guard (backend.engineOutputGain() ?? 0) == 0 else {")),
    "E08": ("a failed restart is recorded as success", ONE(ORCH, "action = controller.step(.restartResult(now: clock.now(), succeeded: r.ok, health: health))", "action = controller.step(.restartResult(now: clock.now(), succeeded: true, health: health))")),
    "E09": ("after the storm limit the re-prime happens anyway", ONE(CTRL, "if recentRestarts.count >= config.maxRePrimesPerWindow {", "if false && recentRestarts.count >= config.maxRePrimesPerWindow {")),
    "E10a": ("engine-stopped time measured from the wrong instant (the moment the controller entered `restarting`, i.e. the prime time, not the stop request). REWRITTEN after the first run: the first form used `stateEnteredAt` inside the closure and did not compile",
             [(CTRL, "        setCurrent {\n            $0.restartedAtSeconds = now\n", "        let wrongInstant = stateEnteredAt\n        setCurrent {\n            $0.restartedAtSeconds = now\n"),
              (CTRL, "$0.engineStoppedSeconds = now - $0.stopIssuedAtSeconds", "$0.engineStoppedSeconds = now - wrongInstant")]),
    "E10b": ("fill at restart read from the snapshot taken BEFORE the prime (Q16)", ONE(ORCH, 'guard let post = backend.snapshot(), let health = RingHealth(raw: post) else { gaveUpReason = "no ring snapshot after the prime"; return }', 'guard let post = Optional(pre), let health = RingHealth(raw: post) else { gaveUpReason = "no ring snapshot after the prime"; return }')),
    "E10c": ("underruns-before recorded as 0 (read after the prime zeroed them)", ONE(CTRL, "underrunsBefore: health.underrunBlocks.max() ?? 0,", "underrunsBefore: 0,")),
    "E10d": ("underruns-after never accumulated", ONE(CTRL, "        guard let owner = epochOwner else { return }\n        let u = h.underrunBlocks.max() ?? 0", "        if true { return }\n        guard let owner = epochOwner else { return }\n        let u = h.underrunBlocks.max() ?? 0")),
    "E10e": ("seconds since the previous restart not recorded", ONE(CTRL, "secondsSincePreviousRestart: lastRestartAt.map { now - $0 },", "secondsSincePreviousRestart: nil,")),
    "E11": ("the number of re-primes in the report differs from the records: failed ones counted (Q34)", ONE(RREP, "rePrimesPerformed = rePrimes.filter(\\.succeeded).count", "rePrimesPerformed = rePrimes.count")),
    # ---- probe report, mapper and arguments ----
    "R01": ("the frame-count table is taken from the wrong reader (left / right swapped, Q31)", ONE(ENGINE, '[recovery(s.reader.0, name: "left (reader 0)"), recovery(s.reader.1, name: "right (reader 1)")]', '[recovery(s.reader.1, name: "left (reader 0)"), recovery(s.reader.0, name: "right (reader 1)")]')),
    "R01b": ("the frame-count calls are read with the wrong stride (Q32)", ONE(ENGINE, "calls.load(fromByteOffset: k * MemoryLayout<UInt64>.stride, as: UInt64.self)", "calls.load(fromByteOffset: k * MemoryLayout<UInt32>.stride, as: UInt64.self)")),
    "R02a": ("the per-reader flags are missing from the report (Q33)", ONE(ENGINE, "diverged: r.diverged != 0, needsReprime: r.needsReprime != 0)", "diverged: false, needsReprime: false)")),
    "R02b": ("the ring-level needsReprime is missing from the report (Q33)", ONE(ENGINE, "RingRecoverySnapshot(standingFill: s.standingFill, needsReprime: s.needsReprime != 0,", "RingRecoverySnapshot(standingFill: s.standingFill, needsReprime: false,")),
    "R03": ("a simulated run is not labelled SIMULATED", ONE(PREP, 'public var isSimulated: Bool { source == "simulated" }', "public var isSimulated: Bool { false }")),
    "R05": ("the recovery mode skips the output gain refusal before the engine start (Q27)", ONE(RUNNER, "guard gain.readBackBeforeStart == 0 else {", "guard recovery != nil || gain.readBackBeforeStart == 0 else {")),
    "R06": ("the JSON round trip loses the per-re-prime records (Q36)", ONE(RREP, "    public var rePrimes: [RePrimeRecord]\n    public var rePrimesPerformed: Int", "    public var rePrimes: [RePrimeRecord] = []\n    private enum CodingKeys: String, CodingKey { case config, start, rePrimesPerformed, suppressedByMinimumInterval, suppressedByStormLimit, gaveUp, readers, standingFillAtEnd, notes }\n    public var rePrimesPerformed: Int")),
    "R07": ("--ring-probe-recovery accepts a gain / volume option (Q37)", ONE(ARGS, "        if let g = arguments.dropFirst().first(where:", "        if !recovery, let g = arguments.dropFirst().first(where:")),
    "R08": ("--ring-probe-recovery accepts zero, negative or non-finite seconds (Q38)", ONE(ARGS, "        if let problem = RingProbeRunner.validate(seconds: seconds) { return .invalid(problem) }", "        if !recovery, let problem = RingProbeRunner.validate(seconds: seconds) { return .invalid(problem) }")),
    # ---- additions (Q) ----
    "Q01": ("the quiet-poll check is skipped", ONE(CTRL, "if quietCount >= config.quietPollsRequired { state = .priming;", "if true { state = .priming;")),
    "Q02": ("the quiet-poll compares only reader 0's call count", ONE(CTRL, "if let last = lastCalls, last == health.calls {", "if let last = lastCalls, last.first == health.calls.first {")),
    "Q03a": ("the quiet-poll count needs one more", ONE(CTRL, "if quietCount >= config.quietPollsRequired { state = .priming;", "if quietCount > config.quietPollsRequired { state = .priming;")),
    "Q03b": ("the quiet-poll count needs one fewer", ONE(CTRL, "if quietCount >= config.quietPollsRequired { state = .priming;", "if quietCount >= config.quietPollsRequired - 1 { state = .priming;")),
    "Q04": ("the stop timeout (engine still running) is ignored", ONE(CTRL, 'if now - stateEnteredAt >= config.stopTimeoutSeconds { return fail("the engine still reported', 'if false && now - stateEnteredAt >= config.stopTimeoutSeconds { return fail("the engine still reported')),
    "Q05": ("the stop timeout (readers still called) is ignored", ONE(CTRL, 'if now - stateEnteredAt >= config.stopTimeoutSeconds { return fail("the readers were still being called', 'if false && now - stateEnteredAt >= config.stopTimeoutSeconds { return fail("the readers were still being called')),
    "Q08": ("the step cap is removed", ONE(ORCH, "if turns > Self.iterationCap {", "if false && turns > Self.iterationCap {")),
    "Q09": ("the epoch about to be zeroed is not added to the sums", ONE(ORCH, "if ok { absorb(pre) }", "if false { absorb(pre) }")),
    "Q10": ("the epoch is added even when the prime was refused (double counted)", ONE(ORCH, "if ok { absorb(pre) }", "absorb(pre)")),
    "Q11": ("the gauges (cursor, fill) are summed like counts", ONE(ORCH, "        s.weakRuleViolations += earlier.weakRuleViolations\n        return s", "        s.weakRuleViolations += earlier.weakRuleViolations\n        s.cursor += earlier.cursor; s.fill += earlier.fill\n        return s")),
    "Q12": ("the underrun counter is not summed over epochs", ONE(ORCH, "s.underrunBlocks += earlier.underrunBlocks; ", "")),
    "Q13": ("the orchestrator ignores its own give-up on later ticks", ONE(ORCH, "guard gaveUpReason == nil, let health = RingHealth(raw: raw) else { return }", "guard let health = RingHealth(raw: raw) else { return }")),
    "Q14a": ("the orchestrator passes the ring's default T instead of the configured primeCallbacks", ONE(ORCH, "backend.prime(callbacks: config.primeCallbacks)", "backend.prime()")),
    "Q14b": ("the simulated backend primes with the ring's default T whatever it is asked for", ONE(SIM, "public func prime(callbacks: UInt32) -> Bool { ring.map { SARingPrime($0, callbacks) } ?? false }", "public func prime(callbacks: UInt32) -> Bool { ring.map { SARingPrime($0, SA_RING_DEFAULT_PRIME_CALLBACKS) } ?? false }")),
    "Q18": ("finish() keeps only the last epoch's recovery table (earlier epochs lost)", ONE(ORCH, "        var readers = baseRecovery\n", '        var readers = [RingReaderRecovery(name: "left (reader 0)"), RingReaderRecovery(name: "right (reader 1)")]\n')),
    "Q19": ("the controller is told the CUMULATIVE counters at the end of the run", [(RUNNER, "            lastEpochRaw = epochRaw\n", ""), (RUNNER, "            if firstRaw == nil { firstRaw = raw }\n", "            lastEpochRaw = raw\n            if firstRaw == nil { firstRaw = raw }\n")]),
    "Q20": ("RingHealth ignores refused jumps in the divergence count", ONE(ORCH, ".map { $0.divergenceJumps + $0.refusedJumps }", ".map { $0.divergenceJumps }")),
    "Q21": ("RingHealth reads the other reader's diverged flag", ONE(ORCH, "diverged: (rec?.readers ?? []).map(\\.diverged),", "diverged: (rec?.readers ?? []).reversed().map(\\.diverged),")),
    "Q22": ("the runner never calls the recovery's tick", ONE(RUNNER, "if act, let recovery { recovery.tick(raw: epochRaw, clock: clock) }", "if false, let recovery { recovery.tick(raw: epochRaw, clock: clock) }")),
    "Q23": ("the runner does not make the counters cumulative", ONE(RUNNER, "let raw = recovery?.cumulative(epochRaw) ?? epochRaw", "let raw = epochRaw")),
    "Q24": ("the runner ignores the recovery's give-up", ONE(RUNNER, "if let why = recovery?.gaveUp {", "if false, let why = recovery?.gaveUp {")),
    "Q25": ("the runner does not use performStart (its own prime loop)", ONE(RUNNER, "            if let recovery {\n                let r = recovery.performStart(clock: clock)", "            if false, let recovery {\n                let r = recovery.performStart(clock: clock)")),
    "Q26": ("the runner does not attach the recovery section", ONE(RUNNER, "report.recovery = recovery.finish(raw: lastEpochRaw)", "report.recovery = nil")),
    "Q28": ("pause() does nothing", ONE(ENGINE, "    func pause() { engine.stop() }", "    func pause() {}")),
    "Q29": ("pause() also removes the configuration-change observer", ONE(ENGINE, "    func pause() { engine.stop() }", "    func pause() { engine.stop(); removeObserver() }")),
    "Q30": ("simulated pause: the engine is stopped BEFORE the render pump is joined", ONE(SIM, '        renderThread?.requestStopAndJoin(); renderThread = nil\n        record("render pump joined (pause)")\n        engine?.pause()\n        record("engine paused")', '        engine?.pause()\n        record("engine paused")\n        renderThread?.requestStopAndJoin(); renderThread = nil\n        record("render pump joined (pause)")')),
    "Q35": ("the markdown puts diverged and needsReprime in each other's column", ONE(RREP, '\\(r.diverged ? "set" : "no") | \\(r.needsReprime ? "set" : "no") |")', '\\(r.needsReprime ? "set" : "no") | \\(r.diverged ? "set" : "no") |")')),
    "Q39": ("simulated options are accepted on a real recovery run", ONE(ARGS, "        if sawSimOption && !simulate { return .invalid(", "        if sawSimOption && !simulate && !recovery { return .invalid(")),
    "Q40": ("the recovery flag is never set by the parser", ONE(ARGS, '                recovery = name.hasPrefix("--ring-probe-recovery")', "                recovery = false")),
    "Q41": ("the file stem ignores the recovery mode", ONE(PREP, 'return (recovery ? "ringrecovery-" : "ringprobe-") + f.string(from: date)', 'return "ringprobe-" + f.string(from: date)')),
    "Q42": ("config: primeCallbacks 0 accepted", ONE(CTRL, '        if primeCallbacks == 0 { return "primeCallbacks must be at least 1" }', '        if false { return "primeCallbacks must be at least 1" }')),
    "Q43": ("config: a threshold of 0 accepted for one of the two", ONE(CTRL, "if underrunBlocksThreshold == 0 || divergenceThreshold == 0 {", "if underrunBlocksThreshold == 0 && divergenceThreshold == 0 {")),
    "Q44": ("config: a minimum interval of 0 rejected", ONE(CTRL, "minIntervalSeconds.isFinite && minIntervalSeconds >= 0)", "minIntervalSeconds.isFinite && minIntervalSeconds > 0)")),
    "Q46": ("the start's restart is not the baseline of the minimum interval", ONE(CTRL, "        lastRestartAt = now\n        inProgressIsStart = false", "        if !inProgressIsStart { lastRestartAt = now }\n        inProgressIsStart = false")),
    "Q48": ("beginStart can run more than once", ONE(CTRL, "guard !hasStarted, state == .idle, failure == nil else { return .none }", "guard state == .idle, failure == nil else { return .none }")),
}


def read(rel):
    with open(os.path.join(ROOT, rel), "rb") as f:
        return f.read()


def write(rel, data):
    with open(os.path.join(ROOT, rel), "wb") as f:
        f.write(data)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def descendants(root_pid):
    """Every descendant of `root_pid` (children, grandchildren, ...), read from `ps` BEFORE anything is killed: once a parent dies its children are re-parented to PID 1 and
    can no longer be found this way. swiftpm-testing-helper puts itself in its OWN process group, so a killpg of the `swift test` group does not reach it."""
    out = subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True).stdout
    children = {}
    for line in out.splitlines():
        a = line.split()
        if len(a) == 2:
            children.setdefault(int(a[1]), []).append(int(a[0]))
    found, todo = [], [root_pid]
    while todo:
        for c in children.get(todo.pop(), []):
            found.append(c)
            todo.append(c)
    return found


def run_tests(filter_regex, timeout):
    """Runs `swift test`. On a timeout the WHOLE descendant tree (and the group) gets SIGTERM, then SIGKILL, so the test helper of a hung mutant is not left behind.
    (The first full run left one orphan swiftpm-testing-helper at 100 % CPU after each Q08 hang; the process-group-only version of this function, used for the second full
    run, still left one, PID 34587, because the helper has its own process group.)"""
    cmd = ["swift", "test", "--filter", filter_regex]
    t0 = time.time()
    p = subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=timeout)
        code = p.returncode
    except subprocess.TimeoutExpired:
        victims = descendants(p.pid)
        out = ""
        for sig in (signal.SIGTERM, signal.SIGKILL):
            for pid in [p.pid] + victims:
                try:
                    os.kill(pid, sig)
                except (ProcessLookupError, PermissionError):
                    pass
            try:
                os.killpg(p.pid, sig)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                out, _ = p.communicate(timeout=10)
                break
            except subprocess.TimeoutExpired:
                continue
        out = (out or "") + "\nTIMEOUT"
        code = 124
    return code, out, time.time() - t0


def classify(code, out):
    if code == 124:
        return "HANG"
    if "error:" in out and ("Build failed" in out or "failed with a nonzero exit code" in out) and "Test run with" not in out:
        return "DID-NOT-COMPILE"
    if code == 0:
        return "SURVIVED"
    return "KILLED"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--results", default="")
    ap.add_argument("--filter", default=FILTER)
    ap.add_argument("--timeout", type=int, default=600)
    args = ap.parse_args()
    ids = [i for i in MUTANTS if not args.only or i in args.only.split(",")]
    touched = sorted({f for i in ids for f, _, _ in MUTANTS[i][1]})
    before = {f: sha(read(f)) for f in touched}
    print("script sha256:", sha(open(__file__, "rb").read()), flush=True)
    print("files before:", json.dumps(before, indent=1), flush=True)
    results = {}
    for mid in ids:
        desc, edits = MUTANTS[mid]
        files = sorted({f for f, _, _ in edits})
        originals = {f: read(f) for f in files}
        try:
            for f, old, new in edits:
                text = read(f).decode()
                if text.count(old) != 1:
                    print(f"{mid}: PATCH DOES NOT MATCH EXACTLY ONCE in {f} ({text.count(old)} matches): {old[:70]!r}", file=sys.stderr, flush=True)
                    results[mid] = {"description": desc, "verdict": "PATCH-ERROR"}
                    break
                write(f, text.replace(old, new, 1).encode())
            else:
                code, out, secs = run_tests(args.filter, args.timeout)
                failing = sorted({line.split("Test ", 1)[1].split("(")[0].strip() for line in out.splitlines() if line.startswith("✘ Test ") and " recorded an issue" in line})
                verdict = classify(code, out)
                tail = [l for l in out.splitlines() if "error:" in l][:2] if verdict == "DID-NOT-COMPILE" else []
                results[mid] = {"description": desc, "verdict": verdict, "exit": code, "seconds": round(secs, 1), "failingTests": failing[:10], "compileErrors": tail}
                print(f"{mid}: {verdict} (exit {code}, {secs:.0f}s) {', '.join(failing[:4])}", flush=True)
        finally:
            for f, data in originals.items():
                write(f, data)
                assert read(f) == data, f"{f} was not restored"
        if args.results:
            with open(args.results, "w") as fh:
                json.dump(results, fh, indent=2)
    after = {f: sha(read(f)) for f in touched}
    print("files unchanged by the run:", before == after, flush=True)
    counts = {}
    for r in results.values():
        counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
    survivors = [m for m, r in results.items() if r["verdict"] == "SURVIVED"]
    hangs = [m for m, r in results.items() if r["verdict"] == "HANG"]
    bad = [m for m, r in results.items() if r["verdict"] in ("DID-NOT-COMPILE", "PATCH-ERROR")]
    print(f"\n{len(results)} mutants: {counts}; survived {survivors}; HANG {hangs}; did not compile / patch error {bad}")
    return 1 if survivors or bad or before != after else 0


if __name__ == "__main__":
    sys.exit(main())
