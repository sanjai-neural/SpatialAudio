import Testing
import Foundation
import SpatialAudioCore
@testable import SpatialAudioEngine

// Step 3b: the audio half of head-tracked listening, on VIRTUAL time with a recording fake output (no device, no camera, no sleeps).
// The pump is stepped directly (`session.pump.step(dt:)`), the camera side is the real `HeadPosePipeline` fed with made-up samples.
// NOT checked here: the real timers, the real EnvironmentRenderer with this session, the camera, and how any of it sounds (UNVERIFIED until Sanjai has listened).

final class TrackedFakeOutput: BlindListeningOutput, @unchecked Sendable {
    enum Event: Equatable { case volume(Float), source(Vector3), listener(ListenerOrientation), started, stopped }
    private let lock = NSLock()
    private var _events: [Event] = []
    private var _volume: Float = 0
    var events: [Event] { lock.lock(); defer { lock.unlock() }; return _events }
    var outputVolume: Float {
        get { lock.lock(); defer { lock.unlock() }; return _volume }
        set { lock.lock(); _volume = newValue; _events.append(.volume(newValue)); lock.unlock() }
    }
    var isRunning: Bool { true }
    var notice: String? { nil }
    func start() throws { lock.lock(); _events.append(.started); lock.unlock() }
    func stop() { lock.lock(); _events.append(.stopped); lock.unlock() }
    func setListener(_ o: ListenerOrientation) { lock.lock(); _events.append(.listener(o)); lock.unlock() }
    func setSourcePosition(_ p: Vector3) { lock.lock(); _events.append(.source(p)); lock.unlock() }
    var listeners: [ListenerOrientation] { events.compactMap { if case .listener(let o) = $0 { o } else { nil } } }
}

@Suite("SteadyNoise") struct SteadyNoiseTests {
    private func rmsDB(_ x: ArraySlice<Float>) -> Double {
        var s = 0.0; for v in x { s += Double(v) * Double(v) }
        return 20 * log10((s / Double(x.count)).squareRoot())
    }

    @Test func levelLengthAndDeterminism() {
        for rate in [44_100.0, 48_000.0] {
            let n = SteadyNoise(sampleRate: rate)
            let a = n.makeLoop()
            #expect(a.count == Int((4 * rate).rounded()))
            #expect(abs(rmsDB(a[...]) - (-30)) < 0.05)
            #expect(a.map { abs($0) }.max()! < 0.4)                       // far from clipping
            #expect(a == n.makeLoop())                                    // same loop every time
        }
    }

    @Test func steadyWithNoGapsEveryWindowWithinOneAndAHalfDecibel() {
        // Measured once: all 200 ms windows (50 % overlap) lie within +-0.36 dB of the loop's RMS at 44.1 and 48 kHz; the bound is looser than that.
        // The old burst loop (0.3 s bursts, 0.2 s silence) would fail this by tens of decibels.
        let rate = 48_000.0
        let l = SteadyNoise(sampleRate: rate).makeLoop()
        let overall = rmsDB(l[...])
        let w = Int(0.2 * rate)
        var i = 0
        while i + w <= l.count {
            #expect(abs(rmsDB(l[i..<(i + w)]) - overall) < 1.5, "window at \(i)")
            i += w / 2
        }
        let burst = TestTone(sampleRate: rate).makeLoop()
        let silent = burst[0..<Int(0.15 * rate)]
        #expect(rmsDB(silent) < overall - 40)                             // the control: the burst loop does have gaps
    }

    @Test func theSeamContinuesTheNoiseInsteadOfCuttingIt() {
        // A jump across the seam is invisible in a single sample of noise (a hard cut of this noise has about the same step size as any neighbouring pair), so the
        // test uses what a real continuation has and a cut does not: correlation between the last and the first sample. Neighbouring samples of this noise have a
        // normalised lag-1 correlation of about 0.71 (measured inside the loop); averaged over 200 seeds the pair across the seam gave 0.72 with the crossfade and
        // about 0 for a hard cut (independent samples), so 0.5 separates them with a wide margin (the mean over 200 seeds has a spread of about 0.07).
        var sum = 0.0
        for seed in 1...200 {
            var n = SteadyNoise(sampleRate: 48_000); n.seed = UInt64(seed) * 7919
            n.loopSeconds = 1; n.crossfadeSeconds = 0.1                    // shorter loops keep the 200 draws fast; the correlation does not depend on the length
            let l = n.makeLoop()
            var power = 0.0
            for v in l { power += Double(v) * Double(v) }
            sum += Double(l[l.count - 1]) * Double(l[0]) / (power / Double(l.count))
        }
        #expect(sum / 200 > 0.5, "mean seam correlation \(sum / 200)")
    }
}

@Suite("TrackedListeningSession") struct TrackedListeningSessionTests {
    private func make(volume: Double = TrackedListeningPolicy.defaultVolume) -> (TrackedListeningSession, TrackedFakeOutput) {
        let out = TrackedFakeOutput()
        return (TrackedListeningSession(output: out, sampleRate: 48_000, volume: volume), out)
    }
    private func pose(_ y: Double, _ p: Double, _ r: Double) -> Quaternion { Quaternion(euler: EulerAngles(yawDegrees: y, pitchDegrees: p, rollDegrees: r)) }
    /// A step long enough for the interpolator to arrive (alpha = 1 - exp(-1 / 0.02)).
    private func settle(_ s: TrackedListeningSession) -> ListenerPosePump.Applied { s.pump.step(dt: 1.0) }

    @Test func startsWithTheVolumeAndTheToneInPlaceBeforeTheEngineAndEndsSilent() throws {
        let (s, out) = make(volume: 0.9)                                   // asks for more than the cap
        try s.start()
        s.stop()
        let ev = out.events
        let started = try #require(ev.firstIndex(of: .started))
        #expect(ev.first == .volume(Float(TrackedListeningPolicy.maximumVolume)))    // capped, and the very first thing that happens
        #expect(ev[..<started].contains(.source(Vector3.direction(azimuthDegrees: 0, elevationDegrees: 0, distance: ListeningTest.sourceDistance))))
        #expect(ev[..<started].contains { if case .listener = $0 { true } else { false } })   // the neutral listener is placed before any sound
        #expect(ev.suffix(2) == [.volume(0), .stopped])                    // silence first, then the engine stops
        #expect(s.snapshot.running == false)
    }

    @Test func theDefaultVolumeIsTheLowOneAndTheCapAlwaysApplies() throws {
        let (s, out) = make()
        #expect(s.snapshot.volume == 0.15)
        try s.start()
        s.setVolume(5)
        #expect(out.outputVolume == Float(TrackedListeningPolicy.maximumVolume))
        s.setVolume(0.25)
        #expect(out.outputVolume == 0.25)
        s.setVolume(-1)
        #expect(out.outputVolume == 0)
        s.stop()
    }

    @Test func rollNeverReachesTheListener() {
        let (s, out) = make()
        s.publish(pose: pose(30, -10, 45), timestamp: 1)
        let a = settle(s)
        #expect(abs(a.pose.euler.rollDegrees) < 1e-6)
        #expect(abs(a.pose.euler.yawDegrees - 30) < 1e-6 && abs(a.pose.euler.pitchDegrees - (-10)) < 1e-6)
        // the listener the renderer received equals the one for the same yaw and pitch without any roll
        let expected = ListenerFrame.orientation(for: pose(30, -10, 0))
        #expect(!(out.listeners.last!.differs(from: expected, tolerance: 1e-9)))
        #expect(s.snapshot.published == 1 && s.snapshot.rejected == 0)
    }

    @Test func aPureTiltChangesNothing() {
        let (s, _) = make()
        _ = settle(s)
        for i in 0..<90 {                                                   // 3 s of 30 Hz frames, roll swinging +-60 degrees
            let r = 60 * sin(Double(i) * 0.4)
            s.publish(pose: pose(0, 0, r), timestamp: Double(i) / 30)
            let a = s.pump.step(dt: 1.0 / 30)
            #expect(!a.orientation.differs(from: .neutral, tolerance: 1e-9), "roll \(r) moved the listener")
        }
        #expect(s.snapshot.published == 90)
    }

    @Test func interpolatingBetweenPosesNeverLeavesARollAtTheOutput() {
        // Two roll-free poses with different yaw AND pitch: the shortest-path interpolation between them is not roll-free in between.
        // The pump's output mapping removes that; the renderer's listener must stay level (right vector horizontal) on every block and the card's "sent" roll is 0 to 1e-12 degrees.
        let (s, out) = make()
        _ = settle(s)
        let targets = [pose(60, 40, 0), pose(-50, -30, 0), pose(80, -45, 0), pose(-70, 35, 0)]
        for (n, target) in targets.enumerated() {
            s.publish(pose: target, timestamp: Double(n))
            for _ in 0..<40 { s.pump.step(dt: 512.0 / 48_000) }
            #expect(abs(s.snapshot.sent?.rollDegrees ?? 99) < 1e-12, "sent roll")            // a quaternion round trip leaves about 1e-15 degrees, not exactly 0.0
        }
        #expect(out.listeners.count > 20)
        for o in out.listeners { #expect(abs(o.right.y) < 1e-12, "right.y \(o.right.y)") }
    }

    @Test func aNonFinitePoseIsRefusedAndNothingMoves() {
        let (s, _) = make()
        s.publish(pose: pose(20, 5, 0), timestamp: 1)
        let before = settle(s)
        s.publish(pose: Quaternion(w: .nan, x: 0, y: 0, z: 0), timestamp: 2)
        s.publish(pose: Quaternion(w: .infinity, x: 0, y: 0, z: 0), timestamp: 3)
        let after = settle(s)
        #expect(s.snapshot.rejected == 2 && s.snapshot.published == 1)
        #expect(after.pose.angle(to: before.pose) < 1e-9)
    }
}

/// Face loss and re-acquisition through the REAL chain: HeadPosePipeline (quality gate, One-Euro filter, calibration, state machine) -> `publish` -> mailbox -> the real
/// `ListenerPosePump` (interpolation, `ListenerFrame`) -> the fake output. Virtual time, no sleeps. The tracker's watchdog is replayed as the pipeline's
/// `processFramesStopped` call every 50 ms once no frame has arrived for 250 ms, which is what `HeadTracker.watchdogTick` does.
@Suite("TrackedListening face loss") struct TrackedListeningFaceLossTests {
    struct Trace { var time: Double; var forward: Vector3; var state: TrackingState }

    private let block = 512.0 / 48_000
    private let frameDt = 1.0 / 30

    private func run() -> (traces: [Trace], endForward: Vector3) {
        let out = TrackedFakeOutput()
        let session = TrackedListeningSession(output: out, sampleRate: 48_000, volume: 0)
        var pipe = HeadPosePipeline()
        var state = TrackingState.static
        var traces: [Trace] = []
        var lastFrame = -1.0
        // yaw 0 for 1 s, smoothstep to 30 degrees LEFT over 1 s (t 1...2), hold; frames stop at t = 4.0; frames return at t = 7.0
        func yawAt(_ t: Double) -> Double { let u = min(max(t - 1, 0), 1); return 30 * u * u * (3 - 2 * u) }
        let lossStart = 4.0, resume = 7.0, end = 9.5
        var nextFrame = 0.0, nextWatchdog = 0.0
        var t = 0.0
        session.pump.step(dt: 0)
        while t < end {
            // camera frames (30 Hz) except during the loss
            while nextFrame <= t {
                if nextFrame < lossStart || nextFrame >= resume {
                    let q = Quaternion(euler: EulerAngles(yawDegrees: yawAt(nextFrame), pitchDegrees: 0, rollDegrees: 0))
                    let o = pipe.process(HeadPoseSample(orientation: q, confidence: 1, timestamp: nextFrame), now: nextFrame)
                    state = o.state; lastFrame = nextFrame
                    session.publish(pose: o.pose, timestamp: nextFrame)
                }
                nextFrame += frameDt
            }
            // watchdog: 50 ms interval, acts only when no frame for more than 250 ms
            while nextWatchdog <= t {
                if lastFrame >= 0, nextWatchdog - lastFrame > 0.25, nextWatchdog < resume {
                    let o = pipe.processFramesStopped(now: nextWatchdog)
                    state = o.state
                    session.publish(pose: o.pose, timestamp: nextWatchdog)
                }
                nextWatchdog += 0.05
            }
            let a = session.pump.step(dt: block)
            traces.append(Trace(time: t, forward: a.orientation.forward, state: state))
            t += block
        }
        return (traces, traces.last!.forward)
    }

    private func angle(_ a: Vector3, _ b: Vector3) -> Double { acos(min(max(a.dot(b), -1), 1)) * 180 / .pi }

    @Test func faceLossHoldsDecaysAndComesBackWithoutAJump() {
        let (tr, endForward) = run()
        // The bounds come from the DESIGN values written here, not from the code's configuration (a mutant that changes the configuration must not change the bound):
        // hold 0.5 s, decay 1.5 s, re-acquire blend 0.25 s, interpolator time constant 20 ms (the documented placeholders). The camera updates the pose at 30 Hz and the
        // watchdog at 20 Hz, so the state machine's smoothstep arrives as steps; a smoothstep over D seconds covering A degrees peaks at 1.5 A / D degrees per second, so
        // the largest step is that times the update period; the interpolator passes a step on over several blocks, at most alpha = 1 - exp(-block / tau) of it in the first.
        // The bound is 1.5 times that first-block share (UNTUNED margin). A jump (decay or blend of 0 seconds, or no interpolator smoothing) lands far above it.
        let cfg = TrackingStateMachineConfig()
        #expect(cfg.holdDuration == 0.5 && cfg.decayDuration == 1.5 && cfg.reacquireBlendDuration == 0.25)
        #expect(PoseInterpolator.Config().timeConstant == 0.020)
        let A = 30.0, alpha = 1 - exp(-block / 0.020)
        let ramp = 1.5 * alpha * (1.5 * A / 1.0 * frameDt)                       // the head's own 1 s turn, one step per camera frame
        let decay = 1.5 * alpha * (1.5 * A / 1.5 * 0.05)                         // one step per watchdog tick
        let reacquire = 1.5 * alpha * (1.5 * A / 0.25 * frameDt)                 // one step per camera frame
        var maxRamp = 0.0, maxLoss = 0.0, maxResume = 0.0, maxHold = 0.0
        for i in 1..<tr.count {
            let d = angle(tr[i].forward, tr[i - 1].forward), t = tr[i].time
            if t >= 1.0 && t < 3.0 { maxRamp = max(maxRamp, d) }
            if t >= 4.6 && t < 7.0 { maxLoss = max(maxLoss, d) }                 // from the end of the stall (4.0 + 0.25 s watchdog + settling) to the first frame back
            if t >= 4.3 && t < 4.8 { maxHold = max(maxHold, d) }
            if t >= 7.0 { maxResume = max(maxResume, d) }
        }
        #expect(maxRamp > 0.2 && maxRamp < ramp, "ramp \(maxRamp) bound \(ramp)")            // not vacuous, and smooth even though frames come at 30 Hz
        #expect(maxHold < 0.05, "hold \(maxHold)")                                           // frozen while holding
        #expect(maxLoss > 0.1 && maxLoss < decay, "loss \(maxLoss) bound \(decay)")          // the decay really moves, but never jumps
        #expect(maxResume > 0.2 && maxResume < reacquire, "resume \(maxResume) bound \(reacquire)")
        // The whole run: the largest single step anywhere is small against a 30 degree swing.
        let worst = (1..<tr.count).map { angle(tr[$0].forward, tr[$0 - 1].forward) }.max()!
        #expect(worst < max(ramp, decay, reacquire), "worst \(worst)")

        // It went to neutral while the face was gone, was static, and followed the head again afterwards (yaw LEFT 30: the fixed source's relative position rotates).
        let beforeResume = tr.last { $0.time < 6.9 }!
        #expect(beforeResume.state == .static)
        #expect(angle(beforeResume.forward, ListenerOrientation.neutral.forward) < 0.1)
        let expectedEnd = ListenerFrame.orientation(for: Quaternion(euler: EulerAngles(yawDegrees: 30, pitchDegrees: 0, rollDegrees: 0))).forward
        #expect(angle(endForward, expectedEnd) < 0.5)
        // states went through the documented order
        var seen: [TrackingState] = []
        for x in tr where seen.last != x.state { seen.append(x.state) }
        #expect(seen == [.static, .locked, .holding, .decaying, .static, .locked])
    }
}
