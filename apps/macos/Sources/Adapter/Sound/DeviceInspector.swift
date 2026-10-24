import CoreAudio
import Foundation

/// Reads what Core Audio knows about one device, for the device inspector: how it is connected, its rates, buffer and delay, and
/// whether its volume, mute and balance are the device's own or Kriya's.
extension AudioControl {
    func details(of device: AudioDevice) -> DeviceDetails {
        let id = device.id
        func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        }
        func uint(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
            var a = address(selector, scope: scope)
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr ? value : 0
        }
        func has(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
            var a = address(selector, scope: scope, element: element)
            return AudioObjectHasProperty(id, &a)
        }
        // The side that matters for the device: its output if it has one, otherwise its input.
        let scope = device.isOutput ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
        // A device's own volume may sit on the main element or on each channel.
        let hardwareVolume = has(kAudioDevicePropertyVolumeScalar, scope: scope) || has(kAudioDevicePropertyVolumeScalar, scope: scope, element: 1)
        let hardwareMute = has(kAudioDevicePropertyMute, scope: scope) || has(kAudioDevicePropertyMute, scope: scope, element: 1)
        var manufacturer: String?
        var m = address(kAudioObjectPropertyManufacturer)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        if AudioObjectGetPropertyData(id, &m, 0, nil, &size, &value) == noErr { manufacturer = value as String }
        return DeviceDetails(
            name: device.name, uid: device.uid,
            transport: DeviceDetails.Transport(code: uint(kAudioDevicePropertyTransportType)),
            isOutput: device.isOutput, isInput: device.isInput,
            sampleRate: sampleRate(of: id) ?? 0, availableRates: sampleRates(of: id),
            outputChannels: channelCount(id, output: true), inputChannels: channelCount(id, output: false),
            bufferFrames: Int(uint(kAudioDevicePropertyBufferFrameSize)),
            deviceLatencyFrames: Int(uint(kAudioDevicePropertyLatency, scope: scope)),
            streamLatencyFrames: streamLatency(id, scope: scope),
            safetyOffsetFrames: Int(uint(kAudioDevicePropertySafetyOffset, scope: scope)),
            hasHardwareVolume: hardwareVolume, hasHardwareMute: hardwareMute, hasBalance: balance(of: id) != nil,
            isHidden: uint(kAudioDevicePropertyIsHidden) != 0, manufacturer: manufacturer)
    }

    private func channelCount(_ device: AudioDeviceID, output: Bool) -> Int {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// The delay of the device's first stream, which Bluetooth and AirPlay devices report here rather than on the device.
    private func streamLatency(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var list = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &list, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return 0 }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &list, 0, nil, &size, &streams) == noErr, let first = streams.first else { return 0 }
        var a = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyLatency, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var vsize = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(first, &a, 0, nil, &vsize, &value) == noErr ? Int(value) : 0
    }
}
