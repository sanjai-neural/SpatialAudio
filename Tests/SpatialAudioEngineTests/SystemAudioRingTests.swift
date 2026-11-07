import AVFoundation
import CoreAudio
import CSystemAudioRing
import Foundation
import Testing

// Step 6b-1. The ring, the producer IOProc and the two readers (CSystemAudioRing), seen from Swift: the same C functions the harnesses in scripts/ drive,
// here with synthetic AudioBufferLists. Everything is SIMULATED input and OFFLINE: it checks our code, nothing about a real tap, a real device or the
// real-time render path. No test uses a clock or a sleep. The threaded behaviour (a producer thread against two reader threads) is covered by the C
// stress harnesses (scripts/check-systemaudioring.sh, tsan-systemaudioring.sh), not here.

private func sample(_ ch: UInt32, _ j: Int64) -> Float {   // the same signal as scripts/systemaudioring_common.h: >= 1.0, distinct per channel and frame
    let h = UInt32(truncatingIfNeeded: j) &* 2654435761 &+ ch &* 40503 &+ 12345
    return Float((h >> 8) & 0xFFFFF) / 1024 + 1
}

private typealias NullableProducer = @convention(c) (UInt32, UnsafePointer<AudioTimeStamp>?, UnsafePointer<AudioBufferList>?, UnsafePointer<AudioTimeStamp>?,
                                                      UnsafeMutablePointer<AudioBufferList>?, UnsafePointer<AudioTimeStamp>?, UnsafeMutableRawPointer?) -> Int32
private let producerProc = unsafeBitCast(SARingIOProc as AudioDeviceIOProc, to: NullableProducer.self)

/// One producer callback with a hand-built list: `buffers` = (channels, byte size, data or nil), data copied into a 16-byte aligned block.
@discardableResult
private func callProducer(_ ring: OpaquePointer, buffers: [(channels: UInt32, byteSize: UInt32, data: [Float]?)], nullList: Bool = false, misalign: Bool = false) -> OSStatus {
    let abl = AudioBufferList.allocate(maximumBuffers: max(buffers.count, 1))
    abl.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(buffers.count)
    var memory: [UnsafeMutableRawPointer] = []
    for (i, b) in buffers.enumerated() {
        var data: UnsafeMutableRawPointer?
        if let d = b.data {
            let mem = UnsafeMutableRawPointer.allocate(byteCount: max(d.count, 1) * 4 + 16, alignment: 16)
            d.withUnsafeBytes { if d.count > 0 { mem.copyMemory(from: $0.baseAddress!, byteCount: d.count * 4) } }
            memory.append(mem)
            data = misalign ? mem + 1 : mem
        }
        abl[i] = AudioBuffer(mNumberChannels: b.channels, mDataByteSize: b.byteSize, mData: data)
    }
    var now = AudioTimeStamp()
    var out = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer())
    let status = withUnsafePointer(to: &now) { producerProc(0, $0, nullList ? nil : abl.unsafePointer, $0, &out, $0, UnsafeMutableRawPointer(ring)) }
    free(abl.unsafeMutablePointer)
    memory.forEach { $0.deallocate() }
    return status
}

@discardableResult
private func commit(_ ring: OpaquePointer, from j0: Int64, frames: Int) -> OSStatus {
    var d = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames { d[2 * i] = sample(0, j0 + Int64(i)); d[2 * i + 1] = sample(1, j0 + Int64(i)) }
    return callProducer(ring, buffers: [(2, UInt32(frames * 8), d)])
}

private struct Rendered { var status: OSStatus; var silent: Bool; var samples: [Float]; var canaryIntact: Bool }

/// One render call. `sampleTime: nil` passes a NULL timestamp; `valid: false` leaves kAudioTimeStampSampleTimeValid unset. `initSilent` is the value
/// the flag has before the call (pass the opposite of what is expected, so a block that never sets it is caught).
private func render(_ rd: OpaquePointer, _ F: Int, sampleTime: Double? = 0, valid: Bool = true, initSilent: Bool) -> Rendered {
    var buf = [Float](repeating: -777, count: F + 8)
    var silent = initSilent
    var ts = AudioTimeStamp()
    if let sampleTime { ts.mSampleTime = sampleTime; ts.mFlags = valid ? .sampleTimeValid : [] }
    let status: OSStatus = buf.withUnsafeMutableBytes { raw in
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(F * 4), mData: raw.baseAddress))
        return withUnsafePointer(to: &ts) { SARingRender(rd, &silent, sampleTime == nil ? nil : $0, UInt32(F), &list) }
    }
    return Rendered(status: status, silent: silent, samples: Array(buf[0..<F]), canaryIntact: buf[F...].allSatisfy { $0 == -777 })
}

private func snapshot(_ ring: OpaquePointer) -> SARingSnapshot { var s = SARingSnapshot(); #expect(SARingTakeSnapshot(ring, &s)); return s }
private func stats(_ s: SARingSnapshot, _ ch: Int) -> SARingReaderStats { ch == 0 ? s.reader.0 : s.reader.1 }
private func expectServed(_ r: Rendered, channel: UInt32, cursor: Int64, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(r.status == 0 && !r.silent && r.canaryIntact, "served block: status \(r.status) silent \(r.silent)", sourceLocation: sourceLocation)
    #expect(r.samples.enumerated().allSatisfy { $0.element == sample(channel, cursor + Int64($0.offset)) }, "served data differs from channel \(channel) frames from \(cursor)", sourceLocation: sourceLocation)
}
private func expectSilence(_ r: Rendered, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(r.status == 0 && r.silent && r.canaryIntact, "silent block: status \(r.status) silent \(r.silent)", sourceLocation: sourceLocation)
    #expect(r.samples.allSatisfy { $0 == 0 && $0.sign == .plus }, "a silent block must be all zeros (no stale data)", sourceLocation: sourceLocation)
}

@Suite struct SystemAudioRingTests {
    @Test func theGuessedConstantsAreTheNamedValuesFromTheBrief() {
        #expect(SA_RING_DEFAULT_CAPACITY_FRAMES == 32768 && SA_RING_DEFAULT_PRIME_CALLBACKS == 4)   // GUESSES (docs/ARCHITECTURE.md), not measurements
        #expect(SA_RING_CHANNELS == 2)
    }

    @Test func eachReaderGetsItsOwnChannelsFramesInEitherBlockOrderAndTheOrderChangesNothing() {
        var finals: [[SARingReaderStats]] = []
        for order in 0..<2 {
            let ring = SARingCreate(1024)!
            defer { SARingFree(ring) }
            var produced: Int64 = 0
            for _ in 0..<4 { commit(ring, from: produced, frames: 128); produced += 128 }
            #expect(SARingPrime(ring, 2))                                   // 2 x 128 behind: start at 256, below the 512-frame window of a 1024 ring
            let rd = [SARingGetReader(ring, 0)!, SARingGetReader(ring, 1)!]
            var cursor: Int64 = 256
            for cycle in 0..<40 {                                           // 40 x 128 frames = 5 laps, commits of 96 / 160 straddle the wrap
                let k = cycle % 2 == 0 ? 96 : 160
                commit(ring, from: produced, frames: k); produced += Int64(k)
                for step in 0..<2 {
                    let ch = order == 0 ? step : 1 - step
                    expectServed(render(rd[ch], 128, sampleTime: Double(1000 + cycle * 128), initSilent: true), channel: UInt32(ch), cursor: cursor)
                }
                cursor += 128
            }
            let s = snapshot(ring)
            for ch in 0..<2 {
                let x = stats(s, ch)
                #expect(x.calls == 40 && x.servedBlocks == 40 && x.servedFrames == 5120 && x.cursor == 5376 && x.fill == 256)
                #expect(x.underrunBlocks == 0 && x.overrunBlocks == 0 && x.tornBlocks == 0 && x.silentFrames == 0)
                #expect(x.phaseValidCalls == 40 && x.phaseSelfChanges == 0 && x.phaseMismatches == 0)
            }
            finals.append([stats(s, 0), stats(s, 1)])
        }
        for ch in 0..<2 { #expect(memcmp_equal(finals[0][ch], finals[1][ch]), "channel \(ch): counters differ between the two block orders") }
    }

    @Test func aBlockThatCannotBeFullyServedIsSilentTheCursorStillAdvancesAndAStarvedReaderStaysStarvedAtEqualRate() {
        let ring = SARingCreate(1024)!
        defer { SARingFree(ring) }
        var produced: Int64 = 0
        for _ in 0..<4 { commit(ring, from: produced, frames: 128); produced += 128 }
        #expect(SARingPrime(ring, 4))
        let l = SARingGetReader(ring, 0)!
        for c in 0..<4 { expectServed(render(l, 128, sampleTime: Double(c * 128), initSilent: true), channel: 0, cursor: Int64(c * 128)) }
        expectSilence(render(l, 128, sampleTime: 512, initSilent: false))
        var x = stats(snapshot(ring), 0)
        #expect(x.underrunBlocks == 1 && x.silentFrames == 128 && x.calls == 5 && x.cursor == 640 && x.fill == -128)   // advanced by exactly frameCount: now AHEAD of the producer
        for k in 0..<5 {                                                    // the producer commits 128 per block the reader asks for 128: still starved every time
            commit(ring, from: produced, frames: 128); produced += 128
            expectSilence(render(l, 128, sampleTime: Double(640 + k * 128), initSilent: false))
        }
        x = stats(snapshot(ring), 0)
        #expect(x.underrunBlocks == 6 && x.cursor == 1280 && x.fill == -128)
        for _ in 0..<3 { commit(ring, from: produced, frames: 128); produced += 128 }
        expectServed(render(l, 128, sampleTime: 1280, initSilent: true), channel: 0, cursor: 1280)   // recovered AT THE CURSOR: the late frames were dropped, never played late
        x = stats(snapshot(ring), 0)
        #expect(x.servedBlocks == 5 && x.underrunBlocks == 6 && x.calls == 11 && x.silentFrames == 768 && x.cursor == 1408 && x.fill == 128)
    }

    @Test func overrunUnderrunAndOversizeBoundariesOfAThousandAndTwentyFourRing() {
        // window = 1024 - 512 = 512. w - r == 512 is served, 513 is an overrun; F == 512 is served, 513 is oversize.
        let at = SARingCreate(1024)!, over = SARingCreate(1024)!, lapped = SARingCreate(1024)!, big = SARingCreate(1024)!, big2 = SARingCreate(1024)!
        defer { [at, over, lapped, big, big2].forEach { SARingFree($0) } }
        for i in 0..<4 { commit(at, from: Int64(i * 128), frames: 128); commit(over, from: Int64(i * 128), frames: 128) }
        commit(over, from: 512, frames: 1)
        expectServed(render(SARingGetReader(at, 0)!, 128, initSilent: true), channel: 0, cursor: 0)
        expectSilence(render(SARingGetReader(over, 1)!, 128, initSilent: false))
        var x = stats(snapshot(over), 1)
        #expect(x.overrunBlocks == 1 && x.servedBlocks == 0 && x.underrunBlocks == 0 && x.tornBlocks == 0)
        for i in 0..<8 { commit(lapped, from: Int64(i * 128), frames: 128) }
        let l = SARingGetReader(lapped, 0)!
        for _ in 0..<4 { expectSilence(render(l, 128, initSilent: false)) }          // w - r = 1024, 896, 768, 640: all overruns
        x = stats(snapshot(lapped), 0)
        #expect(x.overrunBlocks == 4 && x.cursor == 512 && x.silentFrames == 512)
        expectServed(render(l, 128, initSilent: true), channel: 0, cursor: 512)      // w - r == 512
        for i in 0..<8 { commit(big, from: Int64(i * 128), frames: 128); commit(big2, from: Int64(i * 128), frames: 128) }
        #expect(SARingPrime(big, 4) && SARingPrime(big2, 4))                          // start = 1024 - 512 = 512
        expectSilence(render(SARingGetReader(big, 0)!, 513, initSilent: false))      // oversize wins over every other reason, and still advances by 513
        x = stats(snapshot(big), 0)
        #expect(x.oversizeBlocks == 1 && x.underrunBlocks == 0 && x.overrunBlocks == 0 && x.silentFrames == 513 && x.cursor == 1025)
        expectServed(render(SARingGetReader(big2, 0)!, 512, initSilent: true), channel: 0, cursor: 512)   // F == window is served
    }

    @Test func unusableOutputListsWriteNothingReturnParamErrorAndStillAdvanceTheCursor() {
        let ring = SARingCreate(1024)!
        defer { SARingFree(ring) }
        for i in 0..<4 { commit(ring, from: Int64(i * 128), frames: 128) }
        let l = SARingGetReader(ring, 0)!
        let F = 128
        for variant in 0..<7 {
            var buf = [Float](repeating: -777, count: F + 16)
            var silent = true
            var ts = AudioTimeStamp(); ts.mFlags = .sampleTimeValid
            let status: OSStatus = buf.withUnsafeMutableBytes { raw in
                let abl = AudioBufferList.allocate(maximumBuffers: 2)
                defer { free(abl.unsafeMutablePointer) }
                abl.unsafeMutablePointer.pointee.mNumberBuffers = 2           // the subscript is bounds-checked against this: fill both slots first, then set the real count
                abl[0] = AudioBuffer(mNumberChannels: variant == 3 ? 2 : 1, mDataByteSize: variant == 6 ? UInt32(F * 4 - 1) : UInt32(F * 4),
                                     mData: variant == 4 ? nil : (variant == 5 ? raw.baseAddress! + 1 : raw.baseAddress))
                abl[1] = abl[0]
                abl.unsafeMutablePointer.pointee.mNumberBuffers = variant == 1 ? 0 : (variant == 2 ? 2 : 1)
                return withUnsafePointer(to: &ts) { SARingRender(l, &silent, $0, UInt32(F), variant == 0 ? nil : abl.unsafeMutablePointer) }
            }
            #expect(status == kAudio_ParamError && !silent, "variant \(variant): status \(status) silent \(silent)")
            #expect(buf.allSatisfy { $0 == -777 }, "variant \(variant): the output must not be touched")
        }
        let x = stats(snapshot(ring), 0)
        #expect(x.badBufferBlocks == 7 && x.calls == 7 && x.cursor == 7 * 128 && x.silentFrames == 0)
    }

    @Test func theProducerRefusesWhatItCannotReadCountsItAndWritesNothing() {
        let ring = SARingCreate(1024)!
        defer { SARingFree(ring) }
        let good = [Float](repeating: 0.5, count: 1200)
        let cases: [(String, UInt32, () -> Void)] = [
            ("NULL list", SA_RING_REJECT_NO_BUFFERS, { callProducer(ring, buffers: [], nullList: true) }),
            ("no buffers", SA_RING_REJECT_NO_BUFFERS, { callProducer(ring, buffers: []) }),
            ("two buffers", SA_RING_REJECT_BAD_LAYOUT, { callProducer(ring, buffers: [(2, 1024, good), (2, 1024, good)]) }),
            ("mono", SA_RING_REJECT_BAD_LAYOUT, { callProducer(ring, buffers: [(1, 1024, good)]) }),
            ("four channels", SA_RING_REJECT_BAD_LAYOUT, { callProducer(ring, buffers: [(4, 1024, good)]) }),
            ("NULL data", SA_RING_REJECT_NULL_DATA, { callProducer(ring, buffers: [(2, 1024, nil)]) }),
            ("misaligned", SA_RING_REJECT_MISALIGNED, { callProducer(ring, buffers: [(2, 1024, good)], misalign: true) }),
            ("partial frame", SA_RING_REJECT_PARTIAL, { callProducer(ring, buffers: [(2, 12, good)]) }),
            ("empty", SA_RING_REJECT_EMPTY, { callProducer(ring, buffers: [(2, 0, good)]) }),
            ("513 frames in a 1024 ring", SA_RING_REJECT_OVERSIZE, { callProducer(ring, buffers: [(2, 513 * 8, good + good)]) }),
        ]
        var flags: UInt32 = 0
        for (i, c) in cases.enumerated() {
            c.2()
            flags |= c.1
            let s = snapshot(ring)
            #expect(s.rejectedCommits == UInt64(i + 1) && s.rejectFlags == flags && s.w == 0 && s.commits == 0, "\(c.0): rejected \(s.rejectedCommits) flags \(s.rejectFlags) w \(s.w)")
        }
        #expect(producerProc(0, nil, nil, nil, nil, nil, nil) == 0)                  // NULL client data and everything else: returns, does nothing
        commit(ring, from: 0, frames: 128)
        let s = snapshot(ring)
        #expect(s.w == 128 && s.commits == 1 && s.lastCommitFrames == 128 && s.rejectedCommits == 10 && s.capacity == 1024 && s.maxCommit == 512)
    }

    @Test func primeStartsBothReadersAtTheSameFrameBehindTheProducerAndRefusesWhatItCannotDo() {
        let ring = SARingCreate(1024)!
        defer { SARingFree(ring) }
        #expect(!SARingPrime(ring, 4) && !SARingPrime(ring, 0))
        for i in 0..<3 { commit(ring, from: Int64(i * 128), frames: 128) }
        #expect(!SARingPrime(ring, 4))                                               // only 3 callbacks so far
        #expect(stats(snapshot(ring), 0).cursor == 0 && stats(snapshot(ring), 1).cursor == 0)
        _ = render(SARingGetReader(ring, 0)!, 128, sampleTime: 1000, initSilent: true)
        #expect(SARingPrime(ring, 3))                                                // 3 x 128 = 384 = w: start 0
        #expect(stats(snapshot(ring), 0).calls == 0 && stats(snapshot(ring), 0).servedBlocks == 0)
        let afterJump = render(SARingGetReader(ring, 0)!, 128, sampleTime: 99999, initSilent: true)
        expectServed(afterJump, channel: 0, cursor: 0)
        #expect(stats(snapshot(ring), 0).phaseSelfChanges == 0, "prime must forget the published phase")
        commit(ring, from: 384, frames: 256)                                         // w = 640, 4 commits, last 256
        #expect(!SARingPrime(ring, 4) && !SARingPrime(ring, 3))                      // 1024 > what was written; 768 > the 512 the ring can serve
        #expect(SARingPrime(ring, 2))
        let s = snapshot(ring)
        #expect(stats(s, 0).cursor == 128 && stats(s, 1).cursor == 128 && stats(s, 0).fill == 512)
    }

    @Test func theSnapshotComputesFillFromItsOwnLoadsAndKeepsTheTwoReadersCountersApart() {
        let ring = SARingCreate(1024)!
        defer { SARingFree(ring) }
        for i in 0..<4 { commit(ring, from: Int64(i * 128), frames: 128) }
        for _ in 0..<5 { _ = render(SARingGetReader(ring, 0)!, 128, initSilent: true) }
        for _ in 0..<3 { _ = render(SARingGetReader(ring, 1)!, 128, initSilent: true) }
        let s = snapshot(ring)
        for ch in 0..<2 {
            let x = stats(s, ch)
            #expect(x.fill == s.w - x.cursor)
            #expect(x.calls == x.servedBlocks + x.underrunBlocks + x.overrunBlocks + x.tornBlocks + x.oversizeBlocks + x.badBufferBlocks)
        }
        #expect(stats(s, 0).calls == 5 && stats(s, 1).calls == 3 && stats(s, 0).underrunBlocks == 1 && stats(s, 1).underrunBlocks == 0)
        #expect(stats(s, 0).fill == -128 && stats(s, 1).fill == 128)
        #expect(SARingGetReader(ring, 2) == nil)
    }

    @Test func theTimestampPhaseAndTheWeakerRuleAreCountedNeverActedOn() {
        let ring = SARingCreate(4096)!
        defer { SARingFree(ring) }
        for i in 0..<16 { commit(ring, from: Int64(i * 128), frames: 128) }
        let rd = [SARingGetReader(ring, 0)!, SARingGetReader(ring, 1)!]
        for c in 0..<6 {                                                             // R is not asked in cycle 2
            _ = render(rd[0], 128, sampleTime: Double(c * 128), initSilent: true)
            if c != 2 { _ = render(rd[1], 128, sampleTime: Double(c * 128), initSilent: true) }
        }
        var s = snapshot(ring)
        #expect(stats(s, 1).phaseSelfChanges == 1 && stats(s, 0).phaseSelfChanges == 0)
        #expect(stats(s, 0).phaseMismatches == 2 && stats(s, 1).phaseMismatches == 3)   // counts depend on the block order; data and cursors never do
        let ring2 = SARingCreate(4096)!
        defer { SARingFree(ring2) }
        for i in 0..<16 { commit(ring2, from: Int64(i * 128), frames: 128) }
        let a = [SARingGetReader(ring2, 0)!, SARingGetReader(ring2, 1)!]
        for _ in 0..<4 {                                                             // unusable stamps: flag unset, NaN with the flag, a NULL stamp
            for k in 0..<2 {
                _ = render(a[k], 128, sampleTime: 12345, valid: false, initSilent: true)
                _ = render(a[k], 128, sampleTime: .nan, initSilent: true)
                _ = render(a[k], 128, sampleTime: nil, initSilent: true)
            }
        }
        s = snapshot(ring2)
        #expect(stats(s, 0).phaseValidCalls == 0 && stats(s, 0).phaseInvalidCalls == 12 && stats(s, 1).phaseInvalidCalls == 12)
    }

    @Test func aReaderAheadOfTheProducerAtTheMomentOfTheCallIsSilentEvenOnAWrappedRing() {
        let ring = SARingCreate(1024)!
        defer { SARingFree(ring) }
        var produced: Int64 = 0
        for _ in 0..<12 { commit(ring, from: produced, frames: 128); produced += 128 }     // w = 1536: the slots hold OLD frames 512 ..< 1536, never zeros
        #expect(SARingPrime(ring, 4))                                                       // start 1024
        let rd = [SARingGetReader(ring, 0)!, SARingGetReader(ring, 1)!]
        for c in 0..<4 { for ch in 0..<2 { expectServed(render(rd[ch], 128, initSilent: true), channel: UInt32(ch), cursor: Int64(1024 + 128 * c)) } }
        for f in [128, 128, 64, 300, 1] { for ch in 0..<2 { expectSilence(render(rd[ch], f, initSilent: false)) } }   // no commit in between: r - w grows by every block
        let s = snapshot(ring)
        for ch in 0..<2 {
            let x = stats(s, ch)
            #expect(x.underrunBlocks == 5 && x.servedBlocks == 4 && x.overrunBlocks == 0 && x.tornBlocks == 0)
            #expect(x.cursor == 1536 + 128 + 128 + 64 + 300 + 1 && x.fill == -(128 + 128 + 64 + 300 + 1))
        }
    }

    @Test func primeNeedsTCommittedCallbacksNotJustEnoughData() {
        let ring = SARingCreate(1024)!
        defer { SARingFree(ring) }
        commit(ring, from: 0, frames: 512)
        commit(ring, from: 512, frames: 128)
        #expect(!SARingPrime(ring, 4))                                                      // two callbacks, although 4 x 128 frames were written
        #expect(SARingPrime(ring, 2))
        #expect(stats(snapshot(ring), 0).cursor == 384 && stats(snapshot(ring), 1).cursor == 384)
    }

    @Test func aCapacityThatIsNotAPowerOfTwoInRangeIsRefused() {
        #expect(SARingCreate(0) == nil && SARingCreate(1) == nil && SARingCreate(3) == nil && SARingCreate(1000) == nil)
        #expect(SARingCreate(UInt32(SA_RING_MAX_CAPACITY_FRAMES) * 2) == nil)
        let two = SARingCreate(2); #expect(two != nil); SARingFree(two)
        let d = SARingCreate(SA_RING_DEFAULT_CAPACITY_FRAMES)!
        defer { SARingFree(d) }
        #expect(snapshot(d).capacity == 32768 && snapshot(d).maxCommit == 16384)
    }

    @Test func nanInfinityDenormalAndNegativeZeroPassThroughBitForBit() {
        let ring = SARingCreate(1024)!
        defer { SARingFree(ring) }
        let bits: [UInt32] = [0x7fc0_0000, 0x7fc0_0001, 0x7f80_0000, 0xff80_0000, 0x0000_0001, 0x8000_0000, 0x8000_0000, 0x0000_0001]
        let data = bits.map { Float(bitPattern: $0) }
        #expect(callProducer(ring, buffers: [(2, UInt32(data.count * 4), data)]) == 0)    // 4 frames: (L, R) pairs
        for ch in 0..<2 {
            let r = render(SARingGetReader(ring, UInt32(ch))!, 4, initSilent: true)
            #expect(r.status == 0 && !r.silent)
            #expect(r.samples.map(\.bitPattern) == (0..<4).map { bits[2 * $0 + ch] })
        }
    }

    // MARK: the Objective-C factory and an OFFLINE engine (no device, nothing audible)

    @Test func theSourceNodeFactoryAcceptsOnlyMonoFloat32() {
        let ring = SARingCreate(1024)!
        defer { SARingFree(ring) }
        let rd = SARingGetReader(ring, 0)!
        #expect(SACreateSourceNode(rd, AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!) != nil)
        #expect(SACreateSourceNode(rd, AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!) == nil)
        #expect(SACreateSourceNode(rd, AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false)!) == nil)
    }

    @Test func anOfflineEnginePullsEachChannelFromTheRingThroughItsOwnSourceNode() throws {
        // Facts about the OFFLINE (manual rendering) path only: it says nothing about a real-time device, Bluetooth, or the order the engine runs the blocks there.
        let ring = SARingCreate(8192)!
        var produced: Int64 = 0
        for _ in 0..<32 { commit(ring, from: produced, frames: 128); produced += 128 }   // 4096 frames = the 4096-frame window of an 8192 ring
        let mono = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: mono, maximumFrameCount: 512)
        let node = SACreateSourceNode(SARingGetReader(ring, 1)!, mono)!                  // the RIGHT channel's reader
        engine.attach(node)
        if #available(macOS 27.0, *) { try engine.connectNode(node, to: engine.mainMixerNode, format: mono) } else { engine.connect(node, to: engine.mainMixerNode, format: mono) }
        try engine.start()
        let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 512)!
        var rendered: [Float] = []
        for _ in 0..<12 {
            let status = try engine.renderOffline(128, to: out)
            #expect(status == .success)
            rendered.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        }
        engine.stop()
        let s = snapshot(ring)
        let x = stats(s, 1)
        print("offline engine facts: calls \(x.calls), frames requested \(x.framesRequested), served \(x.servedBlocks), underrun \(x.underrunBlocks), overrun \(x.overrunBlocks), oversize \(x.oversizeBlocks), phase valid \(x.phaseValidCalls) invalid \(x.phaseInvalidCalls), reader L calls \(stats(s, 0).calls)")
        #expect(x.servedBlocks > 0 && x.badBufferBlocks == 0)
        #expect(stats(s, 0).calls == 0, "the left reader has no node: it must not be called")
        #expect(x.framesRequested >= 12 * 128)
        // what came out must be the ring's right channel (proportional: the mixer may apply a gain; none is assumed), never the left channel
        let want = (0..<rendered.count).map { sample(1, Int64($0)) }, wrong = (0..<rendered.count).map { sample(0, Int64($0)) }
        let g = rendered[0] / want[0]
        #expect(g > 0.1 && g < 4, "gain of the mixer path: \(g)")
        #expect(zip(rendered, want).allSatisfy { abs($0 - g * $1) <= 1e-3 * max(1, abs($1)) }, "offline output is not the right channel's frames")
        #expect(!zip(rendered, wrong).allSatisfy { abs($0 - g * $1) <= 1e-3 * max(1, abs($1)) })
        SARingFree(ring)
    }
}

private func memcmp_equal(_ a: SARingReaderStats, _ b: SARingReaderStats) -> Bool {
    var x = a, y = b
    return withUnsafeBytes(of: &x) { p in withUnsafeBytes(of: &y) { q in p.elementsEqual(q) } }
}
