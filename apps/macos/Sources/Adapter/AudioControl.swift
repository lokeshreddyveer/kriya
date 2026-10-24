import AppKit
import CoreAudio

/// One sound device, as the system lists it.
struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isOutput: Bool
    let isInput: Bool
}

/// The Mac's volume, mute and sound devices, through Core Audio. Some devices (many monitors over HDMI) have no volume of
/// their own; those report nothing and a change does nothing, and Kriya says so.
final class AudioControl {
    static let commands: [(command: String, title: String)] = [
        ("audio.volume_up", "Volume up"),
        ("audio.volume_down", "Volume down"),
        ("audio.mute", "Mute or unmute the sound"),
        ("audio.mic_mute", "Mute or unmute the microphone"),
        ("audio.next_output", "Switch to the next sound output"),
    ]

    private let toast = Toast()

    // MARK: Devices

    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    func devices() -> [AudioDevice] {
        var size: UInt32 = 0
        var all = address(kAudioHardwarePropertyDevices)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &all, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &all, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let output = channels(id, scope: kAudioObjectPropertyScopeOutput) > 0
            let input = channels(id, scope: kAudioObjectPropertyScopeInput) > 0
            guard output || input, let name = name(of: id), let uid = uid(of: id) else { return nil }
            return AudioDevice(id: id, uid: uid, name: name, isOutput: output, isInput: input)
        }
    }

    private func name(of device: AudioDeviceID) -> String? {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var a = address(kAudioObjectPropertyName)
        let status = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(device, &a, 0, nil, &size, $0) }
        return status == noErr ? name as String : nil
    }

    private func channels(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static let shared = AudioControl()

    /// The unique name Core Audio gives the current output device, for building a device that plays on it.
    func defaultOutputUID() -> String? {
        guard let id = defaultDevice(input: false) else { return nil }
        return uid(of: id)
    }

    func uid(of device: AudioDeviceID) -> String? {
        var a = address(kAudioDevicePropertyDeviceUID)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr ? value as String : nil
    }

    func defaultDevice(input: Bool) -> AudioDeviceID? {
        var a = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr && id != 0 ? id : nil
    }

    @discardableResult
    func setDefault(_ device: AudioDevice) -> Bool {
        var a = address(device.isOutput ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice)
        var id = device.id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    // MARK: Volume and mute

    /// The volume of a device from 0 to 1, or nil when it has none of its own.
    func volume(of device: AudioDeviceID, input: Bool = false) -> Double? {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        var a = address(kAudioDevicePropertyVolumeScalar, scope: scope)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(device, &a), AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr { return Double(value) }
        // Some devices have one volume per channel.
        var left = address(kAudioDevicePropertyVolumeScalar, scope: scope, element: 1)
        var right = address(kAudioDevicePropertyVolumeScalar, scope: scope, element: 2)
        var l = Float32(0), r = Float32(0)
        guard AudioObjectHasProperty(device, &left), AudioObjectGetPropertyData(device, &left, 0, nil, &size, &l) == noErr else { return nil }
        if AudioObjectHasProperty(device, &right), AudioObjectGetPropertyData(device, &right, 0, nil, &size, &r) == noErr { return Double((l + r) / 2) }
        return Double(l)
    }

    @discardableResult
    func setVolume(_ level: Double, of device: AudioDeviceID, input: Bool = false) -> Bool {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        var value = Float32(AudioMath.clamp(level))
        let size = UInt32(MemoryLayout<Float32>.size)
        var main = address(kAudioDevicePropertyVolumeScalar, scope: scope)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(device, &main), AudioObjectIsPropertySettable(device, &main, &settable) == noErr, settable.boolValue {
            return AudioObjectSetPropertyData(device, &main, 0, nil, size, &value) == noErr
        }
        var ok = false
        for element in [AudioObjectPropertyElement(1), 2] {
            var a = address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element)
            if AudioObjectHasProperty(device, &a), AudioObjectSetPropertyData(device, &a, 0, nil, size, &value) == noErr { ok = true }
        }
        return ok
    }

    func isMuted(_ device: AudioDeviceID, input: Bool = false) -> Bool? {
        var a = address(kAudioDevicePropertyMute, scope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &a), AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    @discardableResult
    func setMuted(_ muted: Bool, device: AudioDeviceID, input: Bool = false) -> Bool {
        var a = address(kAudioDevicePropertyMute, scope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var value = UInt32(muted ? 1 : 0)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &a), AudioObjectIsPropertySettable(device, &a, &settable) == noErr, settable.boolValue else { return false }
        return AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    // MARK: Commands

    func run(_ command: String) {
        switch command {
        case "audio.volume_up": nudge(up: true)
        case "audio.volume_down": nudge(up: false)
        case "audio.mute": toggleMute(input: false)
        case "audio.mic_mute": toggleMute(input: true)
        case "audio.next_output": nextOutput()
        default: break
        }
    }

    func nudge(up: Bool) {
        guard let device = defaultDevice(input: false), let current = volume(of: device) else { toast.show("This sound output has no volume of its own.", isError: true); return }
        let next = AudioMath.stepped(current, up: up)
        if setVolume(next, of: device) { _ = setMuted(false, device: device); toast.show("Volume \(AudioMath.percent(next))%") } else { toast.show("This sound output does not let the volume be changed.", isError: true) }
    }

    func set(percent: Int) {
        guard let device = defaultDevice(input: false), setVolume(AudioMath.level(percent: percent), of: device) else { toast.show("This sound output does not let the volume be changed.", isError: true); return }
        toast.show("Volume \(percent)%")
    }

    func toggleMute(input: Bool) {
        guard let device = defaultDevice(input: input), let now = isMuted(device, input: input) else { toast.show("This device cannot be muted.", isError: true); return }
        if setMuted(!now, device: device, input: input) { toast.show(input ? (now ? "Microphone on" : "Microphone muted") : (now ? "Sound on" : "Sound muted")) } else { toast.show("This device cannot be muted.", isError: true) }
    }

    func nextOutput() {
        let outputs = devices().filter(\.isOutput)
        guard outputs.count > 1 else { toast.show("There is only one sound output.", isError: true); return }
        let current = defaultDevice(input: false)
        let index = outputs.firstIndex { $0.id == current } ?? -1
        let next = outputs[(index + 1) % outputs.count]
        if setDefault(next) { toast.show("Sound output: \(next.name)") }
    }

    // MARK: Sample rate and balance

    /// The sample rates the device offers, lowest first.
    func sampleRates(of device: AudioDeviceID) -> [Double] {
        var a = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &ranges) == noErr else { return [] }
        return Array(Set(ranges.map { $0.mMinimum })).sorted()
    }

    func sampleRate(of device: AudioDeviceID) -> Double? {
        var a = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &rate) == noErr ? rate : nil
    }

    func setSampleRate(_ rate: Double, of device: AudioDeviceID) -> Bool {
        var a = address(kAudioDevicePropertyNominalSampleRate)
        var value = Float64(rate)
        return AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float64>.size), &value) == noErr
    }

    /// Left to right, 0 is all left, 0.5 the middle and 1 all right. Nil if the device has no balance.
    func balance(of device: AudioDeviceID) -> Double? {
        var a = address(AudioObjectPropertySelector(0x766D6263), scope: kAudioObjectPropertyScopeOutput)   // 'vmbc'
        guard AudioObjectHasProperty(device, &a) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr ? Double(value) : nil
    }

    func setBalance(_ value: Double, of device: AudioDeviceID) -> Bool {
        var a = address(AudioObjectPropertySelector(0x766D6263), scope: kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(device, &a) else { return false }
        var v = Float32(min(max(value, 0), 1))
        return AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    // MARK: Latency and lookup

    /// What a device adds before sound reaches it, in milliseconds: its own delay, its safety offset and one buffer. Nil if unknown.
    func latencyMilliseconds(of device: AudioDeviceID, input: Bool = false) -> Double? {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        guard let rate = sampleRate(of: device), rate > 0 else { return nil }
        func value(_ selector: AudioObjectPropertySelector) -> UInt32 {
            var a = address(selector, scope: scope)
            var v = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr ? v : 0
        }
        var b = address(kAudioDevicePropertyBufferFrameSize)
        var buffer = UInt32(0)
        var bsize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(device, &b, 0, nil, &bsize, &buffer)
        let frames = value(kAudioDevicePropertyLatency) + value(kAudioDevicePropertySafetyOffset) + buffer
        return frames == 0 ? nil : Double(frames) / rate * 1000
    }

    /// The device with this unique name, if it is connected.
    func device(uid: String) -> AudioDevice? { devices().first { $0.uid == uid } }

    // MARK: Sound effects (alerts)

    /// The device the Mac plays alerts and other sound effects on. It can differ from the main output.
    func defaultSystemOutputDevice() -> AudioDeviceID? {
        var a = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr && id != 0 ? id : nil
    }

    @discardableResult
    func setDefaultSystemOutput(_ device: AudioDevice) -> Bool {
        var a = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var id = device.id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    /// The alert (sound effects) volume, 0 to 1.
    func alertVolume() -> Double? {
        var error: NSDictionary?
        guard let result = NSAppleScript(source: "alert volume of (get volume settings)")?.executeAndReturnError(&error), error == nil else { return nil }
        return Double(result.int32Value) / 100
    }

    @discardableResult
    func setAlertVolume(_ level: Double) -> Bool {
        var error: NSDictionary?
        _ = NSAppleScript(source: "set volume alert volume \(Int((min(max(level, 0), 1) * 100).rounded()))")?.executeAndReturnError(&error)
        return error == nil
    }
}
