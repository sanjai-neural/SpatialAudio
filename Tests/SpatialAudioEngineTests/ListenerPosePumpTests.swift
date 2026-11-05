import Testing
import Foundation
import SpatialAudioCore
@testable import SpatialAudioEngine

/// Thread-safe counter for the timer tests (a plain Int would be a data race, which ThreadSanitizer would rightly flag).
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Suite struct ListenerPosePumpTests {
    let block = 512.0 / 48_000

    func make(mapping: ListenerMapping = ListenerMapping()) -> (PoseMailbox, RecordingSink, ListenerPosePump) {
        let mailbox = PoseMailbox(), sink = RecordingSink()
        return (mailbox, sink, ListenerPosePump(mailbox: mailbox, sink: sink, mapping: mapping))
    }

    func angleBetween(_ a: Vector3, _ b: Vector3) -> Double { acos(min(max(a.dot(b), -1), 1)) / deg }

    @Test func nothingPublishedMeansNeutralWrittenOnce() {
        let (_, sink, pump) = make()
        for _ in 0..<20 { pump.step(dt: block) }
        #expect(sink.listeners == [.neutral])                   // later steps changed nothing, so nothing was re-sent
        let a = pump.applied
        #expect(a?.mailboxSequence == 0 && a?.steps == 20 && a?.sinkWrites == 1)
    }

    @Test func followsAPublishedPoseInSmallStepsWithoutOvershoot() {
        let (mailbox, sink, pump) = make()
        mailbox.publish(yawQ(40), timestamp: 1)
        let target = ListenerFrame.orientation(for: yawQ(40))
        var remaining = angleBetween(ListenerOrientation.neutral.forward, target.forward)
        for step in 0..<150 {
            let a = pump.step(dt: block)
            let now = angleBetween(a.orientation.forward, target.forward)
            if remaining > 1e-4 { #expect(now < remaining, "step \(step) did not get closer") } else { #expect(now <= 1e-3) }
            remaining = now
        }
        #expect(remaining < 0.01)
        // The very first block may cover at most the configured fraction (41%) of the 40 degree turn: no jump.
        let seen = sink.listeners
        var previous = ListenerOrientation.neutral
        for o in seen {
            #expect(angleBetween(previous.forward, o.forward) <= 40 * 0.42, "a single block moved the listener by more than 42% of the turn")
            previous = o
        }
    }

    @Test func onlyChangesReachTheSink() {
        let (mailbox, _, pump) = make()
        mailbox.publish(yawQ(25), timestamp: 1)
        for _ in 0..<200 { pump.step(dt: block) }
        let writes = pump.applied!.sinkWrites
        for _ in 0..<200 { pump.step(dt: block) }
        #expect(pump.applied!.sinkWrites == writes, "a converged, unchanged listener was written again")
        #expect(writes < 200)
    }

    @Test func flippingYawAtRuntimeTakesEffectOnTheNextStepAndBack() {
        let (mailbox, sink, pump) = make()
        mailbox.publish(yawQ(40), timestamp: 1)
        for _ in 0..<150 { pump.step(dt: block) }
        let normal = sink.listeners.last!
        pump.setMapping(ListenerMapping(invertYaw: true))
        pump.step(dt: 0)                                               // no time passes; only the mapping changed
        let flipped = sink.listeners.last!
        #expect(abs(flipped.forward.x + normal.forward.x) < 1e-6 && abs(flipped.forward.z - normal.forward.z) < 1e-6)
        #expect(normal.forward.x < -0.5)                               // sanity: it really was turned left
        pump.setMapping(ListenerMapping())
        pump.step(dt: 0)
        #expect(!sink.listeners.last!.differs(from: normal))
    }

    @Test func aMappingGivenAtConstructionApplies() {
        let (mailbox, sink, pump) = make(mapping: ListenerMapping(invertYaw: true))
        mailbox.publish(yawQ(40), timestamp: 1)
        for _ in 0..<150 { pump.step(dt: block) }
        #expect(sink.listeners.last!.forward.x > 0.5)                  // turned LEFT, but flipped to the right
    }

    @Test func aBadPublishedPoseNeverPullsTheListenerTowardNeutral() {
        let (mailbox, sink, pump) = make()
        mailbox.publish(yawQ(40), timestamp: 1)
        for _ in 0..<150 { pump.step(dt: block) }
        let settled = sink.listeners.last!, writes = pump.applied!.sinkWrites
        mailbox.publish(Quaternion(w: .nan, x: 0, y: 0, z: 0), timestamp: 2)
        mailbox.publish(Quaternion(w: 0, x: 0, y: 0, z: 0), timestamp: 3)
        for _ in 0..<100 { pump.step(dt: block) }
        #expect(!sink.listeners.last!.differs(from: settled, tolerance: 1e-9))
        #expect(pump.applied!.sinkWrites == writes)
        #expect(pump.applied!.mailboxSequence == 3)                    // it did read them; it just refused to follow them
    }

    @Test func aHugeTimeStepLandsOnTheTargetWithoutOvershoot() {
        let (mailbox, _, pump) = make()
        mailbox.publish(eulerQ(70, -20, 15), timestamp: 1)
        let a = pump.step(dt: 1000)                                    // e.g. the Mac slept
        #expect(angleDeg(a.pose, eulerQ(70, -20, 15)) < 1e-6)
    }

    // MARK: - stop() contract

    @Test func stopWaitsForATickThatIsAlreadyRunning() {
        let mailbox = PoseMailbox(), sink = GateSink()
        let pump = ListenerPosePump(mailbox: mailbox, sink: sink)
        mailbox.publish(yawQ(30), timestamp: 1)
        sink.arm()
        pump.start(period: 0.002)
        // A tick is now parked inside the sink, so it is certainly in flight. (The 60 s only bounds a hang; it is not a verdict.)
        #expect(sink.entered.wait(timeout: .now() + .seconds(60)) == .success)

        let stopReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { pump.stop(); stopReturned.signal() }
        // While that tick is parked, stop() has to keep waiting for it. This is a negative wait: a slow machine can only make
        // it pass more easily, it can never make a correct stop() fail.
        let returnedEarly = stopReturned.wait(timeout: .now() + .milliseconds(300)) == .success
        sink.release.signal()
        // If stop() already returned, its signal was consumed above. Otherwise wait for it (bounded: a hang must fail, not hang).
        if !returnedEarly { #expect(stopReturned.wait(timeout: .now() + .seconds(60)) == .success) }
        #expect(!returnedEarly, "stop() returned while a tick was still running inside the sink")
        #expect((pump.applied?.steps ?? 0) >= 1)               // the parked tick was allowed to finish
    }

    // MARK: - live timers (two threads through the real mailbox)

    @Test func timersOnTwoThreadsHandOffThroughTheMailboxAndStopCleanly() async {
        let mailbox = PoseMailbox(), sink = RecordingSink(delay: 0.002)     // slow sink: a tick is usually mid-flight when stop() is called
        let publisher = ScriptedScenePublisher(test: .headSweepYaw, mailbox: mailbox, sink: sink)
        let pump = ListenerPosePump(mailbox: mailbox, sink: sink)
        let publishTimer = PeriodicTimer(label: "test.publisher")
        let published = Counter()
        let origin = MonotonicClock.seconds()
        publishTimer.start(period: 1.0 / 200) {
            publisher.publish(at: MonotonicClock.seconds() - origin + 1.5)        // start part-way into the sweep so it is already moving
            published.increment()
        }
        pump.start(period: 1.0 / 400)

        // Polling `timing` (plain scalar counters under a lock) while the pump thread updates it is what lets ThreadSanitizer
        // check that lock; the larger `Applied` struct is copied with a bulk memcpy that this TSan runtime does not race-check.
        let flowing = await waitUntil { (pump.applied?.mailboxSequence ?? 0) >= 20 && sink.listeners.count >= 20 && pump.timing.ticks >= 20 }
        pump.stop()
        #expect(flowing)
        let stepsAtStop = pump.applied?.steps ?? -1
        let before = published.value
        let timePassed = await waitUntil { published.value >= before + 10 }       // 10 more publishes (~50 ms) with the pump stopped
        #expect(timePassed)
        #expect(pump.applied?.steps == stepsAtStop, "the pump stepped after stop() returned")
        publishTimer.stop()
        let sequence = pump.applied?.mailboxSequence ?? 0
        #expect(sequence >= 20 && sequence <= UInt64(published.value) + 1)
        #expect(pump.timing.ticks > 0)
    }
}
