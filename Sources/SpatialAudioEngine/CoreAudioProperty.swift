import CoreAudio
import Foundation

/// Small, control-thread-only helpers around `AudioObjectGetPropertyData`. Each returns the OSStatus; nothing here runs on an
/// audio thread. Used by the system-audio capture probe (Step 6a).
enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// A property that is an array of AudioObjectIDs (the device list, the tap list, ...).
    static func objectIDs(of object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> (ids: [UInt32], status: Int32) {
        var addr = address(selector)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size)
        guard status == 0 else { return ([], status) }
        guard size > 0 else { return ([], 0) }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = ids.withUnsafeMutableBytes { raw in AudioObjectGetPropertyData(object, &addr, 0, nil, &size, raw.baseAddress!) }
        guard status == 0 else { return ([], status) }
        return (Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size)), 0)
    }

    /// A property that is a CFString the caller must release (UIDs, names).
    static func string(of object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> (value: String?, status: Int32) {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var ref: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        guard status == 0, let ref else { return (nil, status) }
        return (ref.takeRetainedValue() as String, 0)
    }

    static func uint32(of object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> (value: UInt32?, status: Int32) {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        return (status == 0 ? value : nil, status)
    }

    /// Sum of the channels of all streams of a device in the given scope (input or output), from kAudioDevicePropertyStreamConfiguration.
    static func channelCount(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> (channels: Int?, status: Int32) {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size)
        guard status == 0 else { return (nil, status) }
        guard size > 0 else { return (0, 0) }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw)
        guard status == 0 else { return (nil, status) }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return (list.reduce(0) { $0 + Int($1.mNumberChannels) }, 0)
    }
}

enum HostInfo {
    /// `hw.model` (e.g. "Mac16,12").
    static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
