import Testing
import Foundation
@testable import SpatialAudioCore

// Step 6b-3c-0: the synthetic channel-check pattern and its WAV encoding. Generated, never recorded; deterministic by frame index. Nothing here plays a sound.

private func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
private func u32(_ b: [UInt8], _ i: Int) -> Int { u16(b, i) | u16(b, i + 2) << 16 }

@Suite struct ChannelCheckPatternTests {
    @Test func theSegmentsAreLeftOnlyThenRightOnlyThenBothInThatOrder() {
        var leftSeen = false, rightSeen = false, bothSeen = false
        for i in stride(from: 0, to: ChannelCheckPattern.segmentFrames, by: 1) {          // segment 0: 0 to 10 s
            let f = ChannelCheckPattern.frame(Int64(i))
            #expect(f.right == 0, "left-only segment, frame \(i)")
            if f.left != 0 { leftSeen = true }
        }
        for i in ChannelCheckPattern.segmentFrames..<(2 * ChannelCheckPattern.segmentFrames) {   // segment 1: 10 to 20 s
            let f = ChannelCheckPattern.frame(Int64(i))
            #expect(f.left == 0, "right-only segment, frame \(i)")
            if f.right != 0 { rightSeen = true }
        }
        for i in (2 * ChannelCheckPattern.segmentFrames)..<ChannelCheckPattern.cycleFrames {     // segment 2: 20 to 30 s
            let f = ChannelCheckPattern.frame(Int64(i))
            #expect(f.left == f.right, "both segment, frame \(i)")
            if f.left != 0 { bothSeen = true }
        }
        #expect(leftSeen && rightSeen && bothSeen)
    }

    @Test func theSegmentStructureRepeatsEvery30SecondsWhileTheNoiseSamplesDoNot() {
        // The noise is a function of the ABSOLUTE frame index (random access), so the samples differ from cycle to cycle; which channel is active, and when, repeats.
        var differentSomewhere = false
        for i in [1_000, 22_000, 500_000, 900_000, 1_300_000, 5_000, 450_000] as [Int64] {
            let a = ChannelCheckPattern.frame(i), b = ChannelCheckPattern.frame(i + Int64(ChannelCheckPattern.cycleFrames))
            #expect((a.left == 0) == (b.left == 0) && (a.right == 0) == (b.right == 0), "frame \(i)")
            if a.left != b.left || a.right != b.right { differentSomewhere = true }
        }
        #expect(differentSomewhere)
        #expect(ChannelCheckPattern.segmentFrames == 441_000 && ChannelCheckPattern.cycleFrames == 1_323_000)
    }

    @Test func thePatternIsDeterministicAndDoesNotDependOnACallCounterOrTheClock() {
        let a = (0..<2000).map { ChannelCheckPattern.frame(Int64($0) + 700).left }
        let b = (0..<2000).map { ChannelCheckPattern.frame(Int64($0) + 700).left }
        #expect(a == b)
        #expect(ChannelCheckPattern.frame(12_345) == ChannelCheckPattern.frame(12_345))
        // random access equals sequential access
        let sequence = (4_000..<6_000).map { ChannelCheckPattern.frame(Int64($0)).left }
        #expect(sequence[1_000] == ChannelCheckPattern.frame(5_000).left)
    }

    @Test func thePeakIsMinus30DBFSAndNeverAbove() {
        #expect(ChannelCheckPattern.peakAmplitude == 0.0316)
        #expect(abs(20 * log10(Double(ChannelCheckPattern.peakAmplitude)) - (-30)) < 0.01)
        let s = ChannelCheckPattern.statistics(frames: Int64(ChannelCheckPattern.cycleFrames))
        #expect(s.peakAmplitude <= 0.0316 && s.peakAmplitude > 0.0300, "peak \(s.peakAmplitude)")
        #expect(s.leftRMS > 0 && s.rightRMS > 0 && s.leftRMS < 0.0316 && s.rightRMS < 0.0316)
    }

    @Test func everyBurstFadesInAndOutSoItHasNoClick() {
        for unit in [0, 1, 7, 10, 25] {
            let start = Int64(unit * ChannelCheckPattern.unitFrames)
            let seg = unit / ChannelCheckPattern.burstsPerSegment
            func active(_ f: (left: Float, right: Float)) -> Float { seg == 1 ? f.right : f.left }
            #expect(active(ChannelCheckPattern.frame(start)) == 0, "the first sample of the burst in unit \(unit)")
            #expect(active(ChannelCheckPattern.frame(start + Int64(ChannelCheckPattern.burstFrames - 1))) == 0, "the last sample of the burst in unit \(unit)")
            // a sample inside the fade is smaller than the burst's own peak envelope (the envelope is below 1 there)
            let early = abs(active(ChannelCheckPattern.frame(start + 3)))
            #expect(early <= ChannelCheckPattern.peakAmplitude * 3 / Float(ChannelCheckPattern.fadeFrames) + 1e-9)
        }
    }

    @Test func aBurstIsHalfASecondAndTheGapIsExactSilence() {
        let start: Int64 = Int64(3 * ChannelCheckPattern.unitFrames)
        #expect(ChannelCheckPattern.frame(start + 22_040).left != 0, "still inside the burst, just before the end fade")
        for k in [22_050, 22_051, 30_000, 44_099] as [Int64] {
            let f = ChannelCheckPattern.frame(start + k)
            #expect(f.left == 0 && f.right == 0, "gap frame \(k)")
        }
        #expect(ChannelCheckPattern.burstFrames == 22_050 && ChannelCheckPattern.unitFrames == 44_100)
    }

    @Test func theNoiseIsRoughlyUniformAndNotConstant() {
        let xs = (0..<20_000).map { ChannelCheckPattern.noise(Int64($0)) }
        #expect(xs.allSatisfy { $0 >= -1 && $0 < 1 })
        let mean = xs.reduce(0, +) / Float(xs.count)
        #expect(abs(mean) < 0.03 && Set(xs.prefix(1000)).count > 900)
    }

    @Test func theToolLimitsAre900To3600Seconds() {
        #expect(ChannelCheckPattern.validate(seconds: 900) == nil && ChannelCheckPattern.validate(seconds: 3600) == nil && ChannelCheckPattern.validate(seconds: 1200) == nil)
        #expect(ChannelCheckPattern.validate(seconds: 899) != nil && ChannelCheckPattern.validate(seconds: 3601) != nil && ChannelCheckPattern.validate(seconds: 0) != nil && ChannelCheckPattern.validate(seconds: -5) != nil)
        #expect(ChannelCheckPattern.minimumSeconds == 900 && ChannelCheckPattern.maximumSeconds == 3600)
    }
}

@Suite struct ChannelCheckWAVTests {
    @Test func theHeaderIsAStandardPCM16StereoRIFFOf44Bytes() {
        let h = ChannelCheckPattern.wavHeader(frames: 1000)
        #expect(h.count == 44)
        #expect(String(decoding: h[0..<4], as: UTF8.self) == "RIFF" && String(decoding: h[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: h[12..<16], as: UTF8.self) == "fmt " && String(decoding: h[36..<40], as: UTF8.self) == "data")
        #expect(u32(h, 4) == 36 + 4000, "RIFF size")
        #expect(u32(h, 16) == 16 && u16(h, 20) == 1 && u16(h, 22) == 2 && u32(h, 24) == 44_100)
        #expect(u32(h, 28) == 176_400, "byte rate")
        #expect(u16(h, 32) == 4, "block align")
        #expect(u16(h, 34) == 16, "bits per sample")
        #expect(u32(h, 40) == 4000, "data size")
    }

    @Test func theDataSizeFollowsTheFrameCount() {
        #expect(u32(ChannelCheckPattern.wavHeader(frames: 1), 40) == 4 && u32(ChannelCheckPattern.wavHeader(frames: 39_690_000), 40) == 158_760_000)
        #expect(u32(ChannelCheckPattern.wavHeader(frames: 39_690_000), 4) == 158_760_036)
    }

    @Test func quantizingRoundsToNearestAndClips() {
        #expect(ChannelCheckPattern.quantize(0.5) == 16_384 && ChannelCheckPattern.quantize(-0.5) == -16_384, "0.5 x 32767 = 16383.5 rounds to 16384, not truncates")
        #expect(ChannelCheckPattern.quantize(0) == 0 && ChannelCheckPattern.quantize(1) == 32_767 && ChannelCheckPattern.quantize(-1) == -32_767)
        #expect(ChannelCheckPattern.quantize(2) == 32_767 && ChannelCheckPattern.quantize(-2) == -32_767, "clipped, not wrapped")
        #expect(ChannelCheckPattern.quantize(0.0316) == 1_035)
    }

    @Test func samplesAreInterleavedLeftThenRightAndLittleEndian() {
        // the first frames of the first burst are in the left-only segment: right is exactly 0 and left is not
        var idx: Int64 = 0
        while ChannelCheckPattern.quantize(ChannelCheckPattern.frame(idx).left) == 0 { idx += 1 }
        let bytes = ChannelCheckPattern.pcm16(startFrame: idx, count: 1)
        let expected = Int(UInt16(bitPattern: ChannelCheckPattern.quantize(ChannelCheckPattern.frame(idx).left)))
        #expect(bytes.count == 4 && u16(bytes, 0) == expected, "left first, low byte first")
        #expect(bytes[2] == 0 && bytes[3] == 0, "right is silent in the left-only segment")
        // a right-only frame: left bytes 0, right nonzero
        var j = Int64(ChannelCheckPattern.segmentFrames)
        while ChannelCheckPattern.quantize(ChannelCheckPattern.frame(j).right) == 0 { j += 1 }
        let r = ChannelCheckPattern.pcm16(startFrame: j, count: 1)
        #expect(r[0] == 0 && r[1] == 0 && u16(r, 2) == Int(UInt16(bitPattern: ChannelCheckPattern.quantize(ChannelCheckPattern.frame(j).right))))
    }

    @Test func pcm16HasFourBytesPerFrameAndStartsWhereAsked() {
        #expect(ChannelCheckPattern.pcm16(startFrame: 100, count: 50).count == 200 && ChannelCheckPattern.pcm16(startFrame: 0, count: 0).isEmpty)
        let whole = ChannelCheckPattern.pcm16(startFrame: 0, count: 300)
        #expect(Array(whole[400..<404]) == ChannelCheckPattern.pcm16(startFrame: 100, count: 1) && whole.count == 1200)
    }
}
