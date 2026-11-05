import Foundation
import SpatialAudioCore

/// Moves the listener once per audio block: reads the newest pose from the `PoseMailbox`, advances the
/// `PoseInterpolator` by the time since the previous block, converts with `ListenerFrame`, and hands the result to
/// the sink (the renderer).
///
/// Why a pump on its own thread instead of the audio callback (decision record in docs/ARCHITECTURE.md, "Real-time
/// rule"): `AVAudioEnvironmentNode` exposes the listener only as a node property, and `AVAudioEngine.h` says setting or
/// getting node properties can require synchronization with the realtime thread, so they are treated as control-thread calls. This class is therefore
/// ordinary (non-real-time) code and may use locks and classes. It is NOT sample-accurate: it runs once per
/// nominal block period on a timer, and any scheduling jitter shows up in `timing`.
///
/// Threading contract: `step` is called by exactly one logical thread at a time (the timer queue, or a test), and that
/// is the mailbox's single consumer. `setMapping` and the read-only accessors may be called from any thread.
public final class ListenerPosePump: @unchecked Sendable {
    public struct Applied: Equatable, Sendable {
        /// The interpolated head pose (before the audio-side flip switches).
        public var pose: Quaternion
        /// What the sink was last given (after the flip switches).
        public var orientation: ListenerOrientation
        /// Newest mailbox sequence seen (0 = nothing published yet).
        public var mailboxSequence: UInt64
        public var steps: Int
        /// How many times the sink was actually written (unchanged orientations are not re-sent).
        public var sinkWrites: Int
    }

    /// Measured spacing of live timer ticks. Diagnostic only; no verdict is derived from it.
    public struct Timing: Equatable, Sendable {
        public var ticks: Int
        public var meanPeriodMilliseconds: Double
        public var maxPeriodMilliseconds: Double
    }

    private let mailbox: PoseMailbox
    private let sink: ListenerOrientationSink
    private let clock: @Sendable () -> Double
    private let timer = PeriodicTimer(label: "spatialaudio.pose-pump")

    // Shared with other threads.
    private let lock = NSLock()
    private var mapping = ListenerMapping()
    private var latestApplied: Applied?
    private var periodSum = 0.0, periodMax = 0.0, periodCount = 0

    // Owned by whoever calls `step` (single consumer).
    private var interpolator: PoseInterpolator
    private var lastSent: ListenerOrientation?
    private var steps = 0, sinkWrites = 0
    private var sequence: UInt64 = 0
    private var lastTick: Double?

    public init(mailbox: PoseMailbox, sink: ListenerOrientationSink,
                interpolation: PoseInterpolator.Config = PoseInterpolator.Config(),
                mapping: ListenerMapping = ListenerMapping()) {
        self.mailbox = mailbox
        self.sink = sink
        self.interpolator = PoseInterpolator(config: interpolation)
        self.mapping = mapping
        self.clock = MonotonicClock.seconds
    }

    deinit { timer.stop() }

    /// Flip switches for the listening test; takes effect on the next step.
    public func setMapping(_ m: ListenerMapping) {
        lock.lock(); mapping = m; lock.unlock()
    }

    public var currentMapping: ListenerMapping { lock.lock(); defer { lock.unlock() }; return mapping }

    public var applied: Applied? { lock.lock(); defer { lock.unlock() }; return latestApplied }

    public var timing: Timing {
        lock.lock(); defer { lock.unlock() }
        return Timing(ticks: periodCount,
                      meanPeriodMilliseconds: periodCount > 0 ? periodSum / Double(periodCount) * 1000 : 0,
                      maxPeriodMilliseconds: periodMax * 1000)
    }

    /// One block's worth of work. `dt` is the time since the previous step. Deterministic: tests call this directly.
    @discardableResult
    public func step(dt: Double) -> Applied {
        if let reading = mailbox.read() {
            sequence = reading.sequence
            if reading.isNew { interpolator.setTarget(reading.pose) }
        }
        let pose = interpolator.advance(by: dt)
        let map = currentMapping
        let orientation = ListenerFrame.orientation(for: pose, mapping: map)
        if lastSent.map({ orientation.differs(from: $0) }) ?? true {
            sink.setListener(orientation)
            lastSent = orientation
            sinkWrites += 1
        }
        steps += 1
        let a = Applied(pose: pose, orientation: orientation, mailboxSequence: sequence, steps: steps, sinkWrites: sinkWrites)
        lock.lock(); latestApplied = a; lock.unlock()
        return a
    }

    /// Starts ticking every `period` seconds (use the nominal block period, e.g. 512 / sampleRate).
    public func start(period: Double) {
        guard period > 0, period.isFinite else { return }
        lastTick = nil
        timer.start(period: period) { [weak self] in self?.tick(nominalPeriod: period) }
    }

    /// Stops ticking; no step runs after this returns.
    public func stop() { timer.stop() }

    private func tick(nominalPeriod: Double) {
        let now = clock()
        let measured = lastTick.map { now - $0 }          // nil on the very first tick: there is no previous tick to measure from
        lastTick = now
        if let gap = measured {
            lock.lock()
            periodSum += gap; periodMax = max(periodMax, gap); periodCount += 1
            lock.unlock()
        }
        step(dt: measured ?? nominalPeriod)
    }
}
