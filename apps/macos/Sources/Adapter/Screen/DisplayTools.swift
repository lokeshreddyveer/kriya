import AppKit
import CoreGraphics

/// One way a display can be set: a size, a refresh rate and whether it is drawn at HiDPI.
struct DisplayMode: Identifiable, Hashable {
    let width: Int
    let height: Int
    let refresh: Double
    let hidpi: Bool
    let ioID: Int32
    var id: String { "\(width)x\(height)@\(Int(refresh))\(hidpi ? "h" : "")#\(ioID)" }

    var title: String {
        "\(width) × \(height)" + (hidpi ? " HiDPI" : "") + (refresh > 0 ? " · \(Int(refresh.rounded())) Hz" : "")
    }
}

/// A connected display, with what it can do.
struct DisplayEntry: Identifiable {
    let id: CGDirectDisplayID
    let key: String
    let name: String
    let isMain: Bool
    let isBuiltIn: Bool
    let current: DisplayMode?
    let modes: [DisplayMode]
    let frame: CGRect
}

/// Reads the connected displays and changes their mode, position and brightness (in software). Everything goes through
/// the public CoreGraphics display calls, so a bad result is undone by the system when the change is not kept.
final class DisplayTools: ObservableObject {
    private let store: ScreenToolsStore
    private var observer: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var work: DispatchWorkItem?
    private var lastConnected: [String] = []
    /// Called when the list of displays or their settings may have changed.
    var onChange: () -> Void = {}

    init(store: ScreenToolsStore) {
        self.store = store
    }

    func start() {
        lastConnected = Self.displays().map(\.key).sorted()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.changed()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Waking resets the gamma tables, so the dimming is put back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.applyDimming() }
        }
        applyDimming()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        observer = nil
        wakeObserver = nil
        work?.cancel()
        CGDisplayRestoreColorSyncSettings()
    }

    // MARK: Reading

    static func displays() -> [DisplayEntry] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { id in
            let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
            let key: String = {
                if let uuid, let text = CFUUIDCreateString(nil, uuid) { return text as String }
                return "display-\(id)"
            }()
            let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
            let current = CGDisplayCopyDisplayMode(id).map(mode(from:))
            return DisplayEntry(
                id: id, key: key, name: screen?.localizedName ?? "Display \(id)", isMain: CGDisplayIsMain(id) != 0,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0, current: current, modes: modes(of: id), frame: CGDisplayBounds(id)
            )
        }
    }

    private static func mode(from mode: CGDisplayMode) -> DisplayMode {
        DisplayMode(width: mode.width, height: mode.height, refresh: mode.refreshRate, hidpi: mode.pixelWidth > mode.width, ioID: mode.ioDisplayModeID)
    }

    private static func modes(of id: CGDirectDisplayID) -> [DisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        var seen = Set<String>()
        return all.filter { $0.isUsableForDesktopGUI() }.map(mode(from:))
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.width, $0.height, $0.refresh) > ($1.width, $1.height, $1.refresh) }
    }

    // MARK: Changing a display

    /// Sets a display's mode. Returns false when the system refused it.
    @discardableResult
    func set(_ mode: DisplayMode, on id: CGDirectDisplayID) -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let target = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode])?.first(where: { $0.ioDisplayModeID == mode.ioID }) else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, id, target, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        let ok = CGCompleteDisplayConfiguration(config, .forSession) == .success
        if ok { DispatchQueue.main.async { self.onChange() } }
        return ok
    }

    private func move(_ id: CGDirectDisplayID, to origin: CGPoint, in config: CGDisplayConfigRef) {
        CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y))
    }

    // MARK: Profiles

    /// What the displays look like now, for saving.
    func snapshot() -> [DisplayState] {
        Self.displays().map { entry in
            DisplayState(
                key: entry.key, width: UInt32(entry.current?.width ?? Int(entry.frame.width)), height: UInt32(entry.current?.height ?? Int(entry.frame.height)),
                refreshHz: entry.current?.refresh ?? 0, hidpi: entry.current?.hidpi ?? true,
                x: Int32(entry.frame.minX), y: Int32(entry.frame.minY), isMain: entry.isMain
            )
        }
    }

    /// Puts the displays as a saved profile had them: each one's mode and its place in the arrangement.
    func apply(_ profile: DisplayProfile) {
        let connected = Self.displays()
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        for state in profile.displays {
            guard let entry = connected.first(where: { $0.key == state.key }) else { continue }
            if let wanted = entry.modes.first(where: { $0.width == Int(state.width) && $0.height == Int(state.height) && $0.hidpi == state.hidpi && abs($0.refresh - state.refreshHz) < 1 })
                ?? entry.modes.first(where: { $0.width == Int(state.width) && $0.height == Int(state.height) && $0.hidpi == state.hidpi }) {
                let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
                if let target = (CGDisplayCopyAllDisplayModes(entry.id, options) as? [CGDisplayMode])?.first(where: { $0.ioDisplayModeID == wanted.ioID }) {
                    CGConfigureDisplayWithDisplayMode(config, entry.id, target, nil)
                }
            }
            if !state.isMain { move(entry.id, to: CGPoint(x: Int(state.x), y: Int(state.y)), in: config) }
        }
        if CGCompleteDisplayConfiguration(config, .forSession) != .success { CGCancelDisplayConfiguration(config) }
        DispatchQueue.main.async { self.onChange() }
        Log.info("Display", "Applied the display profile “\(profile.name)”")
    }

    func applyNextProfile() {
        let profiles = store.current.displayProfiles
        guard !profiles.isEmpty else { return }
        let connected = Self.displays().map(\.key)
        let matching = profiles.filter { profile in profile.displays.allSatisfy { connected.contains($0.key) } }
        let list = matching.isEmpty ? profiles : matching
        let key = "displayProfileIndex"
        let next = (UserDefaults.standard.integer(forKey: key) + 1) % list.count
        UserDefaults.standard.set(next, forKey: key)
        apply(list[next])
    }

    private func changed() {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let keys = Self.displays().map(\.key).sorted()
            let before = lastConnected
            lastConnected = keys
            applyDimming()
            onChange()
            // A display came or went: the profile saved for exactly this set of displays goes back on.
            if keys != before, store.current.restoreProfileOnChange,
               let id = displayProfileFor(profiles: store.current.displayProfiles, connected: keys),
               let profile = store.current.displayProfiles.first(where: { $0.id == id }) {
                apply(profile)
            }
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    // MARK: Dimming (in software)

    /// Darkens each display by the saved level, by scaling its gamma table. Level 0 leaves it alone.
    func applyDimming() {
        CGDisplayRestoreColorSyncSettings()
        let levels = Dictionary(store.current.dimLevels.map { ($0.key, $0.level) }, uniquingKeysWith: { first, _ in first })
        for entry in Self.displays() {
            guard let level = levels[entry.key], level > 0 else { continue }
            let scale = Float(1 - level)
            CGSetDisplayTransferByFormula(entry.id, 0, scale, 1, 0, scale, 1, 0, scale, 1)
        }
    }

    func setDim(_ level: Double, forKey key: String) {
        store.update { config in
            config.dimLevels.removeAll { $0.key == key }
            if level > 0 { config.dimLevels.append(DimLevel(key: key, level: level)) }
        }
        applyDimming()
    }

    /// The display the pointer is on.
    private func displayUnderPointer() -> DisplayEntry? {
        let point = DisplayManager.mouseLocation()
        return Self.displays().first { $0.frame.contains(point) } ?? Self.displays().first { $0.isMain }
    }

    func dim(by delta: Double) {
        guard let entry = displayUnderPointer() else { return }
        let current = store.current.dimLevels.first { $0.key == entry.key }?.level ?? 0
        setDim(min(0.9, max(0, current + delta)), forKey: entry.key)
    }
}
