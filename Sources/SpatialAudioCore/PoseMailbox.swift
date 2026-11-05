import CPoseMailbox

/// Lock-free, wait-free latest-value handoff of the head pose from the tracking thread
/// (single producer) to the audio render thread (single consumer). Thin wrapper over the
/// C triple buffer in `CPoseMailbox`.
///
/// Rules: exactly one (logical) thread calls `publish`, exactly one other calls `read`.
/// `init`/`deinit` allocate/free and are not real-time safe. Since Step 3a it is read by the pose
/// pump, a control thread, where this class is fine. Code that will run on a render thread must NOT
/// use this class: it reads through the C API (`SAPoseMailboxRead`) with a raw pointer and plain
/// structs (decision record: "Real-time rule" in docs/ARCHITECTURE.md).
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
