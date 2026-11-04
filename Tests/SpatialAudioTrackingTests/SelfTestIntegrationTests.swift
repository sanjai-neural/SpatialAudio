import Testing
import Foundation
import SpatialAudioCore
@testable import SpatialAudioTracking

/// Plays a `SimulatedUser` through the REAL `HeadTracker` (mapping, quality gate, filter, state machine),
/// converts every snapshot with `selfTestFrame`, and files it in a `SelfTestSession`. No camera involved.
private func runSimulated(user: SimulatedUser = SimulatedUser(), mapping: HeadAngleMapping = HeadAngleMapping(),
                          fps: Double = 30) -> SelfTestSession {
    let fake = FakeProvider()
    let tracker = HeadTracker(provider: fake, mapping: mapping)
    var session = SelfTestSession(script: user.script, lighting: .normalLight, startTime: 100)
    let frames = Int((user.script.totalDuration + 1) * fps)
    for k in 0..<frames {
        let elapsed = Double(k) / fps
        let arrival = 100 + elapsed
        let capture = arrival - 0.096
        fake.now = arrival                                              // "pose ready" = arrival
        let raw = user.rawAngles(frameIndex: k, atElapsed: elapsed - 0.096)
        let d = HeadPoseDetection(
            captureTime: capture, receivedAt: arrival - 0.014, detectedAt: arrival,
            face: raw.map { FaceMeasurement(angles: $0, confidence: 0.88, boundingBox: goodBox) },
            facesDetected: raw == nil ? 0 : 1, frameMirrored: user.framesMirrored, videoRotationAngle: 0)
        session.record(tracker.ingest(d).selfTestFrame(arrival: arrival))
    }
    return session
}

private func context(simulated: Bool = true, mapping: HeadAngleMapping = HeadAngleMapping()) -> SelfTestContext {
    SelfTestContext(createdAt: "2026-11-04T15:30:12Z", inputSource: simulated ? "simulated" : "camera",
                    macOSVersion: "27.2", hardwareModel: "Mac16,12", cameraName: nil, capturePreset: "640x480",
                    visionRevision: 3, mappingDuringTest: mapping, machine: TrackingStateMachineConfig())
}

@Suite struct SelfTestIntegrationTests {
    @Test func fullRunThroughTheRealTrackerWithDocumentedConventions() {
        let report = SelfTestAnalyzer.analyze(runSimulated(), context: context())
        #expect(report.signs.allDetermined, "\(report.signs.yaw.reasons) \(report.signs.pitch.reasons) \(report.signs.roll.reasons)")
        #expect(report.signs.recommendedMapping(over: HeadAngleMapping()) == HeadAngleMapping())
        #expect(report.loss.verdict == .pass, "\(report.loss.observedSequence) \(report.loss.notes)")
        #expect(report.loss.jumpCheckMeaningful && !report.loss.jumpFlagged)
        #expect(report.stats.sufficient && report.stats.windowSeconds == 30)
    }

    @Test func latencyFieldsFlowThroughFromTheDetectionTimestamps() throws {
        let stats = SelfTestAnalyzer.analyze(runSimulated(), context: context()).stats
        let delivery = try #require(stats.deliveryMs), vision = try #require(stats.visionMs), total = try #require(stats.totalMs)
        #expect(abs(delivery.mean - 82) < 0.01 && abs(vision.mean - 14) < 0.01 && abs(total.mean - 96) < 0.01)
        let fps = try #require(stats.fpsMean)
        #expect(abs(fps - 30) < 0.5)
    }

    @Test func flippedConventionsAreDetectedThroughTheRealTracker() {
        let user = SimulatedUser(conventions: .init(yawPerLeft: -1, pitchPerUp: 1, rollPerRightEar: 1))
        let report = SelfTestAnalyzer.analyze(runSimulated(user: user), context: context())
        #expect(report.signs.recommendedMapping(over: HeadAngleMapping()) == HeadAngleMapping(invertYaw: true, invertPitch: true, invertRoll: false))
    }

    /// Closing the loop: applying the detected flags to the tracker makes a turn LEFT come out as +yaw in the pose.
    @Test func appliedDetectedFlagsMakeLeftPositiveInTheTrackerOutput() {
        let user = SimulatedUser(conventions: .init(yawPerLeft: -1, pitchPerUp: 1, rollPerRightEar: -1), noiseSigmaDegrees: 0)
        let detected = SelfTestAnalyzer.analyze(runSimulated(user: user), context: context()).signs.recommendedMapping(over: HeadAngleMapping())
        #expect(detected == HeadAngleMapping(invertYaw: true, invertPitch: true, invertRoll: true))

        let fake = FakeProvider()
        let tracker = HeadTracker(provider: fake, mapping: detected)
        var last: TrackingSnapshot!
        var t = 0.0
        // A person in this camera's convention turns left by 30°: raw yaw −30 (flipped), pitch 0, roll 0.
        while t < 2 {
            last = tracker.ingest(HeadPoseDetection(
                captureTime: t, receivedAt: t, detectedAt: t,
                face: FaceMeasurement(angles: VisionFaceAngles(yaw: -30 * deg2rad, pitch: 0, roll: 0), confidence: 1, boundingBox: goodBox),
                facesDetected: 1, frameMirrored: false))
            t += 1.0 / 30
        }
        #expect(abs(last.euler.yawDegrees - 30) < 0.5)                    // left = +yaw
    }
}

@Suite struct SetMappingResetTests {
    let dt = 1.0 / 30

    func lock(_ t: HeadTracker, yaw: Double, from t0: Double = 0, seconds: Double = 2) -> TrackingSnapshot {
        var tt = t0
        var last: TrackingSnapshot!
        while tt <= t0 + seconds { last = t.ingest(detection(at: tt, yaw: yaw)); tt += dt }
        return last
    }

    @Test func changingSignsDropsTheOldCalibration() {
        let t = HeadTracker(provider: FakeProvider())
        _ = lock(t, yaw: 25)
        #expect(t.recenter())
        #expect(abs(lock(t, yaw: 25, from: 2.1).euler.yawDegrees) < 0.5)             // calibrated: 25° reads as 0
        t.setMapping(HeadAngleMapping(invertYaw: true))
        let s = lock(t, yaw: 25, from: 4.2)
        #expect(abs(s.euler.yawDegrees - (-25)) < 0.5)                              // old neutral gone, new sign in effect
    }

    @Test func settingTheSameMappingKeepsTheCalibration() {
        let t = HeadTracker(provider: FakeProvider())
        _ = lock(t, yaw: 25)
        #expect(t.recenter())
        t.setMapping(HeadAngleMapping())                                            // identical
        #expect(abs(lock(t, yaw: 25, from: 2.1).euler.yawDegrees) < 0.5)
    }

    @Test func changingSignsRestartsTheStateMachine() {
        let t = HeadTracker(provider: FakeProvider())
        #expect(lock(t, yaw: 25).state == .locked)
        t.setMapping(HeadAngleMapping(invertPitch: true))
        let first = t.ingest(detection(at: 3, yaw: 25))
        #expect(first.state == .locked && abs(first.pose.angle(to: .identity)) < 1e-9)   // fresh blend from neutral, no jump to a stale pose
    }
}

@Suite struct SelfTestFrameConversionTests {
    @Test func snapshotFieldsAreCopiedWithTheGivenArrivalTime() {
        let t = HeadTracker(provider: FakeProvider())
        var s: TrackingSnapshot!
        var tt = 0.0
        while tt < 1 { s = t.ingest(detection(at: tt, yaw: 20, mirrored: true, received: tt + 0.08, detected: tt + 0.094)); tt += 1.0 / 30 }
        let f = s.selfTestFrame(arrival: 123.5)
        #expect(f.arrival == 123.5 && f.captureTime == s.captureTime)
        #expect(f.angles == s.visionAngles && f.frameMirrored == true && f.state == s.state && f.pose == s.pose)
        #expect(f.qualityOverall == s.quality.overall && !f.isWatchdogTick)
        #expect(abs(f.deliveryLatency - 0.08) < 1e-9 && abs(f.visionDuration - 0.014) < 1e-9)
    }

    @Test func noFaceGivesNilAnglesAndWatchdogTicksAreFlagged() {
        var cfg = HeadTrackerConfig(); cfg.frameTimeout = 0.1
        let clock = FakeClock()
        let t = HeadTracker(provider: FakeProvider(), config: cfg, clock: { clock.read() })
        let none = t.ingest(detection(at: 0, face: false)).selfTestFrame(arrival: 1)
        #expect(none.angles == nil)
        let log = Box(); t.setSnapshotHandler { log.append($0) }
        clock.advance(0.5); t.watchdogTick()
        #expect(log.last!.selfTestFrame(arrival: 2).isWatchdogTick)
    }
}

@Suite struct SimulatedProviderTests {
    @Test func deliversPlausibleDetectionsInRealTimeUntilStopped() async throws {
        let fps = 60.0
        let p = SimulatedHeadPoseProvider(fps: fps)
        let box = DetectionBox()
        let clock = SuspendingClock()
        let t0 = clock.now
        try await p.start { box.add($0) }
        #expect(p.sourceDescription == SimulatedHeadPoseProvider.sourceName)
        let arrived = await waitUntil { box.count >= 5 }
        p.stop()
        let awake = clock.now - t0
        let seconds = Double(awake.components.seconds) + Double(awake.components.attoseconds) / 1e18
        #expect(arrived)
        let n = box.count
        // The timer can never deliver faster than its rate, however late this thread happened to wake up.
        #expect(n <= Int(seconds * fps) + 3, "got \(n) detections in \(seconds) s at \(fps) fps")
        let d = try #require(box.first)
        #expect(d.face != nil && d.captureTime < d.receivedAt && d.receivedAt < d.detectedAt)
        #expect(abs((d.receivedAt - d.captureTime) - 0.050) < 1e-6 && abs((d.detectedAt - d.receivedAt) - 0.010) < 1e-6)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(box.count == n)                                           // nothing after stop
        #expect(p.sourceDescription == nil)
    }

    /// Regression: stop() used to cancel the timer without waiting for a tick that was already running, so one
    /// more detection could be delivered after stop() returned (the protocol says stop() "blocks until released").
    @Test func noDetectionIsDeliveredAfterStopReturns() async throws {
        for iteration in 0..<300 {
            let p = SimulatedHeadPoseProvider(fps: 2000)                  // a tick every 0.5 ms: one is often in flight
            let box = DetectionBox()
            try await p.start { box.add($0) }
            try await Task.sleep(nanoseconds: UInt64(200_000 + (iteration % 7) * 150_000))
            p.stop()
            let n = box.count
            try await Task.sleep(nanoseconds: 3_000_000)
            #expect(box.count == n, "iteration \(iteration): a detection arrived after stop() returned")
        }
    }

    @Test func refusesASecondStartAndHasNoHardwareReleaseReport() async throws {
        let p = SimulatedHeadPoseProvider()
        try await p.start { _ in }
        await #expect(throws: HeadPoseProviderError.alreadyRunning) { try await p.start { _ in } }
        p.stop()
        #expect(p.releaseReport() == nil)                                  // no hardware, no claim
    }

    @Test func beginScriptMakesTheSimulatedPersonMove() async throws {
        let p = SimulatedHeadPoseProvider(user: SimulatedUser(noiseSigmaDegrees: 0), fps: 60)
        let box = DetectionBox()
        try await p.start { box.add($0) }
        // 7 s into the script is inside the first "turn left" hold, where the simulated head is fully turned.
        p.beginScript(at: HeadTracker.monotonicSeconds() - 7.0)
        let moved = await waitUntil { (box.all.last?.face?.angles.yaw ?? 0) * 180 / .pi > 30 }
        p.stop()
        #expect(moved)                                                     // rest yaw is ~1.5°, the left hold is ~46°
    }
}

final class DetectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [HeadPoseDetection] = []
    func add(_ d: HeadPoseDetection) { lock.lock(); items.append(d); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    var first: HeadPoseDetection? { lock.lock(); defer { lock.unlock() }; return items.first }
    var all: [HeadPoseDetection] { lock.lock(); defer { lock.unlock() }; return items }
}
