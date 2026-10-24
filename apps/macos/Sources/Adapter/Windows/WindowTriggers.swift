import AppKit
import Combine

/// The double-taps, per-app layouts and Dock choices, kept in preferences so they survive restarts.
final class WindowTriggerStore: ObservableObject {
    static let shared = WindowTriggerStore()
    private static let tapsKey = "windows.modifierTaps.v1"
    private static let layoutsKey = "windows.appLayoutTriggers.v1"
    private static let dockKey = "windows.dockHideApps.v1"
    static let wrapKey = "pointer.wrapMode"

    @Published private(set) var taps: [ModifierTap]
    @Published private(set) var layoutTriggers: [AppLayoutTrigger]
    @Published private(set) var dockHideApps: [String]
    @Published private(set) var menuFavorites: [AppMenuFavorite]
    private static let menuFavoritesKey = "pointerMenu.favorites.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        taps = (defaults.data(forKey: Self.tapsKey).flatMap { try? JSONDecoder().decode([ModifierTap].self, from: $0) }) ?? []
        layoutTriggers = (defaults.data(forKey: Self.layoutsKey).flatMap { try? JSONDecoder().decode([AppLayoutTrigger].self, from: $0) }) ?? []
        dockHideApps = defaults.stringArray(forKey: Self.dockKey) ?? []
        menuFavorites = (defaults.data(forKey: Self.menuFavoritesKey).flatMap { try? JSONDecoder().decode([AppMenuFavorite].self, from: $0) }) ?? []
    }

    /// Adds or removes a favorite menu item. Returns whether it is a favorite now.
    @discardableResult
    func toggleMenuFavorite(appID: String, path: [String]) -> Bool {
        menuFavorites = AppMenuFavorite.toggled(appID: appID, path: path, in: menuFavorites)
        if let data = try? JSONEncoder().encode(menuFavorites) { defaults.set(data, forKey: Self.menuFavoritesKey) }
        return menuFavorites.contains { $0.appID == appID && $0.path == path }
    }

    func removeMenuFavorite(_ id: String) {
        menuFavorites.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(menuFavorites) { defaults.set(data, forKey: Self.menuFavoritesKey) }
    }

    func addTap(_ tap: ModifierTap) {
        guard taps.count < ModifierTap.maxCount else { return }
        taps.removeAll { $0.modifier == tap.modifier }   // one command per key
        taps.append(tap)
        if let data = try? JSONEncoder().encode(taps) { defaults.set(data, forKey: Self.tapsKey) }
    }

    func removeTap(_ id: String) {
        taps.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(taps) { defaults.set(data, forKey: Self.tapsKey) }
    }

    func addLayoutTrigger(_ trigger: AppLayoutTrigger) {
        guard layoutTriggers.count < AppLayoutTrigger.maxCount else { return }
        layoutTriggers.append(trigger)
        if let data = try? JSONEncoder().encode(layoutTriggers) { defaults.set(data, forKey: Self.layoutsKey) }
    }

    func removeLayoutTrigger(_ id: String) {
        layoutTriggers.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(layoutTriggers) { defaults.set(data, forKey: Self.layoutsKey) }
    }

    func setDockHide(_ appID: String, _ on: Bool) {
        if on, !dockHideApps.contains(appID) { dockHideApps.append(appID) }
        if !on { dockHideApps.removeAll { $0 == appID } }
        defaults.set(dockHideApps, forKey: Self.dockKey)
    }

    var wrapMode: PointerWrapMode {
        get { PointerWrapMode(rawValue: defaults.string(forKey: Self.wrapKey) ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: Self.wrapKey); objectWillChange.send() }
    }
}

/// Watches for the things that start a trigger and runs the command through `run`, the same path a shortcut uses.
final class WindowTriggers {
    private let store: WindowTriggerStore
    private let run: (String) -> Void
    private var monitors: [Any] = []
    private var detector = ModifierTapDetector()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var launchedThisRun = Set<String>()
    private var activatedAfterLaunch = Set<String>()
    private var dockWasAutohide: Bool?
    private var dockChangedByUs = false
    private var cancellables = Set<AnyCancellable>()

    init(store: WindowTriggerStore = .shared, run: @escaping (String) -> Void) {
        self.store = store
        self.run = run
    }

    func start() {
        guard monitors.isEmpty else { return }
        let flags: (NSEvent) -> Void = { [weak self] event in self?.flagsChanged(event) }
        let keys: (NSEvent) -> Void = { [weak self] _ in self?.detector.keyPressed() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel], handler: keys) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in self?.pointerMoved(event) }) { monitors.append(m) }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let id = app.bundleIdentifier else { return }
            self?.launchedThisRun.insert(id)
            self?.activatedAfterLaunch.remove(id)
            self?.appEvent(app, launched: true)
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let id = app.bundleIdentifier, let self else { return }
            let first = !self.activatedAfterLaunch.contains(id)
            self.activatedAfterLaunch.insert(id)
            self.appEvent(app, launched: false, isFirstActivation: first)
            self.syncDock(frontAppID: id)
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier { self?.activatedAfterLaunch.remove(id) }
        })
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        for o in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        workspaceObservers = []
        restoreDock()
    }

    // MARK: Double-tap

    private static func names(_ flags: NSEvent.ModifierFlags) -> Set<String> {
        var out = Set<String>()
        if flags.contains(.shift) { out.insert("shift") }
        if flags.contains(.control) { out.insert("control") }
        if flags.contains(.option) { out.insert("option") }
        if flags.contains(.command) { out.insert("command") }
        if flags.contains(.function) { out.insert("fn") }
        return out
    }

    private func flagsChanged(_ event: NSEvent) {
        guard !store.taps.isEmpty else { return }
        guard let fired = detector.flagsChanged(Self.names(event.modifierFlags), at: event.timestamp),
              let tap = store.taps.first(where: { $0.modifier == fired }) else { return }
        run(tap.command)
    }

    // MARK: Pointer wrap

    private func pointerMoved(_ event: NSEvent) {
        let mode = store.wrapMode
        guard mode != .off, let primary = NSScreen.screens.first else { return }
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        // AppKit's origin is bottom left; the warp call wants top left of the main display.
        let location = NSEvent.mouseLocation
        let point = (x: Double(location.x), y: Double(primary.frame.height - location.y))
        let area = (minX: Double(union.minX), minY: Double(primary.frame.height - union.maxY), maxX: Double(union.maxX), maxY: Double(primary.frame.height - union.minY))
        guard let target = PointerWrapMode.wrapped(point, moving: (Double(event.deltaX), Double(event.deltaY)), area: area, mode: mode) else { return }
        CGWarpMouseCursorPosition(CGPoint(x: target.x, y: target.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    // MARK: Apps opening and coming forward

    private func appEvent(_ app: NSRunningApplication, launched: Bool, isFirstActivation: Bool = false) {
        guard let id = app.bundleIdentifier else { return }
        let fired = AppLayoutTrigger.firing(store.layoutTriggers, appID: id, launched: launched, isFirstActivation: isFirstActivation)
        guard !fired.isEmpty else { return }
        waitForWindow(of: app, attempts: 24) { [weak self] in for trigger in fired { self?.run(trigger.command) } }
    }

    /// A window can take a moment to appear after an app opens; wait for the app's front window to exist and be in front.
    private func waitForWindow(of app: NSRunningApplication, attempts: Int, then body: @escaping () -> Void) {
        guard AXIsProcessTrusted() else { return }
        if attempts <= 0 { return }
        let ready = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
            && AXWindow.focused().map { $0.pid == app.processIdentifier && $0.isStandard } == true
        if ready { body(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.waitForWindow(of: app, attempts: attempts - 1, then: body) }
    }

    // MARK: The Dock

    private func syncDock(frontAppID: String) {
        let wants = store.dockHideApps.contains(frontAppID)
        if wants, !dockChangedByUs {
            readAutohide { [weak self] current in
                guard let self, let current else { return }
                self.dockWasAutohide = current
                if !current { self.setAutohide(true); self.dockChangedByUs = true }
            }
        } else if !wants, dockChangedByUs { restoreDock() }
    }

    private func restoreDock() {
        guard dockChangedByUs else { return }
        dockChangedByUs = false
        if let was = dockWasAutohide { setAutohide(was) }
        dockWasAutohide = nil
    }

    private func readAutohide(_ done: @escaping (Bool?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var error: NSDictionary?
            let result = NSAppleScript(source: "tell application \"System Events\" to get autohide of dock preferences")?.executeAndReturnError(&error)
            DispatchQueue.main.async { done(result?.booleanValue) }
        }
    }

    private func setAutohide(_ on: Bool) {
        DispatchQueue.global(qos: .utility).async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"System Events\" to set autohide of dock preferences to \(on ? "true" : "false")")?.executeAndReturnError(&error)
        }
    }
}
