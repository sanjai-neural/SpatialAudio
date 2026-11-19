import CoreAudio
import CSystemAudioRing
import Foundation
import SpatialAudioCore

/// The real backend of `--ring-probe` (Step 6b-2). EVERYTHING HERE IS UNVERIFIED until Sanjai has run it.
///
/// The 6a tap chain (a global stereo tap excluding this process, unmuted, private; a private tap-only aggregate device) with `SARingIOProc` as the IOProc and
/// the ring as its client data, and a real-time `AVAudioEngine` (two source nodes into the main mixer, output volume 0) on the default output device.
/// `SystemTapBackend` (6a) is deliberately NOT reused or changed: its verified behaviour must stay exactly as it was, so the few Core Audio calls are repeated here.
///
/// Control thread only. The only code that runs on Core Audio's IO thread is the C function `SARingIOProc`; the only code on the engine's render
/// threads are the two blocks of `SACreateSourceNode`, each making one call into `SARingRender`.
///
/// **Lifetime rule: the ring is NEVER freed here** (`finishRing`). `AudioDeviceStop` / `AudioDeviceDestroyIOProcID` / `AudioHardwareDestroyAggregateDevice` /
/// `AudioHardwareDestroyProcessTap` and `AVAudioEngine stop` / `detachNode:` do not say (in the macOS 27.2 headers) that they wait for a callback or render block that
/// is already running; the aggregate destroy is documented as asynchronous. The process exits right after the run, which reclaims the ring.
@available(macOS 14.2, *)
public final class SystemRingBackend: RingProbeBackend {
    public let source = "coreAudioTap"
    public var composition: String {
        let tap: String
        switch tapMode {
        case .globalMixdown: tap = "the tap only"
        case .deviceBound: tap = "a tap BOUND TO THE DEFAULT OUTPUT DEVICE'S STREAM 0 (Step 6b-3b, device-bound)"
        case .processSpecific: tap = "a tap on ONE PROCESS (the test player) bound to the default output device's stream 0 (Step 6b-3c-0, process-specific; mute behaviour \(processTapSpec?.mute.rawValue ?? "unmuted"))"
        }
        return "private aggregate device with \(tap) (no sub-device); SARingIOProc as the IOProc; AVAudioEngine (two source nodes -> main mixer, output volume 0) on the default output device"
    }
    /// Step 6b-3b: which tap `createTap` builds (the global stereo mixdown, or the one bound to the default output device's stream).
    public let tapMode: RingProbeTapMode
    public var hostTicksPerSecond: Double { AudioGetHostClockFrequency() }
    public let ringConstants = RingProbeConstants(capacityFrames: SA_RING_DEFAULT_CAPACITY_FRAMES, primeCallbacks: SA_RING_DEFAULT_PRIME_CALLBACKS)
    public var injectedFaults: String? { nil }

    /// Set by the command before the run: wakes the sampling ticker when the engine reports a configuration change.
    public var onConfigurationChange: (@Sendable () -> Void)?

    private var ring: OpaquePointer?
    private var procID: AudioDeviceIOProcID?
    private var engine: RingProbeEngine?
    private var startOutputDevice: AudioObjectID?
    /// Test seam: true once `SARingFree` has been called on the ring. It must stay false for the whole life of this backend.
    private(set) var ringFreed = false

    /// Step 6b-3c-0: the process-specific tap's target and mute behaviour (nil = not that mode).
    public let processTapSpec: ProcessTapSpec?

    public init(deviceTap: Bool = false, processTap: ProcessTapSpec? = nil) {
        processTapSpec = processTap
        tapMode = processTap != nil ? .processSpecific : (deviceTap ? .deviceBound : .globalMixdown)
    }

    public func preflight() -> String? { nil }

    // MARK: facts

    public func outputDeviceFacts() -> RingOutputFacts {
        let d = AudioDeviceFactsReader.defaultOutputDevice()
        guard let id = d.id else { return RingOutputFacts(statuses: ["kAudioHardwarePropertyDefaultOutputDevice": d.status]) }
        startOutputDevice = id
        let f = AudioDeviceFactsReader.read(device: id, role: "default output device", scope: kAudioObjectPropertyScopeOutput)
        // Copied one field at a time on purpose: the name and the UID-derived fields of `TapDeviceFacts` never reach this report.
        return RingOutputFacts(transportType: f.transportType, transportName: f.transportName, nominalSampleRate: f.nominalSampleRate,
                               actualSampleRate: f.actualSampleRate, bufferFrameSize: f.bufferFrameSize, outputChannels: f.outputChannels,
                               inputChannels: f.inputChannels, statuses: f.statuses.filter { $0.key != "kAudioObjectPropertyName" })
    }

    public func translateOwnPID() -> (object: UInt32, status: Int32) {
        var addr = CoreAudioProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return (object, status)
    }

    // MARK: the tap chain (the same calls as SystemTapBackend)

    public func createTap(excludingProcessObjects: [UInt32]) -> (tap: UInt32, status: Int32) {
        let description: CATapDescription
        switch tapMode {
        case .globalMixdown:
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludingProcessObjects.map { AudioObjectID($0) })
        case .deviceBound:
            // CATapDescription.h: initExcludingProcesses:andDeviceUID:withStream: "Mix all process audio streams destined for the selected device stream except the given
            // processes ... The format of the tap will match the format of this stream." Stream 0 is a GUESS (the header says only "the index of the stream"). The device's UID is
            // read here and used in this call only: it is never stored, logged or reported. Whether the tap really arrives at the output rate is what the spike measures.
            guard let device = startOutputDevice ?? AudioDeviceFactsReader.defaultOutputDevice().id else { return (0, Int32(bitPattern: FourCC.value("!dev"))) }
            let uid = CoreAudioProperty.string(of: device, kAudioDevicePropertyDeviceUID)
            guard uid.status == 0, let deviceUID = uid.value else { return (0, uid.status != 0 ? uid.status : Int32(bitPattern: FourCC.value("!uid"))) }
            description = CATapDescription(__excludingProcesses: excludingProcessObjects.map { NSNumber(value: $0) }, andDeviceUID: deviceUID, withStream: 0)
        case .processSpecific:
            return (0, Int32(bitPattern: FourCC.value("!prc")))      // the process-specific tap is created by `createProcessTap`, never here
        }
        description.name = "SpatialAudio ring probe"
        description.isPrivate = true
        description.muteBehavior = .unmuted          // the original audio stays audible
        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        return (tap, status)
    }

    /// Step 6b-3c-0: the target PID's process object (`kAudioHardwarePropertyTranslatePIDToProcessObject`; "kAudioObjectUnknown" if the PID is not an audio process the system knows).
    public func translateTargetProcess() -> (object: UInt32, status: Int32)? {
        guard let spec = processTapSpec else { return nil }
        var addr = CoreAudioProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = spec.targetPID
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return (object, status)
    }

    /// Step 6b-3c-0: CATapDescription.h `initWithProcesses:andDeviceUID:withStream:`, "Mix all given process audio streams destined for the selected device stream"; the description object reads back
    /// `isExclusive == false` (scratch check of 2026-11-19), although the header's parameter text says "exclude" (a contradiction in the header). The list holds ONLY the target: our own process is absent.
    /// The mute behaviour is the explicit option (default unmuted); what a muted tap does to the target's audio when it is destroyed or our process dies is NOT stated by the headers: that is what the experiments measure.
    public func createProcessTap(includingProcessObjects: [UInt32]) -> (tap: UInt32, status: Int32) {
        guard tapMode == .processSpecific, let spec = processTapSpec else { return (0, Int32(bitPattern: FourCC.value("!prc"))) }
        guard let device = startOutputDevice ?? AudioDeviceFactsReader.defaultOutputDevice().id else { return (0, Int32(bitPattern: FourCC.value("!dev"))) }
        let uid = CoreAudioProperty.string(of: device, kAudioDevicePropertyDeviceUID)
        guard uid.status == 0, let deviceUID = uid.value else { return (0, uid.status != 0 ? uid.status : Int32(bitPattern: FourCC.value("!uid"))) }
        let description = CATapDescription(__processes: includingProcessObjects.map { NSNumber(value: $0) }, andDeviceUID: deviceUID, withStream: 0)
        description.name = "SpatialAudio ring probe (process)"
        description.isPrivate = true
        description.muteBehavior = spec.mute.coreAudioValue
        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        return (tap, status)
    }

    public func readTapUID(_ tap: UInt32) -> (uid: String?, status: Int32) {
        let r = CoreAudioProperty.string(of: tap, kAudioTapPropertyUID)
        return (r.value, r.status)
    }

    public func readTapFormat(_ tap: UInt32) -> (format: TapFormat?, status: Int32) {
        var addr = CoreAudioProperty.address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
        guard status == 0 else { return (nil, status) }
        let id = FourCC.string(asbd.mFormatID) ?? String(format: "0x%08X", asbd.mFormatID)
        return (TapFormat(sampleRate: asbd.mSampleRate, formatID: id, formatFlags: asbd.mFormatFlags, bytesPerPacket: asbd.mBytesPerPacket,
                          framesPerPacket: asbd.mFramesPerPacket, bytesPerFrame: asbd.mBytesPerFrame,
                          channelsPerFrame: asbd.mChannelsPerFrame, bitsPerChannel: asbd.mBitsPerChannel), 0)
    }

    public func createRing() -> Bool {
        ring = SARingCreate(SA_RING_DEFAULT_CAPACITY_FRAMES)
        return ring != nil
    }

    public func createAggregate(tapUID: String) -> (device: UInt32, status: Int32) {
        let description: [String: Any] = [
            // The prefix is the one `--list-audio-devices` looks for, so a leftover of this probe is counted there too.
            kAudioAggregateDeviceNameKey: "SpatialAudio Tap Probe (ring)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: NSNumber(value: 1),
            kAudioAggregateDeviceIsStackedKey: NSNumber(value: 0),
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
            // Deliberately NOT kAudioAggregateDeviceTapAutoStartKey (the header says it makes AudioDeviceStart wait for audio), and no sub-device.
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
        return (device, status)
    }

    public func createIOProc(on device: UInt32) -> Int32 {
        guard let ring else { return Int32(bitPattern: FourCC.value("!obj")) }
        var id: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(AudioObjectID(device), SARingIOProc, UnsafeMutableRawPointer(ring), &id)
        if status == 0 { procID = id }
        return status
    }

    public func start(_ device: UInt32) -> Int32 { AudioDeviceStart(AudioObjectID(device), procID) }
    public func stop(_ device: UInt32) -> Int32 { AudioDeviceStop(AudioObjectID(device), procID) }

    public func destroyIOProc(on device: UInt32) -> Int32 {
        guard let id = procID else { return 0 }
        let status = AudioDeviceDestroyIOProcID(AudioObjectID(device), id)
        if status == 0 { procID = nil }
        return status
    }

    public func destroyAggregate(_ device: UInt32) -> Int32 { AudioHardwareDestroyAggregateDevice(AudioObjectID(device)) }
    public func destroyTap(_ tap: UInt32) -> Int32 { AudioHardwareDestroyProcessTap(AudioObjectID(tap)) }
    public func listDevices() -> (ids: [UInt32], status: Int32) { CoreAudioProperty.objectIDs(of: AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) }
    public func listTaps() -> (ids: [UInt32], status: Int32) { CoreAudioProperty.objectIDs(of: AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyTapList) }

    // MARK: the engine

    public func prepareEngine(tapFormat: TapFormat) -> (ok: Bool, detail: String?) {
        guard let ring else { return (false, "no ring") }
        do {
            let e = try RingProbeEngine(ring: ring, sampleRate: tapFormat.sampleRate, mode: .device)
            e.onConfigurationChange = onConfigurationChange
            e.prepare()
            engine = e
            return (true, nil)
        } catch {
            return (false, "\(error)")
        }
    }

    public func engineFacts() -> RingEngineFacts? { engine?.facts() }
    public func engineOutputGain() -> Double? { engine.map { Double($0.outputGain) } }
    public func prime(callbacks: UInt32) -> Bool { ring.map { SARingPrime($0, callbacks) } ?? false }
    public var isEngineRunning: Bool { engine?.isRunning ?? false }
    public func pauseEngine() { engine?.pause() }

    public func startEngine() -> (ok: Bool, detail: String?) {
        guard let engine else { return (false, "no engine") }
        do { try engine.start(); return (true, nil) } catch { return (false, "\(error)") }
    }

    public func configurationChangeCount() -> Int { engine?.configurationChanges.value ?? 0 }
    public func stopEngine() { engine?.stop() }
    public func detachSourceNodes() { engine?.detachSourceNodes() }

    // MARK: sampling

    public func snapshot() -> RingProbeRawSample? {
        guard let ring else { return nil }
        // The default output device is read again at every sample: a device change is a different event from a rate change on the same device.
        var nominal: Double?, actual: Double?, changed = false
        if let id = AudioDeviceFactsReader.defaultOutputDevice().id {
            nominal = CoreAudioProperty.float64(of: id, kAudioDevicePropertyNominalSampleRate).value
            actual = CoreAudioProperty.float64(of: id, kAudioDevicePropertyActualSampleRate).value
            if let start = startOutputDevice { changed = id != start }
        } else if startOutputDevice != nil { changed = true }
        return RingSnapshotMapper.raw(ring: ring, outputNominalRate: nominal, outputActualRate: actual, defaultOutputChanged: changed)
    }

    // MARK: the ring's fate

    public func finishRing() -> RingDisposition {
        // NOT freed: see the lifetime rule above. (A protocol that WOULD allow freeing is written in docs/ARCHITECTURE.md, marked PLANNED.)
        RingDisposition(freed: false, reason: "kept until the process exits: the headers do not say that stopping the engine or the IO proc, or destroying the aggregate device, waits for a callback that is already running")
    }
}
