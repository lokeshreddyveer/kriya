import Combine
import Foundation

struct ButtonKey: Hashable {
    let button: UInt32
    let modifiers: UInt64
}

/// One preset ready to use on the event tap's thread: the settings with every saved action already looked up, so the
/// handler never touches the interface's data.
struct CompiledMouse {
    var settings: MouseSettings
    var verticalIsNeutral: Bool
    var horizontalIsNeutral: Bool
    var buttonActions: [ButtonKey: Action]
    /// Rules that run when the button is held, not when it is clicked.
    var holdActions: [ButtonKey: Action]
    var holdMs: UInt64
    var gestureActions: [GestureDirection: Action]
    var rockerRightThenLeft: Action?
    var rockerLeftThenRight: Action?
    var gestureConfig: GestureEngineConfig

    init(settings: MouseSettings, actions: [String: Action], neutral: ScrollAxis) {
        self.settings = settings
        verticalIsNeutral = settings.vertical == neutral
        horizontalIsNeutral = settings.horizontal == neutral

        var buttons: [ButtonKey: Action] = [:]
        var holds: [ButtonKey: Action] = [:]
        for rule in settings.buttons {
            guard let action = actions[rule.actionId] else { continue }
            let key = ButtonKey(button: rule.button, modifiers: rule.modifiers)
            if rule.trigger == .hold { holds[key] = action } else { buttons[key] = action }
        }
        buttonActions = buttons
        holdActions = holds
        holdMs = UInt64(settings.holdMs)

        let gestures = settings.gestures
        var byDirection: [GestureDirection: Action] = [:]
        for binding in gestures.bindings {
            if let action = actions[binding.actionId] { byDirection[binding.direction] = action }
        }
        gestureActions = gestures.enabled ? byDirection : [:]
        rockerRightThenLeft = gestures.enabled ? gestures.rockerRightThenLeft.flatMap { actions[$0] } : nil
        rockerLeftThenRight = gestures.enabled ? gestures.rockerLeftThenRight.flatMap { actions[$0] } : nil
        gestureConfig = GestureEngineConfig(
            activationButton: gestures.enabled ? gestures.activationButton : nil,
            threshold: gestures.threshold,
            timeoutMs: gestures.timeoutMs,
            rocker: gestures.enabled && (rockerRightThenLeft != nil || rockerLeftThenRight != nil)
        )
    }
}

/// Mouse presets, the assignments that pick one for a device or an app, and the app exclusions. It also keeps a
/// ready-to-use snapshot for the event tap: for the app in front, the compiled settings of every known device.
final class MouseStore: ObservableObject {
    @Published private(set) var presets: [MousePreset] = []
    @Published private(set) var assignments: [MouseAssignment] = []
    @Published private(set) var config = MouseConfig(excludedAppIds: [], defaultPresetId: "default")
    /// Bumped every time the snapshot is rebuilt, so the feature knows to re-apply pointer settings.
    @Published private(set) var revision = 0
    @Published var lastError: String?

    static let defaultPresetID = "default"

    private struct Snapshot {
        var byDevice: [String: CompiledMouse] = [:]
        var excluded = false
        var revision = 0
    }

    private let core: KriyaCore
    private let library: ActionLibrary
    private let devices: DeviceRegistry
    private let profiles: ProfileStore
    private let lock = NSLock()
    private var snapshot = Snapshot()                    // guarded by lock
    private var pendingSaves: [String: DispatchWorkItem] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(core: KriyaCore, library: ActionLibrary, devices: DeviceRegistry, profiles: ProfileStore) {
        self.core = core
        self.library = library
        self.devices = devices
        self.profiles = profiles
        reload()
    }

    /// Starts keeping the snapshot current as presets, actions, devices and the front app change.
    func start() {
        guard cancellables.isEmpty else { return }
        let changes: [AnyPublisher<Void, Never>] = [
            $presets.map { _ in () }.eraseToAnyPublisher(),
            $assignments.map { _ in () }.eraseToAnyPublisher(),
            $config.map { _ in () }.eraseToAnyPublisher(),
            library.$actions.map { _ in () }.eraseToAnyPublisher(),
            devices.$devices.map { $0.map(\.id) }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            profiles.$frontmostAppID.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(30), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        rebuildSnapshot()
    }

    func reload() {
        do {
            presets = try core.mousePresets()
            assignments = try core.mouseAssignments()
            config = try core.mouseConfig()
        } catch {
            Log.error("Mouse", "Could not load mouse settings: \(error.userMessage)")
        }
    }

    // MARK: Reading

    func preset(_ id: String) -> MousePreset? {
        presets.first { $0.id == id }
    }

    var defaultPreset: MousePreset? { preset(Self.defaultPresetID) }

    var actionIDs: [String] { library.actions.map(\.id) }

    func presetName(_ id: String) -> String {
        preset(id)?.name ?? "Default"
    }

    /// The preset assigned to exactly this device and app (either may be `nil` for "any").
    func assignment(device: String?, app: String?) -> MouseAssignment? {
        assignments.first { $0.deviceId == device && $0.appId == app }
    }

    // MARK: Editing

    /// Changes a preset. The change shows at once and is saved a moment later, so dragging a slider does not write on every step.
    func update(presetID: String, _ change: (inout MouseSettings) -> Void) {
        guard let index = presets.firstIndex(where: { $0.id == presetID }), !presets[index].id.hasPrefix("builtin.") else { return }
        change(&presets[index].settings)
        scheduleSave(presetID)
    }

    func rename(presetID: String, to name: String) {
        guard var preset = preset(presetID), !preset.id.hasPrefix("builtin.") else { return }
        preset.name = name
        save(preset)
    }

    @discardableResult
    func createPreset(named name: String, from settings: MouseSettings? = nil) -> String? {
        let preset = MousePreset(
            id: UUID().uuidString, name: name, isBuiltin: false,
            settings: settings ?? defaultMouseSettings()
        )
        return save(preset) ? preset.id : nil
    }

    @discardableResult
    func duplicate(presetID: String) -> String? {
        guard let source = preset(presetID) else { return nil }
        return createPreset(named: "\(source.name) copy", from: source.settings)
    }

    func deletePreset(_ id: String) {
        flushPendingSave(id)
        do {
            try core.deleteMousePreset(id: id)
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
        reload()
    }

    func setAssignment(device: String?, app: String?, preset presetID: String?) {
        do {
            if let existing = assignment(device: device, app: app) {
                if let presetID {
                    try core.saveMouseAssignment(assignment: MouseAssignment(id: existing.id, deviceId: device, appId: app, presetId: presetID))
                } else {
                    try core.deleteMouseAssignment(id: existing.id)
                }
            } else if let presetID {
                try core.saveMouseAssignment(assignment: MouseAssignment(id: UUID().uuidString, deviceId: device, appId: app, presetId: presetID))
            }
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
        reload()
    }

    func deleteAssignment(_ id: String) {
        try? core.deleteMouseAssignment(id: id)
        reload()
    }

    func setDefaultPreset(_ id: String) {
        var updated = config
        updated.defaultPresetId = id
        saveConfig(updated)
    }

    func setExcludedApps(_ ids: [String]) {
        var updated = config
        updated.excludedAppIds = ids
        saveConfig(updated)
    }

    func restoreDefaults(everything: Bool) {
        pendingSaves.values.forEach { $0.cancel() }
        pendingSaves.removeAll()
        do {
            try core.restoreDefaultMouseSettings(everything: everything)
            lastError = nil
            Log.info("Mouse", everything ? "All mouse settings restored to defaults" : "Default mouse preset restored")
        } catch {
            lastError = error.userMessage
        }
        reload()
    }

    // MARK: Sharing a preset

    func exportPreset(_ id: String, to url: URL) throws {
        flushPendingSave(id)
        let json = try core.exportMousePreset(id: id)
        try json.write(to: url, atomically: true, encoding: .utf8)
        Log.info("Mouse", "Exported a preset to \(url.lastPathComponent)")
    }

    @discardableResult
    func importPreset(from url: URL) throws -> MousePreset {
        let data = try Data(contentsOf: url)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CoreError.Backup(message: "the file is not a Kriya mouse preset")
        }
        let preset = try core.importMousePreset(json: json, newId: UUID().uuidString)
        library.reload()
        reload()
        Log.info("Mouse", "Imported a preset from \(url.lastPathComponent)")
        return preset
    }

    // MARK: Saving

    @discardableResult
    private func save(_ preset: MousePreset) -> Bool {
        do {
            try core.saveMousePreset(preset: preset)
            lastError = nil
            reload()
            return true
        } catch {
            lastError = error.userMessage
            reload()
            return false
        }
    }

    private func saveConfig(_ updated: MouseConfig) {
        do {
            try core.saveMouseConfig(config: updated)
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
        reload()
    }

    private func scheduleSave(_ id: String) {
        pendingSaves[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writePending(id) }
        pendingSaves[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func writePending(_ id: String) {
        pendingSaves[id] = nil
        guard let preset = preset(id) else { return }
        do {
            try core.saveMousePreset(preset: preset)
            lastError = nil
        } catch {
            lastError = error.userMessage
            reload()
        }
    }

    private func flushPendingSave(_ id: String) {
        guard let work = pendingSaves[id] else { return }
        work.cancel()
        writePending(id)
    }

    /// Writes any edit still waiting, for when the app quits.
    func flushPendingSaves() {
        for id in Array(pendingSaves.keys) { flushPendingSave(id) }
    }

    // MARK: The snapshot for the event tap

    private func rebuildSnapshot() {
        let appID = profiles.frontmostAppID
        let actions = Dictionary(library.actions.map { ($0.id, $0.action) }, uniquingKeysWith: { first, _ in first })
        let neutral = defaultMouseSettings().vertical
        let fallback = presets.first { $0.id == Self.defaultPresetID }?.settings ?? defaultMouseSettings()

        var byDevice: [String: CompiledMouse] = [:]
        for key in devices.devices.map(\.id) + [""] {
            let id = resolveMousePreset(
                assignments: assignments, defaultPresetId: config.defaultPresetId,
                deviceId: key.isEmpty ? nil : key, appId: appID
            )
            let settings = presets.first { $0.id == id }?.settings ?? fallback
            byDevice[key] = CompiledMouse(settings: settings, actions: actions, neutral: neutral)
        }
        let excluded = appID.map { config.excludedAppIds.contains($0) } ?? false

        let next = revision + 1
        lock.lock()
        snapshot = Snapshot(byDevice: byDevice, excluded: excluded, revision: next)
        lock.unlock()
        revision = next
    }

    /// Which version of the snapshot is current. Safe to call from the event tap's thread.
    func snapshotRevision() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.revision
    }

    /// The settings to use for a device right now, or `nil` when Kriya should leave the mouse alone (the app in front is
    /// excluded). Safe to call from the event tap's thread.
    func compiled(forDevice id: String?) -> CompiledMouse? {
        lock.lock()
        defer { lock.unlock() }
        if snapshot.excluded { return nil }
        return snapshot.byDevice[id ?? ""] ?? snapshot.byDevice[""]
    }
}
