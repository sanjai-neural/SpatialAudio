import Foundation

// Step 6b-2: the order of operations of `--ring-probe`, its error unwinding, the gain guard and the teardown protocol, behind a backend protocol so that
// every path can be tested without hardware. The real backend (Core Audio tap + AVAudioEngine) and the simulated one live in SpatialAudioEngine.
// IMPLEMENTED-UNVERIFIED until Sanjai has run it.

/// What woke the runner: the sampling timer, a stop request (SIGINT / SIGTERM), or an event of the backend (an engine configuration change).
public enum RingProbeWake: Sendable, Equatable {
    case tick, signal, interrupt
}

/// The sampling timer. The runner takes ONE sample per `.tick`; the cadence comes from here (a timer), never from a sleep in the runner.
public protocol RingProbeTicker: AnyObject {
    func start(periodSeconds: Double)
    /// Blocks until the next event. A pending `.signal` is delivered before an `.interrupt`, an `.interrupt` before a `.tick`.
    func wait() -> RingProbeWake
    /// Idempotent; nothing fires after it returns.
    func stop()
}

/// What the probe needs from Core Audio, AVAudioEngine and the ring (or from stand-ins). Calls that talk to the system return their OSStatus; the runner
/// logs them. Object id 0 is `kAudioObjectUnknown`. There is deliberately NO method that sets a gain: the backend forces the output gain to 0 itself and
/// the runner only READS it back.
public protocol RingProbeBackend: AnyObject {
    /// "coreAudioTap" or "simulated".
    var source: String { get }
    var composition: String { get }
    /// `AudioGetHostClockFrequency()` for the real backend; the simulated one says what it simulates.
    var hostTicksPerSecond: Double { get }
    /// The named guesses N and T the ring is created / primed with.
    var ringConstants: RingProbeConstants { get }
    /// Simulated runs: what was injected (nil for the real backend).
    var injectedFaults: String? { get }

    func preflight() -> String?
    /// Numbers only: no name, no UID.
    func outputDeviceFacts() -> RingOutputFacts
    func translateOwnPID() -> (object: UInt32, status: Int32)
    func createTap(excludingProcessObjects: [UInt32]) -> (tap: UInt32, status: Int32)
    func readTapUID(_ tap: UInt32) -> (uid: String?, status: Int32)
    func readTapFormat(_ tap: UInt32) -> (format: TapFormat?, status: Int32)
    /// Control thread: `SARingCreate` with the named default capacity. False on failure.
    func createRing() -> Bool
    func createAggregate(tapUID: String) -> (device: UInt32, status: Int32)
    /// Registers the ring's producer function as the IOProc, with the ring as client data.
    func createIOProc(on device: UInt32) -> Int32
    func start(_ device: UInt32) -> Int32
    /// Builds the two-source-node graph (mono Float32 at the tap's rate) into the main mixer and FORCES the main mixer's output volume to 0. Nothing runs yet.
    func prepareEngine(tapFormat: TapFormat) -> (ok: Bool, detail: String?)
    func engineFacts() -> RingEngineFacts?
    /// The main mixer's output volume as read back from the engine (nil if there is no engine).
    func engineOutputGain() -> Double?
    /// One `SARingPrime` with `callbacks` as T. It never waits; false = not yet possible. Control thread; the engine must not be running.
    func prime(callbacks: UInt32) -> Bool
    func startEngine() -> (ok: Bool, detail: String?)
    func snapshot() -> RingProbeRawSample?
    /// How many `AVAudioEngineConfigurationChange` notifications arrived.
    func configurationChangeCount() -> Int
    /// Step 6b-3a-2: whether the engine reports it is running (`AVAudioEngine.isRunning`).
    var isEngineRunning: Bool { get }
    /// Step 6b-3a-2: stops the engine for a re-prime WITHOUT detaching the nodes or dropping the configuration-change observer (`stopEngine` is the final teardown step).
    /// Idempotent.
    func pauseEngine()
    func stopEngine()
    func detachSourceNodes()
    func stop(_ device: UInt32) -> Int32
    func destroyIOProc(on device: UInt32) -> Int32
    func destroyAggregate(_ device: UInt32) -> Int32
    func destroyTap(_ tap: UInt32) -> Int32
    func listDevices() -> (ids: [UInt32], status: Int32)
    func listTaps() -> (ids: [UInt32], status: Int32)
    /// Called last. The real backend NEVER frees the ring (the headers do not say that stop / destroy wait for a running callback); a backend whose
    /// producer is its own joined thread joins it and frees. Says which, and why.
    func finishRing() -> RingDisposition
}

extension RingProbeBackend {
    /// One `SARingPrime` with the backend's named default T (what the plain modes use).
    public func prime() -> Bool { prime(callbacks: ringConstants.primeCallbacks) }
}

/// What the runner needs from the recovery orchestrator (Step 6b-3a-2; the implementation is in SpatialAudioEngine). The plain modes pass nil and are unchanged.
public struct RingRecoveryStartOutcome: Sendable {
    public var primed: Bool
    public var primeAttempts: Int
    public var primeWaitSeconds: Double
    public var started: Bool
    public var startDetail: String?
    /// The runner's clock when the engine start returned (the first-pull wait is measured from here).
    public var engineStartedAtSeconds: Double
    public init(primed: Bool, primeAttempts: Int, primeWaitSeconds: Double, started: Bool, startDetail: String?, engineStartedAtSeconds: Double) {
        self.primed = primed; self.primeAttempts = primeAttempts; self.primeWaitSeconds = primeWaitSeconds; self.started = started
        self.startDetail = startDetail; self.engineStartedAtSeconds = engineStartedAtSeconds
    }
}

public protocol RingProbeRecovery: AnyObject {
    /// Replaces the runner's own prime loop and engine start: the SAME controller states as a re-prime (the first prime and the engine start).
    func performStart(clock: TapProbeClock) -> RingRecoveryStartOutcome
    /// Takes a raw snapshot (counters of the current epoch) and returns it with the counters made cumulative across re-primes, so that the series stays one continuous run.
    func cumulative(_ raw: RingProbeRawSample) -> RingProbeRawSample
    /// Called once per timer tick, after the sample was stored. May stop the engine, re-prime and restart it (a few polls, never a sleep of its own: the clock's sleep).
    func tick(raw: RingProbeRawSample, clock: TapProbeClock)
    /// Non-nil once the controller gave up; the runner then ends the run.
    var gaveUp: String? { get }
    /// Called after the last sample; `raw` is the last epoch's snapshot.
    func finish(raw: RingProbeRawSample?) -> RingRecoveryReport
}

public struct RingProbeEnvironment: Sendable {
    public var createdAt: String
    public var macOSVersion: String
    public var hardwareModel: String
    public var ownPID: Int32
    public var requestedSeconds: Double
    public init(createdAt: String, macOSVersion: String, hardwareModel: String, ownPID: Int32, requestedSeconds: Double) {
        self.createdAt = createdAt; self.macOSVersion = macOSVersion; self.hardwareModel = hardwareModel; self.ownPID = ownPID; self.requestedSeconds = requestedSeconds
    }
}

public enum RingProbeRunner {
    public static let maximumSeconds = 600.0
    /// The nominal cadence of the sampling timer. Elapsed time is NEVER taken from this: it is measured per sample.
    public static let samplePeriodSeconds = 1.0
    /// How long to wait for the producer to have committed enough callbacks for `SARingPrime` before reporting "never primed". Only decides when to give
    /// up waiting (a hang guard on the suspending clock), not a measurement; the 6a taps delivered a callback every ~10.7 ms.
    public static let primeDeadlineSeconds = 10.0
    /// The same for the first pull of both readers after the engine started. If the readers are not called by then, the run is INVALID.
    public static let firstPullDeadlineSeconds = 5.0
    public static let pollIntervalSeconds = 0.005

    /// A problem with the requested run time, or nil.
    public static func validate(seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return "the run time must be a positive number of seconds" }
        guard seconds <= maximumSeconds else { return "the run time is limited to \(Int(maximumSeconds)) s" }
        return nil
    }

    enum Name {
        static let createRing = "SARingCreate (control thread)"
        static let createIOProc = "AudioDeviceCreateIOProcID (SARingIOProc, client data = the ring)"
        static let prepareEngine = "AVAudioEngine: attach 2 source nodes (mono Float32), connect to the main mixer, output volume forced to 0"
        static let prime = "SARingPrime"
        static let startEngine = "AVAudioEngine startAndReturnError"
        static let gainRefusal = "output gain read-back"
        static let ownPIDAfter = "AudioObjectGetPropertyData(system, kAudioHardwarePropertyTranslatePIDToProcessObject) after the engine started"
    }

    /// Runs the probe through `backend`. Always tears down what it created, in the protocol's order, on every path.
    public static func run(backend: RingProbeBackend, ticker: RingProbeTicker, environment: RingProbeEnvironment, clock: TapProbeClock,
                           settleLimitSeconds: Double = 2.0, pollIntervalSeconds: Double = RingProbeRunner.pollIntervalSeconds,
                           windowSeconds: Double = RingProbeAnalyzer.defaultWindowSeconds, recovery: RingProbeRecovery? = nil) -> RingProbeReport {
        var calls: [TapProbeCall] = []
        var notes: [String] = []
        var lists = TapProbeLists(settlePolls: 0, settleSeconds: nil)
        var outcome = "ok"
        var stoppedBy = "never started"
        var format: TapFormat?
        var gain = RingGainRecord()
        var timings = RingTimings()
        var samples: [RingProbeSample] = []
        var firstRaw: RingProbeRawSample?
        var engineFacts: RingEngineFacts?
        var ownAfter: UInt32?
        var invalidReason: String?
        var interrupted = false

        func log(_ name: String, _ status: Int32, _ note: String? = nil) { calls.append(TapProbeCall(name: name, status: status, note: note)) }
        func failed(_ name: String) { if outcome == "ok" { outcome = "failed at \(name)" } }
        var lastEpochRaw: RingProbeRawSample?
        /// `act`: a timer tick (the recovery may stop, re-prime and restart the engine after this sample); false for the first and the closing samples.
        func takeSample(act: Bool = false) -> Bool {
            guard let epochRaw = backend.snapshot(), epochRaw.readers.count == 2 else { return false }
            lastEpochRaw = epochRaw
            let raw = recovery?.cumulative(epochRaw) ?? epochRaw     // recovery mode: counters made cumulative across the re-primes
            if firstRaw == nil { firstRaw = raw }
            samples.append(RingProbeSample.make(raw: raw, index: samples.count, first: firstRaw!, previous: samples.last, ticksPerSecond: backend.hostTicksPerSecond))
            if act, let recovery { recovery.tick(raw: epochRaw, clock: clock) }
            return true
        }

        // 0. Lists and the output device's numbers before anything exists.
        let devsBefore = backend.listDevices(); log(TapProbeRunner.Name.devicesList, devsBefore.status, "before")
        let tapsBefore = backend.listTaps(); log(TapProbeRunner.Name.tapsList, tapsBefore.status, "before")
        lists.devicesBefore = devsBefore.status == 0 ? devsBefore.ids.count : nil
        lists.tapsBefore = tapsBefore.status == 0 ? tapsBefore.ids.count : nil
        let outputFacts = backend.outputDeviceFacts()

        // 1. Our own process object, to exclude ourselves.
        let own = backend.translateOwnPID()
        log(TapProbeRunner.Name.translatePID, own.status, own.object == 0 ? "kAudioObjectUnknown: this process is not (yet) an audio client" : "object \(own.object)")
        let excluded: [UInt32] = own.status == 0 && own.object != 0 ? [own.object] : []
        if excluded.isEmpty { notes.append("This process had no audio process object, so nothing was excluded from the tap. The probe's own output is digital silence (gain 0), so it cannot feed back either way.") }

        var tapID: UInt32?, aggregateID: UInt32?, ringCreated = false, ioProcCreated = false, started = false, enginePrepared = false

        // 2-9. Build the chain, prime, start the engine, sample; stop at the first failure.
        build: do {
            if let refusal = backend.preflight() {
                outcome = "refused: \(refusal)"
                notes.append("Refused before creating anything: \(refusal)")
                break build
            }
            let tap = backend.createTap(excludingProcessObjects: excluded)
            log(TapProbeRunner.Name.createTap, tap.status, tap.status == 0 ? "tap object \(tap.tap)" : nil)
            guard tap.status == 0, tap.tap != 0 else { failed(TapProbeRunner.Name.createTap); break build }
            tapID = tap.tap

            let uid = backend.readTapUID(tap.tap); log(TapProbeRunner.Name.tapUID, uid.status)
            guard uid.status == 0, let tapUID = uid.uid else { failed(TapProbeRunner.Name.tapUID); break build }

            let fmt = backend.readTapFormat(tap.tap); log(TapProbeRunner.Name.tapFormat, fmt.status)
            guard fmt.status == 0, let f = fmt.format else { failed(TapProbeRunner.Name.tapFormat); break build }
            format = f
            // The ring accepts exactly one interleaved two-channel Float32 buffer and counts anything else as a refused commit; running against any other
            // format would only produce an empty series, so refuse it with its real cause.
            guard f.isFloat32, f.isInterleaved, f.channelsPerFrame == 2, f.sampleRate > 0, f.sampleRate.isFinite else {
                failed("tap format: the ring needs interleaved Float32 stereo (got \(f.sampleFormatDescription), \(f.channelsPerFrame) ch, \(f.sampleRate) Hz)")
                break build
            }

            ringCreated = backend.createRing()
            log(Name.createRing, ringCreated ? 0 : -108, ringCreated ? nil : "memFullErr")
            guard ringCreated else { failed(Name.createRing); break build }

            let agg = backend.createAggregate(tapUID: tapUID)
            log(TapProbeRunner.Name.createAggregate, agg.status, agg.status == 0 ? "device \(agg.device)" : nil)
            guard agg.status == 0, agg.device != 0 else { failed(TapProbeRunner.Name.createAggregate); break build }
            aggregateID = agg.device

            let proc = backend.createIOProc(on: agg.device); log(Name.createIOProc, proc)
            guard proc == 0 else { failed(Name.createIOProc); break build }
            ioProcCreated = true

            let st = backend.start(agg.device)
            log(TapProbeRunner.Name.start, st, st == 0 ? nil : "the first start of a tap can be refused until the system-audio permission is granted")
            guard st == 0 else { failed(TapProbeRunner.Name.start); break build }
            started = true

            // The engine graph is built (and its output volume forced to 0) while the producer already runs; the engine is NOT started yet.
            let prep = backend.prepareEngine(tapFormat: f)
            log(Name.prepareEngine, prep.ok ? 0 : -1, prep.detail)
            guard prep.ok else { failed(Name.prepareEngine); break build }
            enginePrepared = true
            engineFacts = backend.engineFacts()

            // THE GAIN GUARD: read the volume back from the engine; anything but exactly 0 refuses the run before the engine starts.
            gain.readBackBeforeStart = backend.engineOutputGain()
            guard gain.readBackBeforeStart == 0 else {
                outcome = "refused: output gain read back as \(gain.readBackBeforeStart.map { String($0) } ?? "unreadable"), not 0"
                notes.append("The engine was NOT started: the output gain could not be confirmed as 0.")
                log(Name.gainRefusal, -1, "read back \(gain.readBackBeforeStart.map { String($0) } ?? "nil"), required 0")
                break build
            }

            // Prime (never waits: poll until it succeeds, with a hang guard on the suspending clock), then the engine start. Recovery mode does both through the
            // re-prime controller's states (the same path a re-prime takes); the plain modes keep their own loop, unchanged.
            var startAt = clock.now()
            if let recovery {
                let r = recovery.performStart(clock: clock)
                timings.primeAttempts = r.primeAttempts
                timings.primeWaitSeconds = r.primeWaitSeconds
                log(Name.prime, r.primed ? 0 : -1, r.primed ? "after \(r.primeAttempts) attempt(s), through the re-prime controller" : "never succeeded: \(r.startDetail ?? "-")")
                guard r.primed else {
                    outcome = "never primed"
                    notes.append("SARingPrime never succeeded (recovery mode, same states as a re-prime): \(r.startDetail ?? "fewer tap callbacks than the prime depth"). The engine was not started.")
                    break build
                }
                log(Name.startEngine, r.started ? 0 : -1, r.startDetail)
                guard r.started else { failed(Name.startEngine); break build }
                startAt = r.engineStartedAtSeconds
            } else {
                let primeStart = clock.now()
                var primed = false
                while true {
                    timings.primeAttempts += 1
                    if backend.prime() { primed = true; break }
                    if clock.now() - primeStart >= primeDeadlineSeconds { break }
                    clock.sleep(pollIntervalSeconds)
                }
                timings.primeWaitSeconds = clock.now() - primeStart
                log(Name.prime, primed ? 0 : -1, primed ? "after \(timings.primeAttempts) attempt(s)" : "never succeeded within \(Int(primeDeadlineSeconds)) s")
                guard primed else {
                    outcome = "never primed"
                    notes.append("SARingPrime never succeeded: fewer tap callbacks than the prime depth were committed within \(Int(primeDeadlineSeconds)) s. The engine was not started.")
                    break build
                }

                // Engine start, then wait (completion-based) until BOTH readers have been called at least once.
                startAt = clock.now()
                let es = backend.startEngine()
                log(Name.startEngine, es.ok ? 0 : -1, es.detail)
                guard es.ok else { failed(Name.startEngine); break build }
            }
            gain.readBackAfterStart = backend.engineOutputGain()
            guard gain.readBackAfterStart == 0 else {
                failed("output gain read back as \(gain.readBackAfterStart.map { String($0) } ?? "unreadable") after the engine started")
                break build
            }
            let after = backend.translateOwnPID()
            log(Name.ownPIDAfter, after.status, after.object == 0 ? "kAudioObjectUnknown" : "object \(after.object)")
            ownAfter = after.status == 0 && after.object != 0 ? after.object : nil

            var pulled = false
            while true {
                if let raw = backend.snapshot(), raw.readers.count == 2, raw.readers[0].calls > 0, raw.readers[1].calls > 0 {
                    pulled = true
                    timings.fillAtFirstPull = raw.readers.map(\.fill)
                    break
                }
                if clock.now() - startAt >= firstPullDeadlineSeconds { break }
                clock.sleep(pollIntervalSeconds)
            }
            timings.engineStartToFirstPullSeconds = clock.now() - startAt
            guard pulled else {
                stoppedBy = "no pull"
                invalidReason = "a reader was never called within \(Int(firstPullDeadlineSeconds)) s of the engine start (calls stayed 0): either the engine does not pull source nodes at output gain 0, or something else is wrong"
                break build
            }

            // 8. Sample once per timer tick; elapsed time is measured per sample from the host ticks.
            ticker.start(periodSeconds: samplePeriodSeconds)
            guard takeSample() else { failed("snapshot"); break build }
            var reason = "timeout"
            sampling: while true {
                let wake = ticker.wait()
                if wake == .signal { _ = takeSample(); reason = "signal"; break sampling }
                if backend.configurationChangeCount() > 0 {
                    _ = takeSample()
                    reason = "configurationChange"; interrupted = true
                    break sampling
                }
                if wake == .tick {
                    guard takeSample(act: true) else { failed("snapshot"); break sampling }
                    if let why = recovery?.gaveUp { failed("recovery: \(why)"); reason = "recovery gave up"; break sampling }
                    if samples.last!.elapsedSeconds >= environment.requestedSeconds { break sampling }
                }
            }
            stoppedBy = reason
            gain.readBackAtEnd = backend.engineOutputGain()

            // Lists while everything still exists and runs.
            let devsDuring = backend.listDevices(); log(TapProbeRunner.Name.devicesList, devsDuring.status, "while running")
            let tapsDuring = backend.listTaps(); log(TapProbeRunner.Name.tapsList, tapsDuring.status, "while running")
            if devsDuring.status == 0 { lists.devicesDuring = devsDuring.ids.count; lists.aggregateListedDuring = devsDuring.ids.contains(agg.device) }
            if tapsDuring.status == 0 { lists.tapsDuring = tapsDuring.ids.count; lists.tapListedDuring = tapsDuring.ids.contains(tap.tap) }
        }

        // 10. Teardown, always, best effort (a failed destroy does not skip the next). The ORDER is the protocol (docs/ARCHITECTURE.md, "Step 6b-2"):
        // sampling timer off, engine stop, source nodes detached, IO stopped, IOProc destroyed, aggregate destroyed, tap destroyed, then the ring's fate.
        var order: [String] = []
        var destroyStatuses: [Int32] = []
        ticker.stop(); order.append("sampling timer off")
        if enginePrepared {
            backend.stopEngine(); order.append("engine stop")
            backend.detachSourceNodes(); order.append("source nodes detached")
        }
        if started, let a = aggregateID { let s = backend.stop(a); log(TapProbeRunner.Name.stop, s); destroyStatuses.append(s); order.append("IO stop") }
        if ioProcCreated, let a = aggregateID { let s = backend.destroyIOProc(on: a); log(TapProbeRunner.Name.destroyIOProc, s); destroyStatuses.append(s); order.append("IOProc destroyed") }
        if let a = aggregateID { let s = backend.destroyAggregate(a); log(TapProbeRunner.Name.destroyAggregate, s, "asynchronous according to AudioHardware.h"); destroyStatuses.append(s); order.append("aggregate destroyed") }
        if let t = tapID { let s = backend.destroyTap(t); log(TapProbeRunner.Name.destroyTap, s); destroyStatuses.append(s); order.append("tap destroyed") }
        var disposition: RingDisposition?
        if ringCreated {
            let d = backend.finishRing(); disposition = d
            order.append(d.freed ? "ring freed" : "ring retained")
        }

        // 11. The destroy calls are asynchronous: read the lists until neither object is listed, within a bound (as in Step 6a).
        var verified = false
        let created = aggregateID != nil || tapID != nil
        let pollStart = clock.now()
        var lastDevStatus: Int32 = 0, lastTapStatus: Int32 = 0
        while true {
            let devs = backend.listDevices(), taps = backend.listTaps()
            lists.settlePolls += 1
            lastDevStatus = devs.status; lastTapStatus = taps.status
            let devOK = devs.status == 0, tapOK = taps.status == 0
            if devOK { lists.devicesAfter = devs.ids.count; lists.aggregateListedAfter = aggregateID.map { devs.ids.contains($0) } ?? false }
            if tapOK { lists.tapsAfter = taps.ids.count; lists.tapListedAfter = tapID.map { taps.ids.contains($0) } ?? false }
            let gone = devOK && tapOK && lists.aggregateListedAfter == false && lists.tapListedAfter == false
            if gone { lists.settleSeconds = clock.now() - pollStart; verified = true; break }
            if !created || clock.now() - pollStart >= settleLimitSeconds { break }
            clock.sleep(pollIntervalSeconds)
        }
        log(TapProbeRunner.Name.devicesList, lastDevStatus, "after teardown, last of \(lists.settlePolls) read(s)")
        log(TapProbeRunner.Name.tapsList, lastTapStatus, "after teardown, last of \(lists.settlePolls) read(s)")
        let teardownClean = verified && destroyStatuses.allSatisfy { $0 == 0 }
        if !teardownClean {
            if !verified { notes.append("Teardown could NOT be verified through the device and tap lists within \(String(format: "%.1f", settleLimitSeconds)) s.") }
            if destroyStatuses.contains(where: { $0 != 0 }) { notes.append("At least one stop/destroy call returned a non-zero status (see the call table).") }
        }

        // 12. Statistics, validity, outcome.
        let configChanges = backend.configurationChangeCount()
        var summary: RingProbeSummary?
        if let f = format, !samples.isEmpty { summary = RingProbeAnalyzer.summarize(samples: samples, tapRate: f.sampleRate, windowSeconds: windowSeconds) }
        var flags = summary?.flags ?? []
        if let g = gain.readBackAtEnd, g != 0 { flags.append("output gain read back as \(g) at the end of the run, not 0") }
        if configChanges > 0 { flags.append("the engine posted \(configChanges) configuration-change notification(s)") }
        if outcome == "ok", invalidReason == nil, let s = summary, s.readers.contains(where: { $0.finalCounters.calls == 0 }) {
            invalidReason = "a reader made no call during the whole series (calls stayed 0)"
        }
        if outcome == "ok" {
            if let why = invalidReason { outcome = "invalid: \(why)" }
            else if interrupted { outcome = "interrupted" }
        }
        if interrupted { notes.append("The engine posted AVAudioEngineConfigurationChange (an output route or rate change; the header says the engine then stops itself). The run was stopped and NOT restarted; the series ends there.") }
        if let s = summary {
            for r in s.readers {
                let c = r.finalCounters
                if c.underrunBlocks > 0 {
                    notes.append("\(r.name): \(c.underrunBlocks) underrun block(s), \(c.silentFrames) silent frames in total. EXPECTED in this count-only spike: after an underrun the reader's cursor is ahead of the producer (fill \(r.fillEnd.map(String.init) ?? "-") at the end) and it stays starved at equal rates; the fill slope is still the rate difference, because the cursor advances by frameCount on every call.")
                }
                if c.overrunBlocks > 0 { notes.append("\(r.name): \(c.overrunBlocks) overrun block(s): the reader was lapped (its fill exceeded the serve window); with no cursor jump it stays lapped until the producer slows.") }
                if c.tornBlocks > 0 || c.oversizeBlocks > 0 || c.badBufferBlocks > 0 { notes.append("\(r.name): torn \(c.tornBlocks), oversize \(c.oversizeBlocks), bad buffer \(c.badBufferBlocks).") }
                if let share = r.validTimestampShare, share < 1 { notes.append("\(r.name): only \(String(format: "%.4f", share)) of the calls had a valid sample time, so the phase check was replaced by the weaker rule on the rest.") }
            }
            if s.rejectedCommits > 0 || s.rejectFlags != 0 { notes.append("The producer refused \(s.rejectedCommits) tap callback(s) (reject flags \(s.rejectFlags)): see SA_RING_REJECT_* in CSystemAudioRing.h; nothing was written for those callbacks.") }
            if let fill = timings.fillAtFirstPull, let f0 = fill.max(), Int64(backend.ringConstants.capacityFrames) - Int64(backend.ringConstants.maxCommitFrames) < f0 {
                notes.append("At the first pull the fill (\(f0) frames) already exceeded the serve window: the engine took longer to start than the ring's slack, so the first blocks were overruns.")
            }
        }

        var report = RingProbeReport(
            createdAt: environment.createdAt, source: backend.source, macOSVersion: environment.macOSVersion, hardwareModel: environment.hardwareModel,
            composition: backend.composition, ownPID: environment.ownPID, ownProcessObjectBefore: own.status == 0 && own.object != 0 ? own.object : nil,
            ownProcessObjectAfterEngineStart: ownAfter, excludedProcessObjects: excluded, requestedSeconds: environment.requestedSeconds,
            elapsedSeconds: summary?.spanSeconds ?? 0, stoppedBy: stoppedBy, outcome: outcome, flags: flags, tapFormat: format,
            hostTicksPerSecond: backend.hostTicksPerSecond, constants: ringCreated ? backend.ringConstants : nil, outputGain: gain, timings: timings,
            outputDevice: outputFacts, engine: engineFacts, configurationChanges: configChanges, calls: calls, lists: lists, teardownOrder: order,
            teardownClean: teardownClean, ring: disposition, summary: summary, samples: samples, injectedFaults: backend.injectedFaults, notes: notes)
        if let recovery {
            report.kind = "ring probe (Step 6b-2, recovery mode of Step 6b-3a-2)"
            report.recovery = recovery.finish(raw: lastEpochRaw)
            if let n = report.recovery?.rePrimesPerformed, n > 0 {
                report.notes.append("RECOVERY MODE: the engine was stopped and restarted \(n) time(s) by the re-prime controller. The reader counters in sections 2 to 4 are made cumulative across the re-primes (the ring zeroes them at each prime), but the FILL series jumps at every re-prime by design: its slope over the whole run is NOT a drift measurement here. Per-re-prime numbers are in section 8.")
            }
        }
        return report
    }
}
