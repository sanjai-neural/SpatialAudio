import Foundation

/// Monotonic seconds that do not advance while the Mac sleeps (`CLOCK_UPTIME_RAW`), the same clock the tracker's
/// watchdog uses. Only differences are meaningful.
enum MonotonicClock {
    static let seconds: @Sendable () -> Double = {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }
}

/// A repeating timer on its own serial queue. `stop()` waits for a handler that is already running, so nothing fires
/// after it returns (the same drain the tracker's watchdog uses; skipped when called from the timer's own queue).
final class PeriodicTimer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let key = DispatchSpecificKey<Void>()
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    init(label: String, qos: DispatchQoS = .userInteractive) {
        queue = DispatchQueue(label: label, qos: qos)
        queue.setSpecific(key: key, value: ())
    }

    deinit { timer?.cancel() }

    /// Replaces any running timer. `.strict` + zero leeway asks for the requested cadence instead of coalescing.
    func start(period: Double, _ handler: @escaping @Sendable () -> Void) {
        stop()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now() + period, repeating: period, leeway: .nanoseconds(0))
        t.setEventHandler(handler: handler)
        lock.lock(); timer = t; lock.unlock()
        t.resume()
    }

    func stop() {
        lock.lock(); let t = timer; timer = nil; lock.unlock()
        t?.cancel()
        if t != nil, DispatchQueue.getSpecific(key: key) == nil { queue.sync {} }
    }
}
