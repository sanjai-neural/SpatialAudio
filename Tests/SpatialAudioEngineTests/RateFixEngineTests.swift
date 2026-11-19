import Testing
import Foundation
import SpatialAudioCore
@testable import SpatialAudioEngine

// Step 6b-3b (a2): the engine layer of the device-bound mode. Nothing here creates a Core Audio tap or touches a device: `SystemRingBackend` is only CONSTRUCTED (its init does
// nothing), and the runs are on the SIMULATED backend, whose tap rate and output rate are FABRICATED (its verdict decides nothing). What the real device-bound tap reports is
// exactly what the hardware spike measures; no test here says anything about it.

private final class VirtualStepTicker: RingProbeTicker {
    let sim: SimulatedRingBackend
    let limit: Int
    var waits = 0
    init(sim: SimulatedRingBackend, limit: Int) { self.sim = sim; self.limit = limit }
    func start(periodSeconds: Double) {}
    func wait() -> RingProbeWake {
        waits += 1
        if waits > limit { return .signal }
        sim.advanceOneSecond()
        return .tick
    }
    func stop() {}
}

private final class VirtualStepClock: @unchecked Sendable {
    private let lock = NSLock(); private var t = 0.0
    var clock: TapProbeClock {
        TapProbeClock(now: { [self] in lock.lock(); defer { lock.unlock() }; return t }, sleep: { [self] d in lock.lock(); t += d; lock.unlock() })
    }
}

@Suite struct RateFixEngineTests {
    @Test func theRealBackendRemembersTheDeviceTapSwitchAndSaysSoInItsComposition() {
        guard #available(macOS 14.2, *) else { return }
        let device = SystemRingBackend(deviceTap: true), global = SystemRingBackend()
        #expect(device.tapMode == .deviceBound && global.tapMode == .globalMixdown)
        #expect(device.composition.contains("BOUND TO THE DEFAULT OUTPUT DEVICE'S STREAM 0"))
        #expect(!global.composition.contains("BOUND") && global.composition.contains("with the tap only"))
    }

    @Test func theSimulatedBackendRemembersTheDeviceTapSwitch() {
        #expect(SimulatedRingBackend(pacing: .virtualTime(blocksPerSecond: 94), deviceTap: true).tapMode == .deviceBound)
        #expect(SimulatedRingBackend(pacing: .virtualTime(blocksPerSecond: 94)).tapMode == .globalMixdown)
    }

    @Test func aSimulatedDeviceBoundRunThroughTheRealRingAndEngineCarriesASimulatedS0Verdict() throws {
        let sim = SimulatedRingBackend(pacing: .virtualTime(blocksPerSecond: 94), deviceTap: true)
        let env = RingProbeEnvironment(createdAt: "t", macOSVersion: "t", hardwareModel: "t", ownPID: 1, requestedSeconds: 5)
        let r = RingProbeRunner.run(backend: sim, ticker: VirtualStepTicker(sim: sim, limit: 50), environment: env, clock: VirtualStepClock().clock)
        #expect(r.outcome == "ok" && r.isSimulated && r.tapMode == .deviceBound)
        let fix = try #require(r.rateFix)
        #expect(fix.stage == .s0 && fix.verdict == .proceedToS1 && fix.verdictText.hasPrefix("SIMULATED (fabricated data, decides nothing): "))
        #expect(fix.informational.contains { $0.contains("cannot tell the device-bound tap from the global one") }, "the simulated output is 48 kHz")
        #expect(r.timings.firstSampleRunClockSeconds != nil)
        let g = SimulatedRingBackend(pacing: .virtualTime(blocksPerSecond: 94))
        let rg = RingProbeRunner.run(backend: g, ticker: VirtualStepTicker(sim: g, limit: 50), environment: env, clock: VirtualStepClock().clock)
        #expect(rg.tapMode == .globalMixdown && rg.rateFix == nil)
    }

    @Test func theCommandBuildsTheDeviceBoundBackendOnlyWhenAskedAndTheReportSaysWhich() {
        // A one-second REAL-TIME simulated run (our own threads): the report is SIMULATED. Not a verdict test: the stage is unclassified (1 s).
        let on = RingProbeCommand.run(.init(seconds: 1, simulate: true, deviceTap: true))
        #expect(on.isSimulated && on.tapMode == .deviceBound && on.rateFix?.stage == .unclassified && on.rateFix?.verdict == .unclassified)
        let off = RingProbeCommand.run(.init(seconds: 1, simulate: true))
        #expect(off.isSimulated && off.tapMode == .globalMixdown && off.rateFix == nil)
    }
}
