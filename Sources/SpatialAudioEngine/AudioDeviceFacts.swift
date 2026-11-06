import CoreAudio
import Foundation
import SpatialAudioCore

/// Read-only property reads about one audio device (Step 6a2). Property names verified in the macOS 27.2 SDK headers:
/// kAudioObjectPropertyName, kAudioDevicePropertyTransportType, kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyActualSampleRate,
/// kAudioDevicePropertyLatency, kAudioDevicePropertySafetyOffset, kAudioDevicePropertyStreams, kAudioStreamPropertyLatency,
/// kAudioDevicePropertyBufferFrameSize, kAudioDevicePropertyClockDomain, kAudioDevicePropertyClockDevice, kAudioDevicePropertyDeviceUID.
/// Getters only: nothing is set, nothing is started, no permission is involved. The status of every read is kept and an unreadable value
/// stays nil. UIDs are compared but never recorded.
enum AudioDeviceFactsReader {
    static func read(device: AudioObjectID, role: String, scope: AudioObjectPropertyScope) -> TapDeviceFacts {
        var f = TapDeviceFacts(role: role, scopeRead: scope == kAudioObjectPropertyScopeInput ? "input" : "output")
        func note(_ name: String, _ status: Int32) { f.statuses[name] = status }

        let name = CoreAudioProperty.string(of: device, kAudioObjectPropertyName); note("kAudioObjectPropertyName", name.status); f.name = name.value
        let transport = CoreAudioProperty.uint32(of: device, kAudioDevicePropertyTransportType); note("kAudioDevicePropertyTransportType", transport.status)
        if let t = transport.value {
            f.transportType = t == 0 ? "0" : (FourCC.string(t) ?? String(format: "0x%08X", t))
            f.transportName = TapDeviceTransport.name(t)
        }
        let nominal = CoreAudioProperty.float64(of: device, kAudioDevicePropertyNominalSampleRate); note("kAudioDevicePropertyNominalSampleRate", nominal.status); f.nominalSampleRate = nominal.value
        let actual = CoreAudioProperty.float64(of: device, kAudioDevicePropertyActualSampleRate); note("kAudioDevicePropertyActualSampleRate", actual.status); f.actualSampleRate = actual.value
        let buffer = CoreAudioProperty.uint32(of: device, kAudioDevicePropertyBufferFrameSize); note("kAudioDevicePropertyBufferFrameSize", buffer.status); f.bufferFrameSize = buffer.value
        let inCh = CoreAudioProperty.channelCount(of: device, scope: kAudioObjectPropertyScopeInput); note("kAudioDevicePropertyStreamConfiguration (input)", inCh.status); f.inputChannels = inCh.channels
        let outCh = CoreAudioProperty.channelCount(of: device, scope: kAudioObjectPropertyScopeOutput); note("kAudioDevicePropertyStreamConfiguration (output)", outCh.status); f.outputChannels = outCh.channels

        let latency = CoreAudioProperty.uint32(of: device, kAudioDevicePropertyLatency, scope: scope); note("kAudioDevicePropertyLatency", latency.status); f.deviceLatencyFrames = latency.value
        let safety = CoreAudioProperty.uint32(of: device, kAudioDevicePropertySafetyOffset, scope: scope); note("kAudioDevicePropertySafetyOffset", safety.status); f.safetyOffsetFrames = safety.value
        let streams = CoreAudioProperty.objectIDs(of: device, kAudioDevicePropertyStreams, scope: scope); note("kAudioDevicePropertyStreams", streams.status)
        var streamStatus: Int32 = 0
        for id in streams.ids {
            let l = CoreAudioProperty.uint32(of: AudioObjectID(id), kAudioStreamPropertyLatency)
            if l.status != 0 { streamStatus = l.status } else if let v = l.value { f.streamLatencyFrames.append(v) }
        }
        if !streams.ids.isEmpty { note("kAudioStreamPropertyLatency", streamStatus) }

        let domain = CoreAudioProperty.uint32(of: device, kAudioDevicePropertyClockDomain); note("kAudioDevicePropertyClockDomain", domain.status); f.clockDomain = domain.value
        let clock = CoreAudioProperty.string(of: device, kAudioDevicePropertyClockDevice); note("kAudioDevicePropertyClockDevice", clock.status)
        if clock.status == 0 {
            f.hasClockDevice = !(clock.value ?? "").isEmpty
            let own = CoreAudioProperty.string(of: device, kAudioDevicePropertyDeviceUID); note("kAudioDevicePropertyDeviceUID", own.status)
            if let c = clock.value, let o = own.value, !c.isEmpty { f.clockDeviceIsItself = (c == o) }
        }
        return f
    }

    static func defaultOutputDevice() -> (id: AudioObjectID?, status: Int32) {
        let r = CoreAudioProperty.uint32(of: AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        guard let v = r.value, v != 0 else { return (nil, r.status) }
        return (AudioObjectID(v), r.status)
    }
}
