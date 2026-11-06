import Foundation

// Step 6a: the pure half of the system-audio capture probe. Nothing here touches hardware or Core Audio; the real backend lives in
// SpatialAudioEngine and the real-time callback in the C target CTapProbe. Everything is numbers and short strings only.

/// One callback's measurement, mirroring `SATapProbeRecord` in CTapProbe.h.
public struct TapProbeRecord: Equatable, Sendable {
    public var hostTime: UInt64
    public var sumSquares: Double
    public var frames: UInt32
    public var samples: UInt32
    public var peak: Float
    public var flags: UInt32

    public init(hostTime: UInt64, sumSquares: Double, frames: UInt32, samples: UInt32, peak: Float, flags: UInt32) {
        self.hostTime = hostTime; self.sumSquares = sumSquares; self.frames = frames; self.samples = samples
        self.peak = peak; self.flags = flags
    }
}

/// Bit values of `SATapProbeRecord.flags` (CTapProbe.h).
public enum TapProbeFlag {
    public static let unsupportedFormat: UInt32 = 1
    public static let nullBuffer: UInt32 = 2
    public static let nonFiniteSample: UInt32 = 4
    public static let noBuffers: UInt32 = 8
    public static let noTimestamp: UInt32 = 16
    public static let all: [(name: String, bit: UInt32)] = [
        ("unsupported format", unsupportedFormat), ("null buffer", nullBuffer), ("non-finite sample", nonFiniteSample),
        ("no buffers", noBuffers), ("no timestamp", noTimestamp),
    ]
}

// MARK: - Core Audio status codes and four-character codes

public enum FourCC {
    /// The four ASCII characters of `value` if all are printable, else nil.
    public static func string(_ value: UInt32) -> String? {
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func value(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

public enum CoreAudioStatus {
    /// Names from CoreAudio/AudioHardwareBase.h (checked in the macOS 27.2 SDK); the codes are four-character codes.
    static let names: [UInt32: String] = [
        0: "kAudioHardwareNoError",
        FourCC.value("stop"): "kAudioHardwareNotRunningError",
        FourCC.value("what"): "kAudioHardwareUnspecifiedError",
        FourCC.value("who?"): "kAudioHardwareUnknownPropertyError",
        FourCC.value("!siz"): "kAudioHardwareBadPropertySizeError",
        FourCC.value("nope"): "kAudioHardwareIllegalOperationError",
        FourCC.value("!obj"): "kAudioHardwareBadObjectError",
        FourCC.value("!dev"): "kAudioHardwareBadDeviceError",
        FourCC.value("!str"): "kAudioHardwareBadStreamError",
        FourCC.value("unop"): "kAudioHardwareUnsupportedOperationError",
        FourCC.value("nrdy"): "kAudioHardwareNotReadyError",
        FourCC.value("!dat"): "kAudioDeviceUnsupportedFormatError",
        FourCC.value("!hog"): "kAudioDevicePermissionsError",
    ]

    public static func name(_ status: Int32) -> String? { names[UInt32(bitPattern: status)] }
    public static func fourCC(_ status: Int32) -> String? { FourCC.string(UInt32(bitPattern: status)) }
}

/// One Core Audio call and what it returned.
public struct TapProbeCall: Codable, Equatable, Sendable {
    public var name: String
    public var status: Int32
    /// The status as four characters when they are printable ("what", "!hog"), else nil.
    public var statusFourCC: String?
    /// The SDK constant name when the status is one the header names, else nil (a code the header does not name stays nameless).
    public var statusName: String?
    public var note: String?

    public init(name: String, status: Int32, note: String? = nil) {
        self.name = name; self.status = status
        statusFourCC = status == 0 ? nil : CoreAudioStatus.fourCC(status)
        statusName = CoreAudioStatus.name(status)
        self.note = note
    }

    public var succeeded: Bool { status == 0 }
}

// MARK: - The tap's format

/// The `AudioStreamBasicDescription` of the tap, as plain numbers.
public struct TapFormat: Codable, Equatable, Sendable {
    public var sampleRate: Double
    /// FourCC of `mFormatID`, e.g. "lpcm".
    public var formatID: String
    public var formatFlags: UInt32
    public var bytesPerPacket: UInt32
    public var framesPerPacket: UInt32
    public var bytesPerFrame: UInt32
    public var channelsPerFrame: UInt32
    public var bitsPerChannel: UInt32

    // CoreAudioTypes/CoreAudioBaseTypes.h: kAudioFormatFlagIsFloat 0x1, IsBigEndian 0x2, IsSignedInteger 0x4, IsPacked 0x8, IsNonInterleaved 0x20.
    static let isFloatFlag: UInt32 = 1 << 0, bigEndianFlag: UInt32 = 1 << 1, signedFlag: UInt32 = 1 << 2, packedFlag: UInt32 = 1 << 3
    static let nonInterleavedFlag: UInt32 = 1 << 5

    public init(sampleRate: Double, formatID: String, formatFlags: UInt32, bytesPerPacket: UInt32, framesPerPacket: UInt32,
                bytesPerFrame: UInt32, channelsPerFrame: UInt32, bitsPerChannel: UInt32) {
        self.sampleRate = sampleRate; self.formatID = formatID; self.formatFlags = formatFlags
        self.bytesPerPacket = bytesPerPacket; self.framesPerPacket = framesPerPacket; self.bytesPerFrame = bytesPerFrame
        self.channelsPerFrame = channelsPerFrame; self.bitsPerChannel = bitsPerChannel
    }

    public var isLinearPCM: Bool { formatID == "lpcm" }
    public var isFloat32: Bool { isLinearPCM && formatFlags & Self.isFloatFlag != 0 && bitsPerChannel == 32 }
    public var isInterleaved: Bool { formatFlags & Self.nonInterleavedFlag == 0 }
    public var bytesPerSample: UInt32 { bitsPerChannel / 8 }

    /// "Float32 non-interleaved", "SInt16 interleaved", or "format 'ac-3' (not linear PCM)".
    public var sampleFormatDescription: String {
        guard isLinearPCM else { return "format '\(formatID)' (not linear PCM)" }
        let kind = formatFlags & Self.isFloatFlag != 0 ? "Float" : (formatFlags & Self.signedFlag != 0 ? "SInt" : "UInt")
        return "\(kind)\(bitsPerChannel) \(isInterleaved ? "interleaved" : "non-interleaved")"
            + (formatFlags & Self.bigEndianFlag != 0 ? ", big-endian" : "")
    }
}

// MARK: - Aggregation of the callback records

public struct TapSecondStats: Codable, Equatable, Sendable {
    /// Seconds since the first callback (0-based); the last one may be partial.
    public var second: Int
    public var callbacks: Int
    public var frames: Int
    public var peak: Double
    /// Root mean square over every counted sample of the second; nil if no sample was counted.
    public var rms: Double?
    public var peakDBFS: Double?
    public var rmsDBFS: Double?
    /// Samples were counted and every one was exactly 0.
    public var silent: Bool
}

public struct TapProbeStats: Codable, Equatable, Sendable {
    public var callbackCount: Int
    /// Callbacks that found the record buffer full (their measurement is missing).
    public var dropped: UInt64
    public var framesPerCallback: MinMedianMax?
    /// Time between successive callbacks, milliseconds (from the host timestamps the callbacks received).
    public var callbackIntervalMs: MinMedianMax?
    public var totalFrames: Int
    /// Frames of all but the last callback divided by the time from the first to the last callback: a cross-check of the declared sample rate.
    public var impliedFramesPerSecond: Double?
    public var peak: Double
    public var rms: Double?
    public var perSecond: [TapSecondStats]
    /// One entry per 10 s window of the run (Step 6a2).
    public var windows: [TapWindowStats] = []
    public var silentSeconds: Int
    /// How many callbacks carried each flag.
    public var flagCounts: [String: Int]
}

// MARK: - Device facts, rate samples and 10 s windows (Step 6a2)

/// Core Audio device transport types as the header names them (CoreAudio/AudioHardwareBase.h, macOS 27.2 SDK); an unnamed code stays nameless.
public enum TapDeviceTransport {
    static let names: [UInt32: String] = [
        0: "kAudioDeviceTransportTypeUnknown", FourCC.value("bltn"): "kAudioDeviceTransportTypeBuiltIn",
        FourCC.value("grup"): "kAudioDeviceTransportTypeAggregate", FourCC.value("virt"): "kAudioDeviceTransportTypeVirtual",
        FourCC.value("pci "): "kAudioDeviceTransportTypePCI", FourCC.value("usb "): "kAudioDeviceTransportTypeUSB",
        FourCC.value("1394"): "kAudioDeviceTransportTypeFireWire", FourCC.value("blue"): "kAudioDeviceTransportTypeBluetooth",
        FourCC.value("blea"): "kAudioDeviceTransportTypeBluetoothLE", FourCC.value("hdmi"): "kAudioDeviceTransportTypeHDMI",
        FourCC.value("dprt"): "kAudioDeviceTransportTypeDisplayPort", FourCC.value("airp"): "kAudioDeviceTransportTypeAirPlay",
        FourCC.value("eavb"): "kAudioDeviceTransportTypeAVB", FourCC.value("thun"): "kAudioDeviceTransportTypeThunderbolt",
        FourCC.value("ccwd"): "kAudioDeviceTransportTypeContinuityCaptureWired", FourCC.value("ccwl"): "kAudioDeviceTransportTypeContinuityCaptureWireless",
        FourCC.value("rscr"): "kAudioDeviceTransportTypeRemoteScreen", FourCC.value("rstr"): "kAudioDeviceTransportTypeRemoteStreaming",
    ]
    public static func name(_ code: UInt32) -> String? { names[code] }
}

/// Read-only facts about one audio device, from property reads (the status of every read is kept; an unreadable value is nil, never guessed).
/// The UIDs are NOT recorded (a Bluetooth UID can contain a hardware address); the name is, because it was asked for, and it can contain a person's name.
public struct TapDeviceFacts: Codable, Equatable, Sendable {
    /// "default output device" or "tap aggregate device".
    public var role: String
    public var name: String?
    /// Four characters (e.g. "bltn"), "0" for unknown.
    public var transportType: String?
    public var transportName: String?
    public var nominalSampleRate: Double?
    /// "The current actual sample rate of the AudioDevice as measured by its time stamps" (header).
    public var actualSampleRate: Double?
    public var bufferFrameSize: UInt32?
    public var outputChannels: Int?
    public var inputChannels: Int?
    /// The scope the next three were read in: "output" for an output device, "input" for the tap's aggregate device.
    public var scopeRead: String
    public var deviceLatencyFrames: UInt32?
    public var safetyOffsetFrames: UInt32?
    /// kAudioStreamPropertyLatency of each stream in that scope.
    public var streamLatencyFrames: [UInt32]
    /// Devices with the same non-zero value "are able to be synchronized in hardware"; 0 means unspecified, to be treated as separate from every other device (header).
    public var clockDomain: UInt32?
    /// A clock device UID is named (nil = the read failed).
    public var hasClockDevice: Bool?
    /// The named clock device is the device itself (nil = not applicable or unreadable).
    public var clockDeviceIsItself: Bool?
    /// OSStatus of every read, by property name.
    public var statuses: [String: Int32]

    public init(role: String, name: String? = nil, transportType: String? = nil, transportName: String? = nil, nominalSampleRate: Double? = nil,
                actualSampleRate: Double? = nil, bufferFrameSize: UInt32? = nil, outputChannels: Int? = nil, inputChannels: Int? = nil,
                scopeRead: String = "output", deviceLatencyFrames: UInt32? = nil, safetyOffsetFrames: UInt32? = nil, streamLatencyFrames: [UInt32] = [],
                clockDomain: UInt32? = nil, hasClockDevice: Bool? = nil, clockDeviceIsItself: Bool? = nil, statuses: [String: Int32] = [:]) {
        self.role = role; self.name = name; self.transportType = transportType; self.transportName = transportName
        self.nominalSampleRate = nominalSampleRate; self.actualSampleRate = actualSampleRate; self.bufferFrameSize = bufferFrameSize
        self.outputChannels = outputChannels; self.inputChannels = inputChannels; self.scopeRead = scopeRead
        self.deviceLatencyFrames = deviceLatencyFrames; self.safetyOffsetFrames = safetyOffsetFrames; self.streamLatencyFrames = streamLatencyFrames
        self.clockDomain = clockDomain; self.hasClockDevice = hasClockDevice; self.clockDeviceIsItself = clockDeviceIsItself; self.statuses = statuses
    }

    /// Reads that returned a non-zero status, sorted.
    public var failedReads: [String] { statuses.filter { $0.value != 0 }.keys.sorted() }
}

/// The two `ActualSampleRate` readings (output device, tap aggregate device) taken at the start and after every 10 s slice of the run.
public struct TapRateSample: Codable, Equatable, Sendable {
    public var elapsedSeconds: Double
    public var outputActualRate: Double?
    public var aggregateActualRate: Double?
    public init(elapsedSeconds: Double, outputActualRate: Double?, aggregateActualRate: Double?) {
        self.elapsedSeconds = elapsedSeconds; self.outputActualRate = outputActualRate; self.aggregateActualRate = aggregateActualRate
    }
}

/// The tap's callback cadence in one 10 s window of the run, against the host clock.
public struct TapWindowStats: Codable, Equatable, Sendable {
    /// Seconds since the first callback at which the window starts (0, 10, 20, ...).
    public var startSecond: Int
    public var callbacks: Int
    public var frames: Int
    /// Host-clock time from the first to the last callback of the window.
    public var spanSeconds: Double
    /// Frames of all but the last callback of the window divided by that span; nil with fewer than two callbacks.
    public var impliedFramesPerSecond: Double?
    /// (implied / declared - 1) x 1e6; nil without a declared rate.
    public var impliedVsDeclaredPPM: Double?
    /// Frames delivered before this window's last callback minus declared x (its host time - the first callback's host time): how far ahead (+) or behind (-)
    /// the tap is, in frames, against the declared rate and the host clock. Noise: one callback's scheduling jitter (the callbacks' `inNow` includes it).
    public var cumulativeFrameOffset: Double?
    /// False for the last window (it may be partial).
    public var complete: Bool
}

/// The numbers side by side. Not a verdict: see `TapProbeReport.clockLimits`.
public struct TapRateComparison: Codable, Equatable, Sendable {
    public var tapDeclaredRate: Double
    public var outputNominalRate: Double?
    /// Tap declared rate equals the output device's nominal rate (nil if the latter is unknown).
    public var declaredRatesEqual: Bool?
    public var tapImpliedFramesPerSecond: Double?
    public var tapImpliedVsDeclaredPPM: Double?
    public var outputActualRateFirst: Double?
    public var outputActualRateLast: Double?
    public var outputActualRateMean: Double?
    /// (tap implied / mean output actual - 1) x 1e6 when both exist: a difference of two READINGS, each against what the header calls "time stamps".
    public var tapImpliedVsOutputActualPPM: Double?
}

public enum TapProbeAggregator {
    /// `records` in callback order; `hostTicksPerSecond` is `AudioGetHostClockFrequency()` (0 = unknown: no timing statistics).
    public static func summarize(records: [TapProbeRecord], dropped: UInt64, hostTicksPerSecond: Double,
                                 declaredRate: Double? = nil, windowSeconds: Double = 10) -> TapProbeStats {
        func dbfs(_ x: Double) -> Double? { x > 0 ? 20 * log10(x) : nil }
        let timed = hostTicksPerSecond > 0 && hostTicksPerSecond.isFinite
        let stamped = records.filter { $0.hostTime != 0 }
        var intervals: [Double] = []
        if timed { for (a, b) in zip(stamped, stamped.dropFirst()) where b.hostTime > a.hostTime { intervals.append(Double(b.hostTime - a.hostTime) / hostTicksPerSecond * 1000) } }

        var seconds: [Int: (callbacks: Int, frames: Int, peak: Double, sumSq: Double, samples: Int)] = [:]
        if timed, let base = stamped.first?.hostTime {
            for r in stamped where r.hostTime >= base {
                let s = Int(Double(r.hostTime - base) / hostTicksPerSecond)
                var e = seconds[s] ?? (0, 0, 0, 0, 0)
                e.callbacks += 1; e.frames += Int(r.frames); e.peak = max(e.peak, Double(r.peak)); e.sumSq += r.sumSquares; e.samples += Int(r.samples)
                seconds[s] = e
            }
        }
        let perSecond = seconds.keys.sorted().map { s -> TapSecondStats in
            let e = seconds[s]!
            let rms: Double? = e.samples > 0 ? (e.sumSq / Double(e.samples)).squareRoot() : nil
            return TapSecondStats(second: s, callbacks: e.callbacks, frames: e.frames, peak: e.peak, rms: rms,
                                  peakDBFS: dbfs(e.peak), rmsDBFS: rms.flatMap(dbfs), silent: e.samples > 0 && e.peak == 0 && e.sumSq == 0)
        }

        // 10 s windows of the callback cadence against the host clock.
        var windows: [TapWindowStats] = []
        if timed, windowSeconds > 0, let base = stamped.first?.hostTime {
            var byWindow: [Int: [(t: Double, frames: Int, framesBefore: Int)]] = [:]
            var framesBefore = 0
            for r in stamped where r.hostTime >= base {
                let t = Double(r.hostTime - base) / hostTicksPerSecond
                byWindow[Int(t / windowSeconds), default: []].append((t, Int(r.frames), framesBefore))
                framesBefore += Int(r.frames)
            }
            let keys = byWindow.keys.sorted()
            for w in keys {
                let rows = byWindow[w]!
                let span = (rows.last?.t ?? 0) - (rows.first?.t ?? 0)
                var implied: Double?
                if rows.count > 1, span > 0 { implied = Double(rows.dropLast().reduce(0) { $0 + $1.frames }) / span }
                let last = rows.last!
                windows.append(TapWindowStats(
                    startSecond: Int(Double(w) * windowSeconds), callbacks: rows.count, frames: rows.reduce(0) { $0 + $1.frames }, spanSeconds: span,
                    impliedFramesPerSecond: implied,
                    impliedVsDeclaredPPM: (implied != nil && (declaredRate ?? 0) > 0) ? (implied! / declaredRate! - 1) * 1e6 : nil,
                    cumulativeFrameOffset: (declaredRate ?? 0) > 0 ? Double(last.framesBefore) - declaredRate! * last.t : nil,
                    complete: w != keys.last))
            }
        }

        var flagCounts: [String: Int] = [:]
        for f in TapProbeFlag.all {
            let n = records.filter { $0.flags & f.bit != 0 }.count
            if n > 0 { flagCounts[f.name] = n }
        }
        let totalSamples = records.reduce(0) { $0 + Int($1.samples) }
        let totalSq = records.reduce(0.0) { $0 + $1.sumSquares }
        var implied: Double?
        if timed, let first = stamped.first, let last = stamped.last, last.hostTime > first.hostTime, stamped.count > 1 {
            let frames = stamped.dropLast().reduce(0) { $0 + Int($1.frames) }
            implied = Double(frames) / (Double(last.hostTime - first.hostTime) / hostTicksPerSecond)
        }
        return TapProbeStats(
            callbackCount: records.count, dropped: dropped,
            framesPerCallback: MinMedianMax(records.map { Double($0.frames) }),
            callbackIntervalMs: MinMedianMax(intervals),
            totalFrames: records.reduce(0) { $0 + Int($1.frames) }, impliedFramesPerSecond: implied,
            peak: Double(records.map(\.peak).max() ?? 0), rms: totalSamples > 0 ? (totalSq / Double(totalSamples)).squareRoot() : nil,
            perSecond: perSecond, windows: windows, silentSeconds: perSecond.filter(\.silent).count, flagCounts: flagCounts)
    }
}

// MARK: - The report

/// Device and tap lists read through Core Audio, before the probe, while it ran and after teardown.
public struct TapProbeLists: Codable, Equatable, Sendable {
    public var devicesBefore: Int?
    public var devicesDuring: Int?
    public var devicesAfter: Int?
    public var tapsBefore: Int?
    public var tapsDuring: Int?
    public var tapsAfter: Int?
    public var aggregateListedDuring: Bool?
    public var tapListedDuring: Bool?
    public var aggregateListedAfter: Bool?
    public var tapListedAfter: Bool?
    /// Reads of the lists after the destroy calls until neither object was listed (the header says destruction is asynchronous).
    public var settlePolls: Int
    /// Seconds from the destroy calls until neither object was listed; nil if they were still listed when polling stopped.
    public var settleSeconds: Double?

    public init(settlePolls: Int, settleSeconds: Double?) { self.settlePolls = settlePolls; self.settleSeconds = settleSeconds }
}

public struct TapProbeReport: Codable, Equatable, Sendable {
    /// 1: Step 6a. 2: Step 6a2 (device facts, rate samples, 10 s windows, rate comparison).
    public var schemaVersion = 2
    public var kind = "system-audio tap probe (Step 6a)"
    public var createdAt: String
    /// "coreAudioTap" for the real thing, "simulated" for the test source (a SIMULATED report decides nothing).
    public var source: String
    public var macOSVersion: String
    public var hardwareModel: String
    public var composition: String
    public var muteBehavior: String
    public var privateTap: Bool
    public var privateAggregate: Bool
    public var ownPID: Int32
    /// The audio process object of this process, or nil if Core Audio reported none (kAudioObjectUnknown).
    public var ownProcessObjectID: UInt32?
    public var excludedProcessObjects: [UInt32]
    public var requestedSeconds: Double
    public var elapsedSeconds: Double
    /// "timeout", "signal" or "never started".
    public var stoppedBy: String
    /// "ok" or "failed at <call>".
    public var outcome: String
    public var tapFormat: TapFormat?
    public var hostTicksPerSecond: Double
    public var calls: [TapProbeCall]
    public var stats: TapProbeStats?
    public var lists: TapProbeLists
    /// Read-only facts about the default output device, read before anything was created (Step 6a2).
    public var outputDevice: TapDeviceFacts?
    /// The same facts for the tap's aggregate device, read while it ran (the input-scope latencies; Step 6a2).
    public var aggregateDevice: TapDeviceFacts?
    /// `ActualSampleRate` readings at the start and after every 10 s slice.
    public var rateSamples: [TapRateSample]
    public var rateComparison: TapRateComparison?
    /// Every created object was destroyed (all destroy statuses 0) and neither was listed any more.
    public var teardownClean: Bool
    public var notes: [String]
    public var assumptions: [String]

    public init(createdAt: String, source: String, macOSVersion: String, hardwareModel: String, composition: String, muteBehavior: String,
                privateTap: Bool, privateAggregate: Bool, ownPID: Int32, ownProcessObjectID: UInt32?, excludedProcessObjects: [UInt32],
                requestedSeconds: Double, elapsedSeconds: Double, stoppedBy: String, outcome: String, tapFormat: TapFormat?,
                hostTicksPerSecond: Double, calls: [TapProbeCall], stats: TapProbeStats?, lists: TapProbeLists, teardownClean: Bool,
                notes: [String], assumptions: [String], outputDevice: TapDeviceFacts? = nil, aggregateDevice: TapDeviceFacts? = nil,
                rateSamples: [TapRateSample] = [], rateComparison: TapRateComparison? = nil) {
        self.outputDevice = outputDevice; self.aggregateDevice = aggregateDevice; self.rateSamples = rateSamples; self.rateComparison = rateComparison
        self.createdAt = createdAt; self.source = source; self.macOSVersion = macOSVersion; self.hardwareModel = hardwareModel
        self.composition = composition; self.muteBehavior = muteBehavior; self.privateTap = privateTap; self.privateAggregate = privateAggregate
        self.ownPID = ownPID; self.ownProcessObjectID = ownProcessObjectID; self.excludedProcessObjects = excludedProcessObjects
        self.requestedSeconds = requestedSeconds; self.elapsedSeconds = elapsedSeconds; self.stoppedBy = stoppedBy; self.outcome = outcome
        self.tapFormat = tapFormat; self.hostTicksPerSecond = hostTicksPerSecond; self.calls = calls; self.stats = stats; self.lists = lists
        self.teardownClean = teardownClean; self.notes = notes; self.assumptions = assumptions
    }

    public var isSimulated: Bool { source == "simulated" }

    public static let standardAssumptions = [
        "Measures only: no rendering, no camera, nothing muted (the tap's mute behavior is 'unmuted'); the captured audio is counted, never stored or played.",
        "Whether the tap carried audio is read from the levels; a permission denial or protected (DRM) content can also read as silence. Neither is worked around.",
        "Level and timing numbers come from the callbacks' own host timestamps and buffers; frames per callback is read from the first buffer of each callback.",
        "Status codes are the OSStatus each call returned; names are given only where AudioHardwareBase.h names the code.",
        "The permission prompt text, the Info.plist key it needed and the behavior when denied are observations by the person running the probe (docs/MANUAL_TEST_STEP6A.md), not something the code can detect.",
    ]

    /// Printed in every report (section 4): what a tap-only aggregate device does and does not tell us about clocks. No drift claim is made from one reading.
    public static let clockLimits = [
        "The tap-only aggregate device this probe builds has NO sub-device and NO clock device (neither key is set), so the headers do not say which clock its callbacks follow. The probe does not decide that.",
        "The callback cadence is measured against the HOST clock (the callbacks' own host timestamps). That shows whether the tap's callbacks are regular and whether their frame rate matches the declared rate against the host clock. It does NOT show whether the tap and the output device share a clock.",
        "`kAudioDevicePropertyClockDomain`: devices with the same non-zero value \"are able to be synchronized in hardware\"; 0 means unspecified and is to be treated as separate from every other device (header). An equal non-zero value would mean \"able to be synchronized\", not that they ARE; a 0 on either side settles nothing.",
        "`kAudioDevicePropertyActualSampleRate` is \"as measured by its time stamps\" (header). That it is measured against the host clock is a reading of those words, UNVERIFIED. Two readings that differ are a difference of readings, not a measured drift.",
        "Drift needs a MEASURED SERIES: the 10 s windows and the cumulative frame offset of a long run (600 s) are that series; one reading, or a short run, supports no drift claim. A SIMULATED run supports none at all. The offset has noise of about one callback's scheduling jitter (it does not accumulate).",
    ]

    public static func fileStem(date: Date, timeZone: TimeZone = .current, simulated: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "tapprobe-\(f.string(from: date))" + (simulated ? "-SIMULATED" : "")
    }

    public func jsonData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> TapProbeReport { try JSONDecoder().decode(TapProbeReport.self, from: data) }
}

extension TapProbeReport {
    public func markdown(maxSecondRows: Int = 120) -> String {
        func f(_ x: Double?, _ fmt: String = "%.2f") -> String { x.map { String(format: fmt, $0) } ?? "—" }
        func yn(_ b: Bool?) -> String { b.map { $0 ? "yes" : "no" } ?? "—" }
        func n(_ v: Int?) -> String { v.map(String.init) ?? "—" }
        var L: [String] = []
        L.append("# SpatialAudio system-audio tap probe (Step 6a)")
        L.append("")
        if isSimulated {
            L.append("> **SIMULATED SOURCE** — produced by the test source driving the real C callback, NOT by Core Audio. Do not use these numbers as hardware results.")
            L.append("")
        }
        L.append("- **Date:** \(createdAt)")
        L.append("- **Machine:** \(hardwareModel), macOS \(macOSVersion)")
        L.append("- **Source:** \(source); **composition:** \(composition)")
        L.append("- **Tap:** global stereo mixdown excluding \(excludedProcessObjects.isEmpty ? "nobody (this process had no audio process object)" : "process object(s) \(excludedProcessObjects.map(String.init).joined(separator: ", "))"), mute behavior \(muteBehavior), private tap: \(privateTap), private aggregate device: \(privateAggregate)")
        L.append("- **This process:** pid \(ownPID), audio process object \(ownProcessObjectID.map(String.init) ?? "none reported (kAudioObjectUnknown)")")
        L.append("- **Run:** requested \(f(requestedSeconds, "%.1f")) s, elapsed \(f(elapsedSeconds, "%.2f")) s, stopped by \(stoppedBy); **outcome: \(outcome)**")
        L.append("")
        L.append("## 1. Format of the tap")
        if let t = tapFormat {
            L.append("- **\(t.sampleFormatDescription)**, \(t.channelsPerFrame) channel(s), \(f(t.sampleRate, "%.0f")) Hz, \(t.bitsPerChannel) bits per channel, \(t.bytesPerFrame) bytes per frame, flags 0x\(String(t.formatFlags, radix: 16)), format ID '\(t.formatID)'")
        } else {
            L.append("- not read (the tap or its format query failed; see the call table)")
        }
        L.append("")
        L.append("## 2. Callbacks")
        if let s = stats {
            L.append("- **Callbacks:** \(s.callbackCount) (dropped, buffer full: \(s.dropped)); **frames in total:** \(s.totalFrames); host clock \(f(hostTicksPerSecond, "%.0f")) ticks/s")
            L.append("- **Frames per callback** (min / median / max): \(s.framesPerCallback.map { String(format: "%.0f / %.0f / %.0f", $0.min, $0.median, $0.max) } ?? "—")")
            L.append("- **Callback interval, ms** (min / median / max): \(s.callbackIntervalMs.map { String(format: "%.3f / %.3f / %.3f", $0.min, $0.median, $0.max) } ?? "—")")
            L.append("- **Implied frames per second** (cross-check of the declared rate): \(f(s.impliedFramesPerSecond, "%.0f"))")
            L.append("- **Overall peak:** \(String(format: "%.6f", s.peak)); **overall RMS:** \(f(s.rms, "%.6f")); **silent seconds:** \(s.silentSeconds) of \(s.perSecond.count)")
            L.append("- **Flags** (callbacks with each): \(s.flagCounts.isEmpty ? "none" : s.flagCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
            L.append("")
            L.append("| second | callbacks | frames | peak | peak dBFS | RMS | RMS dBFS | silent |")
            L.append("|---|---|---|---|---|---|---|---|")
            for r in s.perSecond.prefix(maxSecondRows) {
                L.append(String(format: "| %d | %d | %d | %.6f | %@ | %@ | %@ | %@ |", r.second, r.callbacks, r.frames, r.peak,
                                f(r.peakDBFS, "%.1f"), f(r.rms, "%.6f"), f(r.rmsDBFS, "%.1f"), r.silent ? "yes" : "no"))
            }
            if s.perSecond.count > maxSecondRows { L.append("") ; L.append("(first \(maxSecondRows) of \(s.perSecond.count) seconds; all are in the JSON file)") }
        } else {
            L.append("- no callbacks were recorded")
        }
        L.append("")
        L.append("## 3. Every Core Audio call and its status")
        L.append("| # | call | status | code | name | note |")
        L.append("|---|---|---|---|---|---|")
        for (i, c) in calls.enumerated() {
            L.append("| \(i + 1) | \(c.name) | \(c.status) | \(c.statusFourCC.map { "'\($0)'" } ?? (c.status == 0 ? "ok" : "—")) | \(c.statusName ?? "—") | \(c.note ?? "") |")
        }
        L.append("")
        L.append("## 4. Devices, clocks and rates (read-only property reads; Step 6a2)")
        func facts(_ d: TapDeviceFacts?) -> [String] {
            guard let d else { return [] }
            func u(_ v: UInt32?) -> String { v.map(String.init) ?? "—" }
            return ["\(d.role): name **\(d.name ?? "—")**, transport \(d.transportType.map { "'\($0)'" } ?? "—")\(d.transportName.map { " (\($0))" } ?? ""), channels in / out \(d.inputChannels.map(String.init) ?? "—") / \(d.outputChannels.map(String.init) ?? "—")",
                    "  nominal rate \(f(d.nominalSampleRate, "%.1f")) Hz, actual rate \(f(d.actualSampleRate, "%.3f")) Hz, buffer \(u(d.bufferFrameSize)) frames",
                    "  latency (\(d.scopeRead) scope) \(u(d.deviceLatencyFrames)) frames, safety offset \(u(d.safetyOffsetFrames)) frames, stream latency \(d.streamLatencyFrames.isEmpty ? "—" : d.streamLatencyFrames.map(String.init).joined(separator: ", ")) frames",
                    "  clock domain \(u(d.clockDomain)), clock device named: \(yn(d.hasClockDevice))\(d.clockDeviceIsItself == true ? " (the device itself)" : ""), reads with a non-zero status: \(d.failedReads.isEmpty ? "none" : d.failedReads.joined(separator: ", "))"]
        }
        for l in facts(outputDevice) + facts(aggregateDevice) { L.append(l.hasPrefix("  ") ? "  - " + l.trimmingCharacters(in: .whitespaces) : "- " + l) }
        if outputDevice == nil && aggregateDevice == nil { L.append("- no device facts were read") }
        if let c = rateComparison {
            L.append("")
            L.append("**Rates (numbers side by side, not a verdict):** tap declared \(f(c.tapDeclaredRate, "%.1f")) Hz; output nominal \(f(c.outputNominalRate, "%.1f")) Hz (equal: \(yn(c.declaredRatesEqual))); tap implied \(f(c.tapImpliedFramesPerSecond, "%.2f")) frames/s (\(f(c.tapImpliedVsDeclaredPPM, "%+.1f")) ppm against the declared rate); output actual first / last / mean \(f(c.outputActualRateFirst, "%.3f")) / \(f(c.outputActualRateLast, "%.3f")) / \(f(c.outputActualRateMean, "%.3f")) Hz; tap implied against output actual mean: \(f(c.tapImpliedVsOutputActualPPM, "%+.1f")) ppm.")
        }
        if let w = stats?.windows, !w.isEmpty {
            L.append("")
            L.append("| window start (s) | callbacks | frames | span (s) | implied frames/s | vs declared (ppm) | cumulative frame offset | complete |")
            L.append("|---|---|---|---|---|---|---|---|")
            for x in w {
                L.append("| \(x.startSecond) | \(x.callbacks) | \(x.frames) | \(f(x.spanSeconds, "%.3f")) | \(f(x.impliedFramesPerSecond, "%.2f")) | \(f(x.impliedVsDeclaredPPM, "%+.1f")) | \(f(x.cumulativeFrameOffset, "%+.1f")) | \(x.complete ? "yes" : "no (last)") |")
            }
        }
        if !rateSamples.isEmpty {
            L.append("")
            L.append("| elapsed (s) | output ActualSampleRate (Hz) | aggregate ActualSampleRate (Hz) |")
            L.append("|---|---|---|")
            for x in rateSamples { L.append("| \(f(x.elapsedSeconds, "%.1f")) | \(f(x.outputActualRate, "%.3f")) | \(f(x.aggregateActualRate, "%.3f")) |") }
        }
        L.append("")
        L.append("**What this does and does not show:**")
        for x in Self.clockLimits { L.append("- \(x)") }
        L.append("")
        L.append("## 5. Teardown")
        L.append("- **Clean:** \(teardownClean ? "YES" : "NO")")
        L.append("- Devices listed (before / while running / after): \(n(lists.devicesBefore)) / \(n(lists.devicesDuring)) / \(n(lists.devicesAfter)); taps listed: \(n(lists.tapsBefore)) / \(n(lists.tapsDuring)) / \(n(lists.tapsAfter))")
        L.append("- Our aggregate device listed while running: \(yn(lists.aggregateListedDuring)); after teardown: \(yn(lists.aggregateListedAfter)). Our tap listed while running: \(yn(lists.tapListedDuring)); after teardown: \(yn(lists.tapListedAfter))")
        L.append("- Polls after the destroy calls until both were gone: \(lists.settlePolls); seconds until gone: \(f(lists.settleSeconds, "%.3f"))")
        if !notes.isEmpty {
            L.append("")
            L.append("## Notes")
            for x in notes { L.append("- \(x)") }
        }
        L.append("")
        L.append("## Assumptions and limits")
        for a in assumptions { L.append("- \(a)") }
        L.append("")
        return L.joined(separator: "\n")
    }
}
