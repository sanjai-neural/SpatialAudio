import Testing
import Foundation
import CoreAudio
import SpatialAudioCore
@testable import SpatialAudioEngine

// Step 6b-3c-0: the engine layer of the process-specific tap and the synthetic file tool. `SystemRingBackend` is only CONSTRUCTED (its init does nothing); no tap is created, no device is touched, nothing is audible. The
// runs are on the SIMULATED backend (fabricated). What a real muted process-specific tap does is exactly what the hardware experiments measure.

@Suite struct ProcessTapEngineTests {
    @Test func theRealBackendRemembersTheProcessTapSpecAndSaysSoInItsComposition() {
        guard #available(macOS 14.2, *) else { return }
        let spec = ProcessTapSpec(targetPID: 4321, mute: .muted)
        let b = SystemRingBackend(processTap: spec)
        #expect(b.tapMode == .processSpecific && b.processTapSpec == spec)
        #expect(b.composition.contains("a tap on ONE PROCESS (the test player)") && b.composition.contains("mute behaviour muted"))
        let global = SystemRingBackend(), device = SystemRingBackend(deviceTap: true)
        #expect(global.tapMode == .globalMixdown && global.processTapSpec == nil && device.tapMode == .deviceBound && device.processTapSpec == nil)
        #expect(!global.composition.contains("ONE PROCESS") && !device.composition.contains("ONE PROCESS"))
        #expect(SystemRingBackend(deviceTap: true, processTap: spec).tapMode == .processSpecific, "a process tap wins over the device flag (the parser never allows both)")
    }

    @Test func theRealBackendTranslatesNothingAndCreatesNoProcessTapUnlessItIsInThatMode() {
        guard #available(macOS 14.2, *) else { return }
        let global = SystemRingBackend()
        #expect(global.translateTargetProcess() == nil)
        #expect(global.createProcessTap(includingProcessObjects: [5]).tap == 0 && global.createProcessTap(includingProcessObjects: [5]).status != 0, "unsupported outside the process mode")
    }

    @Test func theMuteOptionMapsToCoreAudiosThreeBehaviours() {
        guard #available(macOS 14.2, *) else { return }
        #expect(RingProbeMuteBehavior.unmuted.coreAudioValue == .unmuted && RingProbeMuteBehavior.unmuted.coreAudioValue.rawValue == 0)
        #expect(RingProbeMuteBehavior.muted.coreAudioValue == .muted && RingProbeMuteBehavior.muted.coreAudioValue.rawValue == 1)
        #expect(RingProbeMuteBehavior.mutedWhenTapped.coreAudioValue == .mutedWhenTapped && RingProbeMuteBehavior.mutedWhenTapped.coreAudioValue.rawValue == 2)
    }

    @Test func theSimulatedBackendRemembersTheSpecAndTranslatesAFabricatedTarget() {
        let spec = ProcessTapSpec(targetPID: 321)
        let sim = SimulatedRingBackend(pacing: .virtualTime(blocksPerSecond: 94), processTap: spec)
        #expect(sim.tapMode == .processSpecific && sim.processTapSpec == spec)
        #expect(sim.translateTargetProcess()?.status == 0 && sim.translateTargetProcess()?.object != 0)
        let plain = SimulatedRingBackend(pacing: .virtualTime(blocksPerSecond: 94))
        #expect(plain.tapMode == .globalMixdown && plain.processTapSpec == nil && plain.translateTargetProcess() == nil)
    }

    @Test func theCommandBuildsTheProcessTapBackendOnlyWhenAskedAndTheReportSaysWhich() {
        // A one-second REAL-TIME simulated run on our own threads: the report is SIMULATED. Not a verdict test (the stage is unclassified at 1 s).
        let on = RingProbeCommand.run(.init(seconds: 1, simulate: true, processTap: ProcessTapSpec(targetPID: 321, mute: .muted)))
        #expect(on.isSimulated && on.tapMode == .processSpecific && on.targetProcessPID == 321 && on.muteBehavior == "muted")
        #expect(on.rateFix?.stage == .unclassified)
        let off = RingProbeCommand.run(.init(seconds: 1, simulate: true))
        #expect(off.isSimulated && off.tapMode == .globalMixdown && off.targetProcessPID == nil && off.muteBehavior == "unmuted")
    }
}

@Suite struct ChannelCheckFileToolTests {
    private func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sa-cc-\(UUID().uuidString)-\(name)")
    }

    @Test func aShortFileIsHeaderPlusTheOneShotEncodingByteForByteAcrossChunkBoundaries() throws {
        let url = temp("a.wav"); defer { try? FileManager.default.removeItem(at: url) }
        let frames: Int64 = 100_000                                  // not a multiple of the 44,100-frame chunk
        let summary = try ChannelCheckFileTool.writeFrames(to: url, frames: frames, overwrite: false)
        let data = [UInt8](try Data(contentsOf: url))
        #expect(summary.frames == frames && summary.bytes == 44 + frames * 4 && Int64(data.count) == summary.bytes)
        #expect(data == ChannelCheckPattern.wavHeader(frames: frames) + ChannelCheckPattern.pcm16(startFrame: 0, count: Int(frames)))
    }

    @Test func theSummaryReportsTheRealPeakAndRMSNotAConstant() throws {
        let url = temp("b.wav"); defer { try? FileManager.default.removeItem(at: url) }
        let s = try ChannelCheckFileTool.writeFrames(to: url, frames: Int64(ChannelCheckPattern.cycleFrames), overwrite: false)
        #expect(s.peakDecibelsFullScale < -29.9 && s.peakDecibelsFullScale > -30.4, "peak \(s.peakDecibelsFullScale)")
        #expect(s.leftChannelRMSDecibels < -33 && s.leftChannelRMSDecibels > -50 && s.rightChannelRMSDecibels < -33 && s.rightChannelRMSDecibels > -50)
        #expect(s.seconds == 30)
    }

    @Test func anExistingFileIsNeverOverwrittenUnlessAskedTo() throws {
        let url = temp("c.wav"); defer { try? FileManager.default.removeItem(at: url) }
        try Data([1, 2, 3]).write(to: url)
        #expect(throws: ChannelCheckFileTool.ToolError.fileExists) { try ChannelCheckFileTool.writeFrames(to: url, frames: 1000, overwrite: false) }
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]), "the existing file is untouched")
        _ = try ChannelCheckFileTool.writeFrames(to: url, frames: 1000, overwrite: true)
        #expect(try Data(contentsOf: url).count == 44 + 4000)
    }

    @Test func theToolRefusesDurationsOutsideTheLimitsBeforeWritingAnything() {
        let url = temp("d.wav"); defer { try? FileManager.default.removeItem(at: url) }
        for seconds in [0, 899, 3601] {
            #expect(throws: ChannelCheckFileTool.ToolError.self) { try ChannelCheckFileTool.write(to: url, seconds: seconds) }
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(seconds) s")
        }
    }

    @Test func theFileIsNotReadableByOthers() throws {
        let url = temp("e.wav"); defer { try? FileManager.default.removeItem(at: url) }
        _ = try ChannelCheckFileTool.writeFrames(to: url, frames: 1000, overwrite: false)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }
}

@Suite struct StereoCalibrationTests {
    @Test func aLeftOnlyInputIsLouderInTheLeftEarAndARightOnlyInputInTheRightEar() throws {
        let left = try StereoCalibration.measure(.init(signal: .sine(hz: 4000), amplitude: 0.1, leftActive: true, rightActive: false), sampleRate: 44_100)
        let right = try StereoCalibration.measure(.init(signal: .sine(hz: 4000), amplitude: 0.1, leftActive: false, rightActive: true), sampleRate: 44_100)
        #expect(left.leftEarRMSDecibels - left.rightEarRMSDecibels > 6, "left-only: left ear louder")
        #expect(right.rightEarRMSDecibels - right.leftEarRMSDecibels > 6, "right-only: right ear louder")
        #expect(left.leftEarRelativeDecibels < 6 && left.leftEarRelativeDecibels > -20, "a level near the input, not silence and not a boost: \(left.leftEarRelativeDecibels)")
    }

    @Test func aNearerSourceIsLouderAndTheDefaultDistanceIsTheListeningTestsTwoMetres() throws {
        let c = StereoCalibration.Case(signal: .sine(hz: 1000), amplitude: 0.1, leftActive: true, rightActive: false)
        let near = try StereoCalibration.measure(c, sampleRate: 44_100, distance: 1.0)
        let twoM = try StereoCalibration.measure(c, sampleRate: 44_100, distance: 2.0)
        let byDefault = try StereoCalibration.measure(c, sampleRate: 44_100)
        #expect(near.leftEarRMSDecibels > twoM.leftEarRMSDecibels + 3, "1 m \(near.leftEarRMSDecibels) dB against 2 m \(twoM.leftEarRMSDecibels) dB")
        #expect(byDefault == twoM && ListeningTest.sourceDistance == 2.0)
    }

    @Test func theWarmupIsHalfASecondAndTheRowSaysHowManyFramesWereSkipped() throws {
        let c = StereoCalibration.Case(signal: .sine(hz: 1000), amplitude: 0.1, leftActive: true, rightActive: true)
        #expect(try StereoCalibration.measure(c, sampleRate: 44_100).skippedFrames == 22_050 && StereoCalibration.warmupSeconds == 0.5)
        #expect(try StereoCalibration.measure(c, sampleRate: 48_000).skippedFrames == 24_000)
    }

    @Test func theLevelsAgreeBetween44100And48000HzSoTheOfflineMinus3DBDoesNotShowUpInThisGraph() throws {
        let c = StereoCalibration.Case(signal: .sine(hz: 1000), amplitude: 0.1, leftActive: true, rightActive: true)
        let a = try StereoCalibration.measure(c, sampleRate: 44_100), b = try StereoCalibration.measure(c, sampleRate: 48_000)
        #expect(abs(a.leftEarRelativeDecibels - b.leftEarRelativeDecibels) < 0.5 && abs(a.rightEarRelativeDecibels - b.rightEarRelativeDecibels) < 0.5)
    }

    @Test func aFullScaleRowIsFlaggedAndOnlyFullScaleRowsDecideTheWorstPeakGain() {
        func row(_ peakGain: Double, full: Bool) -> StereoCalibration.Row {
            StereoCalibration.Row(caseName: "x", sampleRate: 44_100, fullScale: full, inputRMSDecibels: 0, leftEarRMSDecibels: 0, rightEarRMSDecibels: 0, leftEarRelativeDecibels: 0,
                                  rightEarRelativeDecibels: 0, outputPeak: 0, skippedFrames: 0, peakGain: peakGain)
        }
        #expect(StereoCalibration.worstFullScalePeakGain([row(0.5, full: true), row(1.4, full: true), row(0.9, full: true), row(9.0, full: false)]) == 1.4, "the worst (largest) full-scale row; a non-full-scale row is ignored")
        #expect(StereoCalibration.worstFullScalePeakGain([row(2, full: false)]) == nil)
        #expect(abs(row(0.5, full: true).peakGainDecibels - (-6.0206)) < 1e-3)
    }

    @Test func theStandardCasesCoverLeftRightAndBothAtTwoLevelsAndNoise() {
        let cases = StereoCalibration.standardCases()
        #expect(cases.count == 27)
        #expect(cases.contains { $0.leftActive && !$0.rightActive } && cases.contains { !$0.leftActive && $0.rightActive } && cases.contains { $0.leftActive && $0.rightActive })
        #expect(cases.filter { $0.amplitude == 1.0 }.count == 15 && cases.filter { $0.amplitude == 0.1 }.count == 12)
        #expect(cases.contains { $0.signal == .noise } && cases.contains { $0.signal == .sine(hz: 100) } && cases.contains { $0.signal == .sine(hz: 8000) })
    }

    @Test func theTableHasOneRowPerMeasurementAndNumbersOnly() throws {
        let row = try StereoCalibration.measure(.init(signal: .sine(hz: 1000), amplitude: 0.1, leftActive: true, rightActive: false), sampleRate: 44_100)
        let t = StereoCalibration.table([row, row])
        #expect(t.split(separator: "\n").count == 4 && t.contains("sine 1000 Hz, peak 0.10, left only") && !t.contains("/Users"))
    }
}
