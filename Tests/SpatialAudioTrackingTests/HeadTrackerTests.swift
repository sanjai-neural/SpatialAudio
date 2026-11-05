import Testing
import Foundation
import SpatialAudioCore
@testable import SpatialAudioTracking

/// Fake provider: tests push detections by hand; no camera involved.
final class FakeProvider: HeadPoseProvider, @unchecked Sendable {
    var now = 0.0
    var started = false
    var stopped = false
    var startError: Error?
    var handler: (@Sendable (HeadPoseDetection) -> Void)?
    var sourceDescription: String? { started ? "fake" : nil }
    func currentTime() -> Double { now }
    func start(handler: @escaping @Sendable (HeadPoseDetection) -> Void) async throws {
        if let startError { throw startError }
        started = true; self.handler = handler
    }
    func stop() { stopped = true; started = false; handler = nil }
}

let deg2rad = Double.pi / 180

let goodBox = NormalizedRect(x: 0.3, y: 0.25, width: 0.3, height: 0.45)

func detection(at t: Double, yaw: Double = 0, pitch: Double = 0, roll: Double = 0,
               face: Bool = true, mirrored: Bool = false, confidence: Double = 1,
               box: NormalizedRect = goodBox,
               received: Double? = nil, detected: Double? = nil) -> HeadPoseDetection {
    HeadPoseDetection(
        captureTime: t, receivedAt: received ?? t, detectedAt: detected ?? t,
        face: face ? FaceMeasurement(angles: VisionFaceAngles(yaw: yaw * deg2rad, pitch: pitch * deg2rad, roll: roll * deg2rad),
                                     confidence: confidence, boundingBox: box) : nil,
        facesDetected: face ? 1 : 0, frameMirrored: mirrored)
}

@Suite struct HeadTrackerTests {
    let dt = 1.0 / 30

    /// Feed `seconds` of identical detections and return the last snapshot.
    func feed(_ tracker: HeadTracker, from t0: Double, seconds: Double,
              _ make: (Double) -> HeadPoseDetection) -> TrackingSnapshot {
        var t = t0
        var last: TrackingSnapshot!
        while t <= t0 + seconds + 1e-9 { last = tracker.ingest(make(t)); t += dt }
        return last
    }

    @Test func lockedPoseFollowsMappedFaceAngles() {
        let fake = FakeProvider(); fake.now = 10
        let t = HeadTracker(provider: fake)
        let s = feed(t, from: 0, seconds: 2) { detection(at: $0, yaw: 30, pitch: 10, roll: 5) }
        #expect(s.state == .locked)
        // Pitch is negated by the mapping (Vision: positive = down).
        #expect(abs(s.euler.yawDegrees - 30) < 0.5)
        #expect(abs(s.euler.pitchDegrees - (-10)) < 0.5)
        #expect(abs(s.euler.rollDegrees - 5) < 0.5)
        #expect(s.facesDetected == 1)
        #expect(s.visionAngles != nil && s.mappedRawEuler != nil)
    }

    @Test func mirroredFrameFlipsYaw() {
        let fake = FakeProvider()
        let t = HeadTracker(provider: fake)
        let s = feed(t, from: 0, seconds: 2) { detection(at: $0, yaw: 30, mirrored: true) }
        #expect(abs(s.euler.yawDegrees - (-30)) < 0.5)
        #expect(s.frameMirrored)
    }

    @Test func mappingOverrideTakesEffect() {
        let fake = FakeProvider()
        let t = HeadTracker(provider: fake)
        t.setMapping(HeadAngleMapping(invertYaw: true))
        let s = feed(t, from: 0, seconds: 2) { detection(at: $0, yaw: 30) }
        #expect(abs(s.euler.yawDegrees - (-30)) < 0.5)
    }

    @Test func latencyFieldsAreDerivedFromTimestamps() {
        let fake = FakeProvider(); fake.now = 5.050
        let t = HeadTracker(provider: fake)
        let s = t.ingest(detection(at: 5.000, received: 5.020, detected: 5.040))
        #expect(abs(s.deliveryLatency - 0.020) < 1e-9)
        #expect(abs(s.visionDuration - 0.020) < 1e-9)
        #expect(abs(s.captureToPoseLatency - 0.050) < 1e-9)
    }

    @Test func fpsEstimateConvergesToFrameRate() {
        let fake = FakeProvider()
        let t = HeadTracker(provider: fake)
        let s = feed(t, from: 0, seconds: 3) { detection(at: $0) }
        #expect(abs(s.framesPerSecond - 30) < 0.5)
    }

    @Test func faceLossHoldsThenDecaysAndNeverJumps() {
        let fake = FakeProvider()
        let t = HeadTracker(provider: fake)
        _ = feed(t, from: 0, seconds: 2) { detection(at: $0, yaw: 40) }
        var prev: Quaternion?
        var maxStep = 0.0
        var states = Set<TrackingState>()
        var tt = 2.0 + dt
        while tt < 6 {
            let s = t.ingest(detection(at: tt, face: false))
            states.insert(s.state)
            if let prev { maxStep = max(maxStep, prev.angle(to: s.pose) * 180 / .pi) }
            prev = s.pose
            #expect(s.visionAngles == nil && s.facesDetected == 0)
            tt += dt
        }
        #expect(states == [.locked, .holding, .decaying, .static])   // .locked = the 0.1 s the gate coasts before it declares the loss
        #expect(maxStep < 40.0 / 45 * 1.6)         // 1.5 s decay at 30 fps = 45 frames, smoothstep peak 1.5x
        #expect(prev!.angle(to: .identity) < 1e-9)
    }

    @Test func recenterMakesCurrentPoseNeutral() {
        let fake = FakeProvider()
        let t = HeadTracker(provider: fake)
        _ = feed(t, from: 0, seconds: 2) { detection(at: $0, yaw: 25) }
        #expect(t.recenter())
        let s = feed(t, from: 2 + dt, seconds: 2) { detection(at: $0, yaw: 25) }
        #expect(abs(s.euler.yawDegrees) < 0.5)
        // A further 10° turn is reported relative to the new neutral.
        let s2 = feed(t, from: 4 + dt, seconds: 2) { detection(at: $0, yaw: 35) }
        #expect(abs(s2.euler.yawDegrees - 10) < 0.5)
    }

    @Test func recenterRefusedWithoutLock() {
        let t = HeadTracker(provider: FakeProvider())
        #expect(!t.recenter())
    }

    @Test func snapshotHandlerReceivesEveryFrame() async throws {
        let fake = FakeProvider()
        let t = HeadTracker(provider: fake, config: noWatchdogConfig())   // a real watchdog tick must not add snapshots
        let box = Box()
        t.setSnapshotHandler { box.append($0) }
        try await t.start()
        for i in 0..<5 { fake.handler?(detection(at: Double(i) * dt)) }
        #expect(box.count == 5)
        t.stop()
        #expect(fake.stopped)
    }

    @Test func startErrorsPropagate() async {
        let fake = FakeProvider()
        fake.startError = HeadPoseProviderError.cameraAccessDenied
        let t = HeadTracker(provider: fake)
        await #expect(throws: HeadPoseProviderError.cameraAccessDenied) { try await t.start() }
    }

    @Test func calibrationSurvivesRestart() async throws {
        let fake = FakeProvider()
        let t = HeadTracker(provider: fake, config: noWatchdogConfig())
        _ = feed(t, from: 0, seconds: 2) { detection(at: $0, yaw: 25) }
        #expect(t.recenter())
        try await t.start()                                  // restart: fresh filter/state, same neutral
        var last: TrackingSnapshot!
        var tt = 0.0
        while tt < 2 { last = t.ingest(detection(at: tt, yaw: 25)); tt += dt }
        #expect(abs(last.euler.yawDegrees) < 0.5)
    }
}

// MARK: - Quality gating and watchdog

/// Polls `condition` until it holds. Fails (returns false) only after `timeout` seconds of AWAKE time:
/// `SuspendingClock` stops advancing while the Mac sleeps, so a system sleep or a frozen process can never
/// produce a spurious timeout. Never derive a pass/fail verdict from a fixed sleep or a wall-clock deadline.
func waitUntil(timeout: Double = 20, _ condition: () -> Bool) async -> Bool {
    let clock = SuspendingClock()
    let deadline = clock.now.advanced(by: .seconds(timeout))
    while !condition() {
        if clock.now >= deadline { return false }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return true
}

/// A tracker config whose watchdog can never fire during a test that is not about the watchdog.
func noWatchdogConfig() -> HeadTrackerConfig {
    var c = HeadTrackerConfig()
    c.frameTimeout = 3600
    return c
}

/// Thread-safe settable clock for driving the watchdog deterministically.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = 1000.0
    func read() -> Double { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ dt: Double) { lock.lock(); t += dt; lock.unlock() }
}

@Suite struct QualityGateTests {
    let dt = 1.0 / 30

    @Test func lowQualityFaceFreezesThePoseAndCountsAsLossOnlyAfterTheDwell() {
        let t = HeadTracker(provider: FakeProvider())
        var tt = 0.0
        var locked: TrackingSnapshot!
        while tt < 2 { locked = t.ingest(detection(at: tt, yaw: 20)); tt += dt }
        #expect(locked.state == .locked && locked.quality.overall == 1)
        // The face shrinks to a tiny box (far away / badly detected): quality 0 even though Vision still reports angles.
        let tiny = NormalizedRect(x: 0.4, y: 0.4, width: 0.03, height: 0.04)
        let first = t.ingest(detection(at: tt, yaw: 70, box: tiny)); tt += dt
        #expect(first.quality.overall == 0 && first.quality.limiting == "size")
        #expect(first.state == .locked)                       // one bad frame is not yet a loss: the pose coasts
        #expect(abs(first.euler.yawDegrees - 20) < 1)         // the bad angles (70°) never reached the pose
        var last = first
        while tt < 2 + 0.3 { last = t.ingest(detection(at: tt, yaw: 70, box: tiny)); tt += dt }
        #expect(last.state == .holding)                       // sustained low quality (> 0.1 s) is a loss
        #expect(abs(last.euler.yawDegrees - 20) < 1)
    }

    @Test func singleGlitchFrameIsRejectedAndTrackingRecoversWithoutJump() {
        let t = HeadTracker(provider: FakeProvider())
        var tt = 0.0
        while tt < 2 { _ = t.ingest(detection(at: tt, yaw: 20)); tt += dt }
        var maxStep = 0.0
        var prev = t.ingest(detection(at: tt, yaw: 20)).pose; tt += dt
        let glitch = t.ingest(detection(at: tt, yaw: 20, box: NormalizedRect(x: 0.62, y: 0.25, width: 0.3, height: 0.45)))  // box jumps ~0.71 face sizes, stays inside the frame
        #expect(glitch.quality.limiting == "center jump" && glitch.state == .locked)   // coasted: not even a hold for one bad frame
        #expect(glitch.pose == prev)
        maxStep = max(maxStep, prev.angle(to: glitch.pose) * 180 / .pi); prev = glitch.pose; tt += dt
        for _ in 0..<45 {
            let s = t.ingest(detection(at: tt, yaw: 20)); tt += dt
            maxStep = max(maxStep, prev.angle(to: s.pose) * 180 / .pi); prev = s.pose
        }
        #expect(maxStep < 1)                                   // same real pose throughout: no visible jump
        #expect(t.ingest(detection(at: tt, yaw: 20)).state == .locked)
    }

    @Test func snapshotExposesQualityBreakdownAndVisionConfidenceSeparately() {
        let t = HeadTracker(provider: FakeProvider())
        let s = t.ingest(detection(at: 0, confidence: 0.88))
        #expect(s.confidence == 0.88)
        #expect(s.quality.visionConfidence == 1 && s.quality.facePresent)
    }
}

@Suite struct WatchdogTests {
    let dt = 1.0 / 30

    func makeTracker(timeout: Double = 0.25) -> (HeadTracker, FakeClock) {
        var cfg = HeadTrackerConfig()
        cfg.frameTimeout = timeout
        let clock = FakeClock()
        return (HeadTracker(provider: FakeProvider(), config: cfg, clock: { clock.read() }), clock)
    }

    /// Delivers frames at 30 fps (advancing the fake monotonic clock) for `seconds`.
    func frames(_ t: HeadTracker, _ clock: FakeClock, from t0: Double, seconds: Double, yaw: Double = 40) -> (TrackingSnapshot, Double) {
        var tt = t0
        var last: TrackingSnapshot!
        while tt <= t0 + seconds + 1e-9 {
            last = t.ingest(detection(at: tt, yaw: yaw)); clock.advance(dt); tt += dt
        }
        return (last, tt)
    }

    @Test func noTickBeforeFirstFrame() {
        let (t, clock) = makeTracker()
        let box = Box(); t.setSnapshotHandler { box.append($0) }
        clock.advance(10); t.watchdogTick()
        #expect(box.count == 0)
    }

    @Test func noTickWhileFramesAreFreshEnough() {
        let (t, clock) = makeTracker()
        let box = Box(); t.setSnapshotHandler { box.append($0) }
        _ = frames(t, clock, from: 0, seconds: 1)
        let before = box.count
        clock.advance(0.20); t.watchdogTick()                  // 200 ms < 250 ms timeout
        #expect(box.count == before)
    }

    @Test func frameSilenceHoldsThenDecaysThenGoesStatic() {
        let (t, clock) = makeTracker()
        let box = Box(); t.setSnapshotHandler { box.append($0) }
        _ = frames(t, clock, from: 0, seconds: 2)
        let log = Box()
        t.setSnapshotHandler { log.append($0) }                // watchdog ticks only from now on
        // Camera goes silent. Tick the watchdog every 50 ms of monotonic time for 5 s.
        for _ in 0..<100 { clock.advance(0.05); t.watchdogTick() }
        let states = log.all.map(\.state)
        let poses = log.all.map(\.pose)
        #expect(states.contains(.holding) && states.contains(.decaying))
        #expect(states.last == .static)
        #expect(poses.last!.angle(to: .identity) < 1e-9)
        // Pose is continuous and decays monotonically toward neutral.
        var maxStepDeg = 0.0
        for (a, b) in zip(poses, poses.dropFirst()) { maxStepDeg = max(maxStepDeg, a.angle(to: b) * 180 / .pi) }
        #expect(maxStepDeg < 40.0 / 30 * 1.6)                  // 1.5 s decay at 20 Hz = 30 steps
        let angles = poses.map { $0.angle(to: .identity) }
        for (a, b) in zip(angles, angles.dropFirst()) { #expect(b <= a + 1e-9) }
    }

    @Test func timeoutIsMeasuredOnTheMonotonicClockNotCameraTimestamps() {
        let (t, clock) = makeTracker()
        let box = Box(); t.setSnapshotHandler { box.append($0) }
        // Camera timestamps jump around wildly; only the monotonic clock decides staleness.
        _ = t.ingest(detection(at: 5000, yaw: 10))
        let n = box.count
        clock.advance(0.1); t.watchdogTick()
        #expect(box.count == n)
        clock.advance(0.2); t.watchdogTick()                  // 0.3 s since the last frame
        #expect(box.count == n + 1)
    }

    @Test func watchdogSnapshotsAreFlaggedAndCarryNoFace() throws {
        let (t, clock) = makeTracker()
        let log = Box()
        t.setSnapshotHandler { log.append($0) }
        _ = frames(t, clock, from: 0, seconds: 1)
        clock.advance(0.4); t.watchdogTick()
        let s = try #require(log.last)
        #expect(s.isWatchdogTick && s.visionAngles == nil && s.facesDetected == 0)
        #expect(abs(s.frameAge - 0.4 - 0) < 0.05 && s.state == .holding)
        #expect(s.quality.limiting == "no frames" && s.quality.overall == 0)
    }

    @Test func framesResumingAfterTimeoutBlendBackWithoutJump() {
        let (t, clock) = makeTracker()
        let log = Box()
        var (_, tt) = frames(t, clock, from: 0, seconds: 2, yaw: 40)
        t.setSnapshotHandler { log.append($0) }
        for _ in 0..<12 { clock.advance(0.05); t.watchdogTick() }          // 0.6 s silence -> into decay
        let beforeResume = log.all.last!.pose
        #expect(beforeResume.angle(to: .identity) > 0.1)                   // not yet at neutral
        var maxStep = 0.0
        var prev = beforeResume
        tt += 0.6                                                          // the camera clock kept running during the silence
        for _ in 0..<60 {                                                  // 2 s of frames again (0.2 s of them only count after the recovery dwell)
            let s = t.ingest(detection(at: tt, yaw: 40)); clock.advance(dt); tt += dt
            maxStep = max(maxStep, prev.angle(to: s.pose) * 180 / .pi); prev = s.pose
        }
        #expect(maxStep < 40.0 / 7 * 1.6)                                  // 0.25 s blend at 30 fps ≈ 7.5 frames
        #expect(abs(prev.euler.yawDegrees - 40) < 1)
    }

    @Test func realTimerFiresAfterStartAndStopsAfterStop() async throws {
        var cfg = HeadTrackerConfig()
        cfg.frameTimeout = 0.05
        cfg.watchdogInterval = 0.01
        let fake = FakeProvider()
        let t = HeadTracker(provider: fake, config: cfg)               // real monotonic clock
        let box = WatchdogBox(); t.setSnapshotHandler { s in if s.isWatchdogTick { box.hit() } }
        try await t.start()
        fake.handler?(detection(at: 0, yaw: 10))                       // one frame, then silence
        let fired = await waitUntil { box.count > 0 }
        #expect(fired)
        t.stop()
        let after = box.count                                          // stop() drains an in-flight tick, so this is final
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(box.count == after)                                    // no ticks after stop
    }

    /// Regression: stop() used to cancel the watchdog timer without waiting for a tick already running, so one
    /// more watchdog snapshot could be delivered after stop() returned.
    @Test func noWatchdogSnapshotIsDeliveredAfterStopReturns() async throws {
        var cfg = HeadTrackerConfig()
        cfg.frameTimeout = 0                                           // every tick after the first frame emits a snapshot
        cfg.watchdogInterval = 0.0005                                  // a tick every 0.5 ms: one is often in flight
        for iteration in 0..<200 {
            let fake = FakeProvider()
            let t = HeadTracker(provider: fake, config: cfg)
            // A deliberately slow consumer (0.2 ms) keeps a tick in flight most of the time, so the race this guards
            // against is hit reliably instead of once in thousands of runs. The count is bumped AFTER the delay.
            let box = WatchdogBox(); t.setSnapshotHandler { s in
                if s.isWatchdogTick { Thread.sleep(forTimeInterval: 0.0002); box.hit() }
            }
            try await t.start()
            fake.handler?(detection(at: 0, yaw: 10))
            try await Task.sleep(nanoseconds: UInt64(300_000 + (iteration % 7) * 200_000))
            t.stop()
            let n = box.count
            try await Task.sleep(nanoseconds: 3_000_000)
            #expect(box.count == n, "iteration \(iteration): a watchdog snapshot arrived after stop() returned")
        }
    }

    @Test func monotonicClockAdvancesAndNeverGoesBackwards() {
        let a = HeadTracker.monotonicSeconds()
        let b = HeadTracker.monotonicSeconds()
        #expect(b >= a && a > 0)
    }
}

final class WatchdogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func hit() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TrackingSnapshot] = []
    func append(_ s: TrackingSnapshot) { lock.lock(); items.append(s); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    var all: [TrackingSnapshot] { lock.lock(); defer { lock.unlock() }; return items }
    var last: TrackingSnapshot? { all.last }
}
