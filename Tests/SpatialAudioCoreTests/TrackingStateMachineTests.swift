import Testing
import Foundation
@testable import SpatialAudioCore

@Suite struct TrackingStateMachineTests {
    let dt = 1.0 / 60
    // hold 0.5s, decay 1.5s, blend 0.25s, minConfidence 0.5
    func makeMachine() -> TrackingStateMachine { TrackingStateMachine() }

    /// Runs the machine, returns (time, output) history. `pose` closure gives pose or nil per time.
    func run(_ m: inout TrackingStateMachine, from t0: Double, to t1: Double,
             pose: (Double) -> Quaternion?, confidence: Double = 1) -> [(Double, TrackingOutput)] {
        var out: [(Double, TrackingOutput)] = []
        var t = t0
        while t <= t1 + 1e-9 {
            out.append((t, m.update(at: t, pose: pose(t), confidence: confidence)))
            t += dt
        }
        return out
    }

    /// Largest angle (deg) between consecutive outputs.
    func maxStep(_ h: [(Double, TrackingOutput)]) -> Double {
        zip(h, h.dropFirst()).map { angleDeg($0.0.1.pose, $0.1.1.pose) }.max() ?? 0
    }

    @Test func startsStaticAtNeutral() {
        let m = makeMachine()
        #expect(m.state == .static)
        #expect(m.lastOutput == .identity)
    }

    @Test func staticStaysAtNeutralWithoutTracking() {
        var m = makeMachine()
        let h = run(&m, from: 0, to: 2) { _ in nil }
        #expect(h.allSatisfy { $0.1.state == .static && $0.1.pose == .identity })
    }

    @Test func firstLockBlendsFromNeutralWithoutJump() {
        var m = makeMachine()
        let target = yawQ(40)
        let h = run(&m, from: 0, to: 1) { _ in target }
        #expect(h[0].1.state == .locked)
        #expect(angleDeg(h[0].1.pose, .identity) < 1e-9)          // starts at neutral, not at target
        #expect(maxStep(h) < 40.0 / 15 * 1.6)                     // bounded speed (smoothstep peak 1.5x)
        #expect(angleDeg(h.last!.1.pose, target) < 1e-9)          // fully converged after blend
    }

    @Test func lockedFollowsLivePoseAfterBlend() {
        var m = makeMachine()
        _ = run(&m, from: 0, to: 1) { _ in yawQ(10) }
        let o = m.update(at: 1.1, pose: yawQ(25))
        #expect(o.state == .locked)
        #expect(angleDeg(o.pose, yawQ(25)) < 1e-9)
    }

    @Test func lossEntersHoldingAtLastOutput() {
        var m = makeMachine()
        _ = run(&m, from: 0, to: 1) { _ in yawQ(30) }
        let before = m.lastOutput
        let o = m.update(at: 1.02, pose: nil)
        #expect(o.state == .holding)
        #expect(o.pose == before)
    }

    @Test func stateSequenceAndTimings() {
        var m = makeMachine()
        _ = run(&m, from: 0, to: 1) { _ in yawQ(30) }       // locked
        _ = m.update(at: 1.0 + dt, pose: nil)                // loss starts at t=1+dt
        let loss = 1.0 + dt
        #expect(m.update(at: loss + 0.49, pose: nil).state == .holding)
        #expect(m.update(at: loss + 0.51, pose: nil).state == .decaying)
        #expect(m.update(at: loss + 1.99, pose: nil).state == .decaying)
        let end = m.update(at: loss + 2.01, pose: nil)
        #expect(end.state == .static)
        #expect(end.pose == .identity)
    }

    @Test func holdFreezesPoseExactly() {
        var m = makeMachine()
        _ = run(&m, from: 0, to: 1) { _ in yawQ(30) }
        let held = m.lastOutput
        let h = run(&m, from: 1 + dt, to: 1.4) { _ in nil }
        #expect(h.allSatisfy { $0.1.pose == held })
    }

    @Test func decayIsMonotonicTowardNeutralAndSmooth() {
        var m = makeMachine()
        _ = run(&m, from: 0, to: 1) { _ in yawQ(60) }
        let h = run(&m, from: 1 + dt, to: 3.5) { _ in nil }
        let angles = h.map { angleDeg($0.1.pose, .identity) }
        for (a, b) in zip(angles, angles.dropFirst()) { #expect(b <= a + 1e-9) }
        #expect(angles.last! < 1e-9)
        #expect(maxStep(h) < 60.0 / 90 * 1.6)                  // 1.5s*60fps=90 frames, smoothstep peak 1.5x
    }

    @Test func neverJumpsAcrossLossAndReacquire() {
        // Pose tracks a moving head; face lost for 3s (through hold, decay and static); returns elsewhere.
        var m = makeMachine()
        func live(_ t: Double) -> Quaternion? {
            if t >= 2 && t < 5 { return nil }
            return t < 2 ? yawQ(50) : yawQ(-40)
        }
        let h = run(&m, from: 0, to: 8, pose: live)
        // Allowed per-frame step: the sudden 90° target change blends over 15 frames at <=1.5x.
        #expect(maxStep(h) < 90.0 / 15 * 1.6)
        #expect(h.contains { $0.1.state == .holding })
        #expect(h.contains { $0.1.state == .decaying })
        #expect(h.contains { $0.1.state == .static })
        #expect(h.last!.1.state == .locked)
        #expect(angleDeg(h.last!.1.pose, yawQ(-40)) < 1e-9)
    }

    @Test func reacquireDuringHoldAndDecayHasNoJump() {
        for lossDuration in [0.2, 1.0, 1.9] {
            var m = makeMachine()
            _ = run(&m, from: 0, to: 1) { _ in yawQ(50) }
            let h = run(&m, from: 1 + dt, to: 4) { t in t < 1 + lossDuration ? nil : yawQ(-30) }
            #expect(maxStep(h) < 80.0 / 15 * 1.6, "lossDuration \(lossDuration)")
        }
    }

    @Test func lossDuringBlendHoldsCurrentOutputNotTarget() {
        var m = makeMachine()
        _ = m.update(at: 0, pose: yawQ(60))
        let mid = m.update(at: 0.1, pose: yawQ(60))     // mid-blend
        #expect(angleDeg(mid.pose, yawQ(60)) > 1)
        let lost = m.update(at: 0.12, pose: nil)
        #expect(lost.state == .holding)
        #expect(lost.pose == mid.pose)
    }

    @Test func lowConfidenceCountsAsLoss() {
        var m = makeMachine()
        _ = run(&m, from: 0, to: 1) { _ in yawQ(30) }
        let o = m.update(at: 1.02, pose: yawQ(80), confidence: 0.2)
        #expect(o.state == .holding)
        #expect(angleDeg(o.pose, yawQ(30)) < 1e-9)
    }

    @Test func nonFinitePoseCountsAsLoss() {
        var m = makeMachine()
        _ = run(&m, from: 0, to: 1) { _ in yawQ(30) }
        let o = m.update(at: 1.02, pose: Quaternion(w: .nan, x: 0, y: 0, z: 0))
        #expect(o.state == .holding)
        #expect(o.pose.isFinite)
    }

    @Test func timeRunningBackwardsDoesNotJumpOrCrash() {
        var m = makeMachine()
        _ = run(&m, from: 0, to: 1) { _ in yawQ(30) }
        let a = m.lastOutput
        let o = m.update(at: 0.5, pose: yawQ(30))
        #expect(angleDeg(o.pose, a) < 1e-9)
        #expect(m.lastUpdateTime == 1.0 || (m.lastUpdateTime ?? 0) >= 1.0 - 1e-9)
    }

    @Test func zeroDurationsAreSafe() {
        var m = TrackingStateMachine(config: .init(holdDuration: 0, decayDuration: 0, reacquireBlendDuration: 0))
        let o = m.update(at: 0, pose: yawQ(30))
        #expect(angleDeg(o.pose, yawQ(30)) < 1e-9)           // no blend configured
        let lost = m.update(at: 0.1, pose: nil)
        #expect(lost.state == .static)
        #expect(lost.pose == .identity)
    }

    @Test func resetReturnsToInitialState() {
        var m = makeMachine()
        _ = run(&m, from: 0, to: 1) { _ in yawQ(30) }
        m.reset()
        #expect(m.state == .static && m.lastOutput == .identity && m.lastUpdateTime == nil)
    }
}

@Suite struct HeadPosePipelineTests {
    let dt = 1.0 / 60

    func sample(_ q: Quaternion, _ t: Double, conf: Double = 1) -> HeadPoseSample {
        HeadPoseSample(orientation: q, confidence: conf, timestamp: t)
    }

    @Test func calibrationAppliedAfterFilter() {
        var p = HeadPosePipeline(calibration: Calibration(neutral: yawQ(20)))
        var out = p.process(nil, now: 0)
        for i in 0...120 { out = p.process(sample(yawQ(50), Double(i) * dt), now: Double(i) * dt) }   // locks after the 0.2 s recovery dwell
        #expect(out.state == .locked)
        #expect(angleDeg(out.pose, yawQ(30)) < 0.01)
    }

    @Test func recenterOnlyWhileLocked() {
        var p = HeadPosePipeline()
        let beforeLock = p.recenter()
        #expect(!beforeLock)                                   // static, nothing tracked
        for i in 0...60 { p.process(sample(yawQ(35), Double(i) * dt), now: Double(i) * dt) }
        let whileLocked = p.recenter()
        #expect(whileLocked)
        for k in 0..<10 { p.process(nil, now: 2 + Double(k) * dt) }   // no face for 0.17 s: past the 0.1 s loss dwell -> holding
        #expect(p.machine.state == .holding)
        let whileHolding = p.recenter()
        #expect(!whileHolding)
    }

    @Test func recenterBlendsToNeutralWithoutJump() {
        var p = HeadPosePipeline()
        var outs: [Quaternion] = []
        for i in 0...120 { outs.append(p.process(sample(yawQ(35), Double(i) * dt), now: Double(i) * dt).pose) }
        #expect(angleDeg(outs.last!, yawQ(35)) < 0.01)
        let recentered = p.recenter()
        #expect(recentered)
        outs.removeAll()
        for i in 121...240 { outs.append(p.process(sample(yawQ(35), Double(i) * dt), now: Double(i) * dt).pose) }
        let steps = zip(outs, outs.dropFirst()).map { angleDeg($0, $1) }
        #expect(steps.max()! < 35.0 / 15 * 1.6)                // smooth, not a 35° jump
        #expect(angleDeg(outs.last!, .identity) < 0.01)        // ends at neutral
    }

    @Test func fullLossAndReturnNeverJumps() {
        var p = HeadPosePipeline()
        var prev: Quaternion?
        var maxStep = 0.0
        var sawStatic = false
        for i in 0...600 {
            let t = Double(i) * dt
            let lost = t > 2 && t < 6
            let target = t < 6 ? yawQ(40) : yawQ(-30)
            let out = p.process(lost ? nil : sample(target, t), now: t)
            if out.state == .static { sawStatic = true }
            if let prev { maxStep = max(maxStep, angleDeg(prev, out.pose)) }
            prev = out.pose
        }
        #expect(sawStatic)
        #expect(maxStep < 70.0 / 15 * 1.6)
    }

    @Test func lowConfidenceSamplesDoNotReachFilter() {
        var p = HeadPosePipeline()
        for i in 0...60 { p.process(sample(yawQ(10), Double(i) * dt), now: Double(i) * dt) }
        // One bad sample: the pose coasts (frozen, state unchanged) and the bad 120° never reaches the filter.
        let first = p.process(sample(yawQ(120), 61 * dt, conf: 0.1), now: 61 * dt)
        #expect(first.state == .locked)
        #expect(angleDeg(first.pose, yawQ(10)) < 0.01)
        // Sustained bad samples (past the 0.1 s dwell) become a loss, still holding the pre-glitch pose.
        var out = first
        for k in 2...12 { out = p.process(sample(yawQ(120), Double(60 + k) * dt, conf: 0.1), now: Double(60 + k) * dt) }
        #expect(out.state == .holding)
        #expect(angleDeg(out.pose, yawQ(10)) < 0.01)
    }
}
