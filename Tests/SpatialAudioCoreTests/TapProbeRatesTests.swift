import Testing
import Foundation
@testable import SpatialAudioCore

// Step 6a2. Device facts, the rate series and the 10 s cadence windows. Pure logic with exact arithmetic and the fake backend; no Core Audio and no clock.

/// 1000 host ticks per second; a callback every `every` ticks (10 = 10 ms) for `count` callbacks starting at tick 5000.
private func cadence(count: Int, every: UInt64 = 10, frames: UInt32 = 480) -> [TapProbeRecord] {
    (0..<count).map { k in TapProbeRecord(hostTime: 5000 + UInt64(k) * every, sumSquares: 0.01, frames: frames, samples: 960, peak: 0.1, flags: 0) }
}

@Suite struct TapWindowTests {
    @Test func aSteadyDeclaredRateGivesExactlyTheDeclaredRateInEveryWindow() throws {
        let st = TapProbeAggregator.summarize(records: cadence(count: 2500), dropped: 0, hostTicksPerSecond: 1000, declaredRate: 48_000)
        #expect(st.windows.map(\.startSecond) == [0, 10, 20] && st.windows.map(\.callbacks) == [1000, 1000, 500] && st.windows.map(\.frames) == [480_000, 480_000, 240_000])
        #expect(st.windows.map(\.complete) == [true, true, false])
        for w in st.windows {
            let implied = try #require(w.impliedFramesPerSecond), ppm = try #require(w.impliedVsDeclaredPPM), off = try #require(w.cumulativeFrameOffset)
            #expect(abs(implied - 48_000) < 1e-6 && abs(ppm) < 1e-6 && abs(off) < 1e-6, "window \(w.startSecond): \(implied) \(ppm) \(off)")
        }
        #expect(abs(st.windows[0].spanSeconds - 9.99) < 1e-9)
    }

    @Test func aRateOffsetShowsInPPMAndGrowsLinearlyInTheCumulativeOffset() throws {
        // 481 frames per 10 ms is 48,100 frames/s against a declared 48,000.
        let st = TapProbeAggregator.summarize(records: cadence(count: 2500, frames: 481), dropped: 0, hostTicksPerSecond: 1000, declaredRate: 48_000)
        let expectedPPM = (48_100.0 / 48_000 - 1) * 1e6
        for w in st.windows {
            let ppm = try #require(w.impliedVsDeclaredPPM)
            #expect(abs(ppm - expectedPPM) < 1e-6)
        }
        // the frames the tap is ahead by equal the number of callbacks before the window's last one (1 frame per callback here)
        #expect(st.windows.map { $0.cumulativeFrameOffset.map { ($0 * 1000).rounded() / 1000 } } == [999, 1999, 2499])
    }

    @Test func aTapThatRunsSlowShowsNegativePPMAndANegativeOffset() throws {
        let st = TapProbeAggregator.summarize(records: cadence(count: 1500, frames: 479), dropped: 0, hostTicksPerSecond: 1000, declaredRate: 48_000)
        let ppm = try #require(st.windows[0].impliedVsDeclaredPPM), offset = try #require(st.windows[1].cumulativeFrameOffset)
        #expect(ppm < 0 && offset < -1000)
    }

    @Test func aCallbackExactlyOnAWindowBoundaryStartsTheNextWindow() {
        let recs = [5000, 5000 + 9990, 5000 + 10_000, 5000 + 10_010].map { TapProbeRecord(hostTime: UInt64($0), sumSquares: 0, frames: 480, samples: 0, peak: 0, flags: 0) }
        let st = TapProbeAggregator.summarize(records: recs, dropped: 0, hostTicksPerSecond: 1000, declaredRate: 48_000)
        #expect(st.windows.map(\.callbacks) == [2, 2] && st.windows.map(\.startSecond) == [0, 10])
    }

    @Test func withoutADeclaredRateTheCadenceStaysButThePPMAndTheOffsetAreEmpty() throws {
        let st = TapProbeAggregator.summarize(records: cadence(count: 1200), dropped: 0, hostTicksPerSecond: 1000)
        #expect(st.windows.count == 2 && st.windows.allSatisfy { $0.impliedVsDeclaredPPM == nil && $0.cumulativeFrameOffset == nil })
        let implied = try #require(st.windows[0].impliedFramesPerSecond)
        #expect(abs(implied - 48_000) < 1e-6)
    }

    @Test func aWindowWithOneCallbackHasNoImpliedRateAndAGapLeavesAVisibleJumpInStartSeconds() {
        let recs = [5000, 5000 + 35_000].map { TapProbeRecord(hostTime: UInt64($0), sumSquares: 0, frames: 480, samples: 0, peak: 0, flags: 0) }
        let st = TapProbeAggregator.summarize(records: recs, dropped: 0, hostTicksPerSecond: 1000, declaredRate: 48_000)
        #expect(st.windows.map(\.startSecond) == [0, 30])                              // windows 10 and 20 had no callbacks: they are absent, the jump shows it
        #expect(st.windows.allSatisfy { $0.impliedFramesPerSecond == nil && $0.callbacks == 1 })
    }

    @Test func noClockOrNoRecordsMeansNoWindows() {
        #expect(TapProbeAggregator.summarize(records: cadence(count: 50), dropped: 0, hostTicksPerSecond: 0, declaredRate: 48_000).windows.isEmpty)
        #expect(TapProbeAggregator.summarize(records: [], dropped: 0, hostTicksPerSecond: 1000, declaredRate: 48_000).windows.isEmpty)
    }

    @Test func theWindowLengthIsAParameter() {
        let st = TapProbeAggregator.summarize(records: cadence(count: 1000), dropped: 0, hostTicksPerSecond: 1000, declaredRate: 48_000, windowSeconds: 4)
        #expect(st.windows.map(\.startSecond) == [0, 4, 8] && st.windows.map(\.callbacks) == [400, 400, 200])
    }
}

@Suite struct TapDeviceFactsTests {
    @Test func transportNamesComeFromTheHeaderAndUnknownCodesStayNameless() {
        #expect(TapDeviceTransport.name(FourCC.value("bltn")) == "kAudioDeviceTransportTypeBuiltIn")
        #expect(TapDeviceTransport.name(FourCC.value("blue")) == "kAudioDeviceTransportTypeBluetooth")
        #expect(TapDeviceTransport.name(FourCC.value("usb ")) == "kAudioDeviceTransportTypeUSB")
        #expect(TapDeviceTransport.name(0) == "kAudioDeviceTransportTypeUnknown")
        #expect(TapDeviceTransport.name(FourCC.value("zzzz")) == nil)
    }

    @Test func onlyNonZeroStatusesAreFailedReadsAndTheyAreSorted() {
        let f = TapDeviceFacts(role: "x", statuses: ["b": 0, "z": -1, "a": 5, "c": 0])
        #expect(f.failedReads == ["a", "z"])
        #expect(TapDeviceFacts(role: "y").failedReads.isEmpty)
    }
}

@Suite struct TapProbeRatesRunnerTests {
    let env = TapProbeEnvironment(createdAt: "2026-11-06T12:00:00Z", macOSVersion: "27.2", hardwareModel: "Mac16,12", ownPID: 99, requestedSeconds: 25)

    func steady(_ n: Int = 2500, frames: UInt32 = 480) -> [TapProbeRecord] { cadence(count: n, frames: frames) }

    func run(_ b: FakeBackend, seconds: Double = 25, window: Double = 10, time: FakeTime = FakeTime(), reasons: [TapProbeStopReason] = [], waits: ((Double) -> Void)? = nil) -> TapProbeReport {
        var e = env; e.requestedSeconds = seconds
        var i = 0
        return TapProbeRunner.run(backend: b, environment: e, clock: TapProbeClock(now: { time.t }, sleep: { time.t += $0 }), windowSeconds: window) { s in
            waits?(s); time.t += s                                  // the run takes the time it waits (fake time, no real waiting)
            defer { i += 1 }
            return i < reasons.count ? reasons[i] : .timeout
        }
    }

    @Test func theRunWaitsInSlicesAndSamplesTheRatesAtTheStartAndAfterEverySlice() {
        let b = FakeBackend(); b.records = steady(); b.actualRates = [(48_000.5, 48_000.25), (48_000.6, 48_000.25), (48_000.7, nil), (48_000.8, 48_000.25)]
        var waited: [Double] = []
        let r = run(b) { waited.append($0) }
        #expect(waited == [10, 10, 5])
        #expect(r.rateSamples.map(\.elapsedSeconds) == [0, 10, 20, 25] && r.elapsedSeconds == 25 && r.stoppedBy == "timeout")
        #expect(r.rateSamples.map(\.outputActualRate) == [48_000.5, 48_000.6, 48_000.7, 48_000.8] && r.rateSamples.map(\.aggregateActualRate) == [48_000.25, 48_000.25, nil, 48_000.25])
        #expect(b.log.filter { $0 == "sampleActualRates" }.count == 4)
    }

    @Test func aShortRunIsOneSliceAndASignalEndsTheRunAtTheSliceBoundary() {
        var waited: [Double] = []
        let one = run(FakeBackend(), seconds: 5) { waited.append($0) }
        #expect(waited == [5] && one.rateSamples.count == 2)
        waited = []
        let b = FakeBackend()
        let sig = run(b, reasons: [.timeout, .signal]) { waited.append($0) }
        #expect(waited == [10, 10] && sig.stoppedBy == "signal" && sig.rateSamples.count == 3 && sig.outcome == "ok" && sig.teardownClean)
    }

    @Test func theWindowLengthIsPassedOnToTheSlicesAndTheAggregator() {
        var waited: [Double] = []
        let b = FakeBackend(); b.records = cadence(count: 1000)
        let r = run(b, seconds: 10, window: 4) { waited.append($0) }
        #expect(waited == [4, 4, 2] && r.stats?.windows.map(\.startSecond) == [0, 4, 8])
    }

    @Test func theOutputFactsAreReadBeforeAnythingIsCreatedAndTheAggregateFactsWhileItRuns() {
        let b = FakeBackend(); b.records = steady()
        let r = run(b)
        #expect(r.outputDevice == b.outFacts && r.aggregateDevice == b.aggFacts)
        let order = b.log
        let out = order.firstIndex(of: "outputDeviceFacts")!, tap = order.firstIndex(of: "createTap")!
        let agg = order.firstIndex(of: "aggregateDeviceFacts")!, start = order.firstIndex(of: "start")!, stop = order.firstIndex(of: "stop")!
        #expect(out < tap && start < agg && agg < stop)
    }

    @Test func aFailureBeforeTheStartStillHasTheOutputFactsButNoAggregateFacts() {
        for failing in ["createTap", "createAggregate", "start"] {
            let b = FakeBackend(); b.failing[failing] = -1
            let r = run(b)
            #expect(r.outputDevice != nil && r.aggregateDevice == nil, "\(failing)")
            #expect(!b.log.contains("aggregateDeviceFacts") && !b.log.contains("sampleActualRates") && r.rateSamples.isEmpty, "\(failing)")
        }
    }

    @Test func aRefusalStillReadsTheOutputDeviceFacts() {
        let b = FakeBackend(); b.refusal = "no"
        let r = run(b)
        #expect(r.outputDevice == b.outFacts && r.aggregateDevice == nil && b.log.contains("outputDeviceFacts"))
    }

    @Test func theRateComparisonPutsTheNumbersSideBySideAndAUnequalNominalRateIsNoted() throws {
        let b = FakeBackend(); b.records = steady()
        b.outFacts.nominalSampleRate = 44_100
        b.actualRates = [(48_000.5, nil), (48_000.7, nil), (48_000.9, nil), (48_001.1, nil)]
        let r = run(b)
        let c = try #require(r.rateComparison)
        #expect(c.tapDeclaredRate == 48_000 && c.outputNominalRate == 44_100 && c.declaredRatesEqual == false)
        let mean = (48_000.5 + 48_000.7 + 48_000.9 + 48_001.1) / 4
        let reportedMean = try #require(c.outputActualRateMean), implied = try #require(c.tapImpliedFramesPerSecond)
        let ppmDeclared = try #require(c.tapImpliedVsDeclaredPPM), ppmActual = try #require(c.tapImpliedVsOutputActualPPM)
        #expect(c.outputActualRateFirst == 48_000.5 && c.outputActualRateLast == 48_001.1 && abs(reportedMean - mean) < 1e-9)
        #expect(abs(implied - 48_000) < 1e-6 && abs(ppmDeclared) < 1e-6)
        #expect(abs(ppmActual - (implied / mean - 1) * 1e6) < 1e-6)
        #expect(r.notes.contains { $0.contains("differs from the output device's nominal rate") })
    }

    @Test func equalNominalRatesGiveNoNoteAndAnUnknownOutputRateGivesNoVerdict() throws {
        let eq = FakeBackend(); eq.records = steady()
        let r1 = run(eq)
        #expect(r1.rateComparison?.declaredRatesEqual == true && !r1.notes.contains { $0.contains("differs from the output device's nominal rate") })
        let unk = FakeBackend(); unk.records = steady(); unk.outFacts.nominalSampleRate = nil
        let r2 = run(unk)
        #expect(r2.rateComparison?.declaredRatesEqual == nil && r2.rateComparison?.outputActualRateMean == nil && r2.rateComparison?.tapImpliedVsOutputActualPPM == nil)
    }

    @Test func unreadableFactsDoNotFailTheRunAndAreNamed() {
        let b = FakeBackend(); b.records = steady()
        b.outFacts.statuses = ["kAudioDevicePropertyClockDomain": Int32(bitPattern: FourCC.value("who?"))]
        b.aggFacts.statuses = ["kAudioDevicePropertyLatency": -1]
        let r = run(b)
        #expect(r.outcome == "ok" && r.teardownClean)
        #expect(r.notes.contains { $0.contains("kAudioDevicePropertyClockDomain") && $0.contains("aggregate: kAudioDevicePropertyLatency") })
    }
}

@Suite struct TapProbeRatesReportTests {
    func report() -> TapProbeReport {
        let b = FakeBackend(); b.records = cadence(count: 2500)
        b.actualRates = [(48_000.5, 48_000.25), (48_000.6, 48_000.25)]
        let t = FakeTime()
        return TapProbeRunner.run(backend: b, environment: TapProbeEnvironment(createdAt: "2026-11-06T12:00:00Z", macOSVersion: "27.2", hardwareModel: "Mac16,12", ownPID: 9, requestedSeconds: 25),
                                  clock: TapProbeClock(now: { t.t }, sleep: { t.t += $0 })) { _ in .timeout }
    }

    @Test func theMarkdownCarriesTheFactsTheSeriesAndTheLimits() {
        let md = report().markdown()
        for needle in ["## 4. Devices, clocks and rates", "default output device: name **fake out**", "tap aggregate device: name **fake aggregate**", "transport 'bltn' (kAudioDeviceTransportTypeBuiltIn)",
                       "clock domain 7", "| window start (s) | callbacks | frames |", "| elapsed (s) | output ActualSampleRate (Hz) | aggregate ActualSampleRate (Hz) |",
                       "**What this does and does not show:**", "## 5. Teardown"] {
            #expect(md.contains(needle), "missing \(needle)")
        }
        for limit in TapProbeReport.clockLimits { #expect(md.contains(limit)) }
        #expect(!md.contains("NaN") && md.range(of: #"(?i)\binf\b"#, options: .regularExpression) == nil)
    }

    @Test func theClockStatementSaysWhatATapOnlyAggregateDoesNotTellUs() {
        let all = TapProbeReport.clockLimits.joined(separator: " ")
        for needle in ["NO sub-device and NO clock device", "does not decide that", "HOST clock", "does NOT show whether the tap and the output device share a clock",
                       "kAudioDevicePropertyClockDomain", "kAudioDevicePropertyActualSampleRate", "MEASURED SERIES", "A SIMULATED run supports none at all"] {
            #expect(all.contains(needle), "missing \(needle)")
        }
    }

    @Test func schemaTwoRoundTripsWithAllTheNewFields() throws {
        let r = report()
        #expect(r.schemaVersion == 2)
        let back = try TapProbeReport.decode(r.jsonData())
        #expect(back == r && back.outputDevice?.name == "fake out" && back.rateSamples.count == 4 && back.stats?.windows.count == 3 && back.rateComparison != nil)
        #expect(!String(decoding: try r.jsonData(), as: UTF8.self).contains("NaN"))
    }
}
