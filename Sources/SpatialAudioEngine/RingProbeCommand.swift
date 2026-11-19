import CoreAudio
import Foundation
import SpatialAudioCore

/// What the app's command-line switches `--ring-probe <seconds>` and `--ring-probe-simulate <seconds>` call (Step 6b-2). The app module only needs this: it builds the
/// backend, runs the probe through the pure `RingProbeRunner` and returns the report. No capture, engine or DSP code lives in the app module.
///
/// There is no option anywhere in this path that sets or raises the output gain: the engine forces it to 0 and the runner refuses to start the engine unless it reads back as 0.
public enum RingProbeCommand {
    public struct Options: Sendable {
        public var seconds: Double
        /// Use the simulated source (our own threads + the real ring). The report is labelled SIMULATED.
        public var simulate: Bool
        /// Simulated runs only.
        public var simulatedFaults: SimulatedRingBackend.Faults
        /// Step 6b-3a-2: non-nil = the recovery mode (the control-thread re-prime with these UNTUNED thresholds). nil = the plain probe, unchanged.
        public var recovery: RePrimeConfig?
        /// Step 6b-3b: build the tap bound to the default output device's stream (`--ring-probe-device-tap`). false = the global mixdown, as before.
        public var deviceTap: Bool
        /// Step 6b-3c-0: a tap on ONE process (the test player) with an explicit mute option (default unmuted); never combined with `deviceTap`.
        public var processTap: ProcessTapSpec?
        /// Step 6b-3c-0: a fault the probe injects into its own resources (needs `processTap`).
        public var muteScenario: MuteScenario?

        public init(seconds: Double, simulate: Bool = false, simulatedFaults: SimulatedRingBackend.Faults = .init(), recovery: RePrimeConfig? = nil, deviceTap: Bool = false,
                    processTap: ProcessTapSpec? = nil, muteScenario: MuteScenario? = nil) {
            self.seconds = seconds; self.simulate = simulate; self.simulatedFaults = simulatedFaults; self.recovery = recovery; self.deviceTap = deviceTap
            self.processTap = processTap; self.muteScenario = muteScenario
        }
    }

    public static func run(_ options: Options, now: Date = Date()) -> RingProbeReport {
        let environment = RingProbeEnvironment(
            createdAt: SelfTestReport.timestamp(now), macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: HostInfo.hardwareModel, ownPID: getpid(), requestedSeconds: options.seconds)

        let ticker = DispatchRingTicker()
        let backend: RingProbeBackend
        if options.simulate {
            let sim = SimulatedRingBackend(pacing: .realTime, faults: options.simulatedFaults, deviceTap: options.deviceTap, processTap: options.processTap)
            sim.onConfigurationChange = { ticker.interrupt() }
            backend = sim
        } else if #available(macOS 14.2, *) {
            let real = SystemRingBackend(deviceTap: options.deviceTap, processTap: options.processTap)
            real.onConfigurationChange = { ticker.interrupt() }
            backend = real
        } else {
            // AudioHardwareCreateProcessTap is API_AVAILABLE(macos(14.2)) (AudioHardwareTapping.h): nothing to probe on older systems.
            return RingProbeReport(
                createdAt: environment.createdAt, source: "coreAudioTap", macOSVersion: environment.macOSVersion, hardwareModel: environment.hardwareModel,
                composition: "none", ownPID: environment.ownPID, ownProcessObjectBefore: nil, ownProcessObjectAfterEngineStart: nil, excludedProcessObjects: [],
                requestedSeconds: options.seconds, elapsedSeconds: 0, stoppedBy: "never started", outcome: "unavailable: AudioHardwareCreateProcessTap needs macOS 14.2",
                flags: [], tapFormat: nil, hostTicksPerSecond: 0, constants: nil, outputGain: RingGainRecord(), timings: RingTimings(), outputDevice: nil, engine: nil,
                configurationChanges: 0, calls: [], lists: TapProbeLists(settlePolls: 0, settleSeconds: nil), teardownOrder: [], teardownClean: true, ring: nil,
                summary: nil, samples: [], injectedFaults: nil, notes: [])
        }

        // Clock for the waits (prime, first pull, post-teardown polling): a SuspendingClock does not advance while the Mac sleeps.
        let suspending = SuspendingClock()
        let origin = suspending.now
        let clock = TapProbeClock(
            now: { let d = origin.duration(to: suspending.now); return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 },
            sleep: { Thread.sleep(forTimeInterval: $0) })

        // Ctrl-C / SIGTERM: the probe still tears everything down (the ticker wakes with .signal).
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            s.setEventHandler { ticker.requestStop() }
            s.resume()
            return s
        }
        defer { sources.forEach { $0.cancel() }; signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL) }

        let orchestrator = options.recovery.map { RingRecoveryOrchestrator(backend: backend, config: $0) }
        // Events (the scenario, the start and the end of the sampling, the teardown) are printed AS THEY HAPPEN and flushed, so that someone watching the output file sees them in time.
        return RingProbeRunner.run(backend: backend, ticker: ticker, environment: environment, clock: clock, recovery: orchestrator, muteScenario: options.muteScenario,
                                   onEvent: { print($0); fflush(stdout) })
    }
}
