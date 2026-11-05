import Testing
import Foundation
@testable import SpatialAudioCore

/// Frames for the loss test, produced by the REAL `TrackingStateMachine` unless noted.
/// Timeline (seconds): turn+hold 0–3, cover cue at 3 (hand covers the lens at 3.4), uncover cue at
/// 3+coverLength (face visible again 0.4 s later), run ends 4 s after the uncover cue.
private struct LossRun {
    var frames: [SelfTestFrame]
    var coverStart: Double
    var uncoverStart: Double
    var end: Double
}

private func lossRun(heldYaw: Double = 25, machine: TrackingStateMachineConfig = TrackingStateMachineConfig(),
                     fps: Double = 30, coverLength: Double = 5, faceReturns: Bool = true,
                     visibleAgain: [ClosedRange<Double>] = [], snapOnLoss: Bool = false) -> LossRun {
    var sm = TrackingStateMachine(config: machine)
    let coverStart = 3.0, uncoverStart = 3.0 + coverLength, end = uncoverStart + 4
    var frames: [SelfTestFrame] = []
    var k = 0
    while Double(k) / fps < end {
        let t = Double(k) / fps
        let visible = t < coverStart + 0.4 || (faceReturns && t >= uncoverStart + 0.4) || visibleAgain.contains { $0.contains(t) }
        let state: TrackingState
        let pose: Quaternion
        if snapOnLoss {
            state = visible ? .locked : .static
            pose = visible ? yawQ(heldYaw) : .identity
        } else {
            let out = sm.update(at: t, pose: visible ? yawQ(heldYaw) : nil)
            state = out.state; pose = out.pose
        }
        frames.append(SelfTestFrame(arrival: t, captureTime: t,
                                    angles: visible ? VisionFaceAngles(yaw: heldYaw * deg, pitch: 0, roll: 0) : nil,
                                    frameMirrored: false, state: state, pose: pose, qualityOverall: visible ? 1 : 0,
                                    deliveryLatency: 0.08, visionDuration: 0.014, totalLatency: 0.094))
        k += 1
    }
    return LossRun(frames: frames, coverStart: coverStart, uncoverStart: uncoverStart, end: end)
}

private func analyze(_ r: LossRun, machine: TrackingStateMachineConfig = TrackingStateMachineConfig(),
                     config: LossAnalysisConfig = LossAnalysisConfig()) -> LossReport {
    LossAnalyzer.analyze(frames: r.frames, coverStart: r.coverStart, uncoverStart: r.uncoverStart, end: r.end,
                         machine: machine, config: config)
}

@Suite struct LossAnalyzerTests {
    // MARK: healthy behaviour

    @Test func healthyRunPassesWithTheExpectedSequenceAndTimings() throws {
        let r = analyze(lossRun())
        #expect(r.verdict == .pass)
        #expect(r.observedSequence == ["locked", "holding", "decaying", "static", "locked"])
        #expect(abs(r.secondsInState.holding - 0.5) < 0.1)
        #expect(abs(r.secondsInState.decaying - 1.5) < 0.1)
        #expect(r.secondsInState.staticState > 2.0)
        let toStatic = try #require(r.timeToStaticSeconds)
        #expect(abs(toStatic - 2.0) < 0.15)
        let reacquire = try #require(r.reacquireSecondsAfterUncoverCue)
        #expect(reacquire > 0.3 && reacquire < 0.6)                    // the simulated hand takes 0.4 s to leave
        #expect(!r.jumpFlagged && r.notes.isEmpty)
    }

    @Test func healthyRunStepsAreSmallAndThePoseTravelIsMeasured() throws {
        let r = analyze(lossRun(heldYaw: 25))
        let travel = try #require(r.heldPoseTravelDegrees)
        #expect(abs(travel - 25) < 0.5 && r.jumpCheckMeaningful)
        #expect(r.maxFrameJumpDegrees > 3 && r.maxFrameJumpDegrees < 6.5)     // reacquire blend peak ≈ 1.5·25/(0.25·30) = 5°
        #expect(r.jumpThresholdDegrees == 10)                                  // floor binds for a 25° turn
        let reacquireTravel = try #require(r.reacquirePoseTravelDegrees)
        #expect(abs(reacquireTravel - 25) < 0.5)
        #expect(r.maxJumpState == "locked")                                    // the biggest step is the reacquire blend
    }

    @Test func largeTurnRaisesTheThresholdSoLegitimateBlendsAreNotFlagged() {
        let r = analyze(lossRun(heldYaw: 60))
        #expect(r.maxFrameJumpDegrees > 10)                                    // a 60° blend legitimately exceeds the 10° floor...
        #expect(r.jumpThresholdDegrees > r.maxFrameJumpDegrees)                // ...and the adaptive threshold accounts for it
        #expect(!r.jumpFlagged && r.verdict == .pass)
    }

    @Test func tinyHeldPoseMakesTheJumpCheckWeakAndSaysSo() {
        let r = analyze(lossRun(heldYaw: 3))
        #expect(r.verdict == .pass && !r.jumpCheckMeaningful)
        #expect(r.notes.contains { $0.contains("jump check is weak") })
    }

    // MARK: pose jumps

    @Test func poseSnappingToNeutralOnLossIsFlagged() {
        let r = analyze(lossRun(snapOnLoss: true))
        #expect(r.jumpFlagged && r.verdict == .fail)
        #expect(r.maxFrameJumpDegrees > 20)
        #expect(r.observedSequence == ["locked", "static", "locked"])
        #expect(r.notes.contains { $0.contains("should never make") })         // locked → static is not a legal transition
    }

    @Test func missingReacquireBlendIsFlaggedAgainstTheConfiguredDesign() {
        let noBlend = TrackingStateMachineConfig(reacquireBlendDuration: 0)
        let run = lossRun(machine: noBlend)                                    // the "machine" under test snaps on reacquire
        let against = analyze(run)                                             // judged against the default 0.25 s blend design
        #expect(against.jumpFlagged && against.verdict == .fail)
        #expect(against.maxFrameJumpDegrees > 20)
        // If the design genuinely says "no blend", the same frames are by design and not flagged.
        let byDesign = analyze(run, machine: noBlend)
        #expect(!byDesign.jumpFlagged && byDesign.jumpThresholdDegrees > 25)
    }

    @Test func stepsAcrossLongFrameGapsAreNotCountedAsJumps() {
        var r = lossRun()
        let gapStart = r.coverStart + 3.5
        r.frames = r.frames.map { f in
            // after the gap the pose is somewhere else entirely
            f.arrival >= gapStart + 1.0 && f.arrival < gapStart + 1.2
                ? SelfTestFrame(arrival: f.arrival, captureTime: f.captureTime, angles: nil, frameMirrored: false, state: f.state,
                                pose: yawQ(80), qualityOverall: 0, deliveryLatency: 0, visionDuration: 0, totalLatency: 0)
                : f
        }.filter { !($0.arrival >= gapStart && $0.arrival < gapStart + 1.0) }
        let report = analyze(r)
        #expect(report.ignoredGapPairs >= 1)
        #expect(report.notes.contains { $0.contains("not counted") })
    }

    // MARK: sequence problems

    @Test func uncoveringBeforeStaticIsIncomplete() {
        let r = analyze(lossRun(coverLength: 1.2))                             // face is back 1.6 s after the hand arrived... only ~1.2 s of loss
        #expect(r.verdict == .incomplete)
        #expect(!r.observedSequence.contains("static"))
        #expect(r.notes.contains { $0.contains("static was never reached") })
    }

    @Test func neverReacquiringIsIncomplete() {
        let r = analyze(lossRun(faceReturns: false))
        #expect(r.verdict == .incomplete && r.observedSequence.last == "static")
        #expect(r.notes.contains { $0.contains("never came back") })
        #expect(r.reacquireSecondsAfterUncoverCue == nil)
    }

    @Test func flappingDuringACoverIsReportedAsIncompleteNotPass() {
        let r = analyze(lossRun(visibleAgain: [4.0...4.2]))                    // a gap in the hand lets the face through briefly
        #expect(r.verdict == .incomplete)
        #expect(r.observedSequence.filter { $0 == "holding" }.count == 2)
        #expect(r.notes.contains { $0.contains("flapped") })
    }

    @Test func illegalTransitionsFailEvenWithAContinuousPose() {
        // Hand-made: locked → static directly, pose never moves. A real machine can never do this.
        func f(_ t: Double, _ s: TrackingState) -> SelfTestFrame {
            SelfTestFrame(arrival: t, captureTime: t, angles: nil, frameMirrored: false, state: s, pose: yawQ(20),
                          qualityOverall: 1, deliveryLatency: 0, visionDuration: 0, totalLatency: 0)
        }
        let frames = (0..<60).map { f(2 + Double($0) / 30, $0 < 20 ? .locked : ($0 < 40 ? .static : .locked)) }
        let r = LossAnalyzer.analyze(frames: frames, coverStart: 2.5, uncoverStart: 3.2, end: 4, machine: TrackingStateMachineConfig())
        #expect(r.verdict == .fail && r.notes.contains { $0.contains("locked>static") })
    }

    @Test func aFrameDeliveryStallDuringTheLossTestIsCalledOut() {
        var run = lossRun()
        run.frames = run.frames.filter { !($0.arrival >= 5.0 && $0.arrival < 5.5) }          // a 0.5 s hole while covered
        let r = analyze(run)
        #expect(r.notes.contains { $0.contains("frame delivery stalled") })
        #expect(!analyze(lossRun()).notes.contains { $0.contains("stalled") })                // a healthy run has no such note
    }

    @Test func tooFewFramesIsIncompleteWithAReason() {
        let r = LossAnalyzer.analyze(frames: [], coverStart: 3, uncoverStart: 8, end: 12, machine: TrackingStateMachineConfig())
        #expect(r.verdict == .incomplete && !r.notes.isEmpty && r.observedSequence.isEmpty)
    }

    // MARK: configuration awareness

    @Test func timingDeviationsFromTheConfiguredDurationsAreNoted() {
        let slow = TrackingStateMachineConfig(holdDuration: 1.2)
        let r = analyze(lossRun(machine: slow))                                // analyzed against the default 0.5 s hold
        #expect(r.notes.contains { $0.contains("holding lasted") })
        #expect(r.verdict == .pass)                                            // notes only: timing alone does not fail the run
    }

    @Test func frameOrderInTheInputDoesNotMatter() {
        var run = lossRun()
        let a = analyze(run)
        run.frames.reverse()
        #expect(analyze(run) == a)
    }

    @Test func reportIsCodable() throws {
        let r = analyze(lossRun())
        #expect(try JSONDecoder().decode(LossReport.self, from: JSONEncoder().encode(r)) == r)
    }
}
