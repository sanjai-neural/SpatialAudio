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

    /// One writer thread and one reader thread hammer the mailbox. Every published sample has w, x, y, z and
    /// timestamp derived from its sequence number, so a torn (half-old / half-new) read is detected.
    ///
    /// The verdict never depends on a clock. The reader stops only after the writer has reported completion
    /// AND the reader has then done one more read; that read began after the final `publish` returned, so a
    /// latest-value mailbox must hand back the final sequence. (An earlier version ended the reader on a 60 s
    /// wall-clock `Date()` deadline. A system sleep, or a process frozen for longer than that, made it fail
    /// spuriously with only `lastSeq == total` red; see docs/STATUS.md.)
    ///
    /// Soak knob for local runs, e.g. under `--sanitize=thread`:
    ///   SA_STRESS_ITERATIONS=100000000 swift test --filter concurrentStress
    @Test func concurrentStressHasNoTornReadsAndMonotonicSequences() async throws {
        let mb = PoseMailbox()
        let total = Self.stressIterations()
        let writerFinished = CompletionFlag()
        let ready = DispatchSemaphore(value: 0)
        let go = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let result = StressResult()

        let writer = Thread {
            ready.signal(); go.wait()                               // both threads start together
            for s in 1...total {
                let v = Double(s)
                mb.publish(Quaternion(w: v, x: v, y: v, z: v), timestamp: v * 0.001)
            }
            writerFinished.set()                                    // after the last publish has returned
            done.signal()
        }
        let reader = Thread {
            ready.signal(); go.wait()
            var lastSeq: UInt64 = 0
            var torn = 0, backwards = 0, newReads = 0, reads = 0
            while true {
                let writerHadFinished = writerFinished.isSet        // sampled BEFORE the read below
                if let r = mb.read() {
                    reads += 1
                    let v = Double(r.sequence)
                    if r.pose.w != v || r.pose.x != v || r.pose.y != v || r.pose.z != v
                        || r.timestamp != v * 0.001 { torn += 1 }
                    if r.sequence < lastSeq { backwards += 1 }
                    if r.isNew { newReads += 1 }
                    lastSeq = r.sequence
                }
                if writerHadFinished { break }                      // that read started after the final publish
            }
            result.set(torn: torn, backwards: backwards, newReads: newReads, reads: reads, lastSeq: lastSeq)
            done.signal()
        }
        writer.start(); reader.start()
        await withCheckedContinuation { c in
            DispatchQueue.global().async {
                ready.wait(); ready.wait()                          // both threads are running
                go.signal(); go.signal()
                done.wait(); done.wait()
                c.resume()
            }
        }
        let r = result.value
        #expect(r.torn == 0)
        #expect(r.backwards == 0)
        #expect(r.lastSeq == total)                 // a read that starts after the last publish sees the final value
        #expect(r.newReads >= 1 && r.newReads <= Int(total))
        print("PoseMailbox stress: iterations=\(total) reads=\(r.reads) distinctNew=\(r.newReads)")
    }

    private static func stressIterations() -> UInt64 {
        max(1, UInt64(ProcessInfo.processInfo.environment["SA_STRESS_ITERATIONS"] ?? "") ?? 200_000)
    }
}

/// Set once by the writer after its last publish; read by the reader before each read.
final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
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
