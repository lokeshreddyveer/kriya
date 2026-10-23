import AppKit
import AudioToolbox
import Combine
import CoreAudio

/// An app that is making sound, or has settings.
struct AudioApp: Identifiable, Equatable {
    let id: String
    let name: String
    let bundleID: String
    var isPlaying: Bool
    var level: Float
}

/// One running change to the sound of one app (or of everything): Kriya taps the app's audio with Core Audio, shapes it, and
/// plays it on the chosen outputs. The app's own sound is muted while the tap runs, and everything is put back when it stops
/// (or if Kriya quits, since the tap belongs to Kriya's process).
@available(macOS 14.2, *)
final class AudioSession {
    let key: String
    let processor = AudioProcessor()
    private(set) var failure: String?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue: DispatchQueue
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: AudioSession.scratchFrames * AudioProcessor.maxChannels)
    static let scratchFrames = 16_384

    init(key: String) {
        self.key = key
        queue = DispatchQueue(label: "app.kriya.audio.\(key)", qos: .userInteractive)
    }

    deinit { scratch.deallocate() }

    var peak: Float { processor.peak }

    /// Starts tapping. `processes` is empty for the whole system. `outputs` are device UIDs; empty means the current output.
    /// Returns a plain-words reason if it could not start.
    @discardableResult
    func start(processes: [AudioObjectID], excluding own: [AudioObjectID], outputs: [String], settings: AppAudioSettings) -> String? {
        stop()
        let description: CATapDescription
        if processes.isEmpty { description = CATapDescription(stereoGlobalTapButExcludeProcesses: own) }
        else { description = CATapDescription(stereoMixdownOfProcesses: processes) }
        description.uuid = UUID()
        description.name = "Kriya \(key)"
        description.isPrivate = true
        description.muteBehavior = .muted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else {
            return fail("macOS did not let Kriya listen to this app (\(status)). Allow Kriya under System Settings › Privacy & Security › Screen & System Audio Recording.")
        }
        tapID = tap

        var uids = outputs
        if uids.isEmpty, let current = AudioControl.shared.defaultOutputUID() { uids = [current] }
        guard let first = uids.first else { stop(); return fail("There is no sound output to play on.") }
        let subDevices: [[String: Any]] = uids.map { [kAudioSubDeviceUIDKey: $0, kAudioSubDeviceDriftCompensationKey: $0 != first] }
        let dictionary: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Kriya \(key)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: first,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: uids.count > 1,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(dictionary as CFDictionary, &aggregate)
        guard status == noErr else { stop(); return fail("The sound could not be redirected (\(status)).") }
        aggregateID = aggregate

        apply(settings)
        let processor = processor
        let scratch = scratch
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { _, inData, _, outData, _ in
            Self.render(processor: processor, scratch: scratch, input: inData, output: outData)
        }
        guard status == noErr, let procID else { stop(); return fail("The sound could not be redirected (\(status)).") }
        status = AudioDeviceStart(aggregate, procID)
        guard status == noErr else { stop(); return fail("The sound could not be started (\(status)).") }
        failure = nil
        return nil
    }

    func apply(_ settings: AppAudioSettings) {
        let s = settings.clamped
        processor.targetGain = Float(s.volume)
        processor.muted = s.muted
        processor.setEQ(gains: s.eq, sampleRate: Float(sampleRate()))
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }

    private func fail(_ message: String) -> String { failure = message; return message }

    private func sampleRate() -> Double {
        guard aggregateID != kAudioObjectUnknown else { return 48_000 }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &rate) == noErr && rate > 0 ? rate : 48_000
    }

    /// The audio thread: copies what the tap heard to the output, changed by the processor.
    private static func render(processor: AudioProcessor, scratch: UnsafeMutablePointer<Float>, input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for (index, out) in outputs.enumerated() {
            guard let outData = out.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let outChannels = max(Int(out.mNumberChannels), 1)
            let outFrames = Int(out.mDataByteSize) / (MemoryLayout<Float>.size * outChannels)
            guard inputs.count > 0 else { memset(out.mData, 0, Int(out.mDataByteSize)); continue }
            let inBuffer = inputs[min(index, inputs.count - 1)]
            guard let inData = inBuffer.mData?.assumingMemoryBound(to: Float.self) else { memset(out.mData, 0, Int(out.mDataByteSize)); continue }
            let inChannels = max(Int(inBuffer.mNumberChannels), 1)
            let inFrames = Int(inBuffer.mDataByteSize) / (MemoryLayout<Float>.size * inChannels)
            let frames = min(outFrames, inFrames, scratchFrames)
            if inChannels == outChannels {
                processor.process(input: inData, output: outData, frames: frames, channels: outChannels, firstChannel: index == 0 ? 0 : 0)
            } else {
                // Different channel counts: shape it as it came, then spread or fold it onto the output's channels.
                processor.process(input: inData, output: scratch, frames: frames, channels: min(inChannels, AudioProcessor.maxChannels))
                for f in 0..<frames {
                    for c in 0..<outChannels { outData[f * outChannels + c] = scratch[f * min(inChannels, AudioProcessor.maxChannels) + (c % inChannels)] }
                }
            }
            if frames < outFrames { memset(outData + frames * outChannels, 0, (outFrames - frames) * outChannels * MemoryLayout<Float>.size) }
        }
    }
}

/// The per-app sound mixer: which apps are making sound, what each is set to, and the sessions that make it so.
final class AppAudioEngine: ObservableObject {
    static let systemKey = "system"
    private static let storeKey = "appAudio.settings.v1"
    private static let profilesKey = "appAudio.profiles.v1"

    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var settings: [String: AppAudioSettings]
    @Published var profiles: [AppAudioProfile] { didSet { saveProfiles() } }
    @Published private(set) var problems: [String: String] = [:]

    private let defaults: UserDefaults
    /// Sessions need macOS 14.2; they are held as plain objects so the rest of the app can build for older systems.
    private var sessions: [String: AnyObject] = [:]

    static var isSupported: Bool { if #available(macOS 14.2, *) { return true } else { return false } }

    @available(macOS 14.2, *)
    private func session(_ key: String) -> AudioSession? { sessions[key] as? AudioSession }

    private func stopSession(_ key: String) {
        if #available(macOS 14.2, *) { session(key)?.stop() }
        sessions[key] = nil
    }

    private func peak(of key: String) -> Float {
        if #available(macOS 14.2, *) { return session(key)?.peak ?? 0 }
        return 0
    }
    private var timer: Timer?
    private var viewers = 0
    private let ownProcess: () -> [AudioObjectID] = { [AudioProcessList.object(forPID: getpid())].compactMap { $0 } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = (defaults.data(forKey: Self.storeKey).flatMap { try? JSONDecoder().decode([String: AppAudioSettings].self, from: $0) }) ?? [:]
        profiles = (defaults.data(forKey: Self.profilesKey).flatMap { try? JSONDecoder().decode([AppAudioProfile].self, from: $0) }) ?? []
    }

    deinit { stopAll() }

    // MARK: Starting and stopping

    /// Brings back what was set before, and keeps new processes of those apps covered.
    func start() { refresh(); scheduleTimer() }

    func stopAll() {
        timer?.invalidate(); timer = nil
        for key in Array(sessions.keys) { stopSession(key) }
    }

    func viewerAppeared() { viewers += 1; refresh(); scheduleTimer() }
    func viewerGone() { viewers = max(viewers - 1, 0); scheduleTimer() }

    private func scheduleTimer() {
        timer?.invalidate(); timer = nil
        let busy = settings.values.contains { !$0.isDefault }
        guard viewers > 0 || busy else { return }
        let t = Timer(timeInterval: viewers > 0 ? 1.5 : 5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Settings

    func current(_ key: String) -> AppAudioSettings { settings[key] ?? AppAudioSettings() }

    func update(_ key: String, _ change: (inout AppAudioSettings) -> Void) {
        var next = current(key)
        change(&next)
        next = next.clamped
        if next.isDefault { settings[key] = nil } else { settings[key] = next }
        save()
        applySession(for: key)
        scheduleTimer()
    }

    func reset(_ key: String) { update(key) { $0 = AppAudioSettings() } }

    func apply(profile: AppAudioProfile, to key: String) { update(key) { $0 = profile.settings } }

    func saveProfile(named name: String, from key: String) {
        profiles.append(AppAudioProfile(name: name, settings: current(key)))
    }

    private func save() { if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.storeKey) } }
    private func saveProfiles() { if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Self.profilesKey) } }

    // MARK: Sessions

    private func processes(for key: String) -> [AudioObjectID] {
        AudioProcessList.read().filter { AudioProcessList.groupKey(for: $0) == key }.map(\.object)
    }

    private func applySession(for key: String) {
        let s = current(key)
        if s.isDefault {
            stopSession(key); problems[key] = nil
            return
        }
        guard #available(macOS 14.2, *) else { problems[key] = "Changing one app's sound needs macOS 14.2 or later."; return }
        let targets = key == Self.systemKey ? [] : processes(for: key)
        if key != Self.systemKey, targets.isEmpty { return }   // not running yet; refresh will start it
        let session = self.session(key) ?? AudioSession(key: key)
        sessions[key] = session
        if let error = session.start(processes: targets, excluding: ownProcess(), outputs: s.outputs, settings: s) {
            problems[key] = error
            stopSession(key)
        } else {
            problems[key] = nil
        }
    }

    /// Looks at who is making sound, starts sessions for apps that have settings and have just appeared, and ends the ones whose
    /// app has gone.
    func refresh() {
        let all = AudioProcessList.read()
        var groups: [String: [AudioProcessList.Entry]] = [:]
        for entry in all { groups[AudioProcessList.groupKey(for: entry), default: []].append(entry) }

        var list: [AudioApp] = groups.compactMap { key, entries in
            guard !key.isEmpty, key != "\(Bundle.main.bundleIdentifier ?? "")" else { return nil }
            let playing = entries.contains { $0.isOutputRunning }
            guard playing || settings[key] != nil else { return nil }
            return AudioApp(id: key, name: AudioProcessList.name(for: key), bundleID: key, isPlaying: playing, level: peak(of: key))
        }
        // Apps that have settings but are not running still show, so they can be changed or reset.
        for key in settings.keys where key != Self.systemKey && !list.contains(where: { $0.id == key }) {
            list.append(AudioApp(id: key, name: AudioProcessList.name(for: key), bundleID: key, isPlaying: false, level: 0))
        }
        list.sort { ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased()) }
        if list != apps { apps = list }

        for (key, s) in settings where !s.isDefault && key != Self.systemKey {
            let present = Set((groups[key] ?? []).map(\.object))
            if sessions[key] == nil, !present.isEmpty { applySession(for: key) }
            else if sessions[key] != nil {
                if present.isEmpty { stopSession(key) }
                else if lastProcessSet[key] != present { lastProcessSet[key] = present; applySession(for: key) }
            }
        }
        for (key, set) in groups.mapValues({ Set($0.map(\.object)) }) { if lastProcessSet[key] == nil { lastProcessSet[key] = set } }
        if settings[Self.systemKey] != nil, sessions[Self.systemKey] == nil, problems[Self.systemKey] == nil { applySession(for: Self.systemKey) }
    }

    private var lastProcessSet: [String: Set<AudioObjectID>] = [:]

    /// Loudness of the app's sound for the activity meter, 0...1.
    func level(of key: String) -> Float { min(peak(of: key), 1) }
}

/// The apps that Core Audio knows are using sound.
enum AudioProcessList {
    struct Entry {
        let object: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isOutputRunning: Bool
    }

    static func read() -> [Entry] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var pid = pid_t(0)
            var psize = UInt32(MemoryLayout<pid_t>.size)
            var paddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &paddr, 0, nil, &psize, &pid) == noErr else { return nil }
            var bundle: CFString = "" as CFString
            var bsize = UInt32(MemoryLayout<CFString>.size)
            var baddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectGetPropertyData(id, &baddr, 0, nil, &bsize, &bundle)
            var running = UInt32(0)
            var rsize = UInt32(MemoryLayout<UInt32>.size)
            var raddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectGetPropertyData(id, &raddr, 0, nil, &rsize, &running)
            return Entry(object: id, pid: pid, bundleID: bundle as String, isOutputRunning: running != 0)
        }
    }

    static func object(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// The app a process belongs to: browsers and others make sound from helper processes named "com.x.app.helper.Renderer".
    static func groupKey(for entry: Entry) -> String { groupKey(forBundleID: entry.bundleID) }

    static func groupKey(forBundleID id: String) -> String {
        if let r = id.range(of: ".helper", options: .caseInsensitive) { return String(id[..<r.lowerBound]) }
        return id
    }

    static func name(for bundleID: String) -> String {
        bundleID == AppAudioEngine.systemKey ? "All sound" : AppChoice.name(for: bundleID)
    }
}
