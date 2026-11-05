import Foundation
import SpatialAudioCore

/// Plays a `ListeningTest` into a `PoseMailbox`, standing in for the tracker: evaluates the script at the given time,
/// publishes the synthetic head pose, and moves the virtual source when the script says so. This is the mailbox's
/// single PRODUCER. No camera or tracking code is involved.
public final class ScriptedScenePublisher: @unchecked Sendable {
    private let mailbox: PoseMailbox
    private let sink: SpatialSceneSink
    private let lock = NSLock()
    private var test: ListeningTest
    private var lastSource: Vector3?

    public init(test: ListeningTest, mailbox: PoseMailbox, sink: SpatialSceneSink) {
        self.test = test; self.mailbox = mailbox; self.sink = sink
    }

    public var currentTest: ListeningTest { lock.lock(); defer { lock.unlock() }; return test }

    /// Switches test; the next `publish` re-applies the source position.
    public func select(_ newTest: ListeningTest) {
        lock.lock(); test = newTest; lastSource = nil; lock.unlock()
    }

    /// Evaluates the script at `scriptTime` (seconds since the script started) and publishes it. Producer thread only.
    @discardableResult
    public func publish(at scriptTime: Double) -> ListeningScene {
        lock.lock(); let t = test; let last = lastSource; lock.unlock()
        let scene = t.scene(at: scriptTime)
        mailbox.publish(scene.headPose, timestamp: scriptTime)
        if last.map({ ($0 - scene.sourcePosition).length > 1e-9 }) ?? true {
            sink.setSourcePosition(scene.sourcePosition)
            lock.lock(); lastSource = scene.sourcePosition; lock.unlock()
        }
        return scene
    }
}

/// The audio-only listening test, live: scripted synthetic head -> `PoseMailbox` -> `ListenerPosePump` ->
/// `EnvironmentRenderer`, with two timers (publisher about 30 Hz like the camera, pump once per nominal block).
/// No camera is opened anywhere on this path.
public final class ListeningTestSession: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var running: Bool
        public var test: ListeningTest
        public var scriptTime: Double
        public var scene: ListeningScene
        /// Where the tone should seem to be (pure geometry, identity mapping): the truth to compare your ears against.
        public var expected: RelativeDirection
        public var applied: ListenerPosePump.Applied?
        public var mapping: ListenerMapping
        public var timing: ListenerPosePump.Timing
        public var notice: String?
    }

    public let renderer: EnvironmentRenderer
    private let mailbox = PoseMailbox()
    private let publisher: ScriptedScenePublisher
    private let pump: ListenerPosePump
    private let publishTimer = PeriodicTimer(label: "spatialaudio.scripted-publisher")
    private let clock = MonotonicClock.seconds
    private let publishPeriod: Double
    private let blockPeriod: Double

    private let lock = NSLock()
    private var running = false
    private var scriptStart = 0.0

    public init(renderer: EnvironmentRenderer, test: ListeningTest, mapping: ListenerMapping = ListenerMapping(),
                publishRateHz: Double = 30, blockFrames: Int = 512) {
        self.renderer = renderer
        self.publisher = ScriptedScenePublisher(test: test, mailbox: mailbox, sink: renderer)
        self.pump = ListenerPosePump(mailbox: mailbox, sink: renderer, mapping: mapping)
        self.publishPeriod = 1 / max(1, publishRateHz)
        self.blockPeriod = Double(max(1, blockFrames)) / renderer.sampleRate
    }

    deinit { stop() }

    public func start() throws {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true; scriptStart = clock()
        lock.unlock()

        // Tone position and first pose are in place before any sound is produced.
        publisher.publish(at: 0)
        pump.step(dt: 0)
        do { try renderer.start() } catch {
            lock.lock(); running = false; lock.unlock()
            throw error
        }
        publishTimer.start(period: publishPeriod) { [weak self] in
            guard let self else { return }
            self.publisher.publish(at: self.scriptTime())
        }
        pump.start(period: blockPeriod)
    }

    public func stop() {
        lock.lock(); let was = running; running = false; lock.unlock()
        guard was else { return }
        pump.stop()
        publishTimer.stop()
        renderer.stop()
    }

    /// Switches the scripted test and restarts its clock.
    public func select(_ test: ListeningTest) {
        lock.lock(); scriptStart = clock(); lock.unlock()
        publisher.select(test)
    }

    public func setMapping(_ m: ListenerMapping) { pump.setMapping(m) }

    public var snapshot: Snapshot {
        let t = publisher.currentTest, time = scriptTime()
        lock.lock(); let isRunning = running; lock.unlock()
        return Snapshot(running: isRunning && renderer.isRunning, test: t, scriptTime: time, scene: t.scene(at: time),
                        expected: t.expectedDirection(at: time), applied: pump.applied, mapping: pump.currentMapping,
                        timing: pump.timing, notice: renderer.notice)
    }

    private func scriptTime() -> Double {
        lock.lock(); defer { lock.unlock() }
        return clock() - scriptStart
    }
}
