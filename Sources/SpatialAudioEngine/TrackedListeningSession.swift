import Foundation
import SpatialAudioCore

/// Step 3b: head-tracked listening, the audio half. The camera tracker's output pose goes in through `publish(pose:timestamp:)`; roll is removed (forced to 0, the
/// tested `RollRemoval` conversion), the pose goes through the `PoseMailbox` to the `ListenerPosePump` (a control-thread timer, interpolation, `ListenerFrame`
/// conversion with the IDENTITY audio-side mapping) and into the renderer. One virtual source sits 2 m straight ahead and never moves: a fixed loudspeaker.
///
/// Nothing here runs on an audio thread: the renderer's listener, source and volume setters are control-thread calls made by the pump or by start / stop (Real-time
/// rule, docs/ARCHITECTURE.md). The output type is the same small protocol the blind test uses (`BlindListeningOutput`); `EnvironmentRenderer` is the real one.
///
/// Threading: the tracker delivers snapshots from two queues (camera frames and the watchdog), but the mailbox has a single producer by contract, so `publish` serializes
/// callers with a lock (a control-thread lock, never touched by the pump or the audio thread). IMPLEMENTED-UNVERIFIED: logic unit-tested on virtual time with a fake
/// output; how it sounds and whether it follows a real head is unknown until Sanjai has listened.
public final class TrackedListeningSession: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var running: Bool
        /// The pose the pump last interpolated and sent (yaw / pitch / roll of THIS pose are what the card shows; roll must read 0).
        public var applied: ListenerPosePump.Applied?
        /// The pose AS SENT to the renderer (after the roll is zeroed at the pump's output): what the card shows. Its roll is 0 to float precision (about 1e-15 degrees).
        public var sent: EulerAngles?
        public var timing: ListenerPosePump.Timing
        /// Poses accepted by `publish`, and poses refused because they were not finite.
        public var published: Int
        public var rejected: Int
        public var volume: Double
        public var notice: String?
    }

    private let output: BlindListeningOutput
    private let mailbox = PoseMailbox()
    let pump: ListenerPosePump            // internal: the tests step it directly on virtual time
    private let blockPeriod: Double
    /// Identity flips, plus roll forced to 0 at the pump's output (`ListenerMapping.zeroRoll`): the third place roll is removed (tracker, `publish`, here).
    private static let outputMapping = ListenerMapping(zeroRoll: true)
    private let lock = NSLock()
    private var running = false
    private var publishedCount = 0, rejectedCount = 0
    private var currentVolume: Double

    public init(output: BlindListeningOutput, sampleRate: Double, volume: Double = TrackedListeningPolicy.defaultVolume, blockFrames: Int = 512) {
        self.output = output
        self.currentVolume = TrackedListeningPolicy.clampedVolume(volume)
        self.blockPeriod = Double(max(1, blockFrames)) / max(1, sampleRate)
        // No flip switches (the camera mapping, default / no invert, is applied in the tracker); roll is forced to 0 at the pump's output.
        self.pump = ListenerPosePump(mailbox: mailbox, sink: output, mapping: Self.outputMapping)
    }

    deinit { stop() }

    // MARK: control

    /// Volume first (capped), the tone at its fixed place and the neutral listener next, then the engine, then the pump timer.
    public func start() throws {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        let v = currentVolume
        lock.unlock()
        output.outputVolume = Float(v)
        output.setSourcePosition(Vector3.direction(azimuthDegrees: 0, elevationDegrees: 0, distance: ListeningTest.sourceDistance))
        pump.step(dt: 0)
        do { try output.start() } catch {
            lock.lock(); running = false; lock.unlock()
            throw error
        }
        pump.start(period: blockPeriod)
    }

    /// Stops the pump, sets the volume to 0, stops the engine. (An abrupt cut; UNVERIFIED by ear.)
    public func stop() {
        lock.lock(); let was = running; running = false; lock.unlock()
        guard was else { return }
        pump.stop()
        output.outputVolume = 0
        output.stop()
    }

    public func setVolume(_ v: Double) {
        let c = TrackedListeningPolicy.clampedVolume(v)
        lock.lock(); currentVolume = c; let r = running; lock.unlock()
        if r { output.outputVolume = Float(c) }
    }

    /// Called by the tracker's snapshot handler from any queue. Removes roll, then hands the pose to the mailbox. A non-finite pose is refused (counted), never published.
    public func publish(pose: Quaternion, timestamp: Double) {
        guard pose.isFinite else {
            lock.lock(); rejectedCount += 1; lock.unlock()
            return
        }
        let q = RollRemoval.removingRoll(from: pose)
        lock.lock()
        mailbox.publish(q, timestamp: timestamp)
        publishedCount += 1
        lock.unlock()
    }

    public var snapshot: Snapshot {
        lock.lock(); let r = running, p = publishedCount, j = rejectedCount, v = currentVolume; lock.unlock()
        let applied = pump.applied
        return Snapshot(running: r && output.isRunning, applied: applied, sent: applied.map { Self.outputMapping.apply(to: $0.pose).euler }, timing: pump.timing, published: p, rejected: j, volume: v, notice: output.notice)
    }
}
