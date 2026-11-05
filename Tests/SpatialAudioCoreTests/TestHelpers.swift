import Foundation
@testable import SpatialAudioCore

let deg = Double.pi / 180

func yawQ(_ degrees: Double) -> Quaternion { Quaternion(axis: .up, angle: degrees * deg) }
func pitchQ(_ degrees: Double) -> Quaternion { Quaternion(axis: .right, angle: degrees * deg) }
func eulerQ(_ y: Double, _ p: Double, _ r: Double) -> Quaternion {
    Quaternion(euler: EulerAngles(yawDegrees: y, pitchDegrees: p, rollDegrees: r))
}
/// Angle between two orientations in degrees.
func angleDeg(_ a: Quaternion, _ b: Quaternion) -> Double { a.angle(to: b) / deg }

func near(_ a: Vector3, _ b: Vector3, _ tol: Double = 1e-9) -> Bool { (a - b).length < tol }

/// Deterministic pseudo-random in [-1, 1] (LCG) so noise tests are reproducible.
struct DeterministicNoise {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53) * 2 - 1
    }
}

// MARK: - Self-test helpers

let goodFaceBox = NormalizedRect(x: 0.3, y: 0.25, width: 0.3, height: 0.45)

/// Runs a `SimulatedUser` through the real mapping + quality gate + pipeline (the same chain
/// `HeadTracker` uses) and files every frame into a `SelfTestSession`. Camera-free.
func simulateSession(user: SimulatedUser = SimulatedUser(), mapping: HeadAngleMapping = HeadAngleMapping(),
                     lighting: LightingTag = .normalLight, fps: Double = 30,
                     delivery: Double = 0.082, vision: Double = 0.014, startTime: Double = 100) -> SelfTestSession {
    var session = SelfTestSession(script: user.script, lighting: lighting, startTime: startTime)
    var pipeline = HeadPosePipeline()
    var estimator = TrackingQualityEstimator()
    let frames = Int((user.script.totalDuration + 1) * fps)
    let latency = delivery + vision
    for k in 0..<frames {
        let elapsed = Double(k) / fps
        let arrival = startTime + elapsed
        let capture = arrival - latency
        let raw = user.rawAngles(frameIndex: k, atElapsed: elapsed - latency)
        let face = raw.map { FaceMeasurement(angles: $0, confidence: 0.88, boundingBox: goodFaceBox) }
        let quality = estimator.update(time: capture, face: face)
        let sample = face.map {
            HeadPoseSample(orientation: Quaternion(euler: mapping.euler(from: $0.angles, frameMirrored: user.framesMirrored)),
                           confidence: quality.overall, timestamp: capture)
        }
        let out = pipeline.process(sample, now: capture)
        _ = session.advance(to: arrival)                       // like the controller: opens the loss test's lock gate
        session.record(SelfTestFrame(
            arrival: arrival, captureTime: capture, angles: raw, frameMirrored: user.framesMirrored,
            videoRotationAngle: 0, state: out.state, pose: out.pose, qualityOverall: quality.overall,
            deliveryLatency: delivery, visionDuration: vision, totalLatency: latency,
            limiting: quality.limiting,
            mappedDegrees: face.map { f in
                let e = mapping.euler(from: f.angles, frameMirrored: user.framesMirrored)
                return AngleTriple(yaw: e.yawDegrees, pitch: e.pitchDegrees, roll: e.rollDegrees)
            },
            faceBox: face?.boundingBox))
    }
    return session
}

func testContext(simulated: Bool = false, mapping: HeadAngleMapping = HeadAngleMapping()) -> SelfTestContext {
    SelfTestContext(createdAt: "2026-11-04T15:30:12Z", inputSource: simulated ? "simulated" : "camera",
                    macOSVersion: "27.2", hardwareModel: "Mac16,12", cameraName: "Test Camera",
                    capturePreset: "640x480", visionRevision: 3, mappingDuringTest: mapping,
                    machine: TrackingStateMachineConfig())
}
