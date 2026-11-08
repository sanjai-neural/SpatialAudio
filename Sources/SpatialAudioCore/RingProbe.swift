import Foundation

// Step 6b-2: the numbers of the ring probe (`--ring-probe`). Pure arithmetic and report types; nothing here touches Core Audio, AVFoundation or the
// ring itself (the engine layer copies the C snapshot into these plain structs). IMPLEMENTED-UNVERIFIED until Sanjai has run it on hardware.
//
// What the probe measures, and ONLY that: what the producer (the tap's IO callback) wrote into the ring, what the two readers (the two source
// nodes of a real-time engine at output gain 0) asked for, and where the fill (w - cursor) went, once per measured second. It says nothing about
// sound, latency, CPU or the product graph.

// MARK: - Plain-number mirrors of the ring's snapshot

/// One reader's counters, copied field by field from `SARingReaderStats`. `cursor` and `fill` are signed: negative fill = the reader is AHEAD of the producer.
public struct RingReaderCounters: Codable, Equatable, Sendable {
    public var calls: UInt64 = 0
    public var framesRequested: UInt64 = 0
    public var servedBlocks: UInt64 = 0
    public var servedFrames: UInt64 = 0
    public var underrunBlocks: UInt64 = 0
    public var overrunBlocks: UInt64 = 0
    public var tornBlocks: UInt64 = 0
    public var oversizeBlocks: UInt64 = 0
    public var badBufferBlocks: UInt64 = 0
    public var silentFrames: UInt64 = 0
    public var phaseValidCalls: UInt64 = 0
    public var phaseInvalidCalls: UInt64 = 0
    public var phaseSelfChanges: UInt64 = 0
    public var phaseMismatches: UInt64 = 0
    public var weakRuleViolations: UInt64 = 0
    public var cursor: Int64 = 0
    public var fill: Int64 = 0
    public init() {}
}

/// The producer's side of one snapshot.
public struct RingProducerCounters: Codable, Equatable, Sendable {
    public var w: Int64 = 0
    public var commits: UInt64 = 0
    public var rejectedCommits: UInt64 = 0
    public var rejectFlags: UInt32 = 0
    public var lastCommitFrames: UInt32 = 0
    public var capacity: UInt32 = 0
    public var maxCommit: UInt32 = 0
    public init() {}
}

/// One reading of the ring plus the clock and rate readings taken with it, made on the control thread by the backend.
public struct RingProbeRawSample: Equatable, Sendable {
    /// `AudioGetCurrentHostTime()` (mach host ticks) read just before the snapshot. Elapsed time is ALWAYS computed from this, never assumed.
    public var hostTicks: UInt64
    /// A clock that keeps counting while the Mac sleeps (`CLOCK_MONOTONIC_RAW`), seconds. Only differences are meaningful. nil if unavailable.
    public var continuousSeconds: Double?
    public var producer: RingProducerCounters
    /// Exactly two: [0] = left, [1] = right.
    public var readers: [RingReaderCounters]
    public var outputNominalRate: Double?
    public var outputActualRate: Double?
    /// The default output device is not the one the run started with (a device change, not a rate change).
    public var defaultOutputChanged: Bool

    public init(hostTicks: UInt64, continuousSeconds: Double? = nil, producer: RingProducerCounters, readers: [RingReaderCounters],
                outputNominalRate: Double? = nil, outputActualRate: Double? = nil, defaultOutputChanged: Bool = false) {
        self.hostTicks = hostTicks; self.continuousSeconds = continuousSeconds; self.producer = producer; self.readers = readers
        self.outputNominalRate = outputNominalRate; self.outputActualRate = outputActualRate; self.defaultOutputChanged = defaultOutputChanged
    }
}

/// One row of the report's series: a raw sample with its MEASURED elapsed time.
public struct RingProbeSample: Codable, Equatable, Sendable {
    public var index: Int
    public var hostTicks: UInt64
    /// Host seconds since sample 0, from the host ticks of THIS sample and the first one (`ticksPerSecond` of the backend). Never the nominal period.
    public var elapsedSeconds: Double
    /// Measured seconds since the previous sample (nil for sample 0).
    public var gapSeconds: Double?
    /// Elapsed on the clock that counts sleep (nil if unavailable).
    public var continuousElapsedSeconds: Double?
    public var producer: RingProducerCounters
    public var readers: [RingReaderCounters]
    public var outputNominalRate: Double?
    public var outputActualRate: Double?
    public var defaultOutputChanged: Bool

    public init(index: Int, hostTicks: UInt64, elapsedSeconds: Double, gapSeconds: Double?, continuousElapsedSeconds: Double?, producer: RingProducerCounters,
                readers: [RingReaderCounters], outputNominalRate: Double?, outputActualRate: Double?, defaultOutputChanged: Bool) {
        self.index = index; self.hostTicks = hostTicks; self.elapsedSeconds = elapsedSeconds; self.gapSeconds = gapSeconds
        self.continuousElapsedSeconds = continuousElapsedSeconds; self.producer = producer; self.readers = readers
        self.outputNominalRate = outputNominalRate; self.outputActualRate = outputActualRate; self.defaultOutputChanged = defaultOutputChanged
    }

    /// Builds the series row for `raw`. `first` is sample 0's raw reading, `previous` the row before this one.
    public static func make(raw: RingProbeRawSample, index: Int, first: RingProbeRawSample, previous: RingProbeSample?, ticksPerSecond: Double) -> RingProbeSample {
        let elapsed = ticksPerSecond > 0 && raw.hostTicks >= first.hostTicks ? Double(raw.hostTicks - first.hostTicks) / ticksPerSecond : 0
        let continuous: Double? = {
            guard let c = raw.continuousSeconds, let c0 = first.continuousSeconds else { return nil }
            return c - c0
        }()
        return RingProbeSample(index: index, hostTicks: raw.hostTicks, elapsedSeconds: elapsed, gapSeconds: previous.map { elapsed - $0.elapsedSeconds },
                               continuousElapsedSeconds: continuous, producer: raw.producer, readers: raw.readers, outputNominalRate: raw.outputNominalRate,
                               outputActualRate: raw.outputActualRate, defaultOutputChanged: raw.defaultOutputChanged)
    }
}

// MARK: - Facts about the setup (numbers and constant strings only: no device names, no UIDs, no paths)

public struct RingProbeConstants: Codable, Equatable, Sendable {
    /// N: frames per channel plane. A GUESS (named constant in CSystemAudioRing.h), not tuned in this step.
    public var capacityFrames: UInt32
    /// T: how many tap callbacks of data the readers start behind the producer. A GUESS, not tuned in this step.
    public var primeCallbacks: UInt32
    /// The most one producer commit may carry; also the in-flight margin, so the serve window is `capacityFrames - maxCommitFrames` (CSystemAudioRing.c).
    public var maxCommitFrames: UInt32 { capacityFrames / 2 }
    public init(capacityFrames: UInt32, primeCallbacks: UInt32) { self.capacityFrames = capacityFrames; self.primeCallbacks = primeCallbacks }
}

/// The default output device, as numbers: transport type, rates, buffer size and channel counts. No name and no UID, on purpose.
public struct RingOutputFacts: Codable, Equatable, Sendable {
    public var transportType: String?
    public var transportName: String?
    public var nominalSampleRate: Double?
    public var actualSampleRate: Double?
    public var bufferFrameSize: UInt32?
    public var outputChannels: Int?
    public var inputChannels: Int?
    /// OSStatus of each property read (a non-zero status leaves the value nil).
    public var statuses: [String: Int32]
    public init(transportType: String? = nil, transportName: String? = nil, nominalSampleRate: Double? = nil, actualSampleRate: Double? = nil,
                bufferFrameSize: UInt32? = nil, outputChannels: Int? = nil, inputChannels: Int? = nil, statuses: [String: Int32] = [:]) {
        self.transportType = transportType; self.transportName = transportName; self.nominalSampleRate = nominalSampleRate
        self.actualSampleRate = actualSampleRate; self.bufferFrameSize = bufferFrameSize; self.outputChannels = outputChannels
        self.inputChannels = inputChannels; self.statuses = statuses
    }
}

/// What the engine graph looked like once it was prepared (rates and channel counts only).
public struct RingEngineFacts: Codable, Equatable, Sendable {
    public var realTime: Bool
    /// The mono Float32 format of both source nodes.
    public var sourceSampleRate: Double
    public var sourceChannels: UInt32
    public var mixerOutputSampleRate: Double?
    public var outputNodeSampleRate: Double?
    public var outputNodeChannels: UInt32?
    public init(realTime: Bool, sourceSampleRate: Double, sourceChannels: UInt32, mixerOutputSampleRate: Double? = nil,
                outputNodeSampleRate: Double? = nil, outputNodeChannels: UInt32? = nil) {
        self.realTime = realTime; self.sourceSampleRate = sourceSampleRate; self.sourceChannels = sourceChannels
        self.mixerOutputSampleRate = mixerOutputSampleRate; self.outputNodeSampleRate = outputNodeSampleRate; self.outputNodeChannels = outputNodeChannels
    }
}

/// Whether the ring was freed, and why / why not.
public struct RingDisposition: Codable, Equatable, Sendable {
    public var freed: Bool
    public var reason: String
    public init(freed: Bool, reason: String) { self.freed = freed; self.reason = reason }
}

// MARK: - Summary

public struct RingReaderSummary: Codable, Equatable, Sendable {
    public var name: String
    /// `framesRequested` end minus start, over the measured host seconds between the first and last sample.
    public var framesRequestedPerHostSecond: Double?
    /// That rate against the tap's declared rate, parts per million.
    public var framesRequestedVsTapPPM: Double?
    public var callsPerHostSecond: Double?
    /// Total frames requested over total calls, over the whole series.
    public var meanFramesPerCall: Double?
    /// Per ONE-SECOND INTERVAL: frames requested divided by calls in the interval; min / median / max over the intervals. NOT the per-call distribution:
    /// the ring keeps the sum of the frame counts and the number of calls, not each call's frame count.
    public var framesPerCallIntervalMeans: MinMedianMax?
    public var fillStart: Int64?
    public var fillEnd: Int64?
    public var fillMin: Int64?
    public var fillMax: Int64?
    /// Least-squares slope of fill against measured elapsed seconds. Negative = the reader runs faster than the producer.
    public var fillSlopeFramesPerSecond: Double?
    /// The same, in parts per million of the tap's declared rate.
    public var fillSlopePPM: Double?
    /// One slope per COMPLETE window (default 60 s) of measured time, in frames per second and in ppm. The spread of these, not a formula standard
    /// error, is the honest uncertainty (6a: the printed standard error was about 4x too small).
    public var perWindowSlopesFramesPerSecond: [Double]
    public var perWindowSlopesPPM: [Double]
    /// Largest minus smallest per-window slope, ppm (nil with fewer than two complete windows).
    public var perWindowSpreadPPM: Double?
    /// The last snapshot's counters.
    public var finalCounters: RingReaderCounters
    /// phaseValidCalls / (valid + invalid), 0...1 (nil if the reader made no call).
    public var validTimestampShare: Double?
}

public struct RingLockstepSummary: Codable, Equatable, Sendable {
    /// Largest |calls(left) - calls(right)| over the samples. The snapshot is not an atomic cut, so 1 can appear even in lockstep.
    public var maxCallsDifference: UInt64
    public var maxFramesRequestedDifference: UInt64
    public var phaseSelfChanges: [UInt64]
    public var phaseMismatches: [UInt64]
    public var weakRuleViolations: [UInt64]
    public var validTimestampShare: [Double?]
}

public struct RingOutputRateSummary: Codable, Equatable, Sendable {
    public var nominalFirst: Double?
    public var nominalLast: Double?
    public var actualFirst: Double?
    public var actualLast: Double?
    public var actualMin: Double?
    public var actualMax: Double?
    /// Number of consecutive-sample pairs where the nominal rate differs at all, or the actual rate differs by more than `rateChangeRelativeThreshold`.
    public var changesBetweenSamples: Int
    public var defaultOutputChangedAtSamples: Int
}

public struct RingProbeSummary: Codable, Equatable, Sendable {
    public var tapRate: Double
    public var sampleCount: Int
    /// Measured host seconds from the first to the last sample.
    public var spanSeconds: Double
    public var producerFramesPerHostSecond: Double?
    public var producerVsTapPPM: Double?
    /// One commit at each end can be missing from or extra in an endpoint ratio: +/- (2 x frames per commit) / (tap rate x span), ppm.
    public var producerEndpointResolutionPPM: Double?
    public var commitsPerHostSecond: Double?
    public var meanFramesPerCommit: Double?
    public var rejectedCommits: UInt64
    public var rejectFlags: UInt32
    public var readers: [RingReaderSummary]
    public var lockstep: RingLockstepSummary
    public var outputRate: RingOutputRateSummary
    /// Run-level flags raised from the series (a gap, a sleep, a rate change, a device change).
    public var flags: [String]
}

// MARK: - Analyzer

public enum RingProbeAnalyzer {
    /// A gap between samples larger than this is flagged (a sleep or a freeze). From the brief; not a measurement.
    public static let gapThresholdSeconds = 3.0
    /// An output-rate change between samples: the nominal rate differs at all, or the actual rate by more than this fraction. A GUESS: the 6a real runs
    /// read exactly the same actual rate at every reading except one 16,000 Hz reading, so jitter below 0.1 % was not seen.
    public static let rateChangeRelativeThreshold = 1e-3
    /// Window of the per-window slopes: one minute, from the brief.
    public static let defaultWindowSeconds = 60.0

    public static func summarize(samples: [RingProbeSample], tapRate: Double, windowSeconds: Double = defaultWindowSeconds) -> RingProbeSummary {
        let usable = samples.filter { $0.readers.count == 2 }
        let first = usable.first, last = usable.last
        let span = (first != nil && last != nil) ? max(last!.elapsedSeconds - first!.elapsedSeconds, 0) : 0
        let rateOK = tapRate > 0 && tapRate.isFinite
        func ppm(_ framesPerSecond: Double?) -> Double? { framesPerSecond.flatMap { rateOK ? ($0 / tapRate - 1) * 1e6 : nil } }

        // Producer
        var prodRate: Double?, commitsRate: Double?, meanCommit: Double?, resolution: Double?
        if let f = first, let l = last, span > 0 {
            prodRate = Double(l.producer.w - f.producer.w) / span
            commitsRate = Double(l.producer.commits - f.producer.commits) / span
            let dc = l.producer.commits - f.producer.commits
            if dc > 0 { meanCommit = Double(l.producer.w - f.producer.w) / Double(dc) }
            if let m = meanCommit, rateOK { resolution = 2 * m / (tapRate * span) * 1e6 }
        }

        // Readers
        let names = ["left", "right"]
        let winSlopes = (0..<2).map { perWindowSlopes(usable, reader: $0, windowSeconds: windowSeconds) }
        let readers: [RingReaderSummary] = (0..<2).map { r in
            let fin = last?.readers[r] ?? RingReaderCounters()
            var framesRate: Double?, callsRate: Double?, meanPerCall: Double?
            if let f = first, let l = last, span > 0 {
                framesRate = Double(l.readers[r].framesRequested - f.readers[r].framesRequested) / span
                callsRate = Double(l.readers[r].calls - f.readers[r].calls) / span
            }
            if fin.calls > 0 { meanPerCall = Double(fin.framesRequested) / Double(fin.calls) }
            var intervalMeans: [Double] = []
            for (a, b) in zip(usable, usable.dropFirst()) {
                let dc = b.readers[r].calls &- a.readers[r].calls
                if b.readers[r].calls > a.readers[r].calls && dc > 0 { intervalMeans.append(Double(b.readers[r].framesRequested - a.readers[r].framesRequested) / Double(dc)) }
            }
            let fills = usable.map { $0.readers[r].fill }
            let slope = slopeOf(fillSeries(usable, reader: r))
            let slopes = winSlopes[r]
            let share: Double? = (fin.phaseValidCalls + fin.phaseInvalidCalls) > 0 ? Double(fin.phaseValidCalls) / Double(fin.phaseValidCalls + fin.phaseInvalidCalls) : nil
            return RingReaderSummary(
                name: names[r], framesRequestedPerHostSecond: framesRate, framesRequestedVsTapPPM: ppm(framesRate), callsPerHostSecond: callsRate,
                meanFramesPerCall: meanPerCall, framesPerCallIntervalMeans: MinMedianMax(intervalMeans), fillStart: fills.first, fillEnd: fills.last,
                fillMin: fills.min(), fillMax: fills.max(), fillSlopeFramesPerSecond: slope, fillSlopePPM: slope.flatMap { rateOK ? $0 / tapRate * 1e6 : nil },
                perWindowSlopesFramesPerSecond: slopes, perWindowSlopesPPM: slopes.map { rateOK ? $0 / tapRate * 1e6 : .nan }.filter(\.isFinite),
                perWindowSpreadPPM: (rateOK && slopes.count >= 2) ? (slopes.max()! - slopes.min()!) / tapRate * 1e6 : nil,
                finalCounters: fin, validTimestampShare: share)
        }

        // Lockstep
        var maxCalls: UInt64 = 0, maxFrames: UInt64 = 0
        for s in usable {
            let c0 = s.readers[0].calls, c1 = s.readers[1].calls, f0 = s.readers[0].framesRequested, f1 = s.readers[1].framesRequested
            maxCalls = max(maxCalls, c0 > c1 ? c0 - c1 : c1 - c0)
            maxFrames = max(maxFrames, f0 > f1 ? f0 - f1 : f1 - f0)
        }
        let finals = [readers[0].finalCounters, readers[1].finalCounters]
        let lockstep = RingLockstepSummary(
            maxCallsDifference: maxCalls, maxFramesRequestedDifference: maxFrames, phaseSelfChanges: finals.map(\.phaseSelfChanges),
            phaseMismatches: finals.map(\.phaseMismatches), weakRuleViolations: finals.map(\.weakRuleViolations), validTimestampShare: readers.map(\.validTimestampShare))

        // Output rate and flags
        var changes = 0, deviceChanges = 0
        var flags: [String] = []
        var sleeps = 0, gaps = 0
        for (a, b) in zip(usable, usable.dropFirst()) {
            if let n0 = a.outputNominalRate, let n1 = b.outputNominalRate, n0 != n1 { changes += 1 }
            else if let r0 = a.outputActualRate, let r1 = b.outputActualRate, r0 > 0, abs(r1 - r0) / r0 > rateChangeRelativeThreshold { changes += 1 }
            if let g = b.gapSeconds, g > gapThresholdSeconds { gaps += 1 }
            if let ca = a.continuousElapsedSeconds, let cb = b.continuousElapsedSeconds {
                let continuousGap = cb - ca, hostGap = b.elapsedSeconds - a.elapsedSeconds
                if continuousGap - hostGap > gapThresholdSeconds { sleeps += 1 }
            }
        }
        for s in usable where s.defaultOutputChanged { deviceChanges += 1 }
        let actuals = usable.compactMap(\.outputActualRate)
        let rate = RingOutputRateSummary(
            nominalFirst: usable.compactMap(\.outputNominalRate).first, nominalLast: usable.compactMap(\.outputNominalRate).last,
            actualFirst: actuals.first, actualLast: actuals.last, actualMin: actuals.min(), actualMax: actuals.max(),
            changesBetweenSamples: changes, defaultOutputChangedAtSamples: deviceChanges)
        if changes > 0 { flags.append("output rate changed between samples (\(changes) time(s))") }
        if gaps > 0 { flags.append("gap of more than \(Int(gapThresholdSeconds)) s between samples on the host clock (\(gaps) time(s)): a freeze, or the process was not scheduled") }
        if sleeps > 0 { flags.append("the Mac slept: the sleep-counting clock advanced more than \(Int(gapThresholdSeconds)) s beyond the host clock between samples (\(sleeps) time(s))") }
        if deviceChanges > 0 { flags.append("the default output device changed during the run (\(deviceChanges) sample(s) after the change)") }

        return RingProbeSummary(
            tapRate: tapRate, sampleCount: usable.count, spanSeconds: span, producerFramesPerHostSecond: prodRate, producerVsTapPPM: ppm(prodRate),
            producerEndpointResolutionPPM: resolution, commitsPerHostSecond: commitsRate, meanFramesPerCommit: meanCommit,
            rejectedCommits: last?.producer.rejectedCommits ?? 0, rejectFlags: last?.producer.rejectFlags ?? 0, readers: readers, lockstep: lockstep,
            outputRate: rate, flags: flags)
    }

    // MARK: pieces (internal so the tests can reach them)

    /// (measured elapsed seconds, fill) of one reader.
    public static func fillSeries(_ samples: [RingProbeSample], reader: Int) -> [(x: Double, y: Double)] {
        samples.map { (x: $0.elapsedSeconds, y: Double($0.readers[reader].fill)) }
    }

    /// Least-squares slope of y against x; nil with fewer than two points, no spread in x, or a non-finite result.
    public static func slopeOf(_ pts: [(x: Double, y: Double)]) -> Double? {
        guard pts.count >= 2 else { return nil }
        let n = Double(pts.count)
        let mx = pts.reduce(0.0) { $0 + $1.x } / n, my = pts.reduce(0.0) { $0 + $1.y } / n
        var sxx = 0.0, sxy = 0.0
        for p in pts { sxx += (p.x - mx) * (p.x - mx); sxy += (p.x - mx) * (p.y - my) }
        guard sxx > 0 else { return nil }
        let s = sxy / sxx
        return s.isFinite ? s : nil
    }

    /// Windows of `windowSeconds` of MEASURED elapsed time, [k w, (k+1) w). Only complete windows count: at least three samples that span at least
    /// 90 % of the window (a partial window at the end of a run is dropped, not extrapolated).
    static func completeWindows(_ samples: [RingProbeSample], windowSeconds: Double) -> [[RingProbeSample]] {
        guard windowSeconds > 0, windowSeconds.isFinite else { return [] }
        var groups: [Int: [RingProbeSample]] = [:]
        for s in samples { groups[Int(s.elapsedSeconds / windowSeconds), default: []].append(s) }
        return groups.keys.sorted().compactMap { k -> [RingProbeSample]? in
            let g = groups[k]!
            guard g.count >= 3, let a = g.first, let b = g.last, b.elapsedSeconds - a.elapsedSeconds >= 0.9 * windowSeconds else { return nil }
            return g
        }
    }

    static func perWindowSlopes(_ samples: [RingProbeSample], reader: Int, windowSeconds: Double) -> [Double] {
        completeWindows(samples, windowSeconds: windowSeconds).compactMap { slopeOf(fillSeries($0, reader: reader)) }
    }
}
