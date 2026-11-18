import Foundation

// Step 6b-3a-2: what the recovery mode of the ring probe adds to the report. Numbers and short constant strings only: no device name, no UID, no path. IMPLEMENTED-UNVERIFIED.

/// One distinct frameCount a reader was asked for, with how many calls asked for it.
public struct FrameCountEntry: Codable, Equatable, Sendable {
    public var frameCount: UInt32
    public var calls: UInt64
    public init(frameCount: UInt32, calls: UInt64) { self.frameCount = frameCount; self.calls = calls }
}

/// A reader's recovery numbers from the ring (Step 6b-3a-1 fields). From the ring it describes ONE epoch (since the last prime); in the report it is the SUM over all epochs.
public struct RingReaderRecovery: Codable, Equatable, Sendable {
    public var name: String
    /// Distinct frameCount values in order of first appearance (the ring keeps at most 8 per epoch; further values are in `frameCountOverflowCalls`).
    public var frameCounts: [FrameCountEntry]
    public var frameCountOverflowCalls: UInt64
    /// nil = no call yet.
    public var minFrameCount: UInt32?
    public var maxFrameCount: UInt32?
    public var overrunJumps: UInt64
    public var overrunJumpFrames: UInt64
    public var divergenceJumps: UInt64
    public var divergenceJumpFrames: UInt64
    public var refusedJumps: UInt64
    public var largestJumpFrames: UInt64
    /// The sticky flags (cleared by a prime). In the report: set if they were set at any time in any epoch.
    public var diverged: Bool
    public var needsReprime: Bool

    public init(name: String = "", frameCounts: [FrameCountEntry] = [], frameCountOverflowCalls: UInt64 = 0, minFrameCount: UInt32? = nil, maxFrameCount: UInt32? = nil,
                overrunJumps: UInt64 = 0, overrunJumpFrames: UInt64 = 0, divergenceJumps: UInt64 = 0, divergenceJumpFrames: UInt64 = 0, refusedJumps: UInt64 = 0,
                largestJumpFrames: UInt64 = 0, diverged: Bool = false, needsReprime: Bool = false) {
        self.name = name; self.frameCounts = frameCounts; self.frameCountOverflowCalls = frameCountOverflowCalls; self.minFrameCount = minFrameCount
        self.maxFrameCount = maxFrameCount; self.overrunJumps = overrunJumps; self.overrunJumpFrames = overrunJumpFrames; self.divergenceJumps = divergenceJumps
        self.divergenceJumpFrames = divergenceJumpFrames; self.refusedJumps = refusedJumps; self.largestJumpFrames = largestJumpFrames
        self.diverged = diverged; self.needsReprime = needsReprime
    }

    /// Adds another epoch: the tables are merged by frameCount value (first appearance keeps its position), counts and jumps are summed, min / max / largest widened, flags ORed.
    public mutating func merge(_ epoch: RingReaderRecovery) {
        for e in epoch.frameCounts {
            if let i = frameCounts.firstIndex(where: { $0.frameCount == e.frameCount }) { frameCounts[i].calls += e.calls } else { frameCounts.append(e) }
        }
        frameCountOverflowCalls += epoch.frameCountOverflowCalls
        if let m = epoch.minFrameCount { minFrameCount = minFrameCount.map { Swift.min($0, m) } ?? m }
        if let m = epoch.maxFrameCount { maxFrameCount = maxFrameCount.map { Swift.max($0, m) } ?? m }
        overrunJumps += epoch.overrunJumps; overrunJumpFrames += epoch.overrunJumpFrames
        divergenceJumps += epoch.divergenceJumps; divergenceJumpFrames += epoch.divergenceJumpFrames
        refusedJumps += epoch.refusedJumps
        largestJumpFrames = Swift.max(largestJumpFrames, epoch.largestJumpFrames)
        diverged = diverged || epoch.diverged
        needsReprime = needsReprime || epoch.needsReprime
    }

    /// calls == sum of the table + the overflow calls; handy for checks.
    public var callsInTable: UInt64 { frameCounts.reduce(0) { $0 + $1.calls } + frameCountOverflowCalls }
}

/// The recovery side of one ring snapshot (what the engine layer copies out of `SARingSnapshot`'s 6b-3a-1 fields): the standing fill T, the ring-level request, both readers.
public struct RingRecoverySnapshot: Equatable, Sendable {
    public var standingFill: UInt32
    public var needsReprime: Bool
    /// Exactly two: [0] = left, [1] = right.
    public var readers: [RingReaderRecovery]
    public init(standingFill: UInt32, needsReprime: Bool, readers: [RingReaderRecovery]) { self.standingFill = standingFill; self.needsReprime = needsReprime; self.readers = readers }
}

/// The recovery section of a report (`--ring-probe-recovery`).
public struct RingRecoveryReport: Codable, Equatable, Sendable {
    public var config: RePrimeConfig
    /// The first prime and engine start, through the same controller states as a re-prime. Not counted as a re-prime.
    public var start: RePrimeRecord?
    public var rePrimes: [RePrimeRecord]
    public var rePrimesPerformed: Int
    public var suppressedByMinimumInterval: Int
    public var suppressedByStormLimit: Int
    /// Why the controller gave up, if it did (the run then ends).
    public var gaveUp: String?
    /// Per reader, summed over every epoch of the run (the ring zeroes its counters at each prime; the orchestrator adds each epoch before that).
    public var readers: [RingReaderRecovery]
    /// T as the ring reported it at the end.
    public var standingFillAtEnd: UInt32?
    public var notes: [String]

    public init(config: RePrimeConfig, start: RePrimeRecord?, rePrimes: [RePrimeRecord], suppressedByMinimumInterval: Int, suppressedByStormLimit: Int, gaveUp: String?,
                readers: [RingReaderRecovery], standingFillAtEnd: UInt32?, notes: [String] = []) {
        self.config = config; self.start = start; self.rePrimes = rePrimes; rePrimesPerformed = rePrimes.filter(\.succeeded).count
        self.suppressedByMinimumInterval = suppressedByMinimumInterval; self.suppressedByStormLimit = suppressedByStormLimit; self.gaveUp = gaveUp
        self.readers = readers; self.standingFillAtEnd = standingFillAtEnd; self.notes = notes
    }

    public func markdownLines() -> [String] {
        func f(_ v: Double?, _ digits: Int = 3) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "-" }
        var out: [String] = []
        out.append("## 8. Recovery (Step 6b-3a-2: control-thread re-prime) - IMPLEMENTED-UNVERIFIED")
        out.append("")
        out.append("Thresholds are UNTUNED parameters: re-prime at **\(config.underrunBlocksThreshold)** underrun blocks, or **\(config.divergenceThreshold)** divergence events, or the ring's `needsReprime` / `diverged` flag; T = **\(config.primeCallbacks)** callbacks; at most **\(config.maxRePrimesPerWindow)** per **\(f(config.windowSeconds, 0)) s** and not within **\(f(config.minIntervalSeconds, 1)) s** of the last restart; after the engine reports stopped, the readers' call counts must stay unchanged for \(config.quietPollsRequired) consecutive observations. The probe samples once per second, so a trigger is seen up to about a second late.")
        out.append("")
        out.append("- **Re-primes performed: \(rePrimesPerformed)** (triggered: \(rePrimes.count)); suppressed by the minimum interval: \(suppressedByMinimumInterval); suppressed by the storm limit: \(suppressedByStormLimit)")
        if let g = gaveUp { out.append("- **GAVE UP: \(g)**") }
        if let s = start {
            out.append("- Start sequence (same states as a re-prime, not counted): \(s.primeAttempts) prime attempt(s); engine start completed at \(f(s.restartedAtSeconds)) s on the run clock; fill at start (L, R): \(s.fillAtRestart.map { $0.map(String.init).joined(separator: ", ") } ?? "-"); \(s.succeeded ? "succeeded" : "FAILED: \(s.failure ?? "?")"); underrun blocks in the epoch after it: \(s.underrunsAfter.map(String.init) ?? "-")")
        }
        out.append("- T at the end (ring's value): \(standingFillAtEnd.map(String.init) ?? "-") frames")
        if !rePrimes.isEmpty {
            out.append("")
            out.append("| # | reason | triggered at (s) | since previous restart (s) | underruns before | engine stopped (s) | prime attempts | fill at restart (L, R) | underruns after | result |")
            out.append("|---|---|---|---|---|---|---|---|---|---|")
            for r in rePrimes {
                out.append("| \(r.index) | \(r.reason.rawValue) | \(f(r.triggeredAtSeconds)) | \(f(r.secondsSincePreviousRestart)) | \(r.underrunsBefore) | \(f(r.engineStoppedSeconds)) | \(r.primeAttempts) | \(r.fillAtRestart.map { $0.map(String.init).joined(separator: ", ") } ?? "-") | \(r.underrunsAfter.map(String.init) ?? "-") | \(r.succeeded ? "ok" : "FAILED: \(r.failure ?? "?")") |")
            }
        }
        out.append("")
        out.append("Per reader, summed over every epoch (the ring zeroes its counters at each prime):")
        out.append("")
        out.append("| | frameCounts asked for (value x calls) | overflow calls | min / max | overrun jumps (frames) | divergence jumps (frames) | refused jumps | largest jump | diverged | needsReprime |")
        out.append("|---|---|---|---|---|---|---|---|---|---|")
        for r in readers {
            let table = r.frameCounts.isEmpty ? "-" : r.frameCounts.map { "\($0.frameCount) x \($0.calls)" }.joined(separator: ", ")
            out.append("| \(r.name) | \(table) | \(r.frameCountOverflowCalls) | \(r.minFrameCount.map(String.init) ?? "-") / \(r.maxFrameCount.map(String.init) ?? "-") | \(r.overrunJumps) (\(r.overrunJumpFrames)) | \(r.divergenceJumps) (\(r.divergenceJumpFrames)) | \(r.refusedJumps) | \(r.largestJumpFrames) | \(r.diverged ? "set" : "no") | \(r.needsReprime ? "set" : "no") |")
        }
        for n in notes { out.append("- \(n)") }
        return out
    }
}
