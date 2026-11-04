import CPoseMailbox

/// Lock-free, wait-free latest-value handoff of the head pose from the tracking thread
/// (single producer) to the audio render thread (single consumer). Thin wrapper over the
/// C triple buffer in `CPoseMailbox`.
///
/// Rules: exactly one thread calls `publish`, exactly one other thread calls `read`.
/// `init`/`deinit` allocate/free and are not real-time safe. Whether Swift class access
/// (ARC) is acceptable inside the audio callback is a Step 3 question; the audio side may
/// need to hold the raw pointer instead.
public final class PoseMailbox: @unchecked Sendable {
    public struct Reading: Equatable, Sendable {
        public var pose: Quaternion
        public var timestamp: Double
        /// 1, 2, 3, ... in publish order.
        public var sequence: UInt64
        /// True iff this is newer than the previous `read()` result.
        public var isNew: Bool
    }

    private let raw: OpaquePointer

    public init() {
        guard let mb = SAPoseMailboxCreate() else { fatalError("PoseMailbox: allocation failed") }
        raw = mb
    }

    deinit { SAPoseMailboxDestroy(raw) }

    /// Producer thread only.
    public func publish(_ pose: Quaternion, timestamp: Double) {
        var s = SAPoseSample(w: pose.w, x: pose.x, y: pose.y, z: pose.z, timestamp: timestamp, sequence: 0)
        SAPoseMailboxPublish(raw, &s)
    }

    /// Consumer thread only. nil until the first publish.
    public func read() -> Reading? {
        var s = SAPoseSample()
        let isNew = SAPoseMailboxRead(raw, &s)
        guard s.sequence > 0 else { return nil }
        return Reading(pose: Quaternion(w: s.w, x: s.x, y: s.y, z: s.z),
                       timestamp: s.timestamp, sequence: s.sequence, isNew: isNew)
    }
}
