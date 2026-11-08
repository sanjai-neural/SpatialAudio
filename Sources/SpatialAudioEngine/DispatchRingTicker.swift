import Foundation
import SpatialAudioCore

/// The sampling timer of the ring probe: a `.strict`, zero-leeway `DispatchSourceTimer` on its own queue that sets a "tick pending" flag; the control thread
/// blocks in `wait()`. Ticks that arrive while the control thread is busy COALESCE into one (a late runner takes one sample, not a burst), and the elapsed
/// time of each sample is measured by the runner from host ticks, so a late tick shows up as a longer measured gap instead of being hidden.
///
/// Stop requests (SIGINT / SIGTERM) and backend events (an engine configuration change) wake `wait()` too, with priority: signal, then interrupt, then tick.
public final class DispatchRingTicker: RingProbeTicker, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SpatialAudio.ringprobe.ticker", qos: .userInitiated)
    private let key = DispatchSpecificKey<Void>()
    private let condition = NSCondition()
    private var tickPending = false, signalPending = false, interruptPending = false
    private var timer: DispatchSourceTimer?

    public init() { queue.setSpecific(key: key, value: ()) }

    deinit { timer?.cancel() }

    public func start(periodSeconds: Double) {
        stop()
        condition.lock(); tickPending = false; condition.unlock()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now() + periodSeconds, repeating: periodSeconds, leeway: .nanoseconds(0))
        t.setEventHandler { [weak self] in self?.post(tick: true, signal: false, interrupt: false) }
        timer = t
        t.resume()
    }

    public func wait() -> RingProbeWake {
        condition.lock()
        defer { condition.unlock() }
        while !(tickPending || signalPending || interruptPending) { condition.wait() }
        if signalPending { return .signal }                  // sticky: a stop request stays pending
        if interruptPending { return .interrupt }            // sticky: the runner reads the backend's counter and stops
        tickPending = false
        return .tick
    }

    /// From a signal handler's queue: wake `wait()` with `.signal` (sticky).
    public func requestStop() { post(tick: false, signal: true, interrupt: false) }
    /// From a backend event (an engine configuration change): wake `wait()` with `.interrupt` (sticky).
    public func interrupt() { post(tick: false, signal: false, interrupt: true) }

    public func stop() {
        let t = timer
        timer = nil
        t?.cancel()
        if t != nil, DispatchQueue.getSpecific(key: key) == nil { queue.sync {} }      // a handler that is already running has finished when this returns
    }

    /// Internal (not private) so the tests can put an exact combination of pending events in place without a timer; production code only calls it from this class.
    func post(tick: Bool, signal: Bool, interrupt: Bool) {
        condition.lock()
        if tick { tickPending = true }
        if signal { signalPending = true }
        if interrupt { interruptPending = true }
        condition.broadcast()
        condition.unlock()
    }
}
