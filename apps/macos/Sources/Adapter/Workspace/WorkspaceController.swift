import AppKit
import Combine

/// App switching and workspace control: the previous app, hiding and quitting apps, relaunching one, focus mode, favourite
/// windows, workspaces that open a set of apps together, cycling windows that overlap, and reaching another display. Each
/// one is a command, so a shortcut, a mouse button, a gesture or a hot corner can run it.
final class WorkspaceController {
    static let commands: [(command: String, title: String)] = {
        func entry(_ command: String, _ title: String) -> (command: String, title: String) { (command: command, title: title) }
        var list = [
            entry("app.previous", "Switch to the previous app"),
            entry("app.hide_all", "Hide all apps"),
            entry("app.hide_others", "Hide other apps"),
            entry("app.quit_all", "Quit all apps (asks first)"),
            entry("app.relaunch", "Relaunch the front app"),
            entry("focus.toggle", "Turn focus mode on or off"),
            entry("window.cycle_here", "Cycle the windows under the pointer"),
            entry("window.focus_other_display", "Focus a window on the next display"),
            entry("window.restore_minimized", "Bring back a minimized window"),
            entry("workspace.undo_last", "Undo the last workspace: quit what it opened, show what it hid"),
        ]
        for slot in 1...5 {
            list.append(entry("window.favorite.\(slot)", "Go to favorite window \(slot)"))
            list.append(entry("window.set_favorite.\(slot)", "Make this window favorite \(slot)"))
        }
        return list
    }()

    private let store: WorkspaceStore
    private let windowController: WindowController
    private let windows: WindowStore
    private let executor: ActionExecutor
    private let isEnabled: () -> Bool
    private let toast = Toast()
    /// Turns on a Sound mode by id and says whether it existed; set by the app. `putSoundBack` undoes it.
    var applySoundMode: (String) -> Bool = { _ in false }
    var putSoundBack: () -> Void = {}

    private var recentApps: [pid_t] = []                 // most recent first, never Kriya
    private var activationObserver: NSObjectProtocol?
    private var focusObserver: NSObjectProtocol?
    private var favoriteKeys: [Int: String] = [:]        // window keys, for this run only
    private var registered = Set<String>()
    private var cancellables = Set<AnyCancellable>()
    private(set) var focusActive = false

    init(store: WorkspaceStore, windowController: WindowController, windows: WindowStore, executor: ActionExecutor, isEnabled: @escaping () -> Bool) {
        self.store = store
        self.windowController = windowController
        self.windows = windows
        self.executor = executor
        self.isEnabled = isEnabled
    }

    func start() {
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            recentApps = [front.processIdentifier]
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.noteActivated(app.processIdentifier)
        }
        for (command, _) in Self.commands { register(command) { [weak self] in self?.run(command) } }
        store.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in self?.registerWorkspaces(config) }
            .store(in: &cancellables)
    }

    func stop() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        setFocus(false, quiet: true)
        for command in registered { executor.unregisterCommand(command) }
        registered.removeAll()
        cancellables.removeAll()
    }

    // MARK: Commands

    private func register(_ command: String, _ work: @escaping () -> Void) {
        registered.insert(command)
        executor.registerCommand(command) { [isEnabled] in
            guard isEnabled() else { return }
            DispatchQueue.main.async { work() }
        }
    }

    private func registerWorkspaces(_ config: WorkspaceConfig) {
        for command in registered where command.hasPrefix("workspace.") {
            executor.unregisterCommand(command)
            registered.remove(command)
        }
        for workspace in config.workspaces {
            let id = workspace.id
            register(workspaceCommand(id: id)) { [weak self] in self?.launch(id) }
        }
    }

    private func run(_ command: String) {
        switch command {
        case "app.previous": previousApp()
        case "app.hide_all": hideApps(keeping: [])
        case "app.hide_others": hideApps(keeping: [NSWorkspace.shared.frontmostApplication?.bundleIdentifier].compactMap { $0 })
        case "app.quit_all": quitAll()
        case "app.relaunch": relaunchFront()
        case "focus.toggle": setFocus(!focusActive)
        case "window.cycle_here": cycleOverlapping()
        case "window.focus_other_display": focusOtherDisplay()
        case "window.restore_minimized": restoreMinimized()
        case "workspace.undo_last": undoLastLaunch()
        default:
            if command.hasPrefix("window.favorite."), let slot = Int(command.dropFirst("window.favorite.".count)) {
                goToFavorite(slot)
            } else if command.hasPrefix("window.set_favorite."), let slot = Int(command.dropFirst("window.set_favorite.".count)) {
                setFavorite(slot)
            }
        }
    }

    // MARK: Apps

    private func noteActivated(_ pid: pid_t) {
        recentApps.removeAll { $0 == pid }
        recentApps.insert(pid, at: 0)
        if recentApps.count > 20 { recentApps.removeLast(recentApps.count - 20) }
    }

    private func previousApp() {
        recentApps.removeAll { NSRunningApplication(processIdentifier: $0) == nil }
        guard recentApps.count > 1, let app = NSRunningApplication(processIdentifier: recentApps[1]) else {
            toast.show("No other app to go back to")
            return
        }
        app.activate()
    }

    private var runningRegular: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
    }

    /// Hides every app except the given ones, Kriya and the Finder.
    @discardableResult
    private func hideApps(keeping keep: [String]) -> [String] {
        let running = runningRegular.compactMap(\.bundleIdentifier)
        let hide = Set(workspaceAppsToHide(running: running, keep: keep, selfId: Bundle.main.bundleIdentifier ?? ""))
        var hidden: [String] = []
        for app in runningRegular where hide.contains(app.bundleIdentifier ?? "") { if !app.isHidden, app.hide() { hidden.append(app.bundleIdentifier ?? "") } }
        return hidden
    }

    private func quitAll() {
        let config = store.current
        let running = runningRegular
        let candidates = Set(workspaceQuitCandidates(running: running.compactMap(\.bundleIdentifier), keep: config.quitKeepAppIds, selfId: Bundle.main.bundleIdentifier ?? ""))
        let apps = running.filter { candidates.contains($0.bundleIdentifier ?? "") }
        guard !apps.isEmpty else {
            toast.show("No apps to quit")
            return
        }
        if config.confirmQuitAll {
            let alert = NSAlert()
            alert.messageText = "Quit \(apps.count) app\(apps.count == 1 ? "" : "s")?"
            alert.informativeText = apps.compactMap(\.localizedName).sorted().joined(separator: ", ") + "\n\nAnything you have not saved may be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit All")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for app in apps { app.terminate() }
    }

    private func relaunchFront() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let url = app.bundleURL else { return }
        let name = app.localizedName ?? "the app"
        app.terminate()
        Task { @MainActor [weak self] in
            for _ in 0..<60 {
                if app.isTerminated { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard app.isTerminated else {
                self?.toast.show("\(name) did not quit, so it was not relaunched.", isError: true)
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { self?.toast.show("Could not reopen \(name): \(error.localizedDescription)", isError: true) }
            }
        }
    }

    // MARK: Focus mode

    /// Hides everything except the focus apps, and keeps it that way: an app that is not a focus app is hidden again as
    /// soon as it comes to the front.
    private func setFocus(_ on: Bool, quiet: Bool = false) {
        if on == focusActive { return }
        if on {
            let keep = store.current.focusAppIds
            guard !keep.isEmpty else {
                toast.show("Choose the apps for focus mode in Settings first.", isError: true)
                return
            }
            hideApps(keeping: keep)
            if let first = runningRegular.first(where: { keep.contains($0.bundleIdentifier ?? "") }) { first.activate() }
            focusObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
                let keep = self.store.current.focusAppIds
                guard !keep.contains(id), !workspaceAppsToHide(running: [id], keep: [], selfId: "").isEmpty else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    app.hide()
                    self.runningRegular.first { keep.contains($0.bundleIdentifier ?? "") }?.activate()
                }
            }
            focusActive = true
            if !quiet { toast.show("Focus mode on") }
        } else {
            if let focusObserver { NSWorkspace.shared.notificationCenter.removeObserver(focusObserver) }
            focusObserver = nil
            focusActive = false
            if !quiet { toast.show("Focus mode off") }
        }
    }

    // MARK: Workspaces

    /// Opens the workspace's apps and addresses, then hides the rest and arranges the windows if it says so.
    private func launch(_ id: String) {
        guard let workspace = store.current.workspaces.first(where: { $0.id == id }) else { return }
        let running = Set(runningRegular.compactMap(\.bundleIdentifier))
        let plan = WorkspaceLaunchPlan.make(appIDs: workspace.appIds, running: running, installed: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
        var opened: [String] = []
        for appID in plan.toOpen {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) else { continue }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
            opened.append(appID)
        }
        var urlsOpened = 0
        for address in workspace.urls { if let url = URL(string: address) { NSWorkspace.shared.open(url); urlsOpened += 1 } }
        toast.show("Opening \(workspace.name)")
        // Apps that were just started need a moment before their windows exist.
        let wait: Double = opened.isEmpty ? 0.3 : 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            let hidden = workspace.hideOthers ? self.hideApps(keeping: workspace.appIds) : []
            if let layoutID = workspace.layoutId, let layout = self.windows.layouts.first(where: { $0.id == layoutID }) {
                self.windowController.restore(layout)
            }
            if let first = workspace.appIds.compactMap({ appID in self.runningRegular.first { $0.bundleIdentifier == appID } }).first { first.activate() }
            let soundApplied = workspace.soundModeId.map { self.applySoundMode($0) } ?? false
            var entry = WorkspaceLaunchLog.Entry(
                at: Date(), workspaceID: workspace.id, workspaceName: workspace.name, opened: opened, alreadyRunning: plan.alreadyRunning,
                notInstalled: plan.notInstalled, hidden: hidden, urlsOpened: urlsOpened
            )
            entry.soundModeApplied = soundApplied
            WorkspaceLaunchLogStore.shared.add(entry)
        }
    }

    /// Puts things back the way they were before the last workspace: quits only what it opened and shows what it hid.
    private func undoLastLaunch() {
        guard let entry = WorkspaceLaunchLogStore.shared.log.lastUndoable else { toast.show("Nothing to undo"); return }
        let running = Set(runningRegular.compactMap(\.bundleIdentifier))
        let plan = WorkspaceRollback.plan(for: entry, running: running)
        for app in runningRegular {
            guard let id = app.bundleIdentifier else { continue }
            if plan.quit.contains(id) { app.terminate() } else if plan.unhide.contains(id) { app.unhide() }
        }
        if entry.soundModeApplied == true { putSoundBack() }
        WorkspaceLaunchLogStore.shared.markUndone(entry.id)
        toast.show("Undid “\(entry.workspaceName)”")
    }

    // MARK: Favourite windows

    private func setFavorite(_ slot: Int) {
        guard AXIsProcessTrusted(), let window = AXWindow.focused(), let appID = window.appID else { return }
        favoriteKeys[slot] = window.key
        store.update { config in
            config.favorites.removeAll { $0.slot == UInt32(slot) }
            config.favorites.append(FavoriteWindow(slot: UInt32(slot), appId: appID, title: window.title))
        }
        toast.show("This window is favorite \(slot)")
    }

    private func goToFavorite(_ slot: Int) {
        guard AXIsProcessTrusted(), let favorite = store.current.favorites.first(where: { $0.slot == UInt32(slot) }) else {
            toast.show("No favorite window \(slot) yet")
            return
        }
        let all = WindowController.openWindows(excluding: windows.currentConfig)
        if let key = favoriteKeys[slot], let exact = all.first(where: { $0.window.key == key }) {
            exact.window.raise()
        } else if let match = all.first(where: { $0.appID == favorite.appId && $0.title == favorite.title }) ?? all.first(where: { $0.appID == favorite.appId }) {
            match.window.raise()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: favorite.appId) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    // MARK: Windows

    /// Windows on screen from front to back: the owner, and the frame, in the top-left coordinates of the accessibility API.
    private func stackedWindows() -> [(pid: pid_t, frame: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let mine = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0, let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != mine,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 40, rect.height > 40 else { return nil }
            return (pid, rect)
        }
    }

    private func axWindow(pid: pid_t, frame: CGRect) -> AXWindow? {
        AXWindow.windows(ofApp: pid).first { candidate in
            guard let f = candidate.frame else { return false }
            return abs(f.x - frame.minX) < 6 && abs(f.y - frame.minY) < 6 && abs(f.width - frame.width) < 6
        }
    }

    /// Raises the window at the bottom of the stack under the pointer, so pressing it again works down through the pile.
    private func cycleOverlapping() {
        guard AXIsProcessTrusted() else { return }
        let pointer = DisplayManager.mouseLocation()
        let stack = stackedWindows().filter { $0.frame.contains(pointer) }
        guard stack.count > 1, let bottom = stack.last, let window = axWindow(pid: bottom.pid, frame: bottom.frame) else { return }
        window.raise()
    }

    /// Brings the front-most window on the next display to the front.
    private func focusOtherDisplay() {
        guard AXIsProcessTrusted() else { return }
        let displays = windowController.displays
        displays.refresh()
        let list = displays.ordered
        guard list.count > 1 else {
            toast.show("There is only one display")
            return
        }
        let pointer = DisplayManager.mouseLocation()
        let currentIndex = list.firstIndex { $0.full.cg.contains(pointer) } ?? 0
        let next = list[(currentIndex + 1) % list.count]
        guard let top = stackedWindows().first(where: { next.full.cg.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }),
              let window = axWindow(pid: top.pid, frame: top.frame) else {
            toast.show("No window on the next display")
            return
        }
        window.raise()
    }

    /// Brings back a minimized window: one of the front app's if it has any, otherwise the first one found.
    private func restoreMinimized() {
        guard AXIsProcessTrusted() else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ordered = runningRegular.sorted { ($0.processIdentifier == front ? 0 : 1) < ($1.processIdentifier == front ? 0 : 1) }
        for app in ordered {
            if let minimized = AXWindow.windows(ofApp: app.processIdentifier).first(where: { $0.isMinimized }) {
                minimized.raise()
                return
            }
        }
        toast.show("No minimized windows")
    }
}


/// The launch log, kept in preferences.
final class WorkspaceLaunchLogStore: ObservableObject {
    static let shared = WorkspaceLaunchLogStore()
    private let key = "workspaceLaunchLog.v1"
    @Published private(set) var log: WorkspaceLaunchLog

    private init() {
        log = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(WorkspaceLaunchLog.self, from: $0) } ?? WorkspaceLaunchLog()
    }

    func add(_ entry: WorkspaceLaunchLog.Entry) { change { $0.add(entry) } }
    func markUndone(_ id: String) { change { $0.markUndone(id) } }
    func clear() { change { $0 = WorkspaceLaunchLog() } }

    private func change(_ edit: (inout WorkspaceLaunchLog) -> Void) {
        var next = log
        edit(&next)
        log = next
        if let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: key) }
    }
}
