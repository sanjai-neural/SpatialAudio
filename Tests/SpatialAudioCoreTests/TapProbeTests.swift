import Testing
import Foundation
@testable import SpatialAudioCore

// Step 6a. Pure logic of the system-audio capture probe: status codes, formats, record aggregation, the report, and the sequencer that
// builds the capture chain and tears it down. No Core Audio anywhere; the fake backend below stands in for it.

private func rec(_ t: UInt64, frames: UInt32 = 512, samples: UInt32 = 1024, peak: Float = 0.1, rms: Double = 0.05, flags: UInt32 = 0) -> TapProbeRecord {
    TapProbeRecord(hostTime: t, sumSquares: rms * rms * Double(samples), frames: frames, samples: samples, peak: peak, flags: flags)
}

@Suite struct CoreAudioStatusTests {
    @Test func fourCharacterCodesPrintOnlyWhenPrintable() {
        #expect(FourCC.string(FourCC.value("what")) == "what" && FourCC.string(FourCC.value("!hog")) == "!hog")
        #expect(FourCC.string(0) == nil && FourCC.string(0xFFFF_FFCE) == nil)                     // -50 (paramErr) is not four characters
        #expect(FourCC.value("lpcm") == 0x6C70_636D)
    }

    @Test func onlyCodesTheHeaderNamesGetANameAndPermissionIsOneOfThem() {
        #expect(CoreAudioStatus.name(0) == "kAudioHardwareNoError")
        #expect(CoreAudioStatus.name(Int32(bitPattern: FourCC.value("what"))) == "kAudioHardwareUnspecifiedError")
        #expect(CoreAudioStatus.name(Int32(bitPattern: FourCC.value("!hog"))) == "kAudioDevicePermissionsError")
        #expect(CoreAudioStatus.name(Int32(bitPattern: FourCC.value("nope"))) == "kAudioHardwareIllegalOperationError")
        #expect(CoreAudioStatus.name(-50) == nil && CoreAudioStatus.name(Int32(bitPattern: FourCC.value("zzzz"))) == nil)   // never invent a name
    }

    @Test func aCallRecordsItsStatusAndOnlyAFailureGetsACode() {
        let ok = TapProbeCall(name: "x", status: 0)
        #expect(ok.succeeded && ok.statusFourCC == nil && ok.statusName == "kAudioHardwareNoError")
        let bad = TapProbeCall(name: "y", status: Int32(bitPattern: FourCC.value("!hog")), note: "n")
        #expect(!bad.succeeded && bad.statusFourCC == "!hog" && bad.statusName == "kAudioDevicePermissionsError" && bad.note == "n")
        let odd = TapProbeCall(name: "z", status: -50)
        #expect(odd.statusFourCC == nil && odd.statusName == nil && odd.status == -50 && !odd.succeeded)
    }
}

@Suite struct TapFormatTests {
    func f(_ id: String = "lpcm", flags: UInt32, bits: UInt32 = 32, ch: UInt32 = 2) -> TapFormat {
        TapFormat(sampleRate: 48_000, formatID: id, formatFlags: flags, bytesPerPacket: bits / 8, framesPerPacket: 1, bytesPerFrame: bits / 8, channelsPerFrame: ch, bitsPerChannel: bits)
    }

    @Test func describesTheSampleFormat() {
        #expect(f(flags: 0x29).sampleFormatDescription == "Float32 non-interleaved")          // float | packed | non-interleaved
        #expect(f(flags: 0x09).sampleFormatDescription == "Float32 interleaved")
        #expect(f(flags: 0x0C, bits: 16).sampleFormatDescription == "SInt16 interleaved")      // signed | packed
        #expect(f(flags: 0x08, bits: 16).sampleFormatDescription == "UInt16 interleaved")
        #expect(f(flags: 0x0B).sampleFormatDescription == "Float32 interleaved, big-endian")
        #expect(f("ac-3", flags: 0).sampleFormatDescription == "format 'ac-3' (not linear PCM)")
    }

    @Test func onlyThirtyTwoBitFloatPcmCountsAsFloat32() {
        #expect(f(flags: 0x29).isFloat32 && f(flags: 0x29).bytesPerSample == 4 && !f(flags: 0x29).isInterleaved && f(flags: 0x09).isInterleaved)
        #expect(!f(flags: 0x29, bits: 64).isFloat32 && !f(flags: 0x0C).isFloat32 && !f("ac-3", flags: 0x29).isFloat32)
    }
}

@Suite struct TapProbeAggregatorTests {
    /// 1000 ticks per second; a callback every 100 ticks (0.1 s) starting at tick 5000, 25 callbacks: seconds 0, 1 and 2 (10, 10 and 5 callbacks).
    func steady(peakBySecond: [Float], rmsBySecond: [Double]) -> [TapProbeRecord] {
        (0..<25).map { k in
            let s = k / 10
            return rec(5000 + UInt64(k) * 100, peak: peakBySecond[s], rms: rmsBySecond[s])
        }
    }

    @Test func countsFramesAndIntervalsExactly() throws {
        let st = TapProbeAggregator.summarize(records: steady(peakBySecond: [0.5, 0.25, 0], rmsBySecond: [0.1, 0.05, 0]), dropped: 3, hostTicksPerSecond: 1000)
        #expect(st.callbackCount == 25 && st.dropped == 3 && st.totalFrames == 25 * 512)
        let fr = try #require(st.framesPerCallback)
        #expect(fr.min == 512 && fr.median == 512 && fr.max == 512)
        let iv = try #require(st.callbackIntervalMs)
        #expect(abs(iv.min - 100) < 1e-9 && abs(iv.median - 100) < 1e-9 && abs(iv.max - 100) < 1e-9)
        // 24 callbacks of 512 frames over 2.4 s
        #expect(abs((st.impliedFramesPerSecond ?? 0) - 24 * 512 / 2.4) < 1e-6)
    }

    @Test func perSecondBucketsPeakRmsAndSilence() throws {
        let st = TapProbeAggregator.summarize(records: steady(peakBySecond: [0.5, 0.25, 0], rmsBySecond: [0.1, 0.05, 0]), dropped: 0, hostTicksPerSecond: 1000)
        #expect(st.perSecond.map(\.second) == [0, 1, 2] && st.perSecond.map(\.callbacks) == [10, 10, 5])
        #expect(st.perSecond.map(\.frames) == [5120, 5120, 2560])
        #expect(st.perSecond[0].peak == 0.5 && st.perSecond[1].peak == 0.25 && st.perSecond[2].peak == 0)
        let rms0 = try #require(st.perSecond[0].rms), rms1 = try #require(st.perSecond[1].rms), db0 = try #require(st.perSecond[0].peakDBFS)
        #expect(abs(rms0 - 0.1) < 1e-12 && abs(rms1 - 0.05) < 1e-12)
        #expect(abs(db0 - (-6.020599913279624)) < 1e-9)
        #expect(st.perSecond[2].peakDBFS == nil && st.perSecond[2].rmsDBFS == nil)                 // silence has no dBFS, not -infinity
        #expect(st.perSecond.map(\.silent) == [false, false, true] && st.silentSeconds == 1)
        #expect(st.peak == 0.5)
    }

    @Test func medianAndMaxFollowTheDataNotTheAverage() throws {
        let ts: [UInt64] = [1000, 1010, 1022, 1052]                                        // intervals 10, 12, 30 ms at 1000 ticks/s
        let frames: [UInt32] = [256, 512, 512, 1024]
        let recs = zip(ts, frames).map { rec($0, frames: $1) }
        let st = TapProbeAggregator.summarize(records: recs, dropped: 0, hostTicksPerSecond: 1000)
        let iv = try #require(st.callbackIntervalMs), fr = try #require(st.framesPerCallback)
        #expect(abs(iv.min - 10) < 1e-9 && abs(iv.median - 12) < 1e-9 && abs(iv.max - 30) < 1e-9)
        #expect(fr.min == 256 && fr.median == 512 && fr.max == 1024)
    }

    @Test func flagsAreCountedPerFlag() {
        let recs = [rec(1000, flags: TapProbeFlag.nonFiniteSample), rec(1100, flags: TapProbeFlag.nonFiniteSample | TapProbeFlag.nullBuffer), rec(1200)]
        let st = TapProbeAggregator.summarize(records: recs, dropped: 0, hostTicksPerSecond: 1000)
        #expect(st.flagCounts == ["non-finite sample": 2, "null buffer": 1])
    }

    @Test func recordsWithoutATimestampOrWithoutAClockGiveNoTimingButStillCount() {
        let recs = [rec(0), rec(0), rec(0)]
        let a = TapProbeAggregator.summarize(records: recs, dropped: 0, hostTicksPerSecond: 1000)
        #expect(a.callbackCount == 3 && a.callbackIntervalMs == nil && a.perSecond.isEmpty && a.impliedFramesPerSecond == nil)
        let b = TapProbeAggregator.summarize(records: [rec(1000), rec(1100)], dropped: 0, hostTicksPerSecond: 0)
        #expect(b.callbackCount == 2 && b.callbackIntervalMs == nil && b.perSecond.isEmpty)
    }

    @Test func noRecordsIsAnHonestEmptyResult() {
        let st = TapProbeAggregator.summarize(records: [], dropped: 0, hostTicksPerSecond: 1000)
        #expect(st.callbackCount == 0 && st.framesPerCallback == nil && st.rms == nil && st.perSecond.isEmpty && st.silentSeconds == 0 && st.peak == 0)
    }

    @Test func unsupportedFormatCallbacksAreNotCountedAsSilence() {
        // frames counted, samples 0: levels unknown, which is not the same as silent
        let recs = (0..<10).map { k in TapProbeRecord(hostTime: 1000 + UInt64(k) * 100, sumSquares: 0, frames: 512, samples: 0, peak: 0, flags: TapProbeFlag.unsupportedFormat) }
        let st = TapProbeAggregator.summarize(records: recs, dropped: 0, hostTicksPerSecond: 1000)
        #expect(st.perSecond.count == 1 && st.perSecond[0].rms == nil && st.perSecond[0].silent == false && st.silentSeconds == 0 && st.rms == nil)
    }

    @Test func overallRmsWeightsEverySample() throws {
        let a = rec(1000, samples: 100, rms: 0.2), b = rec(1100, samples: 300, rms: 0.4)
        let st = TapProbeAggregator.summarize(records: [a, b], dropped: 0, hostTicksPerSecond: 1000)
        let expected = ((0.2 * 0.2 * 100 + 0.4 * 0.4 * 300) / 400).squareRoot()
        let overall = try #require(st.rms)
        #expect(abs(overall - expected) < 1e-12)
    }
}

// MARK: - The sequencer, with a scriptable fake backend

final class FakeTime: @unchecked Sendable {
    var t = 0.0
    var sleeps = 0
}

final class FakeBackend: TapProbeBackend {
    let source = "fake"
    var composition = "fake composition"
    // scripting
    var refusal: String?
    var ownObject: UInt32 = 4242
    var failing: [String: Int32] = [:]            // method name -> OSStatus to return
    var readsUntilGone = 1                        // list reads after destroy that still show the object; Int.max = never gone
    var goneDespiteFailure: Set<String> = []      // destroy calls that return an error status but still remove the object
    var formatBits: UInt32 = 32                   // bits per channel the fake tap reports
    var outFacts = TapDeviceFacts(role: "default output device", name: "fake out", transportType: "bltn", transportName: "kAudioDeviceTransportTypeBuiltIn",
                                  nominalSampleRate: 48_000, actualSampleRate: 48_000, bufferFrameSize: 512, outputChannels: 2, inputChannels: 0, scopeRead: "output",
                                  deviceLatencyFrames: 1, safetyOffsetFrames: 2, streamLatencyFrames: [3], clockDomain: 7, hasClockDevice: false, statuses: [:])
    var aggFacts = TapDeviceFacts(role: "tap aggregate device", name: "fake aggregate", scopeRead: "input", deviceLatencyFrames: 4, clockDomain: 0, statuses: [:])
    var actualRates: [(output: Double?, aggregate: Double?)] = []     // returned in order by sampleActualRates; the last one repeats
    private var rateReads = 0
    var records: [TapProbeRecord] = []
    // observation
    var log: [String] = []
    var live: Set<String> = []                    // objects currently alive: "tap", "aggregate", "ioproc", "running"
    var excludedSeen: [UInt32] = []
    private var destroyedReads = 0, tapDestroyedReads = 0
    private var aggregateDestroyed = false, tapDestroyed = false

    func status(_ name: String) -> Int32 { failing[name] ?? 0 }

    func preflight() -> String? { log.append("preflight"); return refusal }
    func translateOwnPID() -> (object: UInt32, status: Int32) { log.append("translateOwnPID"); return (ownObject, status("translateOwnPID")) }
    func createTap(excludingProcessObjects: [UInt32]) -> (tap: UInt32, status: Int32) {
        log.append("createTap"); excludedSeen = excludingProcessObjects
        let s = status("createTap"); if s == 0 { live.insert("tap") }
        return (s == 0 ? 11 : 0, s)
    }
    func readTapUID(_ tap: UInt32) -> (uid: String?, status: Int32) { log.append("readTapUID"); let s = status("readTapUID"); return (s == 0 ? "uid" : nil, s) }
    func readTapFormat(_ tap: UInt32) -> (format: TapFormat?, status: Int32) {
        log.append("readTapFormat"); let s = status("readTapFormat")
        return (s == 0 ? TapFormat(sampleRate: 48_000, formatID: "lpcm", formatFlags: 0x29, bytesPerPacket: 4, framesPerPacket: 1, bytesPerFrame: 4, channelsPerFrame: 2, bitsPerChannel: formatBits) : nil, s)
    }
    func prepareCapture(format: TapFormat, capacity: Int) -> Bool { log.append("prepareCapture"); return status("prepareCapture") == 0 }
    func createAggregate(tapUID: String) -> (device: UInt32, status: Int32) {
        log.append("createAggregate"); let s = status("createAggregate"); if s == 0 { live.insert("aggregate") }
        return (s == 0 ? 22 : 0, s)
    }
    func createIOProc(on device: UInt32) -> Int32 { log.append("createIOProc"); let s = status("createIOProc"); if s == 0 { live.insert("ioproc") }; return s }
    func start(_ device: UInt32) -> Int32 { log.append("start"); let s = status("start"); if s == 0 { live.insert("running") }; return s }
    func stop(_ device: UInt32) -> Int32 { log.append("stop"); live.remove("running"); return status("stop") }
    func destroyIOProc(on device: UInt32) -> Int32 { log.append("destroyIOProc"); live.remove("ioproc"); return status("destroyIOProc") }
    func destroyAggregate(_ device: UInt32) -> Int32 { log.append("destroyAggregate"); aggregateDestroyed = true; let s = status("destroyAggregate"); if s == 0 || goneDespiteFailure.contains("destroyAggregate") { live.remove("aggregate") }; return s }
    func destroyTap(_ tap: UInt32) -> Int32 { log.append("destroyTap"); tapDestroyed = true; let s = status("destroyTap"); if s == 0 || goneDespiteFailure.contains("destroyTap") { live.remove("tap") }; return s }

    func listDevices() -> (ids: [UInt32], status: Int32) {
        log.append("listDevices")
        var listed = live.contains("aggregate")                          // alive (never destroyed, or the destroy failed)
        if aggregateDestroyed { destroyedReads += 1; if destroyedReads <= readsUntilGone { listed = true } }   // asynchronous destroy
        return (listed ? [1, 2, 22] : [1, 2], status("listDevices"))
    }
    func listTaps() -> (ids: [UInt32], status: Int32) {
        log.append("listTaps")
        var listed = live.contains("tap")
        if tapDestroyed { tapDestroyedReads += 1; if tapDestroyedReads <= readsUntilGone { listed = true } }
        return (listed ? [11] : [], status("listTaps"))
    }
    func outputDeviceFacts() -> TapDeviceFacts { log.append("outputDeviceFacts"); return outFacts }
    func aggregateDeviceFacts(_ device: UInt32) -> TapDeviceFacts { log.append("aggregateDeviceFacts"); return aggFacts }
    func sampleActualRates(aggregate: UInt32?) -> (output: Double?, aggregate: Double?) {
        log.append("sampleActualRates")
        guard !actualRates.isEmpty else { return (nil, nil) }
        defer { rateReads += 1 }
        return actualRates[min(rateReads, actualRates.count - 1)]
    }
    func collect() -> TapProbeCollected { log.append("collect"); return TapProbeCollected(records: records, dropped: 0, hostTicksPerSecond: 1000) }
}

@Suite struct TapProbeRunnerTests {
    let env = TapProbeEnvironment(createdAt: "2026-11-05T12:00:00Z", macOSVersion: "27.2", hardwareModel: "Mac16,12", ownPID: 99, requestedSeconds: 5)

    func clock(_ t: FakeTime) -> TapProbeClock { TapProbeClock(now: { t.t }, sleep: { t.t += $0; t.sleeps += 1 }) }

    func run(_ b: FakeBackend, time: FakeTime = FakeTime(), limit: Double = 2.0, reason: TapProbeStopReason = .timeout, waited: (Double) -> Void = { _ in }) -> TapProbeReport {
        TapProbeRunner.run(backend: b, environment: env, clock: clock(time), settleLimitSeconds: limit, pollIntervalSeconds: 0.01) { s in waited(s); return reason }
    }

    func steadyRecords() -> [TapProbeRecord] { (0..<20).map { k in rec(5000 + UInt64(k) * 100, peak: 0.3, rms: 0.1) } }

    @Test func aSuccessfulRunBuildsRunsAndTearsDownInOrder() throws {
        let b = FakeBackend(); b.records = steadyRecords()
        var waitedFor: Double?
        let r = run(b) { waitedFor = $0 }
        #expect(r.outcome == "ok" && r.teardownClean && r.stoppedBy == "timeout" && waitedFor == 5)
        #expect(b.live.isEmpty)
        let order = b.log.filter { !["listDevices", "listTaps", "outputDeviceFacts", "aggregateDeviceFacts", "sampleActualRates"].contains($0) }
        #expect(order == ["translateOwnPID", "preflight", "createTap", "readTapUID", "readTapFormat", "prepareCapture", "createAggregate", "createIOProc",
                          "start", "stop", "destroyIOProc", "collect", "destroyAggregate", "destroyTap"])
        #expect(b.excludedSeen == [4242] && r.excludedProcessObjects == [4242] && r.ownProcessObjectID == 4242)
        #expect(r.stats?.callbackCount == 20 && r.tapFormat?.sampleFormatDescription == "Float32 non-interleaved")
        #expect(r.lists.aggregateListedDuring == true && r.lists.tapListedDuring == true && r.lists.aggregateListedAfter == false && r.lists.tapListedAfter == false)
        #expect(r.source == "fake" && r.composition == "fake composition" && r.muteBehavior == "unmuted" && r.privateTap && r.privateAggregate)
    }

    @Test func everyCallIsLoggedWithItsStatus() {
        let r = run(FakeBackend())
        let names = r.calls.map(\.name)
        for expected in ["AudioHardwareCreateProcessTap", "AudioObjectGetPropertyData(tap, kAudioTapPropertyFormat)", "AudioHardwareCreateAggregateDevice",
                         "AudioDeviceCreateIOProcID", "AudioDeviceStart", "AudioDeviceStop", "AudioDeviceDestroyIOProcID",
                         "AudioHardwareDestroyAggregateDevice", "AudioHardwareDestroyProcessTap"] {
            #expect(names.contains(expected), "missing \(expected)")
        }
        #expect(r.calls.allSatisfy { $0.succeeded })
    }

    @Test(arguments: ["createTap", "readTapUID", "readTapFormat", "prepareCapture", "createAggregate", "createIOProc", "start"])
    func aFailureAtAnyStepUnwindsEverythingThatWasCreatedAndNeverRuns(step: String) {
        let b = FakeBackend()
        b.failing[step] = Int32(bitPattern: FourCC.value("what"))
        var waitCalled = false
        let r = run(b) { _ in waitCalled = true }
        #expect(r.outcome.hasPrefix("failed at "), "\(step): \(r.outcome)")
        #expect(b.live.isEmpty, "\(step) left \(b.live) alive")
        #expect(!waitCalled && r.stoppedBy == "never started" && r.elapsedSeconds == 0)
        #expect(r.teardownClean)                               // what exists was destroyed and is gone from the lists
        // reverse order: nothing is stopped or destroyed before it was created
        let order = b.log
        if let c = order.firstIndex(of: "createAggregate"), let d = order.firstIndex(of: "destroyAggregate") { #expect(c < d) }
        if order.contains("createIOProc") && b.status("createIOProc") == 0 { #expect(order.contains("destroyIOProc")) }
        #expect(!order.contains("stop"), "\(step): stop was called although the device never started")
        if step == "createTap" { #expect(!order.contains("destroyTap") && !order.contains("createAggregate")) }
    }

    @Test(arguments: [UInt32(0), 4])
    func aTapFormatWithoutAWholeByteSampleSizeIsRefusedWithItsRealCauseBeforeAnythingIsAllocated(bits: UInt32) {
        let b = FakeBackend(); b.formatBits = bits
        var waitCalled = false
        let r = run(b) { _ in waitCalled = true }
        #expect(r.outcome.hasPrefix("failed at tap format: no whole-byte sample size"), "\(r.outcome)")
        #expect(r.outcome.contains("bitsPerChannel \(bits)") && r.notes.contains { $0.contains("\(bits) bits per channel") })
        let order = b.log
        #expect(!order.contains("prepareCapture") && !order.contains("createAggregate") && !order.contains("createIOProc") && !order.contains("start"))
        #expect(!r.calls.contains { $0.name == "allocate record buffer (control thread)" })        // not reported as an allocation failure
        #expect(!waitCalled && b.live.isEmpty && r.teardownClean && order.contains("destroyTap"))   // the tap that WAS created is destroyed
        #expect(r.tapFormat?.bitsPerChannel == bits)
    }

    @Test func aFailedStartDestroysTheIOProcTheAggregateAndTheTapInThatOrder() {
        let b = FakeBackend(); b.failing["start"] = -1
        _ = run(b)
        let tail = b.log.filter { ["destroyIOProc", "destroyAggregate", "destroyTap"].contains($0) }
        #expect(tail == ["destroyIOProc", "destroyAggregate", "destroyTap"])
    }

    @Test func theStatusCodeOfAFailureIsRecordedWithItsNameAndCode() throws {
        let b = FakeBackend(); b.failing["createAggregate"] = Int32(bitPattern: FourCC.value("!hog"))
        let r = run(b)
        let c = try #require(r.calls.first { $0.name == "AudioHardwareCreateAggregateDevice" })
        #expect(c.status == Int32(bitPattern: FourCC.value("!hog")) && c.statusFourCC == "!hog" && c.statusName == "kAudioDevicePermissionsError")
        #expect(r.outcome == "failed at AudioHardwareCreateAggregateDevice")
    }

    @Test func aFailedDestroyDoesNotSkipTheOthersAndTheTeardownIsNotClean() {
        let b = FakeBackend(); b.failing["destroyAggregate"] = Int32(bitPattern: FourCC.value("what"))
        let r = run(b)
        #expect(b.log.contains("destroyTap"))                                   // best effort: the tap is still destroyed
        #expect(!r.teardownClean && r.notes.contains { $0.contains("non-zero status") })
    }

    @Test func aDestroyStatusAloneMakesTheTeardownNotCleanEvenIfTheListsLookEmpty() {
        for call in ["destroyTap", "destroyAggregate"] {
            let b = FakeBackend()
            b.failing[call] = Int32(bitPattern: FourCC.value("what"))
            b.goneDespiteFailure = [call]                       // the object really is gone from the lists; only the status says it failed
            let r = run(b)
            #expect(r.lists.aggregateListedAfter == false && r.lists.tapListedAfter == false && r.lists.settleSeconds != nil, "\(call): lists should look clean")
            #expect(!r.teardownClean, "\(call): a non-zero destroy status must not be called clean")
            #expect(r.notes.contains { $0.contains("non-zero status") } && !r.notes.contains { $0.contains("could NOT be verified") })
        }
    }

    @Test func destructionThatNeverShowsInTheListsIsBoundedByTheClockNotAHang() {
        let b = FakeBackend(); b.readsUntilGone = .max
        let time = FakeTime()
        let r = run(b, time: time, limit: 0.5)
        #expect(!r.teardownClean && r.lists.settleSeconds == nil && r.lists.aggregateListedAfter == true)
        #expect(r.lists.settlePolls == 51)                                      // 0.5 s limit / 0.01 s polls, plus the first read
        #expect(time.sleeps == 50 && r.notes.contains { $0.contains("could NOT be verified") })
    }

    @Test func theAsynchronousDestroyIsPolledUntilTheObjectsLeaveTheLists() {
        let b = FakeBackend(); b.readsUntilGone = 3
        let time = FakeTime()
        let r = run(b, time: time)
        #expect(r.teardownClean && r.lists.settlePolls == 4)                    // three reads still show it, the fourth does not
        #expect(abs((r.lists.settleSeconds ?? -1) - 0.03) < 1e-9 && time.sleeps == 3)
    }

    @Test func aRefusalCreatesNothingAndSaysWhy() {
        let b = FakeBackend(); b.refusal = "the default output device has 1 input channel(s)"
        var waitCalled = false
        let r = run(b) { _ in waitCalled = true }
        #expect(r.outcome == "refused: the default output device has 1 input channel(s)")
        #expect(!b.log.contains("createTap") && !waitCalled && b.live.isEmpty && r.teardownClean)
        #expect(r.notes.contains { $0.contains("Refused before creating anything") })
    }

    @Test func aStopRequestEndsTheRunEarlyAndStillTearsDown() {
        let b = FakeBackend()
        let r = run(b, reason: .signal)
        #expect(r.stoppedBy == "signal" && r.outcome == "ok" && r.teardownClean && b.live.isEmpty)
    }

    @Test func withoutAnAudioProcessObjectNothingIsExcludedAndTheReportSaysSo() {
        let b = FakeBackend(); b.ownObject = 0
        let r = run(b)
        #expect(b.excludedSeen.isEmpty && r.excludedProcessObjects.isEmpty && r.ownProcessObjectID == nil)
        #expect(r.notes.contains { $0.contains("no audio process object") } && r.outcome == "ok")
    }

    @Test func silenceAndMissingCallbacksAreSaidOutLoudNotHidden() {
        let silent = FakeBackend(); silent.records = (0..<20).map { k in rec(5000 + UInt64(k) * 100, peak: 0, rms: 0) }
        #expect(run(silent).notes.contains { $0.contains("SILENT") && $0.contains("protected") })
        let none = FakeBackend()
        #expect(run(none).notes.contains { $0.contains("no callback ran") })
    }

    @Test func theRecordBufferIsSizedFromTheRunTimeAndCapped() {
        #expect(TapProbeRunner.recordCapacity(forSeconds: 10) == 10_000 + 4096)
        #expect(TapProbeRunner.recordCapacity(forSeconds: 0) == 1000 + 4096)
        #expect(TapProbeRunner.recordCapacity(forSeconds: 1_000_000) == 600_000 + 4096)
    }
}

@Suite struct TapProbeReportTests {
    func report(source: String = "fake") -> TapProbeReport {
        let b = FakeBackend(); b.records = (0..<30).map { k in rec(5000 + UInt64(k) * 100, peak: 0.3, rms: 0.1) }
        let t = FakeTime()
        var r = TapProbeRunner.run(backend: b, environment: TapProbeEnvironment(createdAt: "2026-11-05T12:00:00Z", macOSVersion: "27.2", hardwareModel: "Mac16,12", ownPID: 99, requestedSeconds: 5),
                                   clock: TapProbeClock(now: { t.t }, sleep: { t.t += $0 })) { _ in .timeout }
        r.source = source
        return r
    }

    @Test func jsonRoundTripsAndContainsNoNaN() throws {
        let r = report()
        let data = try r.jsonData()
        #expect(try TapProbeReport.decode(data) == r)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("NaN") && !text.lowercased().contains("infinity") && text.count < 100_000)
    }

    @Test func markdownHasTheSectionsAndTheSimulatedBannerOnlyForSimulatedSources() {
        let real = report(source: "coreAudioTap").markdown()
        for needle in ["# SpatialAudio system-audio tap probe (Step 6a)", "## 1. Format of the tap", "## 2. Callbacks", "## 3. Every Core Audio call and its status",
                       "## 4. Devices, clocks and rates", "What this does and does not show", "## 5. Teardown", "Float32 non-interleaved", "Frames per callback", "Callback interval", "mute behavior unmuted", "## Assumptions and limits"] {
            #expect(real.contains(needle), "missing \(needle)")
        }
        #expect(!real.contains("SIMULATED SOURCE"))
        let sim = report(source: "simulated")
        #expect(sim.isSimulated && sim.markdown().contains("SIMULATED SOURCE"))
        #expect(!real.contains("NaN") && real.range(of: #"(?i)\binf\b"#, options: .regularExpression) == nil)
    }

    @Test func theSecondTableIsCappedButTheJSONKeepsEverySecond() {
        var r = report()
        let seconds = (0..<300).map { TapSecondStats(second: $0, callbacks: 1, frames: 1, peak: 0.1, rms: 0.05, peakDBFS: -20, rmsDBFS: -26, silent: false) }
        r.stats?.perSecond = seconds
        let md = r.markdown(maxSecondRows: 120)
        #expect(md.contains("first 120 of 300 seconds") && md.split(separator: "\n").filter { $0.hasPrefix("| ") && $0.contains("| no |") }.count == 120)
        #expect(r.stats?.perSecond.count == 300)
    }

    @Test func fileNamesFollowTheReportNamingRulesAndSimulatedOnesAreMarked() {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let tz = TimeZone(identifier: "UTC")!
        let real = TapProbeReport.fileStem(date: date, timeZone: tz, simulated: false)
        let sim = TapProbeReport.fileStem(date: date, timeZone: tz, simulated: true)
        #expect(real.hasPrefix("tapprobe-") && !real.contains("SIMULATED") && sim == real + "-SIMULATED")
        #expect(real.range(of: #"^tapprobe-\d{8}-\d{6}$"#, options: .regularExpression) != nil)
    }
}
