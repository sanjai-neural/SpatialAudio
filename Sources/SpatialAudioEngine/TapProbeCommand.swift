import CoreAudio
import Foundation
import SpatialAudioCore

/// What the app's command-line switches (`--tap-probe <seconds>` and friends) call. This is the only thing the app module needs from
/// the capture code: it builds the backend, runs the probe through the pure `TapProbeRunner` and returns the report. No capture or
/// DSP code lives in the app module.
public enum TapProbeCommand {
    public struct Options: Sendable {
        public var seconds: Double
        /// Use the simulated source (test thread + the real C callback). The report is labelled SIMULATED.
        public var simulate: Bool
        /// Add the default output device to the aggregate device (refused if it has input channels unless `allowDeviceInputs`).
        public var withOutputDevice: Bool
        public var allowDeviceInputs: Bool

        public init(seconds: Double, simulate: Bool = false, withOutputDevice: Bool = false, allowDeviceInputs: Bool = false) {
            self.seconds = seconds; self.simulate = simulate; self.withOutputDevice = withOutputDevice; self.allowDeviceInputs = allowDeviceInputs
        }
    }

    /// A problem with the requested run time, or nil.
    public static func validate(seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return "the run time must be a positive number of seconds" }
        guard seconds <= TapProbeRunner.maximumSeconds else { return "the run time is limited to \(Int(TapProbeRunner.maximumSeconds)) s (the record buffer is sized from it)" }
        return nil
    }

    public static func run(_ options: Options, now: Date = Date()) -> TapProbeReport {
        let environment = TapProbeEnvironment(
            createdAt: SelfTestReport.timestamp(now), macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: HostInfo.hardwareModel, ownPID: getpid(), requestedSeconds: options.seconds)

        let backend: TapProbeBackend
        if options.simulate {
            backend = SimulatedTapBackend(pacing: .realTime)
        } else if #available(macOS 14.2, *) {
            backend = SystemTapBackend(composition: options.withOutputDevice ? .withDefaultOutputDevice(allowDeviceInputs: options.allowDeviceInputs) : .tapOnly)
        } else {
            // AudioHardwareCreateProcessTap is API_AVAILABLE(macos(14.2)) (AudioHardwareTapping.h): nothing to probe on older systems.
            return TapProbeReport(
                createdAt: environment.createdAt, source: "coreAudioTap", macOSVersion: environment.macOSVersion, hardwareModel: environment.hardwareModel,
                composition: "none", muteBehavior: "unmuted", privateTap: true, privateAggregate: true, ownPID: environment.ownPID,
                ownProcessObjectID: nil, excludedProcessObjects: [], requestedSeconds: options.seconds, elapsedSeconds: 0, stoppedBy: "never started",
                outcome: "unavailable: AudioHardwareCreateProcessTap needs macOS 14.2", tapFormat: nil, hostTicksPerSecond: 0, calls: [], stats: nil,
                lists: TapProbeLists(settlePolls: 0, settleSeconds: nil), teardownClean: true, notes: [], assumptions: TapProbeReport.standardAssumptions)
        }

        // Clock for the post-teardown polling: a SuspendingClock does not advance while the Mac sleeps.
        let suspending = SuspendingClock()
        let origin = suspending.now
        let clock = TapProbeClock(
            now: { let d = origin.duration(to: suspending.now); return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 },
            sleep: { Thread.sleep(forTimeInterval: $0) })

        // Early stop on Ctrl-C / SIGTERM: the probe still tears everything down.
        let stopRequested = DispatchSemaphore(value: 0)
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            s.setEventHandler { stopRequested.signal() }
            s.resume()
            return s
        }
        defer { sources.forEach { $0.cancel() }; signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL) }

        return TapProbeRunner.run(backend: backend, environment: environment, clock: clock) { seconds in
            // The run time is the point of the probe (N seconds of capture), not a verdict: a signal ends it early.
            stopRequested.wait(timeout: .now() + seconds) == .success ? .signal : .timeout
        }
    }

    /// `--list-audio-devices`: counts only (no device names, which can be personal). Run it from a fresh process after a probe to
    /// look for leftovers. Note: a PRIVATE aggregate device or tap is invisible to other processes by design, so this can only show
    /// that nothing visible was left behind; the in-process "after teardown" lists in the report are the stronger evidence.
    public static func listAudioObjects() -> String {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let devices = CoreAudioProperty.objectIDs(of: system, kAudioHardwarePropertyDevices)
        let taps = CoreAudioProperty.objectIDs(of: system, kAudioHardwarePropertyTapList)
        var aggregates = 0, ours = 0
        for id in devices.ids {
            let cls = CoreAudioProperty.uint32(of: id, kAudioObjectPropertyClass).value
            if cls == kAudioAggregateDeviceClassID { aggregates += 1 }
            if let name = CoreAudioProperty.string(of: id, kAudioObjectPropertyName).value, name.hasPrefix("SpatialAudio Tap Probe") { ours += 1 }
        }
        var lines = """
        audio objects visible to this process (status of the device list read: \(devices.status), of the tap list read: \(taps.status))
        devices: \(devices.ids.count)
        aggregate devices: \(aggregates)
        devices named "SpatialAudio Tap Probe": \(ours)
        taps: \(taps.ids.count)
        """
        // Step 6a2: the read-only facts the probe's report carries, for the default output device (property getters only; nothing is created or started).
        let d = AudioDeviceFactsReader.defaultOutputDevice()
        if let id = d.id {
            let f = AudioDeviceFactsReader.read(device: id, role: "default output device", scope: kAudioObjectPropertyScopeOutput)
            func u(_ v: UInt32?) -> String { v.map(String.init) ?? "-" }
            lines += """

            default output device (read-only property reads):
              name: \(f.name ?? "-")   transport: \(f.transportType ?? "-") \(f.transportName ?? "")
              nominal rate: \(f.nominalSampleRate.map { String(format: "%.1f", $0) } ?? "-") Hz   actual rate: \(f.actualSampleRate.map { String(format: "%.3f", $0) } ?? "-") Hz   buffer: \(u(f.bufferFrameSize)) frames
              channels in / out: \(f.inputChannels.map(String.init) ?? "-") / \(f.outputChannels.map(String.init) ?? "-")
              latency (output scope): \(u(f.deviceLatencyFrames)) frames   safety offset: \(u(f.safetyOffsetFrames)) frames   stream latency: \(f.streamLatencyFrames.map(String.init).joined(separator: ", ")) frames
              clock domain: \(u(f.clockDomain))   clock device named: \(f.hasClockDevice.map { $0 ? "yes" : "no" } ?? "-")\(f.clockDeviceIsItself == true ? " (the device itself)" : "")
              reads with a non-zero status: \(f.failedReads.isEmpty ? "none" : f.failedReads.joined(separator: ", "))
            """
        } else {
            lines += "\ndefault output device: none readable (status \(d.status))"
        }
        return lines
    }
}
