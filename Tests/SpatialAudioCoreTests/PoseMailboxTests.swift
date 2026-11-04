import Testing
import Foundation
@testable import SpatialAudioCore

@Suite struct PoseMailboxTests {
    @Test func readBeforeAnyPublishIsNil() {
        #expect(PoseMailbox().read() == nil)
    }

    @Test func publishThenReadReturnsValueAsNew() throws {
        let mb = PoseMailbox()
        let q = eulerQ(30, 10, 5)
        mb.publish(q, timestamp: 12.5)
        let r = try #require(mb.read())
        #expect(r.isNew && r.sequence == 1 && r.timestamp == 12.5)
        #expect(r.pose == q)                      // stored bit-for-bit, not renormalized
    }

    @Test func secondReadWithoutPublishIsNotNewButSameValue() throws {
        let mb = PoseMailbox()
        mb.publish(yawQ(10), timestamp: 1)
        let a = try #require(mb.read())
        let b = try #require(mb.read())
        #expect(a.isNew && !b.isNew)
        #expect(a.pose == b.pose && a.sequence == b.sequence)
    }

    @Test func latestValueWinsWhenReaderSkipsPublishes() throws {
        let mb = PoseMailbox()
        for i in 1...5 { mb.publish(yawQ(Double(i) * 10), timestamp: Double(i)) }
        let r = try #require(mb.read())
        #expect(r.sequence == 5 && r.timestamp == 5 && r.isNew)
        #expect(angleDeg(r.pose, yawQ(50)) < 1e-9)
    }

    @Test func interleavedPublishAndReadNeverGoBackwards() throws {
        let mb = PoseMailbox()
        var last: UInt64 = 0
        for i in 1...1000 {
            mb.publish(.identity, timestamp: Double(i))
            if i % 3 == 0 {
                let r = try #require(mb.read())
                #expect(r.sequence >= last && r.sequence == UInt64(i))
                last = r.sequence
            }
        }
    }

    /// One writer thread and one reader thread. Every published sample has all of w, x, y, z and
    /// timestamp derived from its sequence number, so any torn (half-old/half-new) read is detected.
    /// Run normally and under Thread Sanitizer (`swift test --sanitize=thread`).
    @Test func concurrentStressHasNoTornReadsAndMonotonicSequences() async throws {
        let mb = PoseMailbox()
        let total: UInt64 = 200_000
        let done = DispatchSemaphore(value: 0)
        let result = StressResult()

        let writer = Thread {
            for s in 1...total {
                let v = Double(s)
                mb.publish(Quaternion(w: v, x: v, y: v, z: v), timestamp: v * 0.001)
            }
            done.signal()
        }
        let reader = Thread {
            var lastSeq: UInt64 = 0
            var torn = 0, backwards = 0, newReads = 0, reads = 0
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                if let r = mb.read() {
                    reads += 1
                    let v = Double(r.sequence)
                    if r.pose.w != v || r.pose.x != v || r.pose.y != v || r.pose.z != v
                        || r.timestamp != v * 0.001 { torn += 1 }
                    if r.sequence < lastSeq { backwards += 1 }
                    if r.isNew { newReads += 1 }
                    lastSeq = r.sequence
                    if r.sequence == total { break }
                }
            }
            result.set(torn: torn, backwards: backwards, newReads: newReads, reads: reads, lastSeq: lastSeq)
            done.signal()
        }
        writer.start(); reader.start()
        await withCheckedContinuation { c in
            DispatchQueue.global().async { done.wait(); done.wait(); c.resume() }
        }
        let r = result.value
        #expect(r.torn == 0)
        #expect(r.backwards == 0)
        #expect(r.lastSeq == total)                 // reader eventually observes the final value
        #expect(r.newReads >= 1 && r.newReads <= Int(total))
        print("PoseMailbox stress: reads=\(r.reads) distinctNew=\(r.newReads) of \(total) published")
    }
}

final class StressResult: @unchecked Sendable {
    struct Values { var torn = 0, backwards = 0, newReads = 0, reads = 0; var lastSeq: UInt64 = 0 }
    private let lock = NSLock()
    private var v = Values()
    func set(torn: Int, backwards: Int, newReads: Int, reads: Int, lastSeq: UInt64) {
        lock.lock(); v = Values(torn: torn, backwards: backwards, newReads: newReads, reads: reads, lastSeq: lastSeq); lock.unlock()
    }
    var value: Values { lock.lock(); defer { lock.unlock() }; return v }
}
