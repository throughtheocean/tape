import CoreAudio
import Foundation

/// An audio device with input streams, read from the Core Audio HAL.
public struct InputDevice: Equatable, Hashable, Identifiable, Sendable {
    public var id: AudioDeviceID
    public var uid: String
    public var name: String
    public var channelCount: Int
    public var sampleRate: Double

    /// Channel choices shown to the user: pairs first, then single channels, zero based.
    public var channelChoices: [[Int]] {
        var out: [[Int]] = []
        var c = 0
        while c + 1 < channelCount {
            out.append([c, c + 1])
            c += 2
        }
        out += (0..<channelCount).map { [$0] }
        return out
    }

    public static func label(_ channels: [Int]) -> String {
        channels.count == 2 ? "\(channels[0] + 1)+\(channels[1] + 1)" : channels.map { String($0 + 1) }.joined(separator: ",")
    }
}

public enum AudioDevices {
    /// All devices with at least one input channel. Never changes any system setting.
    public static func inputDevices() -> [InputDevice] {
        deviceIDs().compactMap { id in
            let channels = inputChannelCount(id)
            guard channels > 0 else { return nil }
            return InputDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                               name: string(id, kAudioObjectPropertyName) ?? "Device \(id)",
                               channelCount: channels, sampleRate: nominalRate(id))
        }
    }

    /// Calls `handler` on the main queue whenever devices appear or disappear. Never unregistered;
    /// meant for one app wide observer.
    public static func observeDeviceList(_ handler: @escaping @Sendable () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { _, _ in handler() }
    }

    public static var defaultInputDevice: AudioDeviceID? { systemDevice(kAudioHardwarePropertyDefaultInputDevice) }
    public static var defaultOutputDevice: AudioDeviceID? { systemDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    /// The device's latency on its input or output side. Missing properties count as 0.
    public static func latency(_ id: AudioDeviceID, input: Bool) -> DeviceLatency {
        let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        func value(_ selector: AudioObjectPropertySelector, _ object: AudioObjectID? = nil) -> Int {
            let s = object == nil ? scope : kAudioObjectPropertyScopeGlobal
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: s, mElement: kAudioObjectPropertyElementMain)
            var v = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(object ?? id, &address, 0, nil, &size, &v) == noErr ? Int(v) : 0
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var stream = AudioStreamID(0)
        var size = UInt32(MemoryLayout<AudioStreamID>.size)
        let hasStream = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &stream) == noErr && stream != 0
        return DeviceLatency(deviceFrames: value(kAudioDevicePropertyLatency), safetyFrames: value(kAudioDevicePropertySafetyOffset),
                             streamFrames: hasStream ? value(kAudioStreamPropertyLatency, stream) : 0,
                             bufferFrames: value(kAudioDevicePropertyBufferFrameSize), sampleRate: nominalRate(id))
    }

    public static func name(_ id: AudioDeviceID) -> String? { string(id, kAudioObjectPropertyName) }

    private static func systemDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func nominalRate(_ id: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr ? rate : 0
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
