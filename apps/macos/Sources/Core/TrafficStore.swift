import Combine
import Foundation

extension TrafficProfile: Identifiable {}
extension TrafficButton: Identifiable {
    public var id: String { title }

    static var all: [TrafficButton] { [.close, .minimize, .zoom] }

    var title: String {
        switch self {
        case .close: return "Close"
        case .minimize: return "Minimize"
        case .zoom: return "Zoom"
        }
    }

    var colorName: String {
        switch self {
        case .close: return "Red"
        case .minimize: return "Yellow"
        case .zoom: return "Green"
        }
    }

    /// What a new rule for this button starts as.
    var suggestedAction: TrafficAction {
        switch self {
        case .close: return .quitApp
        case .minimize: return .minimizeAllWindows
        case .zoom: return .maximize
        }
    }
}

/// What the window buttons have done, for the Diagnostics and Window Buttons panes.
struct TrafficStats: Equatable {
    var handled = 0
    var replayedAsNormal = 0
    var duplicatesSuppressed = 0
    var leftNative = 0
}

/// Window-button settings: what each button does, per-app profiles, hover menus and exclusions. `resolve` can be called
/// from the event tap's thread; everything else is for the interface.
final class TrafficStore: ObservableObject {
    @Published private(set) var config = defaultTrafficConfig()
    @Published private(set) var profiles: [TrafficProfile] = []
    @Published var lastError: String?
    /// Set when macOS would not give Kriya a way to watch clicks. The buttons then simply keep their normal behavior.
    @Published var interceptionIssue: String?

    private struct Snapshot {
        var config = defaultTrafficConfig()
        var profiles: [TrafficProfile] = []
        var idle = true
    }

    private let core: KriyaCore
    private let lock = NSLock()
    private var snapshot = Snapshot()          // guarded by lock
    private var stats = TrafficStats()         // guarded by lock
    private var pendingSave: DispatchWorkItem?

    init(core: KriyaCore) {
        self.core = core
        reload()
    }

    func reload() {
        do {
            config = try core.trafficConfig()
            profiles = try core.trafficProfiles()
        } catch {
            Log.error("Buttons", "Could not load window-button settings: \(error.userMessage)")
        }
        publishSnapshot()
    }

    private func publishSnapshot() {
        let idle = trafficIsIdle(config: config, profiles: profiles)
        lock.lock()
        snapshot = Snapshot(config: config, profiles: profiles, idle: idle)
        lock.unlock()
    }

    // MARK: For the event tap (any thread)

    var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.idle
    }

    var currentConfig: TrafficConfig {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.config
    }

    func resolve(appID: String?, button: TrafficButton, modifiers: UInt64) -> TrafficAction {
        lock.lock()
        let current = snapshot
        lock.unlock()
        return trafficResolve(config: current.config, profiles: current.profiles, appId: appID, button: button, modifiers: modifiers)
    }

    func isExcluded(appID: String?) -> Bool {
        lock.lock()
        let current = snapshot.config
        lock.unlock()
        return trafficIsExcluded(config: current, appId: appID)
    }

    func count(_ change: (inout TrafficStats) -> Void) {
        lock.lock()
        change(&stats)
        lock.unlock()
    }

    func currentStats() -> TrafficStats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    func resetStats() {
        lock.lock()
        stats = TrafficStats()
        lock.unlock()
    }

    // MARK: Editing

    /// Changes show at once and are saved a moment later.
    func update(_ change: (inout TrafficConfig) -> Void) {
        change(&config)
        publishSnapshot()
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func write() {
        pendingSave = nil
        do {
            try core.saveTrafficConfig(config: config)
            lastError = nil
        } catch {
            lastError = error.userMessage
            reload()
        }
    }

    func flushPendingSaves() {
        guard let work = pendingSave else { return }
        work.cancel()
        write()
    }

    func saveProfile(_ profile: TrafficProfile) {
        perform { try core.saveTrafficProfile(profile: profile) }
    }

    func deleteProfile(_ id: String) {
        perform { try core.deleteTrafficProfile(id: id) }
    }

    func addProfile(appID: String) {
        saveProfile(TrafficProfile(id: UUID().uuidString, appId: appID, enabled: true, bindings: []))
    }

    /// Puts every button back to normal. With `everything`, also removes app profiles, hover menus and exclusions.
    func restoreNative(everything: Bool) {
        pendingSave?.cancel()
        pendingSave = nil
        perform { try core.restoreDefaultTrafficSettings(everything: everything) }
    }

    private func perform(_ work: () throws -> Void) {
        // A change still waiting to be saved is written first, so reloading afterwards cannot lose it.
        flushPendingSaves()
        do {
            try work()
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
        reload()
    }
}

extension TrafficAction {
    var title: String { trafficActionTitle(action: self) }

    var symbol: String {
        switch self {
        case .native: return "arrow.uturn.backward"
        case .doNothing: return "nosign"
        case .closeWindow: return "xmark.circle"
        case .quitApp: return "power"
        case .hideApp, .hideOtherApps: return "eye.slash"
        case .minimizeWindow, .minimizeAllWindows: return "minus.circle"
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        case .toggleFullScreen: return "arrow.up.left.and.down.right.magnifyingglass"
        case .center: return "scope"
        case .snap: return "rectangle.split.2x1"
        case .run: return "bolt"
        case .closeOrQuit: return "xmark.circle.fill"
        case .restoreMinimized: return "arrow.up.right.square"
        case .restoreSize: return "arrow.counterclockwise"
        case .layoutPalette: return "circle.grid.cross"
        }
    }
}
