import Testing
import Foundation
import SpatialAudioCore
@testable import SpatialAudioEngine

/// Measurements of what AVAudioEnvironmentNode actually does, made by manual OFFLINE rendering: no audio hardware, no
/// sound, no microphone. They establish the conventions the Core conversion relies on, which the header does not
/// spell out (it only fixes forward = -Z and up = +Y; it never says which side +X is). What they cannot establish is how
/// anything SOUNDS on a pair of headphones: that is the listening test.
@Suite(.serialized) struct EnvironmentRendererOfflineTests {
    let warmUp = 0.25                       // seconds skipped at the start of every measurement

    // MARK: - source side convention

    @Test func aSourceAtPlusXIsLouderInTheRightChannelAndMinusXInTheLeft() throws {
        let right = try renderStatic(source: Vector3(2, 0, 0))
        let left = try renderStatic(source: Vector3(-2, 0, 0))
        let ahead = try renderStatic(source: Vector3(0, 0, -2))
        // Measured 2026-11-05 on this Mac with the pink-noise test tone: +7.7 dB, -7.7 dB and -0.3 dB. The sign is what
        // matters, so the thresholds are about half the measurement (a white-noise probe gave twice the level).
        #expect(right.rightMinusLeftDecibels(from: warmUp) > 4, "right source: \(right.rightMinusLeftDecibels(from: warmUp)) dB")
        #expect(left.rightMinusLeftDecibels(from: warmUp) < -4, "left source: \(left.rightMinusLeftDecibels(from: warmUp)) dB")
        #expect(abs(ahead.rightMinusLeftDecibels(from: warmUp)) < 3, "front source: \(ahead.rightMinusLeftDecibels(from: warmUp)) dB")
        #expect(right.rms(right.right, from: warmUp) > 0.001)            // the signal is really there, not two silent channels
    }

    // MARK: - listener orientation (our conversion), as heard through the engine

    @Test func turningTheHeadLeftMovesAFrontSourceToTheRight() throws {
        let ahead = Vector3(0, 0, -2)
        let turnedLeft = try renderStatic(source: ahead, pose: yawQ(60))
        let turnedRight = try renderStatic(source: ahead, pose: yawQ(-60))
        let straight = try renderStatic(source: ahead, pose: .identity)
        #expect(turnedLeft.rightMinusLeftDecibels(from: warmUp) > 4)     // head left -> tone on the RIGHT (measured +7.5 dB)
        #expect(turnedRight.rightMinusLeftDecibels(from: warmUp) < -4)   // head right -> tone on the LEFT (measured -7.8 dB)
        #expect(abs(straight.rightMinusLeftDecibels(from: warmUp)) < 3)
    }

    /// The strong check: rotating the listener by R must render exactly like leaving the listener alone and moving the
    /// source by R^-1, for yaw, pitch, roll and combinations (positions are in the engine's own frame, so this ties the
    /// listener vectors to the source convention without any assumption about handedness). The WRONG direction and "no
    /// rotation at all" must differ a lot, which is what makes a pass meaningful.
    @Test func rotatingTheListenerEqualsMovingTheSourceTheOtherWay() throws {
        let p = Vector3(1.2, 0.5, -1.6)
        let poses: [(String, Quaternion)] = [
            ("yaw +30", eulerQ(30, 0, 0)), ("yaw -50", eulerQ(-50, 0, 0)),
            ("pitch +25", eulerQ(0, 25, 0)), ("pitch -25", eulerQ(0, -25, 0)),
            ("roll +20", eulerQ(0, 0, 20)), ("roll -20", eulerQ(0, 0, -20)),
            ("yaw 40 pitch 15 roll -10", eulerQ(40, 15, -10)), ("yaw -70 pitch -20 roll 30", eulerQ(-70, -20, 30)),
        ]
        let neutral = try renderStatic(source: p)
        for (name, q) in poses {
            let listenerRotated = try renderStatic(source: p, pose: q)
            let sourceMovedBack = try renderStatic(source: q.inverse().rotate(p))
            let sourceMovedWrong = try renderStatic(source: q.rotate(p))
            let right = StereoRender.relativeDifference(listenerRotated, sourceMovedBack, from: warmUp)
            let wrong = StereoRender.relativeDifference(listenerRotated, sourceMovedWrong, from: warmUp)
            let unrotated = StereoRender.relativeDifference(listenerRotated, neutral, from: warmUp)
            // Measured 2026-11-05: right 0.000000 for every pose, wrong-direction 0.48-1.40, unrotated 0.30-1.39.
            #expect(right < 1e-3, "\(name): rotating the listener differs from moving the source back by \(right)")
            #expect(wrong > 0.2, "\(name): the wrong-direction control only differs by \(wrong), so this test could not catch a sign error")
            #expect(unrotated > 0.2, "\(name): the pose barely changed the rendering (\(unrotated))")
        }
    }

    /// Test-the-test, kept as a permanent test: the flip switches really do produce a renderer that disagrees with the
    /// geometry, and the invariance check above would see it.
    @Test func aFlippedAxisIsCaughtByTheSameInvarianceCheck() throws {
        let p = Vector3(1.2, 0.5, -1.6)
        let cases: [(String, Quaternion, ListenerMapping)] = [
            ("yaw flipped", eulerQ(40, 0, 0), ListenerMapping(invertYaw: true)),
            ("pitch flipped", eulerQ(0, 25, 0), ListenerMapping(invertPitch: true)),
            ("roll flipped", eulerQ(0, 0, 20), ListenerMapping(invertRoll: true)),
        ]
        for (name, q, mapping) in cases {
            let flipped = try renderStatic(source: p, pose: q, mapping: mapping)
            let truth = try renderStatic(source: q.inverse().rotate(p))
            #expect(StereoRender.relativeDifference(flipped, truth, from: warmUp) > 0.2, "\(name) went unnoticed")
        }
    }

    // MARK: - what the engine reports back

    @Test func avAudiosAngularYawIsClockwisePositiveWhichIsWhyWeUseVectors() throws {
        let renderer = try EnvironmentRenderer(mode: .offline(maximumFrames: renderBlock))
        // Our yaw +30 = turn LEFT 30 degrees. AVAudio's angular yaw reads back NEGATIVE (clockwise-positive).
        renderer.setListener(ListenerFrame.orientation(for: yawQ(30)))
        var a = renderer.listenerAngularOrientationReadback
        #expect(abs(a.yaw + 30) < 0.01 && abs(a.pitch) < 0.01 && abs(a.roll) < 0.01, "yaw/pitch/roll = \(a)")
        renderer.setListener(ListenerFrame.orientation(for: yawQ(-45)))
        a = renderer.listenerAngularOrientationReadback
        #expect(abs(a.yaw - 45) < 0.01)
        // Pitch (+ = up) and roll (+ = right ear down) agree with the project's convention.
        renderer.setListener(ListenerFrame.orientation(for: pitchQ(25)))
        a = renderer.listenerAngularOrientationReadback
        #expect(abs(a.pitch - 25) < 0.01 && abs(a.yaw) < 0.01 && abs(a.roll) < 0.01, "pitch readback \(a)")
        renderer.setListener(ListenerFrame.orientation(for: Quaternion(axis: .forward, angle: 20 * deg)))
        a = renderer.listenerAngularOrientationReadback
        #expect(abs(a.roll - 20) < 0.01 && abs(a.yaw) < 0.01 && abs(a.pitch) < 0.01, "roll readback \(a)")
    }

    @Test func isConfiguredForHeadphoneHRTFAndTheSystemDoesNotRotateTheListener() throws {
        let renderer = try EnvironmentRenderer(mode: .offline(maximumFrames: renderBlock))
        let d = renderer.diagnostics
        #expect(d.outputTypeIsHeadphones)
        #expect(d.hrtfHQApplicable, "HRTFHQ is not among the applicable rendering algorithms")
        #expect(d.sourceUsesHRTFHQ)
        if let off = d.systemListenerHeadTrackingOff { #expect(off) }
        #expect(d.sampleRate == 48_000)
        #expect(!renderer.isRunning)
    }

    // MARK: - level control and lifecycle

    @Test func zeroVolumeIsExactSilenceAndHalfVolumeIsSixDecibelsDown() throws {
        func render(_ volume: Float) throws -> StereoRender {
            let r = try EnvironmentRenderer(mode: .offline(maximumFrames: renderBlock), initialSource: Vector3(2, 0, 0))
            r.outputVolume = volume
            try r.start()
            defer { r.stop() }
            return try r.renderOffline(blocks: 80, blockFrames: renderBlock)
        }
        let silent = try render(0), half = try render(0.5), full = try render(1)
        #expect(silent.left.allSatisfy { $0 == 0 } && silent.right.allSatisfy { $0 == 0 })      // the lever the silent live smoke test relies on
        let ratio = 20 * log10(half.rms(half.right, from: warmUp) / full.rms(full.right, from: warmUp))
        #expect(abs(ratio + 6.02) < 1.0, "half volume changed the level by \(ratio) dB")
    }

    @Test func theToneIsGatedBurstsNotAContinuousSound() throws {
        let r = try renderStatic(source: Vector3(0, 0, -2), seconds: 2.0)
        // Cell layout: silence 0.2 s, burst 0.3 s. Compare a window inside a burst with one inside the silence.
        let burst = r.rms(r.left, from: 0.30, to: 0.45), gap = r.rms(r.left, from: 0.05, to: 0.15)
        #expect(burst > 0.001)
        #expect(gap < 0.05 * burst, "silence part is not quiet: \(gap) vs \(burst)")
    }

    @Test func offlineRenderingIsRepeatable() throws {
        let a = try renderStatic(source: Vector3(1, 0.3, -1.5), pose: eulerQ(20, 5, 0))
        let b = try renderStatic(source: Vector3(1, 0.3, -1.5), pose: eulerQ(20, 5, 0))
        #expect(StereoRender.relativeDifference(a, b) < 1e-6)
    }

    @Test func startAndStopAreIdempotentAndOfflineOnlyCallsAreRejectedForLive() throws {
        let r = try EnvironmentRenderer(mode: .offline(maximumFrames: renderBlock))
        try r.start(); try r.start()
        #expect(r.isRunning)
        r.stop(); r.stop()
        #expect(!r.isRunning)
        #expect(throws: EnvironmentRendererError.self) { try r.renderOffline(blocks: 1, blockFrames: renderBlock + 1) }
    }
}
