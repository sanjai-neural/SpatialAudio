import CoreAudio
import CTapProbe
import Foundation
import SpatialAudioCore

/// The real Core Audio backend of the system-audio capture probe (Step 6a). EVERYTHING HERE IS UNVERIFIED until Sanjai has run it.
///
/// Control thread only. The only code that runs on Core Audio's IO thread is the C function `SATapProbeIOProc` (CTapProbe), which
/// this class registers with `AudioDeviceCreateIOProcID`. API names and availability were read from the macOS 27.2 SDK headers
/// (docs/ARCHITECTURE.md, "System audio capture probe"): `AudioHardwareCreateProcessTap` and `AudioHardwareDestroyProcessTap` are
/// `API_AVAILABLE(macos(14.2))`, hence this class is too (this Mac runs 27.2 and cannot test 14.2 vs 14.4).
///
/// Lifetime rule: the record buffer is NEVER freed here. AudioDeviceDestroyIOProcID and AudioHardwareDestroyAggregateDevice do
/// not say (header) that they wait for a callback that is already running, and the destroy of an aggregate device is documented as
/// asynchronous, so freeing could race with a late callback. The probe process exits right after the run, so the buffer is
/// reclaimed then. Step 6b needs a real lifetime protocol.
@available(macOS 14.2, *)
public final class SystemTapBackend: TapProbeBackend {
    public enum Composition: Sendable, Equatable {
        /// Private aggregate device containing only the tap (the shape of Apple's sample: name and UID, no sub-device).
        case tapOnly
        /// Also the default output device as main sub-device. Refused if that device has input channels, unless allowed.
        case withDefaultOutputDevice(allowDeviceInputs: Bool)
    }

    public let source = "coreAudioTap"
    public private(set) var composition: String
    private let mode: Composition

    private var probe: OpaquePointer?          // SATapProbe*, see the lifetime rule above
    private var procID: AudioDeviceIOProcID?
    private var outputDeviceUID: String?
    private var outputDeviceInputChannels: Int?
    private var outputDeviceID: AudioObjectID?          // the default output device read by `outputDeviceFacts`, sampled again for the rate series

    public init(composition: Composition = .tapOnly) {
        mode = composition
        switch composition {
        case .tapOnly: self.composition = "private aggregate device with the tap only (no sub-device)"
        case .withDefaultOutputDevice: self.composition = "private aggregate device with the tap and the default output device as main sub-device (not resolved yet)"
        }
    }

    // MARK: preflight

    public func preflight() -> String? {
        guard case .withDefaultOutputDevice(let allow) = mode else { return nil }
        let system = AudioObjectID(kAudioObjectSystemObject)
        let dev = CoreAudioProperty.uint32(of: system, kAudioHardwarePropertyDefaultOutputDevice)
        guard let id = dev.value, id != 0 else { return "no default output device could be read (status \(dev.status))" }
        let uid = CoreAudioProperty.string(of: id, kAudioDevicePropertyDeviceUID)
        let transport = CoreAudioProperty.uint32(of: id, kAudioDevicePropertyTransportType).value.flatMap { FourCC.string($0) } ?? "unknown"
        let inputs = CoreAudioProperty.channelCount(of: id, scope: kAudioObjectPropertyScopeInput)
        outputDeviceUID = uid.value
        outputDeviceInputChannels = inputs.channels
        composition = "private aggregate device with the tap and the default output device (UID \(uid.value ?? "unreadable"), transport '\(transport)', "
            + "\(inputs.channels.map(String.init) ?? "unknown") input channel(s)) as main sub-device"
        guard uid.value != nil else { return "the default output device's UID could not be read (status \(uid.status))" }
        guard let n = inputs.channels else { return "the default output device's input channel count could not be read (status \(inputs.status))" }
        if n > 0 && !allow {
            return "the default output device has \(n) input channel(s) (transport '\(transport)'); putting it into the aggregate device could open a microphone input or switch a Bluetooth headset's profile. Use the built-in speakers or pass --allow-device-inputs"
        }
        return nil
    }

    // MARK: building the chain

    public func translateOwnPID() -> (object: UInt32, status: Int32) {
        var addr = CoreAudioProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return (object, status)
    }

    public func createTap(excludingProcessObjects: [UInt32]) -> (tap: UInt32, status: Int32) {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludingProcessObjects.map { AudioObjectID($0) })
        description.name = "SpatialAudio tap probe"
        description.isPrivate = true
        description.muteBehavior = .unmuted          // the original audio stays audible
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

    public func prepareCapture(format: TapFormat, capacity: Int) -> Bool {
        probe = SATapProbeCreate(UInt32(clamping: capacity), format.bytesPerSample, format.isFloat32)
        return probe != nil
    }

    public func createAggregate(tapUID: String) -> (device: UInt32, status: Int32) {
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SpatialAudio Tap Probe",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: NSNumber(value: 1),
            kAudioAggregateDeviceIsStackedKey: NSNumber(value: 0),
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
            // Deliberately NOT kAudioAggregateDeviceTapAutoStartKey: the header says it makes AudioDeviceStart wait for audio.
        ]
        if case .withDefaultOutputDevice = mode, let uid = outputDeviceUID {
            description[kAudioAggregateDeviceMainSubDeviceKey] = uid
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid]]
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
        return (device, status)
    }

    public func createIOProc(on device: UInt32) -> Int32 {
        guard let probe else { return Int32(bitPattern: FourCC.value("!obj")) }
        var id: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(AudioObjectID(device), SATapProbeIOProc, UnsafeMutableRawPointer(probe), &id)
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

    // MARK: read-only device facts (Step 6a2)

    public func outputDeviceFacts() -> TapDeviceFacts {
        let d = AudioDeviceFactsReader.defaultOutputDevice()
        guard let id = d.id else { return TapDeviceFacts(role: "default output device", statuses: ["kAudioHardwarePropertyDefaultOutputDevice": d.status]) }
        outputDeviceID = id
        var f = AudioDeviceFactsReader.read(device: id, role: "default output device", scope: kAudioObjectPropertyScopeOutput)
        f.statuses["kAudioHardwarePropertyDefaultOutputDevice"] = d.status
        return f
    }

    public func aggregateDeviceFacts(_ device: UInt32) -> TapDeviceFacts {
        AudioDeviceFactsReader.read(device: AudioObjectID(device), role: "tap aggregate device", scope: kAudioObjectPropertyScopeInput)
    }

    public func sampleActualRates(aggregate: UInt32?) -> (output: Double?, aggregate: Double?) {
        (outputDeviceID.flatMap { CoreAudioProperty.float64(of: $0, kAudioDevicePropertyActualSampleRate).value },
         aggregate.flatMap { CoreAudioProperty.float64(of: AudioObjectID($0), kAudioDevicePropertyActualSampleRate).value })
    }

    public func collect() -> TapProbeCollected {
        TapProbeCollected(records: TapProbeRecords.read(probe), dropped: probe.map(SATapProbeDropped) ?? 0, hostTicksPerSecond: AudioGetHostClockFrequency())
    }
}

/// Copies the published records out of a probe, field by field, on the control thread.
enum TapProbeRecords {
    static func read(_ probe: OpaquePointer?) -> [TapProbeRecord] {
        guard let probe else { return [] }
        let n = SATapProbeCommitted(probe)                   // acquire
        var out: [TapProbeRecord] = []
        out.reserveCapacity(Int(n))
        for i in 0..<n {
            var r = SATapProbeRecord()
            guard SATapProbeReadRecord(probe, i, &r) else { break }
            out.append(TapProbeRecord(hostTime: r.hostTime, sumSquares: r.sumSquares, frames: r.frames, samples: r.samples, peak: r.peak, flags: r.flags,
                                       inputHostTime: r.inputHostTime, inputSampleTime: r.inputSampleTime))
        }
        return out
    }
}
