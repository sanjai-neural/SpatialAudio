import Testing
import Foundation
@testable import SpatialAudioCore

/// Step 2d, item 1: the quality gate with hysteresis and minimum dwell. The real 08:12 self-test showed the state
/// machine chattering (decaying, locked, holding, locked, holding, ... with a 0.07 s hold). These tests drive the real
/// pipeline with synthetic quality that hovers around the old 0.5 threshold, show that the OLD behaviour
/// (`QualityGateConfig.singleThreshold`) chatters, and prove the new default does not, while real loss and recovery still work.
@Suite struct QualityGateHysteresisTests {
    let dt = 1.0 / 30
    let pose = yawQ(20)

    /// Runs the pipeline for `seconds` at 30 fps with the quality given by `quality(t)` (nil = no face).
    /// Returns every distinct state change as "from>to" plus the final state and the largest output step.
    func run(_ gate: QualityGateConfig, seconds: Double, from start: Double = 0, pipeline: HeadPosePipeline? = nil,
             quality: (Double) -> Double?) -> (transitions: [String], pipeline: HeadPosePipeline, maxStepDegrees: Double, log: [(t: Double, state: TrackingState)]) {
        var p = pipeline ?? HeadPosePipeline(gate: gate)
        var last: TrackingState? = pipeline?.machine.state
        var prevPose: Quaternion? = pipeline?.machine.lastOutput
        var transitions: [String] = []
        var maxStep = 0.0
        var log: [(Double, TrackingState)] = []
        var t = start
        while t < start + seconds {
            let q = quality(t - start)
            let sample = q.map { HeadPoseSample(orientation: pose, confidence: $0, timestamp: t) }
            let out = p.process(sample, now: t)
            if let last, last != out.state { transitions.append("\(last.rawValue)>\(out.state.rawValue)") }
            if let prevPose { maxStep = max(maxStep, prevPose.angle(to: out.pose) * 180 / .pi) }
            last = out.state; prevPose = out.pose
            log.append((t, out.state))
            t += dt
        }
        return (transitions, p, maxStep, log)
    }

    /// 1.0 for the first second (so both gates are locked), then `hover(t)`.
    func hoverAfterLock(_ hover: @escaping (Double) -> Double) -> (Double) -> Double? {
        { t in t < 1.0 ? 1.0 : hover(t) }
    }

    // MARK: - the chatter, and its removal

    @Test func aSineHoveringAroundTheOldThresholdChattersWithoutTheGateAndNotWithIt() {
        // 0.38...0.62 at 3 Hz: crosses 0.5 six times a second, but is below 0.40 for only ~0.06 s per cycle.
        let q = hoverAfterLock { 0.5 + 0.12 * sin(2 * .pi * 3 * ($0 - 1.0)) }
        let old = run(.singleThreshold(0.5), seconds: 12, quality: q)
        let new = run(QualityGateConfig(), seconds: 12, quality: q)
        #expect(old.transitions.count >= 60, "the single threshold should chatter, saw \(old.transitions.count) transitions")
        #expect(old.transitions.contains("locked>holding") && old.transitions.contains("holding>locked"))
        #expect(new.transitions == ["static>locked"], "the new gate changed state \(new.transitions.count) times: \(new.transitions)")
    }

    @Test func noiseInsideTheHysteresisBandDoesNotChatterEither() {
        var noise = DeterministicNoise(seed: 7)
        let samples = (0..<400).map { _ in 0.5 + 0.09 * noise.next() }          // 0.41...0.59, all inside the band
        func q(_ t: Double) -> Double? { t < 1.0 ? 1.0 : samples[min(Int((t - 1.0) / dt), samples.count - 1)] }
        let old = run(.singleThreshold(0.5), seconds: 13, quality: q)
        let new = run(QualityGateConfig(), seconds: 13, quality: q)
        #expect(old.transitions.count >= 20)
        #expect(new.transitions == ["static>locked"])
    }

    @Test func aLostStateAlsoDoesNotChatterWhileQualityHoversBelowTheRecoveryThreshold() {
        // Never reaches 0.6 for long, so tracking must stay lost (static) instead of flickering on every good-looking frame.
        let q: (Double) -> Double? = { 0.5 + 0.12 * sin(2 * .pi * 3 * $0) }
        let old = run(.singleThreshold(0.5), seconds: 12, quality: q)
        let new = run(QualityGateConfig(), seconds: 12, quality: q)
        #expect(old.transitions.count >= 30)
        #expect(new.transitions.isEmpty, "\(new.transitions)")
        #expect(new.pipeline.machine.state == .static)
    }

    @Test func singleFrameAndShortDipsAcrossTheLossThresholdAreIgnored() {
        for lowFrames in [1, 2] {                     // 0.033 s and 0.067 s dips, shorter than the 0.1 s dwell
            let period = lowFrames + 4
            let q = hoverAfterLock { t in Int(((t - 1.0) / dt).rounded()) % period < lowFrames ? 0.0 : 1.0 }
            let new = run(QualityGateConfig(), seconds: 12, quality: q)
            #expect(new.transitions == ["static>locked"], "dips of \(lowFrames) frame(s): \(new.transitions)")
            #expect(new.maxStepDegrees < 20.5 + 1e-6)   // only the initial blend in from neutral, never a snap
        }
    }

    // MARK: - real loss and recovery still work

    @Test func aRealLossStillGoesHoldingDecayingStaticOnTime() {
        let q: (Double) -> Double? = { t in t < 2 ? 1.0 : nil }                     // face disappears at t = 2 s
        let r = run(QualityGateConfig(), seconds: 6, quality: q)
        #expect(r.transitions == ["static>locked", "locked>holding", "holding>decaying", "decaying>static"], "\(r.transitions)")
        let firstHolding = r.log.first { $0.state == .holding }!.t
        #expect(firstHolding >= 2 + 0.1 - 1e-9 && firstHolding <= 2 + 0.1 + dt + 1e-9, "loss declared at \(firstHolding)")
        let firstDecay = r.log.first { $0.state == .decaying }!.t
        #expect(abs((firstDecay - firstHolding) - 0.5) <= dt + 1e-9)               // hold is the configured 0.5 s, measured from the declared loss
        #expect(r.maxStepDegrees < 20.5 + 1e-6)                                    // never a jump (20° is the whole pose)
    }

    @Test func aLossIsAlsoDetectedWhenQualityIsLowButAFaceIsStillThere() {
        let q: (Double) -> Double? = { t in t < 2 ? 1.0 : 0.2 }
        let r = run(QualityGateConfig(), seconds: 4, quality: q)
        #expect(r.transitions.contains("locked>holding"))
        #expect(r.pipeline.machine.state == .static || r.pipeline.machine.state == .decaying)
    }

    @Test func recoveryNeedsAnUninterruptedGoodStretch() {
        let lost = run(QualityGateConfig(), seconds: 5, quality: { t in t < 1.0 ? 1.0 : nil })
        #expect(lost.pipeline.machine.state == .static)
        // 0.15 s of good quality, then bad again: not enough.
        var brief = run(QualityGateConfig(), seconds: 0.15, from: 10, pipeline: lost.pipeline, quality: { _ in 0.9 })
        #expect(brief.pipeline.machine.state != .locked)
        brief = run(QualityGateConfig(), seconds: 0.5, from: 10.2, pipeline: brief.pipeline, quality: { _ in 0.2 })
        #expect(brief.pipeline.machine.state != .locked)
        // 0.5 s of good quality: tracking resumes about 0.2 s in.
        let back = run(QualityGateConfig(), seconds: 0.6, from: 11, pipeline: brief.pipeline, quality: { _ in 0.9 })
        let relock = back.log.first { $0.state == .locked }
        #expect(relock != nil && relock!.t >= 11 + 0.2 - 1e-9 && relock!.t <= 11 + 0.2 + dt + 1e-9, "relocked at \(String(describing: relock?.t))")
        #expect(back.maxStepDegrees < 20.5 + 1e-6)
    }

    @Test func qualityInsideTheBandKeepsWhicheverDecisionWasMadeLast() {
        let lockedThenBand = run(QualityGateConfig(), seconds: 6, quality: { t in t < 1.0 ? 1.0 : 0.5 })
        #expect(lockedThenBand.transitions == ["static>locked"])                     // 0.5 is inside 0.40...0.60: stays locked
        let lostThenBand = run(QualityGateConfig(), seconds: 6, quality: { t in t < 1.0 ? nil : 0.5 })
        #expect(lostThenBand.transitions.isEmpty)                                    // 0.5 does not recover a lost track
    }

    @Test func framesThatStoppedArrivingAreLostImmediatelyWithoutTheDwell() {
        var p = run(QualityGateConfig(), seconds: 2, quality: { _ in 1.0 }).pipeline
        #expect(p.machine.state == .locked)
        let out = p.processFramesStopped(now: 2.05)
        #expect(out.state == .holding)                                                // no 0.1 s grace: the camera has gone quiet
        #expect(!p.gate.isTracking)
    }

    // MARK: - the gate itself

    @Test func gateDecisionsFollowTheDocumentedRules() {
        var g = QualityGate()                                  // 0.40 / 0.60 / 0.10 s / 0.20 s
        #expect(g.update(quality: 0.9, at: 0.00) == .lost)     // recovery dwell starts
        #expect(g.update(quality: 0.9, at: 0.10) == .lost)
        #expect(g.update(quality: 0.9, at: 0.20) == .good)     // 0.2 s of good: tracking
        #expect(g.update(quality: 0.5, at: 0.30) == .good)     // inside the band: still good
        #expect(g.update(quality: 0.39, at: 0.40) == .coast)   // dip starts
        #expect(g.update(quality: 0.39, at: 0.49) == .coast)   // 0.09 s: not yet
        #expect(g.update(quality: 0.39, at: 0.50) == .lost)    // 0.10 s: loss
        #expect(g.update(quality: 0.5, at: 0.60) == .lost)     // 0.5 < 0.60: does not recover
    }

    @Test func aGoodFrameResetsTheLossCountdownAndABadOneResetsTheRecoveryCountdown() {
        var g = QualityGate()
        _ = g.update(quality: 1, at: 0); _ = g.update(quality: 1, at: 0.2)
        #expect(g.isTracking)
        #expect(g.update(quality: 0.1, at: 1.00) == .coast)
        #expect(g.update(quality: 0.9, at: 1.08) == .good)     // recovered inside the dwell: countdown cleared
        #expect(g.update(quality: 0.1, at: 1.10) == .coast)    // a NEW countdown starts here, not at 1.00
        #expect(g.update(quality: 0.1, at: 1.19) == .coast)
        #expect(g.update(quality: 0.1, at: 1.20) == .lost)
        #expect(g.update(quality: 0.9, at: 2.00) == .lost)
        #expect(g.update(quality: 0.2, at: 2.10) == .lost)     // a bad frame cancels the recovery countdown
        #expect(g.update(quality: 0.9, at: 2.20) == .lost)
        #expect(g.update(quality: 0.9, at: 2.39) == .lost)
        #expect(g.update(quality: 0.9, at: 2.40) == .good)
    }

    @Test func nonFiniteQualityCountsAsZeroAndForceLostResets() {
        var g = QualityGate()
        _ = g.update(quality: 1, at: 0); _ = g.update(quality: 1, at: 0.2)
        #expect(g.update(quality: .nan, at: 0.3) == .coast)
        g.forceLost()
        #expect(!g.isTracking)
        #expect(g.update(quality: 1, at: 0.4) == .lost)
    }

    @Test func theSingleThresholdConfigReproducesTheOldBehaviour() {
        var g = QualityGate(config: .singleThreshold(0.5))
        #expect(g.update(quality: 0.5, at: 0) == .good)
        #expect(g.update(quality: 0.49, at: 0.03) == .lost)
        #expect(g.update(quality: 0.5, at: 0.06) == .good)
    }

    @Test func coastKeepsStateAndPoseAndOnlyAdvancesTheClock() {
        var m = TrackingStateMachine()
        _ = m.update(at: 0, pose: yawQ(30))
        let locked = m.update(at: 0.1, pose: yawQ(30))
        let c = m.coast(at: 0.2)
        #expect(c.state == .locked && c.pose == locked.pose && m.lastUpdateTime == 0.2)
        _ = m.coast(at: 0.1)                                   // time never runs backwards
        #expect(m.lastUpdateTime == 0.2)
    }
}
