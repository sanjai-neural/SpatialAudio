import Testing
import Foundation
import SpatialAudioCore
@testable import SpatialAudioEngine

/// The whole Step 3a chain, offline and deterministic: scripted scene -> PoseMailbox -> ListenerPosePump ->
/// ListenerFrame conversion -> AVAudioEnvironmentNode -> stereo samples. These replace "does it sound right?" with a
/// measurement wherever a measurement is possible; they do not replace the listening itself.
@Suite(.serialized) struct ListeningTestOfflineTests {
    /// Mean expected azimuth and measured right-minus-left level for consecutive windows of the render.
    func windows(_ render: StereoRender, _ test: ListeningTest, length: Double = 0.5) -> (azimuth: [Double], level: [Double]) {
        var az = [Double](), ild = [Double]()
        let count = Int(Double(render.frameCount) / render.sampleRate / length)
        for k in 0..<count {
            let a = Double(k) * length, b = a + length
            az.append((0..<50).map { test.expectedDirection(at: a + (Double($0) + 0.5) * length / 50).azimuthDegrees }.reduce(0, +) / 50)
            ild.append(render.rightMinusLeftDecibels(from: a, to: b))
        }
        return (az, ild)
    }

    @Test func theYawSweepMovesTheToneAwayFromTheDirectionOfTheTurn() throws {
        let render = try renderScripted(.headSweepYaw, seconds: 12)
        let w = windows(render, .headSweepYaw)
        var rightSide = 0, leftSide = 0
        for (az, level) in zip(w.azimuth, w.level) {
            if az >= 30 { rightSide += 1; #expect(level > 4, "tone should be on the RIGHT (expected \(az)°) but R-L = \(level) dB") }
            if az <= -30 { leftSide += 1; #expect(level < -4, "tone should be on the LEFT (expected \(az)°) but R-L = \(level) dB") }
            if abs(az) < 10 { #expect(abs(level) < 4, "tone should be near the middle (expected \(az)°) but R-L = \(level) dB") }
        }
        #expect(rightSide >= 4 && leftSide >= 4, "the sweep must visit both sides, otherwise the checks above prove nothing")
        // Measured 2026-11-05: 0.9855 (the level difference saturates beyond about 50 degrees, so it is monotonic, not linear).
        #expect(correlation(w.azimuth, w.level) > 0.9)
    }

    @Test func flippingYawAtTheAudioSideMirrorsTheSweep() throws {
        let render = try renderScripted(.headSweepYaw, seconds: 12, mapping: ListenerMapping(invertYaw: true))
        let w = windows(render, .headSweepYaw)
        #expect(correlation(w.azimuth, w.level) < -0.9)               // exactly the "it sounds backwards" case the switch is for
    }

    @Test func theSourceSidesTestPutsTheToneLeftThenRightThenAhead() throws {
        let render = try renderScripted(.sourceSides, seconds: 9)
        #expect(render.rightMinusLeftDecibels(from: 0.25, to: 2.9) < -4)
        #expect(render.rightMinusLeftDecibels(from: 3.25, to: 5.9) > 4)
        #expect(abs(render.rightMinusLeftDecibels(from: 6.25, to: 8.9)) < 3)
    }

    @Test func theHoldsTestSitsOnTheRightWhileTheHeadIsLeftAndOnTheLeftWhileItIsRight() throws {
        let render = try renderScripted(.headHoldsYaw, seconds: 14)
        #expect(render.rightMinusLeftDecibels(from: 3.4, to: 5.9) > 4)      // head turned LEFT 45 -> tone on the RIGHT
        #expect(render.rightMinusLeftDecibels(from: 10.4, to: 12.9) < -4)   // head turned RIGHT 45 -> tone on the LEFT
        #expect(abs(render.rightMinusLeftDecibels(from: 0.3, to: 1.9)) < 3)
        #expect(abs(render.rightMinusLeftDecibels(from: 7.3, to: 8.9)) < 3)
    }

    @Test func pitchAndRollSweepsAreAudibleAndReallyMoveTheListener() throws {
        for test in [ListeningTest.headSweepPitch, .headSweepRoll] {
            let moving = try renderScripted(test, seconds: 6)
            #expect(moving.rms(moving.left, from: 0.5) > 0.001 && moving.rms(moving.right, from: 0.5) > 0.001, "\(test) is silent")
            // A head that never moves (tone at the same place) must sound different from the sweep.
            let still = try renderStatic(source: test.scene(at: 0).sourcePosition, seconds: 6)
            #expect(StereoRender.relativeDifference(moving, still, from: 1.5) > 0.05, "\(test): the head motion changed nothing")
        }
    }

    @Test func theWholeChainIsDeterministic() throws {
        let a = try renderScripted(.headSweepYaw, seconds: 3)
        let b = try renderScripted(.headSweepYaw, seconds: 3)
        #expect(StereoRender.relativeDifference(a, b) < 1e-6)
    }
}
