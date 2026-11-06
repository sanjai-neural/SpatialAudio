import Foundation

// Step 6a: the order of operations of the probe, its error unwinding and its status log, behind a backend protocol so that
// every failure path can be tested without hardware. The real backend (Core Audio) and the simulated one live in SpatialAudioEngine.

public struct TapProbeCollected: Sendable {
    public var records: [TapProbeRecord]
    public var dropped: UInt64
    /// `AudioGetHostClockFrequency()` for the real backend; the simulated source says what it simulates.
    public var hostTicksPerSecond: Double

    public init(records: [TapProbeRecord], dropped: UInt64, hostTicksPerSecond: Double) {
        self.records = records; self.dropped = dropped; self.hostTicksPerSecond = hostTicksPerSecond
    }
}

/// What the probe needs from Core Audio (or from a stand-in). Every method that talks to the system returns the OSStatus; the
/// runner logs it. An object id of 0 is `kAudioObjectUnknown`.
public protocol TapProbeBackend: AnyObject {
    /// "coreAudioTap" or "simulated".
    var source: String { get }
    /// Human-readable description of the aggregate-device composition in use.
    var composition: String { get }

    /// A reason to refuse to run at all (nothing is created), or nil. Used for compositions that could open an input the
    /// person did not ask for. Not a Core Audio call, so it has no status.
    func preflight() -> String?

    func translateOwnPID() -> (object: UInt32, status: Int32)
    func createTap(excludingProcessObjects: [UInt32]) -> (tap: UInt32, status: Int32)
    func readTapUID(_ tap: UInt32) -> (uid: String?, status: Int32)
    func readTapFormat(_ tap: UInt32) -> (format: TapFormat?, status: Int32)
    /// Control thread: allocate the record buffer for `capacity` callbacks, laid out for `format`. False on failure.
    func prepareCapture(format: TapFormat, capacity: Int) -> Bool
    func createAggregate(tapUID: String) -> (device: UInt32, status: Int32)
    func createIOProc(on device: UInt32) -> Int32
    func start(_ device: UInt32) -> Int32
    func stop(_ device: UInt32) -> Int32
    func destroyIOProc(on device: UInt32) -> Int32
    func destroyAggregate(_ device: UInt32) -> Int32
    func destroyTap(_ tap: UInt32) -> Int32
    func listDevices() -> (ids: [UInt32], status: Int32)
    func listTaps() -> (ids: [UInt32], status: Int32)
    /// Read-only property reads of the default output device (Step 6a2). Called once, before anything is created; remembers the device for `sampleActualRates`.
    func outputDeviceFacts() -> TapDeviceFacts
    /// The same for the tap's aggregate device (input-scope latencies), read while it runs.
    func aggregateDeviceFacts(_ device: UInt32) -> TapDeviceFacts
    /// `ActualSampleRate` of the output device read earlier and of the aggregate device (nil = unreadable).
    func sampleActualRates(aggregate: UInt32?) -> (output: Double?, aggregate: Double?)
    /// Control thread, after stop: the records published so far.
    func collect() -> TapProbeCollected
}

public enum TapProbeStopReason: String, Sendable {
    case timeout, signal
}

public struct TapProbeEnvironment: Sendable {
    public var createdAt: String
    public var macOSVersion: String
    public var hardwareModel: String
    public var ownPID: Int32
    public var requestedSeconds: Double
    public init(createdAt: String, macOSVersion: String, hardwareModel: String, ownPID: Int32, requestedSeconds: Double) {
        self.createdAt = createdAt; self.macOSVersion = macOSVersion; self.hardwareModel = hardwareModel
        self.ownPID = ownPID; self.requestedSeconds = requestedSeconds
    }
}

/// Time source for the polling after teardown. The real one is a `SuspendingClock` (does not advance while the Mac sleeps);
/// tests pass a fake that advances only when told, so no verdict ever depends on wall-clock time.
public struct TapProbeClock: Sendable {
    public var now: @Sendable () -> Double
    public var sleep: @Sendable (Double) -> Void
    public init(now: @escaping @Sendable () -> Double, sleep: @escaping @Sendable (Double) -> Void) { self.now = now; self.sleep = sleep }
}

public enum TapProbeRunner {
    public static let maximumSeconds = 600.0
    /// The run waits in slices of this many seconds and samples the device rates after each (Step 6a2); the cadence windows have the same length.
    public static let windowSeconds = 10.0
    /// Upper bound used to size the record buffer: callbacks per second the probe is prepared to store.
    public static let assumedMaxCallbacksPerSecond = 1000.0

    public static func recordCapacity(forSeconds seconds: Double) -> Int {
        Int(min(max(seconds, 1), maximumSeconds) * assumedMaxCallbacksPerSecond) + 4096
    }

    // Names of the calls as they appear in the report.
    enum Name {
        static let devicesList = "AudioObjectGetPropertyData(system, kAudioHardwarePropertyDevices)"
        static let tapsList = "AudioObjectGetPropertyData(system, kAudioHardwarePropertyTapList)"
        static let translatePID = "AudioObjectGetPropertyData(system, kAudioHardwarePropertyTranslatePIDToProcessObject)"
        static let createTap = "AudioHardwareCreateProcessTap"
        static let tapUID = "AudioObjectGetPropertyData(tap, kAudioTapPropertyUID)"
        static let tapFormat = "AudioObjectGetPropertyData(tap, kAudioTapPropertyFormat)"
        static let allocate = "allocate record buffer (control thread)"
        static let createAggregate = "AudioHardwareCreateAggregateDevice"
        static let createIOProc = "AudioDeviceCreateIOProcID"
        static let start = "AudioDeviceStart"
        static let stop = "AudioDeviceStop"
        static let destroyIOProc = "AudioDeviceDestroyIOProcID"
        static let destroyAggregate = "AudioHardwareDestroyAggregateDevice"
        static let destroyTap = "AudioHardwareDestroyProcessTap"
    }

    /// Runs the probe through `backend`. Always tears down what it created, in reverse order, on every path.
    /// `waitForStop(seconds)` blocks until the run time is over or a stop was requested (a signal) and says which.
    public static func run(backend: TapProbeBackend, environment: TapProbeEnvironment, clock: TapProbeClock,
                           settleLimitSeconds: Double = 2.0, pollIntervalSeconds: Double = 0.01, windowSeconds: Double = TapProbeRunner.windowSeconds,
                           waitForStop: (Double) -> TapProbeStopReason) -> TapProbeReport {
        var calls: [TapProbeCall] = []
        var notes: [String] = []
        var lists = TapProbeLists(settlePolls: 0, settleSeconds: nil)
        var outcome = "ok"
        var stoppedBy = "never started"
        var elapsed = 0.0
        var format: TapFormat?
        var collected: TapProbeCollected?
        var rateSamples: [TapRateSample] = []
        var aggregateFacts: TapDeviceFacts?

        func log(_ name: String, _ status: Int32, _ note: String? = nil) { calls.append(TapProbeCall(name: name, status: status, note: note)) }
        func failed(_ name: String) { if outcome == "ok" { outcome = "failed at \(name)" } }

        // 0. Lists before anything exists.
        let devsBefore = backend.listDevices(); log(Name.devicesList, devsBefore.status, "before")
        let tapsBefore = backend.listTaps(); log(Name.tapsList, tapsBefore.status, "before")
        lists.devicesBefore = devsBefore.status == 0 ? devsBefore.ids.count : nil
        lists.tapsBefore = tapsBefore.status == 0 ? tapsBefore.ids.count : nil

        // 0b. Read-only facts about the default output device, before anything exists (property reads only).
        let outputFacts = backend.outputDeviceFacts()

        // 1. Our own process object, to exclude ourselves.
        let own = backend.translateOwnPID()
        log(Name.translatePID, own.status, own.object == 0 ? "kAudioObjectUnknown: this process is not (yet) an audio client" : "object \(own.object)")
        let excluded: [UInt32] = own.status == 0 && own.object != 0 ? [own.object] : []
        if excluded.isEmpty { notes.append("This process has no audio process object, so nothing could be excluded; it plays no audio during the probe, so it would not appear in the tap either way. Excluding ourselves matters once a renderer plays through this process (Step 6b).") }

        var tapID: UInt32?, aggregateID: UInt32?, ioProcCreated = false, started = false

        // 2-7. Build the capture chain; stop at the first failure.
        build: do {
            if let refusal = backend.preflight() {
                outcome = "refused: \(refusal)"
                notes.append("Refused before creating anything: \(refusal)")
                break build
            }
            let tap = backend.createTap(excludingProcessObjects: excluded)
            log(Name.createTap, tap.status, tap.status == 0 ? "tap object \(tap.tap)" : nil)
            guard tap.status == 0, tap.tap != 0 else { failed(Name.createTap); break build }
            tapID = tap.tap

            let uid = backend.readTapUID(tap.tap); log(Name.tapUID, uid.status)
            guard uid.status == 0, let tapUID = uid.uid else { failed(Name.tapUID); break build }

            let fmt = backend.readTapFormat(tap.tap); log(Name.tapFormat, fmt.status)
            guard fmt.status == 0, let f = fmt.format else { failed(Name.tapFormat); break build }
            format = f
            // The C callback divides by bytes-per-sample x channels, so a format without a whole-byte sample size (for example
            // 0 or 4 bits per channel) cannot be measured. Refuse it with its real cause instead of letting the allocation fail.
            guard f.bytesPerSample > 0 else {
                failed("tap format: no whole-byte sample size (bitsPerChannel \(f.bitsPerChannel))")
                notes.append("The tap reported \(f.bitsPerChannel) bits per channel, which gives no whole-byte sample size; the probe cannot measure such a format.")
                break build
            }

            let ok = backend.prepareCapture(format: f, capacity: recordCapacity(forSeconds: environment.requestedSeconds))
            log(Name.allocate, ok ? 0 : -108, ok ? nil : "memFullErr")
            guard ok else { failed(Name.allocate); break build }

            let agg = backend.createAggregate(tapUID: tapUID)
            log(Name.createAggregate, agg.status, agg.status == 0 ? "device \(agg.device)" : nil)
            guard agg.status == 0, agg.device != 0 else { failed(Name.createAggregate); break build }
            aggregateID = agg.device

            let proc = backend.createIOProc(on: agg.device); log(Name.createIOProc, proc)
            guard proc == 0 else { failed(Name.createIOProc); break build }
            ioProcCreated = true

            let st = backend.start(agg.device)
            log(Name.start, st, st == 0 ? nil : "the first start of a tap can be refused until the system-audio permission is granted")
            guard st == 0 else { failed(Name.start); break build }
            started = true

            // 8. Run, in slices; the device rates are read at the start and after every slice (a series, not one reading).
            let t0 = clock.now()
            func sampleRates() {
                let r = backend.sampleActualRates(aggregate: agg.device)
                rateSamples.append(TapRateSample(elapsedSeconds: clock.now() - t0, outputActualRate: r.output, aggregateActualRate: r.aggregate))
            }
            sampleRates()
            var remaining = environment.requestedSeconds
            var reason = TapProbeStopReason.timeout
            while remaining > 1e-9 {
                let slice = min(windowSeconds, remaining)
                let r = waitForStop(slice)
                remaining -= slice
                sampleRates()
                if r == .signal { reason = .signal; break }
            }
            elapsed = clock.now() - t0
            stoppedBy = reason.rawValue
            aggregateFacts = backend.aggregateDeviceFacts(agg.device)

            // 9. Lists while everything still exists and runs.
            let devsDuring = backend.listDevices(); log(Name.devicesList, devsDuring.status, "while running")
            let tapsDuring = backend.listTaps(); log(Name.tapsList, tapsDuring.status, "while running")
            if devsDuring.status == 0 { lists.devicesDuring = devsDuring.ids.count; lists.aggregateListedDuring = devsDuring.ids.contains(agg.device) }
            if tapsDuring.status == 0 { lists.tapsDuring = tapsDuring.ids.count; lists.tapListedDuring = tapsDuring.ids.contains(tap.tap) }
        }

        // 10. Teardown: always, reverse order, best effort (a failed destroy does not skip the next).
        var destroyStatuses: [Int32] = []
        if started, let a = aggregateID { let s = backend.stop(a); log(Name.stop, s); destroyStatuses.append(s) }
        if ioProcCreated, let a = aggregateID { let s = backend.destroyIOProc(on: a); log(Name.destroyIOProc, s); destroyStatuses.append(s) }
        if format != nil { collected = backend.collect() }
        if let a = aggregateID { let s = backend.destroyAggregate(a); log(Name.destroyAggregate, s, "asynchronous according to AudioHardware.h"); destroyStatuses.append(s) }
        if let t = tapID { let s = backend.destroyTap(t); log(Name.destroyTap, s); destroyStatuses.append(s) }

        // 11. The destroy calls are asynchronous: read the lists until neither object is listed, within a bound.
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
        log(Name.devicesList, lastDevStatus, "after teardown, last of \(lists.settlePolls) read(s)")
        log(Name.tapsList, lastTapStatus, "after teardown, last of \(lists.settlePolls) read(s)")
        let teardownClean = verified && destroyStatuses.allSatisfy { $0 == 0 }
        if !teardownClean {
            if !verified { notes.append("Teardown could NOT be verified through the device and tap lists within \(String(format: "%.1f", settleLimitSeconds)) s.") }
            if destroyStatuses.contains(where: { $0 != 0 }) { notes.append("At least one stop/destroy call returned a non-zero status (see the call table).") }
        }

        // 12. Statistics and observations.
        var stats: TapProbeStats?
        if let c = collected {
            stats = TapProbeAggregator.summarize(records: c.records, dropped: c.dropped, hostTicksPerSecond: c.hostTicksPerSecond,
                                                 declaredRate: format?.sampleRate, windowSeconds: windowSeconds)
        }
        if let s = stats {
            if started && s.callbackCount == 0 { notes.append("The device started but no callback ran.") }
            if s.callbackCount > 0 && !s.perSecond.isEmpty && s.silentSeconds == s.perSecond.count {
                notes.append("Every counted sample was exactly 0: SILENT. Possible reasons: nothing was playing; the audio was protected (DRM) content, which may be silent; or the permission was refused without an error code. Not worked around.")
            }
            if s.dropped > 0 { notes.append("\(s.dropped) callback(s) found the record buffer full; their measurements are missing.") }
            if !s.flagCounts.isEmpty { notes.append("Some callbacks carried measurement flags (see section 2); the levels exclude what the flags say was skipped.") }
            if let f = format, let implied = s.impliedFramesPerSecond, f.sampleRate > 0, abs(implied - f.sampleRate) / f.sampleRate > 0.05 {
                notes.append(String(format: "Implied frames per second (%.0f) differs from the tap's declared rate (%.0f) by more than 5%%.", implied, f.sampleRate))
            }
        }

        // Rate comparison: numbers side by side, no verdict.
        var comparison: TapRateComparison?
        if let f = format {
            let actuals = rateSamples.compactMap(\.outputActualRate)
            let mean = actuals.isEmpty ? nil : actuals.reduce(0, +) / Double(actuals.count)
            let implied = stats?.impliedFramesPerSecond
            comparison = TapRateComparison(
                tapDeclaredRate: f.sampleRate, outputNominalRate: outputFacts.nominalSampleRate,
                declaredRatesEqual: outputFacts.nominalSampleRate.map { $0 == f.sampleRate },
                tapImpliedFramesPerSecond: implied,
                tapImpliedVsDeclaredPPM: (implied != nil && f.sampleRate > 0) ? (implied! / f.sampleRate - 1) * 1e6 : nil,
                outputActualRateFirst: actuals.first, outputActualRateLast: actuals.last, outputActualRateMean: mean,
                tapImpliedVsOutputActualPPM: (implied != nil && (mean ?? 0) > 0) ? (implied! / mean! - 1) * 1e6 : nil)
            if comparison?.declaredRatesEqual == false {
                notes.append(String(format: "The tap's declared rate (%.1f Hz) differs from the output device's nominal rate (%.1f Hz): a rate conversion is needed somewhere.", f.sampleRate, outputFacts.nominalSampleRate ?? 0))
            }
        }
        let unreadable = outputFacts.failedReads + (aggregateFacts?.failedReads.map { "aggregate: " + $0 } ?? [])
        if !unreadable.isEmpty { notes.append("Some device property reads returned a non-zero status and are left empty (see section 4): \(unreadable.joined(separator: ", ")).") }

        return TapProbeReport(
            createdAt: environment.createdAt, source: backend.source, macOSVersion: environment.macOSVersion,
            hardwareModel: environment.hardwareModel, composition: backend.composition, muteBehavior: "unmuted",
            privateTap: true, privateAggregate: true, ownPID: environment.ownPID,
            ownProcessObjectID: own.status == 0 && own.object != 0 ? own.object : nil, excludedProcessObjects: excluded,
            requestedSeconds: environment.requestedSeconds, elapsedSeconds: elapsed, stoppedBy: stoppedBy, outcome: outcome,
            tapFormat: format, hostTicksPerSecond: collected?.hostTicksPerSecond ?? 0, calls: calls, stats: stats, lists: lists,
            teardownClean: teardownClean, notes: notes, assumptions: TapProbeReport.standardAssumptions,
            outputDevice: outputFacts, aggregateDevice: aggregateFacts, rateSamples: rateSamples, rateComparison: comparison)
    }
}
