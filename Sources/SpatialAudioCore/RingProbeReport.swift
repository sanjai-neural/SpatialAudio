import Foundation

// Step 6b-2: the report of `--ring-probe`. Numbers and short constant strings only: no device name, no UID, no path (the 6a 600 s report carried a
// headphone name; this one cannot, because the facts type has no name field and the runner copies none).

public struct RingGainRecord: Codable, Equatable, Sendable {
    /// What the code sets before the engine starts. A constant: the mode has no option that changes it.
    public var setTo: Double
    /// The main mixer's output volume read back BEFORE the engine start (the run is refused unless this is exactly 0).
    public var readBackBeforeStart: Double?
    /// ... right after the engine started (a non-zero value stops the run).
    public var readBackAfterStart: Double?
    /// ... at the end of the run, before teardown (recorded; a non-zero value is flagged).
    public var readBackAtEnd: Double?
    public init(setTo: Double = 0, readBackBeforeStart: Double? = nil, readBackAfterStart: Double? = nil, readBackAtEnd: Double? = nil) {
        self.setTo = setTo; self.readBackBeforeStart = readBackBeforeStart; self.readBackAfterStart = readBackAfterStart; self.readBackAtEnd = readBackAtEnd
    }
}

public struct RingTimings: Codable, Equatable, Sendable {
    /// Priming attempts (each is one `SARingPrime`; it never waits, so the runner retries) and the measured wait until one succeeded.
    public var primeAttempts: Int = 0
    public var primeWaitSeconds: Double?
    /// Measured: `startAndReturnError` plus the wait until BOTH readers had been called at least once.
    public var engineStartToFirstPullSeconds: Double?
    /// Each reader's fill (frames) in the snapshot that first showed both readers called. Prime depth plus whatever the producer wrote while the engine started.
    public var fillAtFirstPull: [Int64]?
    public init() {}
}

public struct RingProbeReport: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var kind = "ring probe (Step 6b-2)"
    public var createdAt: String
    /// "coreAudioTap" for the real run, "simulated" for the test source (a SIMULATED report decides nothing).
    public var source: String
    public var macOSVersion: String
    public var hardwareModel: String
    public var composition: String
    public var muteBehavior: String
    public var privateTap: Bool
    public var privateAggregate: Bool
    public var ownPID: Int32
    public var ownProcessObjectBefore: UInt32?
    /// Read again after the engine started (control: is it still the same object?).
    public var ownProcessObjectAfterEngineStart: UInt32?
    public var excludedProcessObjects: [UInt32]
    public var requestedSeconds: Double
    /// Measured host seconds from the first to the last sample.
    public var elapsedSeconds: Double
    /// "timeout", "signal", "configurationChange", "no pull" (the readers were never called) or "never started".
    public var stoppedBy: String
    /// "ok", "interrupted", "invalid: <why>", "never primed", "failed at <step>" or "refused: <why>".
    public var outcome: String
    public var flags: [String]
    public var tapFormat: TapFormat?
    public var hostTicksPerSecond: Double
    public var constants: RingProbeConstants?
    public var outputGain: RingGainRecord
    public var timings: RingTimings
    public var outputDevice: RingOutputFacts?
    public var engine: RingEngineFacts?
    public var configurationChanges: Int
    public var calls: [TapProbeCall]
    public var lists: TapProbeLists
    /// The teardown steps in the order they actually ran.
    public var teardownOrder: [String]
    public var teardownClean: Bool
    public var ring: RingDisposition?
    public var summary: RingProbeSummary?
    public var samples: [RingProbeSample]
    /// Simulated runs only: what was injected, so the report cannot be mistaken for a hardware result.
    public var injectedFaults: String?
    public var notes: [String]
    public var assumptions: [String]

    public var isSimulated: Bool { source == "simulated" }

    public init(createdAt: String, source: String, macOSVersion: String, hardwareModel: String, composition: String, ownPID: Int32,
                ownProcessObjectBefore: UInt32?, ownProcessObjectAfterEngineStart: UInt32?, excludedProcessObjects: [UInt32], requestedSeconds: Double,
                elapsedSeconds: Double, stoppedBy: String, outcome: String, flags: [String], tapFormat: TapFormat?, hostTicksPerSecond: Double,
                constants: RingProbeConstants?, outputGain: RingGainRecord, timings: RingTimings, outputDevice: RingOutputFacts?, engine: RingEngineFacts?,
                configurationChanges: Int, calls: [TapProbeCall], lists: TapProbeLists, teardownOrder: [String], teardownClean: Bool, ring: RingDisposition?,
                summary: RingProbeSummary?, samples: [RingProbeSample], injectedFaults: String?, notes: [String]) {
        self.createdAt = createdAt; self.source = source; self.macOSVersion = macOSVersion; self.hardwareModel = hardwareModel; self.composition = composition
        muteBehavior = "unmuted"; privateTap = true; privateAggregate = true
        self.ownPID = ownPID; self.ownProcessObjectBefore = ownProcessObjectBefore; self.ownProcessObjectAfterEngineStart = ownProcessObjectAfterEngineStart
        self.excludedProcessObjects = excludedProcessObjects; self.requestedSeconds = requestedSeconds; self.elapsedSeconds = elapsedSeconds
        self.stoppedBy = stoppedBy; self.outcome = outcome; self.flags = flags; self.tapFormat = tapFormat; self.hostTicksPerSecond = hostTicksPerSecond
        self.constants = constants; self.outputGain = outputGain; self.timings = timings; self.outputDevice = outputDevice; self.engine = engine
        self.configurationChanges = configurationChanges; self.calls = calls; self.lists = lists; self.teardownOrder = teardownOrder
        self.teardownClean = teardownClean; self.ring = ring; self.summary = summary; self.samples = samples; self.injectedFaults = injectedFaults
        self.notes = notes; self.assumptions = RingProbeReport.standardAssumptions
    }

    /// Printed in every report. What this run is, and what it is not.
    public static let standardAssumptions = [
        "Measurement only: the engine's main mixer output volume is 0 (set in code, read back before the engine starts; the run is refused otherwise, and the mode has no option that changes it). Nothing is audible from this probe, nothing is stored, and the tap is unmuted: the original audio plays as usual.",
        "COUNT-ONLY ring (Step 6b-1): a reader advances its cursor by exactly the frameCount it was asked for on EVERY call, served or not. After an underrun a reader is therefore AHEAD of the producer (negative fill) and, at equal producer and reader rate, STAYS starved. Starvation after an underrun is EXPECTED in this spike: no re-prime and no cursor jump exist yet.",
        "frameCount per call is observable only as a mean over each one-second interval (the ring keeps the sum of frame counts and the number of calls, not each call's frame count). A constant mean does not prove that every call asked for the same number of frames.",
        "Elapsed time is MEASURED per sample from the host clock (mach host ticks read on the control thread), never assumed from the timer's nominal one second. The snapshot is not an atomic cut: counters of different readers and the producer may be from slightly different instants, so fill has a resolution of about one commit or one call.",
        "The fill slope is the least-squares slope of fill against measured time. The uncertainty is the SPREAD of the per-window (one minute) slopes, not a formula standard error: in Step 6a the printed standard error was about four times too small because the jitter is not independent. A run shorter than two minutes has at most one complete window and no spread.",
        "The tap's callbacks and the engine's pulls are both compared with the HOST clock here. Nothing in this report says anything about sound, latency, CPU load, or whether the product graph (HRTF, environment node) behaves the same; the graph is two source nodes into the main mixer.",
        "The two source-node render blocks are the non-realtime-marked kind (`initWithFormat:renderBlock:`, macOS 10.15+); the header calls the realtime-safe initializer preferred for a real-time engine, but that one is macOS 27+ and not callable from Swift. Whether this matters on this Mac is not measured.",
    ]

    public static func fileStem(date: Date, timeZone: TimeZone = .current, simulated: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "ringprobe-\(f.string(from: date))" + (simulated ? "-SIMULATED" : "")
    }

    public func jsonData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> RingProbeReport { try JSONDecoder().decode(RingProbeReport.self, from: data) }
}

// MARK: - Markdown

extension RingProbeReport {
    public func markdown() -> String {
        func f(_ v: Double?, _ digits: Int = 3) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "-" }
        func i(_ v: Int64?) -> String { v.map(String.init) ?? "-" }
        var out: [String] = []
        out.append("# Ring probe report (Step 6b-2)\(isSimulated ? " - SIMULATED SOURCE" : "")")
        if isSimulated {
            out.append("")
            out.append("**SIMULATED: a test thread stands in for the tap and a manual-rendering engine for the device. Fabricated data: it decides nothing about this Mac.**")
            if let faults = injectedFaults { out.append("Injected: \(faults)") }
        }
        out.append("")
        out.append("- Created: \(createdAt)   macOS: \(macOSVersion)   Model: \(hardwareModel)")
        out.append("- Outcome: **\(outcome)**   stopped by: \(stoppedBy)   requested: \(f(requestedSeconds, 1)) s   measured span: \(f(elapsedSeconds, 3)) s")
        out.append("- Flags: \(flags.isEmpty ? "none" : flags.joined(separator: "; "))")
        out.append("- Output gain: set to \(f(outputGain.setTo, 1)), read back before start \(f(outputGain.readBackBeforeStart)), after start \(f(outputGain.readBackAfterStart)), at end \(f(outputGain.readBackAtEnd))")
        out.append("- Configuration changes (engine): \(configurationChanges)   Teardown clean: \(teardownClean ? "YES" : "NO")")
        if let c = constants { out.append("- Ring constants (GUESSES, not tuned): capacity N = \(c.capacityFrames) frames per channel, prime depth T = \(c.primeCallbacks) callbacks") }
        if let t = tapFormat { out.append("- Tap format: \(t.sampleFormatDescription), \(t.channelsPerFrame) ch, \(f(t.sampleRate, 1)) Hz") }
        out.append("")
        out.append("## 1. Setup")
        out.append("- Composition: \(composition)")
        out.append("- Own audio process object before the tap / after the engine started: \(ownProcessObjectBefore.map(String.init) ?? "none") / \(ownProcessObjectAfterEngineStart.map(String.init) ?? "none"); excluded: \(excludedProcessObjects.map(String.init).joined(separator: ", "))")
        out.append("- Prime: \(timings.primeAttempts) attempt(s), waited \(f(timings.primeWaitSeconds)) s")
        out.append("- Engine start to both readers called: \(f(timings.engineStartToFirstPullSeconds)) s; fill at the first pull (L, R): \(timings.fillAtFirstPull.map { $0.map(String.init).joined(separator: ", ") } ?? "-") frames")
        if let e = engine { out.append("- Engine: \(e.realTime ? "real-time, rendering to the default output device" : "manual rendering (no device)"); source nodes mono Float32 at \(f(e.sourceSampleRate, 1)) Hz; main mixer output \(f(e.mixerOutputSampleRate, 1)) Hz; output node \(f(e.outputNodeSampleRate, 1)) Hz, \(e.outputNodeChannels.map(String.init) ?? "-") ch") }
        if let d = outputDevice {
            out.append("- Output device (numbers only): transport \(d.transportType ?? "-") \(d.transportName ?? ""); nominal \(f(d.nominalSampleRate, 1)) Hz; actual \(f(d.actualSampleRate, 3)) Hz; buffer \(d.bufferFrameSize.map(String.init) ?? "-") frames; channels in/out \(d.inputChannels.map(String.init) ?? "-")/\(d.outputChannels.map(String.init) ?? "-")")
        }
        out.append("")
        out.append("## 2. Producer and readers against the host clock")
        if let s = summary {
            out.append("- Samples: \(s.sampleCount) over \(f(s.spanSeconds)) s measured host time. Tap declared rate: \(f(s.tapRate, 1)) Hz.")
            out.append("- Producer: \(f(s.producerFramesPerHostSecond, 2)) frames per host second (\(f(s.producerVsTapPPM, 1)) ppm against the declared rate; endpoint resolution about +/- \(f(s.producerEndpointResolutionPPM, 1)) ppm); \(f(s.commitsPerHostSecond, 2)) commits per host second, mean \(f(s.meanFramesPerCommit, 2)) frames per commit; rejected commits \(s.rejectedCommits), reject flags \(s.rejectFlags)")
            out.append("")
            out.append("| | frames requested / host s | vs tap rate (ppm) | calls / host s | mean frames per call | per-interval mean frames per call (min / median / max) | valid timestamps |")
            out.append("|---|---|---|---|---|---|---|")
            for r in s.readers {
                let m = r.framesPerCallIntervalMeans
                out.append("| \(r.name) | \(f(r.framesRequestedPerHostSecond, 2)) | \(f(r.framesRequestedVsTapPPM, 1)) | \(f(r.callsPerHostSecond, 2)) | \(f(r.meanFramesPerCall, 2)) | \(f(m?.min, 2)) / \(f(m?.median, 2)) / \(f(m?.max, 2)) | \(r.validTimestampShare.map { String(format: "%.4f", $0) } ?? "-") |")
            }
            out.append("")
            out.append("## 3. Fill (w - cursor, frames; negative = the reader is ahead of the producer)")
            out.append("| | start | end | min | max | slope (frames/s) | slope (ppm of tap rate) | per-minute slopes (ppm) | spread of per-minute slopes (ppm) |")
            out.append("|---|---|---|---|---|---|---|---|---|")
            for r in s.readers {
                out.append("| \(r.name) | \(i(r.fillStart)) | \(i(r.fillEnd)) | \(i(r.fillMin)) | \(i(r.fillMax)) | \(f(r.fillSlopeFramesPerSecond, 3)) | \(f(r.fillSlopePPM, 1)) | \(r.perWindowSlopesPPM.isEmpty ? "-" : r.perWindowSlopesPPM.map { String(format: "%.1f", $0) }.joined(separator: ", ")) | \(f(r.perWindowSpreadPPM, 1)) |")
            }
            out.append("")
            out.append("## 4. Per-reader counters (last snapshot)")
            out.append("| | calls | frames requested | served | underrun | overrun | torn | oversize | bad buffer | silent frames | phase valid | phase invalid | phase self-changes | phase mismatches | weak-rule violations |")
            out.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
            for r in s.readers {
                let c = r.finalCounters
                out.append("| \(r.name) | \(c.calls) | \(c.framesRequested) | \(c.servedBlocks) | \(c.underrunBlocks) | \(c.overrunBlocks) | \(c.tornBlocks) | \(c.oversizeBlocks) | \(c.badBufferBlocks) | \(c.silentFrames) | \(c.phaseValidCalls) | \(c.phaseInvalidCalls) | \(c.phaseSelfChanges) | \(c.phaseMismatches) | \(c.weakRuleViolations) |")
            }
            let l = s.lockstep
            out.append("")
            out.append("Lockstep: max |calls L - calls R| over the samples \(l.maxCallsDifference), max |frames requested L - R| \(l.maxFramesRequestedDifference) (the snapshot is not an atomic cut); phase self-changes L/R \(l.phaseSelfChanges.map(String.init).joined(separator: "/")), phase mismatches L/R \(l.phaseMismatches.map(String.init).joined(separator: "/")), weak-rule violations L/R \(l.weakRuleViolations.map(String.init).joined(separator: "/")).")
            let o = s.outputRate
            out.append("")
            out.append("## 5. Output device rate")
            out.append("- Nominal first/last: \(f(o.nominalFirst, 1)) / \(f(o.nominalLast, 1)) Hz; actual first/last/min/max: \(f(o.actualFirst, 3)) / \(f(o.actualLast, 3)) / \(f(o.actualMin, 3)) / \(f(o.actualMax, 3)) Hz; changes between samples: \(o.changesBetweenSamples); default-output-device changes: \(o.defaultOutputChangedAtSamples)")
        } else {
            out.append("- No series was recorded.")
        }
        out.append("")
        out.append("## 6. Core Audio / engine calls")
        out.append("| # | call | status | note |")
        out.append("|---|---|---|---|")
        for (n, c) in calls.enumerated() {
            let st = c.status == 0 ? "0" : "\(c.status)\(c.statusFourCC.map { " '\($0)'" } ?? "")\(c.statusName.map { " \($0)" } ?? "")"
            out.append("| \(n + 1) | \(c.name) | \(st) | \(c.note ?? "") |")
        }
        out.append("")
        out.append("Teardown order that ran: \(teardownOrder.isEmpty ? "-" : teardownOrder.joined(separator: " -> "))")
        if let r = ring { out.append("Ring: \(r.freed ? "freed" : "NOT freed"): \(r.reason)") }
        out.append("Lists (devices before/during/after, taps before/during/after): \(lists.devicesBefore.map(String.init) ?? "-")/\(lists.devicesDuring.map(String.init) ?? "-")/\(lists.devicesAfter.map(String.init) ?? "-"), \(lists.tapsBefore.map(String.init) ?? "-")/\(lists.tapsDuring.map(String.init) ?? "-")/\(lists.tapsAfter.map(String.init) ?? "-")")
        out.append("")
        out.append("## 7. Notes")
        for n in notes { out.append("- \(n)") }
        out.append("")
        out.append("## What this report does and does not show")
        for a in assumptions { out.append("- \(a)") }
        return out.joined(separator: "\n") + "\n"
    }
}
