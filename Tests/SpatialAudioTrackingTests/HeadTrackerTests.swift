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

func detection(at t: Double, yaw: Double = 0, pitch: Double = 0, roll: Double = 0,
               face: Bool = true, mirrored: Bool = false, confidence: Double = 1,
               received: Double? = nil, detected: Double? = nil) -> HeadPoseDetection {
    HeadPoseDetection(
        captureTime: t, receivedAt: received ?? t, detectedAt: detected ?? t,
        face: face ? FaceMeasurement(angles: VisionFaceAngles(yaw: yaw * deg2rad, pitch: pitch * deg2rad, roll: roll * deg2rad),
                                     confidence: confidence, boundingBoxArea: 0.2) : nil,
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
        #expect(states == [.holding, .decaying, .static])
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
        let t = HeadTracker(provider: fake)
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
        let t = HeadTracker(provider: fake)
        _ = feed(t, from: 0, seconds: 2) { detection(at: $0, yaw: 25) }
        #expect(t.recenter())
        try await t.start()                                  // restart: fresh filter/state, same neutral
        var last: TrackingSnapshot!
        var tt = 0.0
        while tt < 2 { last = t.ingest(detection(at: tt, yaw: 25)); tt += dt }
        #expect(abs(last.euler.yawDegrees) < 0.5)
    }
}

final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TrackingSnapshot] = []
    func append(_ s: TrackingSnapshot) { lock.lock(); items.append(s); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
}
