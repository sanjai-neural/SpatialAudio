import CoreAudio
import CTapProbe
import Foundation
import Testing
import SpatialAudioCore
@testable import SpatialAudioEngine

// Step 6a. The C callback (CTapProbe) fed with synthetic AudioBufferLists, and the simulated backend run through the real sequencer.
// Everything here is SIMULATED input: it checks the measuring code, never anything about a real Mac. No verdict depends on a clock
// (the burst source has an exact synthetic timeline); the one threaded test waits on a completion condition.

/// Builds an AudioBufferList whose buffers hold the given float samples (`nil` = a buffer with mData == NULL of that many samples),
/// calls the C callback once on it, and frees everything.
private func callback(_ probe: OpaquePointer, buffers: [[Float]?], sampleCounts: [Int]? = nil, channelsPerBuffer: UInt32 = 1,
                      byteSizeOverride: UInt32? = nil, host: UInt64 = 1000) {
    let abl = AudioBufferList.allocate(maximumBuffers: max(buffers.count, 1))
    var memory: [UnsafeMutableRawPointer] = []
    abl.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(buffers.count)
    for (i, b) in buffers.enumerated() {
        let count = b?.count ?? (sampleCounts?[i] ?? 0)
        var data: UnsafeMutableRawPointer?
        if let b {
            let mem = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1) * 4, alignment: 16)
            memory.append(mem)
            b.withUnsafeBytes { if count > 0 { mem.copyMemory(from: $0.baseAddress!, byteCount: count * 4) } }
            data = mem
        }
        abl[i] = AudioBuffer(mNumberChannels: channelsPerBuffer, mDataByteSize: byteSizeOverride ?? UInt32(count * 4), mData: data)
    }
    var now = AudioTimeStamp(); now.mHostTime = host
    var inputTime = now, outputTime = AudioTimeStamp()
    var output = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer())
    _ = SATapProbeIOProc(0, &now, abl.unsafePointer, &inputTime, &output, &outputTime, UnsafeMutableRawPointer(probe))
    free(abl.unsafeMutablePointer)
    memory.forEach { $0.deallocate() }
}

private func record(_ probe: OpaquePointer, _ index: UInt32 = 0) -> SATapProbeRecord {
    var r = SATapProbeRecord()
    #expect(SATapProbeReadRecord(probe, index, &r))
    return r
}

@Suite struct CTapProbeCallbackTests {
    @Test func theRecordIsThirtyTwoBytesAsDocumented() {
        #expect(MemoryLayout<SATapProbeRecord>.size == 32)
    }

    @Test func nonInterleavedStereoFramesLevelsAndHostTime() throws {
        let p = try #require(SATapProbeCreate(8, 4, true)); defer { SATapProbeFree(p) }
        callback(p, buffers: [[0.5, -0.25, 0, 0.1], [-0.75, 0.2, 0.3, 0]], host: 123_456)
        let r = record(p)
        #expect(r.frames == 4 && r.samples == 8 && r.hostTime == 123_456 && r.flags == 0)      // one buffer per channel: frames = bytes / 4
        #expect(r.peak == 0.75)
        let expected = [0.5, -0.25, 0, 0.1, -0.75, 0.2, 0.3, 0].map { Double(Float($0)) * Double(Float($0)) }.reduce(0, +)
        #expect(abs(r.sumSquares - expected) < 1e-12)
        #expect(SATapProbeCommitted(p) == 1 && SATapProbeDropped(p) == 0)
    }

    @Test func interleavedStereoDividesByTheChannelsInTheBuffer() throws {
        let p = try #require(SATapProbeCreate(8, 4, true)); defer { SATapProbeFree(p) }
        callback(p, buffers: [[0.5, -0.5, 0.25, -0.25, 0.1, -0.1, 0, 0]], channelsPerBuffer: 2)
        let r = record(p)
        #expect(r.frames == 4 && r.samples == 8 && r.peak == 0.5)
    }

    @Test func nanAndInfinityAreFlaggedAndLeftOutOfEverything() throws {
        let p = try #require(SATapProbeCreate(8, 4, true)); defer { SATapProbeFree(p) }
        callback(p, buffers: [[0.5, .nan, .infinity, -0.25, -.infinity]])
        let r = record(p)
        #expect(r.flags == SA_TAP_FLAG_NON_FINITE_SAMPLE)
        #expect(r.peak == 0.5 && r.samples == 2 && r.frames == 5)                           // RMS is over the 2 finite samples, not 5
        #expect(abs(r.sumSquares - (0.25 + 0.0625)) < 1e-12)
    }

    @Test func aBufferWithoutDataIsFlaggedAndSkippedButItsSizeStillCountsAsFrames() throws {
        let p = try #require(SATapProbeCreate(8, 4, true)); defer { SATapProbeFree(p) }
        callback(p, buffers: [nil, [0.5, 0.5]], sampleCounts: [6, 0])
        let r = record(p)
        #expect(r.flags == SA_TAP_FLAG_NULL_BUFFER && r.frames == 6 && r.samples == 2 && r.peak == 0.5)
    }

    @Test func aNonFloatFormatCountsFramesFromTheByteSizeAndComputesNoLevels() throws {
        let p = try #require(SATapProbeCreate(8, 2, false)); defer { SATapProbeFree(p) }      // 16-bit samples
        callback(p, buffers: [[1, 2, 3, 4]], channelsPerBuffer: 2)                              // 16 bytes / (2 bytes x 2 channels) = 4 frames
        let r = record(p)
        #expect(r.flags == SA_TAP_FLAG_UNSUPPORTED_FORMAT && r.frames == 4 && r.samples == 0 && r.peak == 0 && r.sumSquares == 0)
    }

    @Test func aFloatFormatThatIsNotThirtyTwoBitIsNotTreatedAsFloat32() throws {
        let p = try #require(SATapProbeCreate(8, 8, true)); defer { SATapProbeFree(p) }       // 64-bit float claimed: not supported
        callback(p, buffers: [[0.5, 0.5, 0.5, 0.5]], channelsPerBuffer: 1)
        let r = record(p)
        #expect(r.flags == SA_TAP_FLAG_UNSUPPORTED_FORMAT && r.frames == 2 && r.samples == 0)
    }

    @Test func noBuffersAndEmptyBuffersAreHandled() throws {
        let p = try #require(SATapProbeCreate(8, 4, true)); defer { SATapProbeFree(p) }
        callback(p, buffers: [])
        #expect(record(p, 0).flags == SA_TAP_FLAG_NO_BUFFERS && record(p, 0).frames == 0)
        callback(p, buffers: [[]])
        let r = record(p, 1)
        #expect(r.flags == 0 && r.frames == 0 && r.samples == 0 && r.peak == 0)
    }

    @Test func anUnknownSampleSizeGivesNoFrames() throws {
        let p = try #require(SATapProbeCreate(8, 0, false)); defer { SATapProbeFree(p) }
        callback(p, buffers: [[1, 2, 3, 4]])
        #expect(record(p).frames == 0)
    }

    @Test func aFullBufferDropsAndCountsInsteadOfOverwriting() throws {
        let p = try #require(SATapProbeCreate(3, 4, true)); defer { SATapProbeFree(p) }
        for k in 0..<5 { callback(p, buffers: [[Float(k + 1) / 10]], host: UInt64(1000 + k)) }
        #expect(SATapProbeCommitted(p) == 3 && SATapProbeDropped(p) == 2 && SATapProbeCapacity(p) == 3)
        #expect((0..<3).map { record(p, UInt32($0)).hostTime } == [1000, 1001, 1002])          // the first three survive
        var r = SATapProbeRecord()
        #expect(!SATapProbeReadRecord(p, 3, &r))                                              // never published
    }

    @Test func recordsAreReadableOnlyAfterTheyArePublishedAndInOrder() throws {
        let p = try #require(SATapProbeCreate(4, 4, true)); defer { SATapProbeFree(p) }
        var r = SATapProbeRecord()
        #expect(!SATapProbeReadRecord(p, 0, &r) && SATapProbeCommitted(p) == 0)
        for k in 0..<3 { callback(p, buffers: [[0.5]], host: UInt64(10 * (k + 1))) }
        #expect((0..<3).map { record(p, UInt32($0)).hostTime } == [10, 20, 30])
    }

    @Test func creationRejectsAZeroCapacityAndFreeingNothingIsSafe() {
        #expect(SATapProbeCreate(0, 4, true) == nil)
        SATapProbeFree(nil)                         // the only call in the API that accepts NULL
    }

    @Test func manySamplesAccumulateInDoublePrecision() throws {
        let p = try #require(SATapProbeCreate(2, 4, true)); defer { SATapProbeFree(p) }
        callback(p, buffers: [Array(repeating: Float(0.5), count: 100_000)])
        let r = record(p)
        #expect(r.samples == 100_000 && abs(r.sumSquares - 25_000) < 1e-6)
    }
}

// MARK: - The simulated backend through the real sequencer

private final class TestTime: @unchecked Sendable { var t = 0.0 }

@Suite struct SimulatedTapBackendTests {
    let env = TapProbeEnvironment(createdAt: "2026-11-05T12:00:00Z", macOSVersion: "27.2", hardwareModel: "Mac16,12", ownPID: 99, requestedSeconds: 4)

    func run(callbacks: Int = 300, format: TapFormat = SimulatedTapBackend.stereoFloat48k, amplitude: Float = 0.25, readsUntilGone: Int = 2) -> TapProbeReport {
        let backend = SimulatedTapBackend(pacing: .burst(callbacks: callbacks), format: format, amplitude: amplitude, readsUntilGone: readsUntilGone)
        let time = TestTime()
        return TapProbeRunner.run(backend: backend, environment: env, clock: TapProbeClock(now: { time.t }, sleep: { time.t += $0 })) { _ in .timeout }
    }

    @Test func aBurstRunIsCountedExactlyAndLabelledSimulated() throws {
        let r = run()
        #expect(r.isSimulated && r.source == "simulated" && r.outcome == "ok" && r.teardownClean && r.stoppedBy == "timeout")
        let s = try #require(r.stats)
        #expect(s.callbackCount == 300 && s.dropped == 0 && s.totalFrames == 300 * 512)
        let fr = try #require(s.framesPerCallback)
        #expect(fr.min == 512 && fr.median == 512 && fr.max == 512)
        let iv = try #require(s.callbackIntervalMs)
        let expected = 512.0 / 48_000 * 1000                                                    // 10.6667 ms on the exact synthetic timeline
        #expect(abs(iv.median - expected) < 0.001 && abs(iv.min - expected) < 0.001 && abs(iv.max - expected) < 0.001)
        #expect(s.perSecond.map(\.callbacks).reduce(0, +) == 300 && s.perSecond.count == 4)
        #expect(abs((s.impliedFramesPerSecond ?? 0) - 48_000) < 1)
        #expect(r.hostTicksPerSecond == 1_000_000_000)
    }

    @Test func aSineOfAmplitudeQuarterReadsAsQuarterPeakAndItsRms() throws {
        let s = try #require(run().stats)
        #expect(s.peak > 0.24 && s.peak <= 0.25)
        let rms = try #require(s.rms)
        #expect(abs(rms - 0.25 / 2.0.squareRoot()) < 0.002)
        #expect(s.silentSeconds == 0 && s.flagCounts.isEmpty)
    }

    @Test func theFormatTravelsThroughTheChain() throws {
        let f = try #require(run().tapFormat)
        #expect(f == SimulatedTapBackend.stereoFloat48k && f.sampleFormatDescription == "Float32 non-interleaved" && f.channelsPerFrame == 2 && f.sampleRate == 48_000)
    }

    @Test func silenceIsRecordedAsSilenceAndSaidOutLoud() throws {
        let r = run(amplitude: 0)
        let s = try #require(r.stats)
        #expect(s.peak == 0 && s.silentSeconds == s.perSecond.count && !s.perSecond.isEmpty)
        #expect(r.notes.contains { $0.contains("SILENT") && $0.contains("protected") })
    }

    @Test func aNonFloatTapIsFlaggedOnEveryCallbackAndNeverCalledSilent() throws {
        let sint16 = TapFormat(sampleRate: 48_000, formatID: "lpcm", formatFlags: 0x0C, bytesPerPacket: 4, framesPerPacket: 1, bytesPerFrame: 4, channelsPerFrame: 2, bitsPerChannel: 16)
        let r = run(callbacks: 100, format: sint16)
        let s = try #require(r.stats)
        #expect(s.flagCounts == ["unsupported format": 100] && s.silentSeconds == 0 && s.rms == nil)
        #expect(s.framesPerCallback?.median == 512 && r.tapFormat?.sampleFormatDescription == "SInt16 interleaved")
        #expect(r.notes.contains { $0.contains("measurement flags") })
    }

    @Test func anInterleavedFloatTapGivesTheSameFramesAndLevels() throws {
        let f = TapFormat(sampleRate: 48_000, formatID: "lpcm", formatFlags: 0x09, bytesPerPacket: 8, framesPerPacket: 1, bytesPerFrame: 8, channelsPerFrame: 2, bitsPerChannel: 32)
        let s = try #require(run(callbacks: 100, format: f).stats)
        #expect(s.framesPerCallback?.median == 512 && s.totalFrames == 51_200 && s.peak > 0.24 && s.flagCounts.isEmpty)
    }

    @Test func theAsynchronousDestroyIsPolledAndTheTeardownIsVerified() {
        let r = run(readsUntilGone: 2)
        #expect(r.lists.settlePolls == 3 && r.lists.aggregateListedDuring == true && r.lists.tapListedDuring == true)
        #expect(r.lists.aggregateListedAfter == false && r.lists.tapListedAfter == false && r.lists.devicesBefore == 3 && r.lists.tapsBefore == 0)
    }

    @Test func aBurstRunIsDeterministic() {
        #expect(run().stats == run().stats)
    }

    @Test func theReportRoundTripsAndCarriesTheBanner() throws {
        let r = run(callbacks: 50)
        #expect(try TapProbeReport.decode(r.jsonData()) == r)
        #expect(r.markdown().contains("SIMULATED SOURCE"))
    }

    @Test func aRealTimeSourceDeliversCallbacksUntilStoppedAndStopJoinsTheThread() async throws {
        let b = SimulatedTapBackend(pacing: .realTime)
        struct Box: @unchecked Sendable { let backend: SimulatedTapBackend }      // read from the polling closure; the thread-safety is the C buffer's
        let box = Box(backend: b)
        let tap = b.createTap(excludingProcessObjects: [])
        #expect(tap.status == 0 && b.prepareCapture(format: SimulatedTapBackend.stereoFloat48k, capacity: 4096))
        let agg = b.createAggregate(tapUID: "x")
        #expect(b.createIOProc(on: agg.device) == 0 && b.start(agg.device) == 0)
        // Wait on a completion condition (5 callbacks seen); the deadline only bounds how long to wait before failing.
        let sawFive = await waitUntil { box.backend.collect().records.count >= 5 }
        #expect(sawFive)
        #expect(b.stop(agg.device) == 0)
        let a = b.collect(), c = b.collect()
        #expect(a.records == c.records && a.records.count >= 5)                    // the thread is joined: nothing changes any more
        #expect(a.records.map(\.hostTime) == a.records.map(\.hostTime).sorted() && a.records.allSatisfy { $0.frames == 512 && $0.peak <= 0.25 })
        #expect(a.hostTicksPerSecond == AudioGetHostClockFrequency())
    }
}

@Suite struct TapProbeCommandTests {
    @Test func theRunTimeIsValidated() {
        #expect(TapProbeCommand.validate(seconds: 10) == nil && TapProbeCommand.validate(seconds: 600) == nil && TapProbeCommand.validate(seconds: 0.5) == nil)
        #expect(TapProbeCommand.validate(seconds: 0) != nil && TapProbeCommand.validate(seconds: -3) != nil)
        #expect(TapProbeCommand.validate(seconds: .nan) != nil && TapProbeCommand.validate(seconds: .infinity) != nil)
        #expect(TapProbeCommand.validate(seconds: 601) != nil)
    }
}
