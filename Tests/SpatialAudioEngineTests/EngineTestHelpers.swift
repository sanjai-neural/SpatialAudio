import Foundation
import SpatialAudioCore
@testable import SpatialAudioEngine

let deg = Double.pi / 180

func yawQ(_ degrees: Double) -> Quaternion { Quaternion(axis: .up, angle: degrees * deg) }
func pitchQ(_ degrees: Double) -> Quaternion { Quaternion(axis: .right, angle: degrees * deg) }
func eulerQ(_ y: Double, _ p: Double, _ r: Double) -> Quaternion {
    Quaternion(euler: EulerAngles(yawDegrees: y, pitchDegrees: p, rollDegrees: r))
}
func angleDeg(_ a: Quaternion, _ b: Quaternion) -> Double { a.angle(to: b) / deg }
func near(_ a: Vector3, _ b: Vector3, _ tol: Double = 1e-9) -> Bool { (a - b).length < tol }

/// Records every orientation it is given. Thread-safe, so timer tests can read it from the test thread.
final class RecordingSink: SpatialSceneSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _listeners: [ListenerOrientation] = []
    private var _sources: [Vector3] = []
    /// Makes every `setListener` slow, which widens the window in which a tick is "in flight" so a missing drain on stop() is
    /// caught reliably instead of by luck. It only slows the system under test; no verdict depends on the delay itself.
    let delay: TimeInterval

    init(delay: TimeInterval = 0) { self.delay = delay }

    func setListener(_ orientation: ListenerOrientation) {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.lock(); _listeners.append(orientation); lock.unlock()
    }
    func setSourcePosition(_ position: Vector3) { lock.lock(); _sources.append(position); lock.unlock() }

    var listeners: [ListenerOrientation] { lock.lock(); defer { lock.unlock() }; return _listeners }
    var sources: [Vector3] { lock.lock(); defer { lock.unlock() }; return _sources }
}

/// Parks inside `setListener` on the first call after `arm()` until `release` is signalled, so a test can hold a pump tick
/// "in flight" with certainty (no timing luck involved).
final class GateSink: ListenerOrientationSink, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = false

    func arm() { lock.lock(); armed = true; lock.unlock() }

    func setListener(_ orientation: ListenerOrientation) {
        lock.lock(); let park = armed; armed = false; lock.unlock()
        if park { entered.signal(); _ = release.wait(timeout: .now() + .seconds(60)) }     // bounded, so a failing test cannot hang the suite
    }
}

/// Polls `condition` until it is true or the deadline passes. The deadline is on `SuspendingClock`, which does not advance
/// while the Mac sleeps, and it only decides how long to wait before failing: the verdict comes from `condition`.
func waitUntil(timeout: Duration = .seconds(30), _ condition: @Sendable () -> Bool) async -> Bool {
    let clock = SuspendingClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

// MARK: - Offline rendering helpers

let renderBlock = 512

/// Static scene: listener fixed at `pose` (through the real conversion), tone fixed at `source`, no pump.
func renderStatic(source: Vector3, pose: Quaternion = .identity, mapping: ListenerMapping = ListenerMapping(),
                  seconds: Double = 0.75) throws -> StereoRender {
    let renderer = try EnvironmentRenderer(mode: .offline(maximumFrames: renderBlock), initialSource: source)
    renderer.setListener(ListenerFrame.orientation(for: pose, mapping: mapping))
    try renderer.start()
    defer { renderer.stop() }
    return try renderer.renderOffline(blocks: Int(seconds * renderer.sampleRate) / renderBlock, blockFrames: renderBlock)
}

/// The whole Step 3a chain, offline and deterministic: scripted scene -> mailbox -> pump -> conversion -> engine.
/// The publisher runs at 30 Hz of script time, the pump steps once per block, exactly as the live timers do.
func renderScripted(_ test: ListeningTest, seconds: Double, mapping: ListenerMapping = ListenerMapping()) throws -> StereoRender {
    let renderer = try EnvironmentRenderer(mode: .offline(maximumFrames: renderBlock))
    let mailbox = PoseMailbox()
    let publisher = ScriptedScenePublisher(test: test, mailbox: mailbox, sink: renderer)
    let pump = ListenerPosePump(mailbox: mailbox, sink: renderer, mapping: mapping)
    publisher.publish(at: 0)
    pump.step(dt: 0)
    try renderer.start()
    defer { renderer.stop() }
    let rate = renderer.sampleRate
    let blockSeconds = Double(renderBlock) / rate
    var nextPublish = 0.0
    return try renderer.renderOffline(blocks: Int(seconds * rate) / renderBlock, blockFrames: renderBlock) { block in
        let t = Double(block) * blockSeconds
        while nextPublish <= t { publisher.publish(at: nextPublish); nextPublish += 1.0 / 30 }
        pump.step(dt: blockSeconds)
    }
}

/// Pearson correlation of two equally long series.
func correlation(_ a: [Double], _ b: [Double]) -> Double {
    precondition(a.count == b.count && a.count > 1)
    let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
    var num = 0.0, da = 0.0, db = 0.0
    for i in a.indices { num += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb) }
    return num / (da * db).squareRoot()
}
