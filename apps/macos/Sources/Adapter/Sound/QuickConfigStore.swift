import AppKit
import Combine

/// Names for outputs and inputs, and a picture for each. Shared so every picker shows the same name.
final class DeviceNames: ObservableObject {
    static let shared = DeviceNames()
    private static let key = "soundDeviceNames.v1"

    @Published private(set) var labels: [String: DeviceLabel]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        labels = (defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: DeviceLabel].self, from: $0) }) ?? [:]
    }

    /// The hidden devices, read straight from the saved labels so it can be asked from any thread.
    static func hiddenUIDs(defaults: UserDefaults = .standard) -> Set<String> {
        let labels = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: DeviceLabel].self, from: $0) } ?? [:]
        return DeviceNaming.hiddenUIDs(labels)
    }

    func name(for device: AudioDevice) -> String { DeviceNaming.name(device.name, uid: device.uid, labels: labels) }
    func symbol(for device: AudioDevice, fallback: String) -> String { DeviceNaming.symbol(uid: device.uid, fallback: fallback, labels: labels) }

    /// Puts a whole set of names, icons and hidden devices in place (a Quick Config being applied).
    func replaceAll(_ next: [String: DeviceLabel]) {
        labels = next
        if let data = try? JSONEncoder().encode(labels) { defaults.set(data, forKey: Self.key) }
    }

    func set(_ label: DeviceLabel, for uid: String) {
        labels = DeviceNaming.setting(label, for: uid, in: labels)
        if let data = try? JSONEncoder().encode(labels) { defaults.set(data, forKey: Self.key) }
    }
}

/// Saved whole-sound setups: devices, volumes, every app's settings and favorites, each with a command a shortcut can run.
final class QuickConfigStore: ObservableObject {
    private static let key = "soundQuickConfigs.v1"
    @Published private(set) var configs: [QuickConfig]
    @Published private(set) var message: String?
    private let defaults: UserDefaults
    private let engine: AppAudioEngine
    private let audio: AudioControl

    init(engine: AppAudioEngine, audio: AudioControl = .shared, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.audio = audio
        self.defaults = defaults
        configs = (defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([QuickConfig].self, from: $0) }) ?? []
    }

    static func command(for id: String) -> String { "sound.quickconfig.\(id)" }

    private func save() { if let data = try? JSONEncoder().encode(configs) { defaults.set(data, forKey: Self.key) } }

    /// What this Mac's sound is set to right now.
    func capture(named name: String) -> QuickConfig {
        var config = QuickConfig(name: QuickConfig.uniqueName(name, among: configs.map(\.name)))
        if let out = audio.defaultDevice(input: false) {
            config.outputUID = audio.uid(of: out)
            if let uid = config.outputUID, let v = audio.volume(of: out) { config.deviceVolumes[uid] = v }
        }
        if let input = audio.defaultDevice(input: true) {
            config.inputUID = audio.uid(of: input)
            if let uid = config.inputUID, let v = audio.volume(of: input, input: true) { config.deviceVolumes[uid] = v }
        }
        config.apps = engine.settings
        config.favorites = engine.favorites
        config.menuBarApps = engine.menuBarApps
        config.boostApps = engine.boostApps.sorted()
        config.excludedApps = engine.excluded.sorted()
        config.effectsUID = audio.defaultSystemOutputDevice().flatMap { audio.uid(of: $0) }
        config.outputPriority = DevicePriorityRunner.shared.outputPriority
        config.inputPriority = DevicePriorityRunner.shared.inputPriority
        config.autoEQ = AutoEQRunner.shared.stored
        config.deviceLabels = DeviceNames.shared.labels
        config.mixerDensity = defaults.string(forKey: "soundMixer.density")
        config.mixerAppearance = defaults.string(forKey: "soundMixer.appearance")
        return config
    }

    @discardableResult
    func saveCurrent(named name: String) -> QuickConfig {
        let config = capture(named: name)
        guard configs.count < QuickConfig.maxConfigs else { message = "That is the most Quick Configs Kriya keeps."; return config }
        configs.append(config)
        save()
        message = "Saved “\(config.name)”."
        return config
    }

    /// Restores the devices that are connected and their volumes, every app's settings, favorites, menu-bar icons, boost and left-alone
    /// apps, the sound-effects output, the order of devices, device names and icons, headphone corrections and how the mixer looks.
    /// Sound rules, places, MIDI and modes are kept apart and have their own export. Says what could not be restored.
    func apply(_ id: String) {
        guard let config = configs.first(where: { $0.id == id }) else { return }
        var missing: [String] = []
        if let uid = config.outputUID { if let d = audio.device(uid: uid), d.isOutput { audio.setDefault(d) } else { missing.append("the output") } }
        if let uid = config.inputUID { if let d = audio.device(uid: uid), d.isInput { audio.setDefault(d) } else { missing.append("the input") } }
        for (uid, volume) in config.deviceVolumes {
            guard let d = audio.device(uid: uid) else { continue }
            _ = audio.setVolume(volume, of: d.id, input: d.isInput && !d.isOutput)
        }
        if let uid = config.effectsUID {
            if let d = audio.device(uid: uid), d.isOutput { _ = audio.setDefaultSystemOutput(d) } else { missing.append("the sound-effects output") }
        }
        // The icons, boost and left-alone apps first: taking boost away also brings an app's volume down to 100%.
        engine.restoreSetup(menuBarApps: config.menuBarApps, boost: config.boostApps, excluded: config.excludedApps)
        engine.replaceAll(settings: config.apps, favorites: config.favorites)
        if let order = config.outputPriority { DevicePriorityRunner.shared.outputPriority = order }
        if let order = config.inputPriority { DevicePriorityRunner.shared.inputPriority = order }
        if let labels = config.deviceLabels { DeviceNames.shared.replaceAll(labels) }
        if let density = config.mixerDensity { defaults.set(density, forKey: "soundMixer.density") }
        if let appearance = config.mixerAppearance { defaults.set(appearance, forKey: "soundMixer.appearance") }
        if let corrections = config.autoEQ { AutoEQRunner.shared.replaceAll(corrections) }
        message = missing.isEmpty ? "Applied “\(config.name)”." : "Applied “\(config.name)”, but \(missing.joined(separator: " and ")) is not connected."
    }

    func rename(_ id: String, to name: String) {
        guard let i = configs.firstIndex(where: { $0.id == id }) else { return }
        let others = configs.filter { $0.id != id }.map(\.name)
        configs[i].name = QuickConfig.uniqueName(name, among: others)
        save()
    }

    func duplicate(_ id: String) {
        guard let config = configs.first(where: { $0.id == id }), configs.count < QuickConfig.maxConfigs else { return }
        configs.append(config.duplicated(among: configs.map(\.name)))
        save()
    }

    func delete(_ id: String) { configs.removeAll { $0.id == id }; save() }

    func exportData() -> Data? { QuickConfig.exported(configs) }

    @discardableResult
    func importData(_ data: Data) -> Int? {
        guard let added = QuickConfig.imported(data, existingNames: configs.map(\.name)) else { message = "That file is not a set of Quick Configs."; return nil }
        let room = max(QuickConfig.maxConfigs - configs.count, 0)
        configs += added.prefix(room)
        save()
        message = "Added \(min(added.count, room)) Quick Config\(min(added.count, room) == 1 ? "" : "s")."
        return min(added.count, room)
    }
}
