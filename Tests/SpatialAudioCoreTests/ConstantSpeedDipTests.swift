import Testing
import Foundation
@testable import SpatialAudioCore

/// Step 2f, item 2: what a short quality dip does to the output of the REAL pipeline while the head is turning at a constant speed.
///
/// Measured first (numbers in docs/STATUS.md, "Step 2f findings"): at 90 deg/s (3.00 deg per frame at 30 fps) the control's largest
/// per-frame step is 3.04 deg; a 1-frame dip gives 6.01 deg (1.98x) and a 2-frame dip 9.01 deg (2.96x). The pose coasts (frozen)
/// during the dip and then catches up in ONE step of (dip frames + 1) x the per-frame head motion. So the dip case IS clearly worse than
/// the control, by design of the coast. These tests do not call that good: they pin the two properties that are reasonable (the tracker
/// stays locked, and the catch-up never exceeds how far the head really moved during the dip: no overshoot, no snap) and that the
/// output is back on the control's trajectory right after. They deliberately do NOT assert that the pose keeps moving during the dip,
/// so a later, smoother coast would not fail them. The data is synthetic (a perfectly steady head and exact orientations); it says
/// nothing about a real camera.
@Suite struct ConstantSpeedTurnDipTests {
    static let fps = 30.0
    static let turnStartFrame = 30                       // 1.0 s of stillness lets the gate lock first (first lock needs 0.2 s)

    struct Run {
        /// Output pose step (degrees) from the previous frame, for every frame from the start of the turn (index = frame - 30).
        var steps: [Double]
        /// Tracker state for the same frames.
        var states: [TrackingState]
    }

    /// The head sits still for 1 s, then turns about +yaw at `speed` degrees per second. Frames in `dips` have quality 0.2 (below the
    /// gate's loss threshold of 0.40) but still carry the true orientation.
    func run(speed: Double, dips: Set<Int> = [], seconds: Double = 4) -> Run {
        var p = HeadPosePipeline()
        var prev: Quaternion?
        var steps: [Double] = [], states: [TrackingState] = []
        for k in 0..<Int(seconds * Self.fps) {
            let t = Double(k) / Self.fps
            let head = yawQ(t < 1.0 ? 0 : speed * (t - 1.0))
            let out = p.process(HeadPoseSample(orientation: head, confidence: dips.contains(k) ? 0.2 : 1.0, timestamp: t), now: t)
            if k >= Self.turnStartFrame {
                if let prev { steps.append(prev.angle(to: out.pose) * 180 / .pi) } else { steps.append(0) }
                states.append(out.state)
            }
            prev = out.pose
        }
        return Run(steps: steps, states: states)
    }

    static let speeds: [Double] = [45, 90, 180]

    @Test(arguments: speeds) func theControlTurnsTheOutputAtTheHeadsOwnSpeed(speed: Double) {
        let c = run(speed: speed)
        let perFrame = speed / Self.fps
        #expect(c.states.allSatisfy { $0 == .locked })
        #expect((c.steps.max() ?? 0) <= perFrame * 1.05, "max step \(c.steps.max() ?? 0) vs head \(perFrame) per frame")
        #expect(c.steps.suffix(60).allSatisfy { abs($0 - perFrame) < 0.02 * perFrame })             // settled: exactly the head's step
    }

    @Test(arguments: speeds, [1, 2]) func aShortDipKeepsTheTrackerLockedAndTheCatchUpIsNoBiggerThanTheHeadMoved(speed: Double, dipFrames: Int) {
        let first = 60
        let dips = Set(first..<(first + dipFrames))
        let r = run(speed: speed, dips: dips)
        let perFrame = speed / Self.fps
        #expect(r.states.allSatisfy { $0 == .locked }, "a \(dipFrames)-frame dip changed the state")
        // the largest step may be at most the head's motion over the dip frames plus the resume frame
        let bound = Double(dipFrames + 1) * perFrame * 1.05
        #expect((r.steps.max() ?? 0) <= bound, "max step \(r.steps.max() ?? 0) deg > bound \(bound) deg at \(speed) deg/s, \(dipFrames)-frame dip")
    }

    @Test(arguments: speeds, [1, 2]) func afterTheDipTheOutputIsBackOnTheControlsTrajectory(speed: Double, dipFrames: Int) {
        let first = 60
        let r = run(speed: speed, dips: Set(first..<(first + dipFrames)))
        let c = run(speed: speed)
        let resumeIndex = first + dipFrames - Self.turnStartFrame            // the catch-up frame
        for i in (resumeIndex + 2)..<r.steps.count {
            #expect(abs(r.steps[i] - c.steps[i]) < 0.05, "frame \(i + Self.turnStartFrame): \(r.steps[i]) vs control \(c.steps[i])")
        }
    }

    @Test(arguments: speeds, [1, 2]) func isolatedDipsDoNotAccumulate(speed: Double, dipFrames: Int) {
        var dips = Set<Int>()
        for start in [45, 60, 75, 90, 105] { for j in 0..<dipFrames { dips.insert(start + j) } }
        let r = run(speed: speed, dips: dips)
        let bound = Double(dipFrames + 1) * (speed / Self.fps) * 1.05
        #expect(r.states.allSatisfy { $0 == .locked })
        #expect((r.steps.max() ?? 0) <= bound, "max step \(r.steps.max() ?? 0) > \(bound)")
    }
}
