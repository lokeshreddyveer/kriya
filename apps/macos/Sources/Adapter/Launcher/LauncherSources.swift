import AppKit
import ApplicationServices

/// Timers started from the launcher ("timer 5m"). They live while Kriya runs, and tell you when they are done.
final class LauncherTimers: ObservableObject {
    struct Running: Identifiable {
        let id = UUID()
        let label: String
        let end: Date
    }

    @Published private(set) var running: [Running] = []
    private var timers: [UUID: Timer] = [:]
    private let toast = Toast()

    func start(seconds: TimeInterval) {
        let item = Running(label: LauncherTimerParser.describe(seconds), end: Date().addingTimeInterval(seconds))
        running.append(item)
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            NSSound(named: NSSound.Name("Glass"))?.play()
            self?.toast.show("Timer finished: \(item.label)")
            self?.remove(item.id)
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[item.id] = timer
        toast.show("Timer started: \(item.label)")
    }

    func cancel(_ id: UUID) {
        timers[id]?.invalidate()
        remove(id)
    }

    private func remove(_ id: UUID) {
        timers[id] = nil
        running.removeAll { $0.id == id }
    }

    static func remaining(_ item: Running, now: Date = Date()) -> String {
        let left = max(0, Int(item.end.timeIntervalSince(now).rounded()))
        return String(format: "%d:%02d", left / 60, left % 60)
    }
}

/// Finding files by name with Spotlight, only for what the person typed, only in their home folder. The words go to the
/// Mac's own search and nowhere else.
final class LauncherFileSearch {
    static let maxResults = 6
    static let minimumLength = 3

    /// Called on the main thread when a search finishes.
    var onResults: () -> Void = {}

    private let queue = DispatchQueue(label: "app.kriya.launcher.files", qos: .userInitiated)
    private var results: [String: [URL]] = [:]
    private var requested = ""
    private var pending: DispatchWorkItem?
    private var generation = 0

    /// What the search found for exactly this text so far.
    func results(for query: String) -> [URL] { results[query] ?? [] }

    func search(_ query: String) {
        guard Self.isSearchable(query), results[query] == nil, requested != query else { return }
        requested = query
        pending?.cancel()
        generation += 1
        let mine = generation
        let work = DispatchWorkItem { [weak self] in
            let found = Self.find(query)
            DispatchQueue.main.async {
                guard let self, self.generation == mine else { return }
                if self.results.count > 40 { self.results.removeAll() }
                self.results[query] = found
                self.onResults()
            }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func cancel() {
        pending?.cancel()
        generation += 1
        requested = ""
    }

    /// Text that is safe and worth handing to the search: not an option, not tiny, not huge.
    static func isSearchable(_ query: String) -> Bool {
        query.count >= minimumLength && query.count <= 60 && !query.hasPrefix("-") && !query.contains("\0")
    }

    /// Whether a path is something to offer: not hidden, not in a library or a build folder.
    static func isWorthShowing(_ path: String, home: String) -> Bool {
        let relative = path.hasPrefix(home) ? String(path.dropFirst(home.count)) : path
        let parts = relative.split(separator: "/").map(String.init)
        if parts.contains(where: { $0.hasPrefix(".") }) { return false }
        let skipped: Set<String> = ["Library", "node_modules", "DerivedData", "build", "Pods", "venv", ".build", "target"]
        if parts.contains(where: { skipped.contains($0) }) { return false }
        return !path.hasSuffix(".app")
    }

    private static func find(_ query: String) -> [URL] {
        let home = NSHomeDirectory()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", home, "-name", query]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        // Spotlight has a second and a half to answer, and is cut off if it is flooding us.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5, execute: watchdog)
        var buffer = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if buffer.count > 400_000 { process.terminate(); break }
        }
        process.waitUntilExit()
        watchdog.cancel()
        let paths = String(decoding: buffer, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { isWorthShowing($0, home: home) }
            .prefix(300)
        let ranked = paths.compactMap { path -> (String, Int)? in
            let name = (path as NSString).lastPathComponent
            guard let score = FuzzyMatcher.score(query, in: name) else { return nil }
            return (path, score)
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.count < $1.0.count }
        return ranked.prefix(maxResults).map { URL(fileURLWithPath: $0.0) }
    }
}

/// Where the launcher gets what it lists: apps, windows, settings, clipboard, files, a calculator, timers and emoji.
final class LauncherSources {
    private struct OpenWindow {
        let key: String
        let appName: String
        let title: String
        let appPath: String?
        let minimized: Bool
        let window: AXWindow
    }

    let timers = LauncherTimers()
    /// Apple Intelligence, when set up: a typed question, and actions on the clipboard.
    var intelligence: IntelligenceCoordinator?
    /// Quicklinks, scripts, converters and meetings.
    var tools: LauncherToolSources?
    /// Where file actions are recorded for Undo, and what Move To and Copy To run on.
    var finder: FinderService?
    var audio: AudioControl?
    var notes: NotesController?
    var focus: FocusSessionController?
    var sharedClipboard: SharedClipboardService?
    let bookmarks = BookmarkIndex()
    let menuBarItems = MenuBarItemIndex()
    /// Files gathered from several places, to act on together.
    let fileBuffer = FileBuffer()
    /// Runs a workflow with some text, and says what a workflow is called. Set by the app.
    var runWorkflow: (String, String) -> Void = { _, _ in }
    var workflowTitle: (String) -> String? = { _ in nil }
    /// Opens a settings pane. Set by the app.
    var openSettings: (SettingsPane) -> Void = { _ in }
    private var recentFiles: [URL] = []
    private let frontMenu = FrontAppMenu()
    let contacts = ContactsSource()
    private let files = LauncherFileSearch()
    private weak var inventory: AppInventory?
    private let clipboard: ClipboardService
    let prefs: LauncherPrefs
    private let queue = DispatchQueue(label: "app.kriya.launcher.windows", qos: .userInitiated)
    private let lock = NSLock()
    private var windows: [OpenWindow] = []
    private var systemApps: (list: [(name: String, id: String, url: URL)], at: Date)?
    weak var palette: CommandPalette?

    init(inventory: AppInventory, clipboard: ClipboardService, prefs: LauncherPrefs) {
        self.inventory = inventory
        self.clipboard = clipboard
        self.prefs = prefs
    }

    func register(in palette: CommandPalette) {
        self.palette = palette
        tools?.selectionProvider = { [weak palette] in palette?.model.selectionText ?? "" }
        palette.addProvider { [weak self] in self?.appEntries() ?? [] }
        palette.addProvider { [weak self] in self?.windowEntries() ?? [] }
        palette.addProvider { [weak self] in self?.systemEntries() ?? [] }
        palette.addProvider { [weak self] in self?.runningTimerEntries() ?? [] }
        palette.addProvider { [weak self] in self?.intelligenceEntries() ?? [] }
        palette.addProvider { [weak self] in self?.musicEntries() ?? [] }
        palette.addProvider { [weak self] in self?.finderWindowEntries() ?? [] }
        palette.addProvider { [weak self] in self?.monitorPresetEntries() ?? [] }
        FinderWindowTracker.shared.start()
        RecentAppsTracker.shared.start()
        palette.addProvider { [weak self] in (self?.tools?.staticEntries() ?? []) + (self?.tools?.meetingEntries() ?? []) }
        palette.addQueryProvider { [weak self] text in self?.queryEntries(text) ?? [] }
        palette.addQueryProvider { [weak self] text in self?.navigationEntries(text) ?? [] }
        palette.addQueryProvider { [weak self] text in self?.argumentEntries(text) ?? [] }
        palette.addQueryProvider { [weak self] text in (self?.soundEntries(text) ?? []) + (self?.addressEntries(text) ?? []) + (self?.noteEntries(text) ?? []) + (self?.jobEntries(text) ?? []) + (self?.focusEntries(text) ?? []) + (self?.sharedClipboardEntries(text) ?? []) + (self?.bookmarkEntries(text) ?? []) + (self?.menuBarItemEntries(text) ?? []) + (self?.passwordEntries(text) ?? []) + (self?.terminalEntries(text) ?? []) + (self?.colorPickerEntries(text) ?? []) }
        palette.addQueryProvider { [weak self] text in (self?.quitEntries(text) ?? []) + (self?.menuEntries(text) ?? []) + (self?.contactEntries(text) ?? []) }
        palette.model.tokenProvider = { [weak self] word in self?.token(for: word) }
        palette.model.startProvider = { [weak self] in self?.startEntries() ?? [] }
        palette.model.selectionProvider = { [weak self] text in self?.selectionEntries(text) ?? [] }
        palette.extraActions = { [weak self] entry in self?.extraActions(for: entry) ?? [] }
        palette.willShow = { [weak self] in self?.prepare() }
        files.onResults = { [weak palette] in palette?.model.refresh() }
        tools?.onChange = { [weak palette] in palette?.model.refresh() }
    }

    /// Gathers what takes a moment (the open windows) as the launcher opens.
    private func prepare() {
        frontMenu.refresh(app: NSWorkspace.shared.frontmostApplication)
        files.cancel()
        fileBuffer.prune()
        refreshRecentFiles()
        guard prefs.data.isEnabled(.window), AXIsProcessTrusted() else {
            setWindows([])
            return
        }
        queue.async { [weak self] in
            var found: [OpenWindow] = []
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.bundleIdentifier != Bundle.main.bundleIdentifier {
                for window in AXWindow.windows(ofApp: app.processIdentifier) where window.isStandard {
                    found.append(OpenWindow(
                        key: window.key, appName: app.localizedName ?? "App", title: window.title, appPath: app.bundleURL?.path,
                        minimized: window.isMinimized, window: window
                    ))
                }
            }
            self?.setWindows(found)
            DispatchQueue.main.async { self?.palette?.entriesChanged() }
        }
    }

    private func setWindows(_ list: [OpenWindow]) {
        lock.lock()
        windows = list
        lock.unlock()
    }

    // MARK: Apps

    private func appEntries() -> [PaletteEntry] {
        guard prefs.data.isEnabled(.app) else { return [] }
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        var byID: [String: PaletteEntry] = [:]
        for app in inventory?.apps ?? [] {
            byID[app.bundleID] = appEntry(name: app.name, id: app.bundleID, url: app.url, running: runningIDs.contains(app.bundleID))
        }
        for app in systemApplications() where byID[app.id] == nil {
            byID[app.id] = appEntry(name: app.name, id: app.id, url: app.url, running: runningIDs.contains(app.id))
        }
        for app in running {
            guard let id = app.bundleIdentifier, byID[id] == nil, let url = app.bundleURL else { continue }
            byID[id] = appEntry(name: app.localizedName ?? url.deletingPathExtension().lastPathComponent, id: id, url: url, running: true)
        }
        return Array(byID.values)
    }

    func appEntry(name: String, id: String, url: URL, running: Bool) -> PaletteEntry {
        var actions = [
            PaletteAction(title: "Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) },
            PaletteAction(title: "Copy Path", symbol: "doc.on.doc") { Self.copy(url.path) },
        ]
        if running {
            actions.append(PaletteAction(title: "Hide \(name)", symbol: "eye.slash") { NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.hide() })
            actions.append(PaletteAction(title: "Quit \(name)", symbol: "xmark.circle") { NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.terminate() })
        }
        return PaletteEntry(id: "app:\(id)", title: name, subtitle: running ? "Running" : "Application", symbol: "app", category: .app, iconPath: url.path, actions: actions, fileURL: url, appBundleID: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// The apps macOS keeps in its own folders, which the Apps list does not cover. Read at most every few minutes.
    private func systemApplications() -> [(name: String, id: String, url: URL)] {
        if let systemApps, Date().timeIntervalSince(systemApps.at) < 300 { return systemApps.list }
        var list: [(name: String, id: String, url: URL)] = []
        for folder in ["/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities"] {
            let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == "app" {
                guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
                list.append((url.deletingPathExtension().lastPathComponent, id, url))
            }
        }
        systemApps = (list, Date())
        return list
    }

    // MARK: Windows

    private func windowEntries() -> [PaletteEntry] {
        guard prefs.data.isEnabled(.window) else { return [] }
        lock.lock()
        let list = windows
        lock.unlock()
        return list.map { item in
            PaletteEntry(
                id: "window:\(item.key)", title: item.title.isEmpty ? item.appName : item.title,
                subtitle: item.minimized ? "\(item.appName) · minimized" : item.appName, symbol: "macwindow", category: .window,
                iconPath: item.appPath, rememberable: false
            ) { item.window.raise() }
        }
    }

    // MARK: System

    private struct SystemPane { let title: String; let anchor: String; let symbol: String }

    private static let systemPanes: [SystemPane] = [
        SystemPane(title: "Wi-Fi", anchor: "com.apple.wifi-settings-extension", symbol: "wifi"),
        SystemPane(title: "Bluetooth", anchor: "com.apple.BluetoothSettings", symbol: "wave.3.right"),
        SystemPane(title: "Network", anchor: "com.apple.Network-Settings.extension", symbol: "network"),
        SystemPane(title: "Notifications", anchor: "com.apple.Notifications-Settings.extension", symbol: "bell.badge"),
        SystemPane(title: "Sound", anchor: "com.apple.Sound-Settings.extension", symbol: "speaker.wave.2"),
        SystemPane(title: "Focus", anchor: "com.apple.Focus-Settings.extension", symbol: "moon"),
        SystemPane(title: "General", anchor: "com.apple.systempreferences.GeneralSettings", symbol: "gearshape"),
        SystemPane(title: "Appearance", anchor: "com.apple.Appearance-Settings.extension", symbol: "circle.lefthalf.filled"),
        SystemPane(title: "Accessibility", anchor: "com.apple.Accessibility-Settings.extension", symbol: "accessibility"),
        SystemPane(title: "Control Center", anchor: "com.apple.ControlCenter-Settings.extension", symbol: "switch.2"),
        SystemPane(title: "Desktop & Dock", anchor: "com.apple.Desktop-Settings.extension", symbol: "dock.rectangle"),
        SystemPane(title: "Displays", anchor: "com.apple.Displays-Settings.extension", symbol: "display"),
        SystemPane(title: "Wallpaper", anchor: "com.apple.Wallpaper-Settings.extension", symbol: "photo"),
        SystemPane(title: "Battery", anchor: "com.apple.Battery-Settings.extension", symbol: "battery.100"),
        SystemPane(title: "Lock Screen", anchor: "com.apple.Lock-Screen-Settings.extension", symbol: "lock.display"),
        SystemPane(title: "Privacy & Security", anchor: "com.apple.settings.PrivacySecurity.extension", symbol: "hand.raised"),
        SystemPane(title: "Touch ID & Password", anchor: "com.apple.Touch-ID-Settings.extension", symbol: "touchid"),
        SystemPane(title: "Users & Groups", anchor: "com.apple.Users-Groups-Settings.extension", symbol: "person.2"),
        SystemPane(title: "Passwords", anchor: "com.apple.Passwords-Settings.extension", symbol: "key"),
        SystemPane(title: "Keyboard", anchor: "com.apple.Keyboard-Settings.extension", symbol: "keyboard"),
        SystemPane(title: "Mouse", anchor: "com.apple.Mouse-Settings.extension", symbol: "computermouse"),
        SystemPane(title: "Trackpad", anchor: "com.apple.Trackpad-Settings.extension", symbol: "rectangle.and.hand.point.up.left"),
        SystemPane(title: "Printers & Scanners", anchor: "com.apple.Print-Scan-Settings.extension", symbol: "printer"),
        SystemPane(title: "Login Items & Extensions", anchor: "com.apple.LoginItems-Settings.extension", symbol: "person.badge.key"),
        SystemPane(title: "Software Update", anchor: "com.apple.Software-Update-Settings.extension", symbol: "arrow.triangle.2.circlepath"),
        SystemPane(title: "Storage", anchor: "com.apple.settings.Storage", symbol: "internaldrive"),
        SystemPane(title: "Date & Time", anchor: "com.apple.Date-Time-Settings.extension", symbol: "clock"),
        SystemPane(title: "Language & Region", anchor: "com.apple.Localization-Settings.extension", symbol: "globe"),
    ]

    private func systemEntries() -> [PaletteEntry] {
        guard prefs.data.isEnabled(.system) else { return [] }
        var list = Self.systemPanes.map { pane in
            PaletteEntry(id: "system:\(pane.anchor)", title: "System Settings: \(pane.title)", subtitle: "macOS", symbol: pane.symbol, category: .system) {
                if let url = URL(string: "x-apple.systempreferences:\(pane.anchor)") { NSWorkspace.shared.open(url) }
            }
        }
        list.append(PaletteEntry(id: "system:displaysleep", title: "Turn the display off", subtitle: "macOS", symbol: "moon.zzz", category: .system) { Self.run("/usr/bin/pmset", ["displaysleepnow"]) })
        list.append(PaletteEntry(id: "system:sleep", title: "Put the Mac to sleep", subtitle: "macOS", symbol: "powersleep", category: .system) { Self.run("/usr/bin/pmset", ["sleepnow"]) })
        list.append(PaletteEntry(id: "system:lock", title: "Lock the screen", subtitle: "macOS", symbol: "lock", category: .system, keywords: ["lock"]) {
            // ⌃⌘Q, which macOS reserves for locking.
            Self.pressKeys(12, [.maskControl, .maskCommand])
        })
        list.append(PaletteEntry(id: "system:darkmode", title: "Switch between light and dark mode", subtitle: "macOS", symbol: "circle.lefthalf.filled", category: .system, keywords: ["appearance", "theme"]) {
            LauncherSystemCommands.appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        })
        list.append(PaletteEntry(id: "system:emptytrash", title: "Empty the Trash", subtitle: "macOS · asks first", symbol: "trash", category: .system, keywords: ["bin"]) {
            if LauncherSystemCommands.confirm("Empty the Trash?", detail: "Everything in the Trash is deleted for good.", button: "Empty Trash") {
                LauncherSystemCommands.appleScript("tell application \"Finder\" to empty trash")
            }
        })
        list.append(PaletteEntry(id: "system:desktopicons", title: "Show or hide the desktop icons", subtitle: "macOS · restarts Finder", symbol: "menubar.dock.rectangle", category: .system) {
            let current = (try? ToolRunner.run("/usr/bin/defaults", ["read", "com.apple.finder", "CreateDesktop"])) ?? "1"
            let next = current.trimmingCharacters(in: .whitespacesAndNewlines) == "0" ? "true" : "false"
            _ = try? ToolRunner.run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", next])
            _ = try? ToolRunner.run("/usr/bin/killall", ["Finder"])
        })
        for (id, title, symbol, verb, question) in [
            ("restart", "Restart the Mac", "arrow.clockwise.circle", "restart", "Restart the Mac?"),
            ("shutdown", "Shut down the Mac", "power", "shut down", "Shut down the Mac?"),
            ("logout", "Log out", "rectangle.portrait.and.arrow.right", "log out", "Log out?"),
        ] {
            list.append(PaletteEntry(id: "system:\(id)", title: title, subtitle: "macOS · asks first", symbol: symbol, category: .system) {
                if LauncherSystemCommands.confirm(question, detail: "Apps with unsaved work will ask to save first.", button: title) {
                    LauncherSystemCommands.appleScript("tell application \"System Events\" to \(verb)")
                }
            })
        }
        return list
    }

    /// Presses one key with modifiers, marked as Kriya's own so no other feature reacts to it.
    private static func pressKeys(_ code: CGKeyCode, _ flags: CGEventFlags) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try? process.run()
    }

    // MARK: Timers

    private func runningTimerEntries() -> [PaletteEntry] {
        guard prefs.data.isEnabled(.utility) else { return [] }
        return timers.running.map { item in
            PaletteEntry(id: "timer-cancel:\(item.id)", title: "Cancel the \(item.label) timer", subtitle: "\(LauncherTimers.remaining(item)) left", symbol: "timer", category: .utility, rememberable: false) { [weak timers] in
                timers?.cancel(item.id)
            }
        }
    }

    // MARK: What depends on what was typed

    private func queryEntries(_ text: String) -> [PaletteEntry] {
        var found: [PaletteEntry] = []
        let data = prefs.data

        if data.isEnabled(.calculator), let answer = LauncherCalculator.evaluate(text) {
            found.append(PaletteEntry(
                id: "calc:\(text)", title: answer, subtitle: "\(text) =", symbol: "equal.square", category: .calculator, rememberable: false,
                queryScore: 1000, actions: [PaletteAction(title: "Copy the Answer", symbol: "doc.on.doc") { Self.copy(answer) }]
            ) { Self.copy(answer) })
        }
        if data.isEnabled(.utility), let seconds = LauncherTimerParser.seconds(from: text) {
            found.append(PaletteEntry(
                id: "timer:\(Int(seconds))", title: "Start a \(LauncherTimerParser.describe(seconds)) timer", subtitle: "You will hear a sound and see a message", symbol: "timer",
                category: .utility, rememberable: false, queryScore: 950
            ) { [weak timers] in timers?.start(seconds: seconds) })
        }
        if data.isEnabled(.emoji) {
            for entry in LauncherEmoji.search(text) {
                found.append(PaletteEntry(
                    id: "emoji:\(entry.emoji)", title: "\(entry.emoji)  \(entry.words.split(separator: " ").prefix(2).joined(separator: " "))", subtitle: "Copy this emoji",
                    symbol: "face.smiling", category: .emoji, rememberable: false, queryScore: 250
                ) { Self.copy(entry.emoji) })
            }
        }
        if data.isEnabled(.intelligence), let question = Self.question(in: text), let intelligence, intelligence.service.isAvailable, intelligence.service.settings.inLauncher {
            found.append(PaletteEntry(
                id: "ai:ask:\(question)", title: "Ask Apple Intelligence: \(Self.oneLine(question))", subtitle: "On this Mac, offline: it cannot look things up", symbol: "sparkles",
                category: .intelligence, rememberable: false, queryScore: 900
            ) { [weak intelligence] in intelligence?.ask(question) })
        }
        if data.isEnabled(.intelligence), let question = Self.researchQuestion(in: text), let intelligence, intelligence.service.isAvailable, intelligence.service.settings.webResearchOn == true, !LocalOnly.isOn {
            found.append(PaletteEntry(
                id: "ai:research:\(question)", title: "Research on the web: \(Self.oneLine(question))", subtitle: "Looks it up on Wikipedia; answers from the sources, which it lists", symbol: "globe",
                category: .intelligence, rememberable: false, queryScore: 905
            ) { [weak intelligence] in intelligence?.research(question) })
        }
        if data.isEnabled(.clipboard) { found.append(contentsOf: clipboardEntries(text)) }
        if data.isEnabled(.file) { found.append(contentsOf: fileEntries(text)) }
        if let tools { found.append(contentsOf: tools.queryEntries(text)) }
        if data.isEnabled(.web) { found.append(contentsOf: webEntries(text, engineID: data.webEngine)) }
        return found
    }

    // MARK: The web

    /// An address typed as one word opens; "yt cats" searches YouTube; anything else can be searched on the default site.
    /// Only the words typed are sent anywhere, and only when the result is chosen.
    func webEntries(_ text: String, engineID: String?) -> [PaletteEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var found: [PaletteEntry] = []

        if let address = WebSearch.address(in: trimmed) {
            found.append(PaletteEntry(
                id: "web:open:\(trimmed)", title: "Open \(trimmed)", subtitle: address.host ?? "Web address", symbol: "safari",
                category: .web, rememberable: false, queryScore: 900,
                actions: [PaletteAction(title: "Copy the Address", symbol: "doc.on.doc") { Self.copy(address.absoluteString) }]
            ) { NSWorkspace.shared.open(address) })
        }
        if let (engine, rest) = WebSearch.trigger(in: trimmed), let url = WebSearch.url(for: engine, query: rest) {
            found.append(PaletteEntry(
                id: "web:\(engine.id):\(rest)", title: "Search \(engine.name) for “\(Self.oneLine(rest))”", subtitle: "Opens in your browser", symbol: engine.symbol,
                category: .web, rememberable: false, queryScore: 980
            ) { NSWorkspace.shared.open(url) })
        }
        found += fallbackEntries(trimmed, defaultEngine: engineID)
        return found
    }

    /// What text that matched nothing is offered to, in the order the person chose (Settings › Launcher › Fallbacks).
    private func fallbackEntries(_ text: String, defaultEngine: String?) -> [PaletteEntry] {
        var found: [PaletteEntry] = []
        let short = Self.oneLine(text)
        for (index, id) in prefs.data.activeFallbacks.enumerated() {
            let score = 20 - index
            func web(_ engine: SearchEngine) {
                guard let url = WebSearch.url(for: engine, query: text) else { return }
                let others = WebSearch.engines.filter { $0.id != engine.id }.compactMap { other -> PaletteAction? in
                    guard let target = WebSearch.url(for: other, query: text) else { return nil }
                    return PaletteAction(title: "Search \(other.name)", symbol: other.symbol) { NSWorkspace.shared.open(target) }
                }
                var entry = PaletteEntry(
                    id: "web:\(engine.id):all:\(text)", title: "Search \(engine.name) for “\(short)”", subtitle: "Opens in your browser", symbol: engine.symbol,
                    category: .web, rememberable: false, queryScore: score, actions: others
                ) { NSWorkspace.shared.open(url) }
                entry.isFallback = true
                found.append(entry)
            }
            if id == "web" {
                web(WebSearch.engine(id: defaultEngine))
            } else if id.hasPrefix("engine:") {
                web(WebSearch.engine(id: String(id.dropFirst("engine:".count))))
            } else if id == "ai", let intelligence, intelligence.service.isAvailable, intelligence.service.settings.inLauncher {
                var entry = PaletteEntry(
                    id: "fallback:ai:\(text)", title: "Ask Apple Intelligence: \(short)", subtitle: "On this Mac, offline: it cannot look things up", symbol: "sparkles",
                    category: .intelligence, rememberable: false, queryScore: score
                ) { [weak intelligence] in intelligence?.ask(text) }
                entry.isFallback = true
                found.append(entry)
            } else if id.hasPrefix("quicklink:"), let link = tools?.extras.quicklinks.first(where: { $0.id == String(id.dropFirst("quicklink:".count)) }), link.takesQuery, let url = link.url(for: text) {
                var entry = PaletteEntry(
                    id: "fallback:link:\(link.id):\(text)", title: "\(link.name): \(short)", subtitle: "Opens in your browser", symbol: "link", category: .web, rememberable: false, queryScore: score
                ) { NSWorkspace.shared.open(url) }
                entry.isFallback = true
                found.append(entry)
            } else if id.hasPrefix("script:"), let tools, let script = tools.extras.scripts.first(where: { $0.id == String(id.dropFirst("script:".count)) }) {
                var entry = PaletteEntry(
                    id: "fallback:script:\(script.id):\(text)", title: "Run “\(script.name)” with “\(short)”", subtitle: "Script", symbol: "terminal", category: .command, rememberable: false, queryScore: score
                ) { [weak tools] in tools?.runScript(script, argument: text) }
                entry.isFallback = true
                found.append(entry)
            }
        }
        return found
    }

    private func clipboardEntries(_ text: String) -> [PaletteEntry] {
        guard text.count >= 2, clipboard.isRunning else { return [] }
        let lock = ClipboardLock.shared
        if lock.needsUnlock {
            return [PaletteEntry(
                id: "clip:locked", title: "Clipboard history is locked", subtitle: "Press Return to unlock it with Touch ID or your password", symbol: "lock",
                category: .clipboard, rememberable: false, queryScore: 150
            ) { [weak self] in
                lock.ensureUnlocked(reason: "Search your clipboard history") { _ in self?.palette?.show() }
            }]
        }
        return clipboard.store.search(text, limit: 4).map { item in
            let title = item.sensitive ? "•••••••• Sensitive" : Self.oneLine(item.title ?? item.preview)
            var detail = ["Clipboard"]
            if let app = item.sourceApp { detail.append(AppChoice.name(for: app)) }
            var actions = [
                PaletteAction(title: "Paste as Plain Text", symbol: "textformat") { [clipboard] in clipboard.paster.choose(item, plain: true) },
                PaletteAction(title: "Delete from History", symbol: "trash") { [clipboard] in clipboard.store.delete(item.id) },
            ]
            actions.append(contentsOf: intelligenceActions(for: item))
            return PaletteEntry(
                id: "clip:\(item.id)", title: title, subtitle: detail.joined(separator: " · "), symbol: item.kind.symbol, category: .clipboard, rememberable: false, queryScore: 200,
                actions: actions
            ) { [clipboard] in clipboard.paster.choose(item, plain: false) }
        }
    }

    private func fileEntries(_ text: String) -> [PaletteEntry] {
        files.search(text)
        let excluded = prefs.data.fileSearchExcluded ?? []
        return files.results(for: text).filter { !FileSearchFilter.isExcluded($0.path, folders: excluded) }.map { url in
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let score = 150 + min(100, (FuzzyMatcher.score(text, in: url.lastPathComponent) ?? 0) / 10)
            return fileEntry(url, isFolder: isFolder, score: score, prefix: "file")
        }
    }

    private func fileEntry(_ url: URL, isFolder: Bool, score: Int?, prefix: String, rememberable: Bool = true) -> PaletteEntry {
        let place = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        return PaletteEntry(
            id: "\(prefix):\(url.path)", title: url.lastPathComponent, subtitle: place, symbol: isFolder ? "folder" : "doc", category: .file, iconPath: url.path,
            rememberable: rememberable, queryScore: score, fileURL: url, isDirectory: isFolder
        ) { NSWorkspace.shared.open(url) }
    }

    // MARK: Browsing folders and the file buffer

    /// A path typed with / or ~ lists that folder; Tab goes in, Shift-Tab goes up. The buffer, if it holds files, stays on top.
    private func navigationEntries(_ text: String) -> [PaletteEntry] {
        guard prefs.data.isEnabled(.file), let (folder, prefix) = FileNavigation.split(text) else { return [] }
        let items = FileNavigation.list(folder: folder, prefix: prefix)
        var list = items.enumerated().map { index, item in fileEntry(item.url, isFolder: item.isDirectory, score: 900 - index, prefix: "nav", rememberable: false) }
        if let buffer = bufferEntry() { list.insert(buffer, at: 0) }
        return list
    }

    /// The files in the buffer as one result, with things to do with all of them.
    func bufferEntry() -> PaletteEntry? {
        guard !fileBuffer.isEmpty else { return nil }
        let urls = fileBuffer.urls
        let names = urls.prefix(3).map(\.lastPathComponent).joined(separator: ", ") + (urls.count > 3 ? ", …" : "")
        func run(_ kind: FinderActionKind, title: String) {
            guard let finder else { return }
            let item = FinderItem(id: "launcher-buffer", title: title, kind: kind, enabled: true, applies: .anything, extensions: [], appIds: [], confirm: false)
            finder.runner.run(item, paths: urls.map(\.path), target: nil, child: nil)
        }
        let actions = [
            PaletteAction(title: "Move to…", symbol: "folder") { run(.moveTo(folder: nil), title: "Move") },
            PaletteAction(title: "Copy to…", symbol: "folder.badge.plus") { run(.copyTo(folder: nil), title: "Copy") },
            PaletteAction(title: "Compress", symbol: "doc.zipper") { run(.compress, title: "Compress") },
            PaletteAction(title: "Copy the Paths", symbol: "doc.on.doc") { Self.copy(urls.map(\.path).joined(separator: "\n")) },
            PaletteAction(title: "Remove the Last One", symbol: "minus.circle", keepsOpen: true) { [weak self] in if let last = urls.last { self?.fileBuffer.remove(last) } },
            PaletteAction(title: "Empty the Buffer", symbol: "xmark.circle", destructive: true, keepsOpen: true) { [weak self] in self?.fileBuffer.clear() },
        ]
        return PaletteEntry(
            id: "buffer:files", title: "File buffer: \(urls.count) file\(urls.count == 1 ? "" : "s")", subtitle: names, symbol: "tray.full", category: .file,
            rememberable: false, queryScore: 999, actions: actions
        ) { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /// What can be done with a file, a folder or an app that a result stands for.
    private func extraActions(for entry: PaletteEntry) -> [PaletteAction] {
        var list: [PaletteAction] = []
        if let url = entry.fileURL {
            if entry.appBundleID == nil {
                list.append(PaletteAction(title: "Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            }
            list.append(PaletteAction(title: "Copy Path", symbol: "doc.on.doc") { Self.copy(url.path) })
            if entry.appBundleID == nil {
                list.append(PaletteAction(title: "Open With…", symbol: "arrow.up.forward.app") { Self.openWith(url) })
                if !entry.isDirectory { list.append(PaletteAction(title: "Quick Look", symbol: "eye") { Self.quickLook(url) }) }
                list.append(PaletteAction(title: "Get Info", symbol: "info.circle") { ScriptOutputWindow.show(title: url.lastPathComponent, text: FileMetadata.describe(url)) })
                list.append(PaletteAction(title: "Share…", symbol: "square.and.arrow.up") { FinderMetadata.share([url]) })
                list.append(PaletteAction(title: "Add to the File Buffer", symbol: "tray.and.arrow.down", keepsOpen: true) { [weak self] in self?.fileBuffer.add(url) })
                list.append(PaletteAction(title: "Move to the Trash", symbol: "trash", destructive: true) { [weak self] in self?.trash(url) })
            } else if let id = entry.appBundleID {
                list.append(PaletteAction(title: "Uninstall…", symbol: "trash", destructive: true) { [weak self] in
                    self?.openSettings(.apps)
                    Log.info("Launcher", "Opened Apps to uninstall \(id.prefix(60))")
                })
            }
        }
        return list
    }

    private static func openWith(_ url: URL) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        panel.message = "Choose the app to open “\(url.lastPathComponent)” with."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func quickLook(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Moves a file to the Trash, and writes it into the file history so Undo can bring it back.
    private func trash(_ url: URL) {
        var result: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            if let trashed = (result as URL?)?.path {
                finder?.runner.history.record(title: "Moved “\(url.lastPathComponent)” to the Trash", steps: [.moved(from: url.path, to: trashed)], failures: [])
            }
            Toast().show("Moved “\(url.lastPathComponent)” to the Trash")
        } catch {
            Toast().show("“\(url.lastPathComponent)” could not be moved to the Trash.", isError: true)
        }
    }

    // MARK: The opening list: recent files and today's events

    /// Files used in the last week, found with Spotlight when the launcher opens.
    private func refreshRecentFiles() {
        guard prefs.data.showRecentFiles != false, prefs.data.isEnabled(.file) else { return }
        queue.async { [weak self] in
            let output = (try? ToolRunner.run("/usr/bin/mdfind", ["-attr", "kMDItemLastUsedDate", "-onlyin", NSHomeDirectory(), "kMDItemLastUsedDate >= $time.now(-604800)"], timeout: 3)) ?? ""
            let found = RecentFiles.parse(output, home: NSHomeDirectory(), limit: 6)
            DispatchQueue.main.async {
                self?.recentFiles = found
                self?.palette?.entriesChanged()
            }
        }
    }

    private func startEntries() -> [(entry: PaletteEntry, section: String)] {
        var list: [(entry: PaletteEntry, section: String)] = []
        if let buffer = bufferEntry() { list.append((buffer, "File buffer")) }
        if prefs.data.showTodayEvents != false, let tools { list += tools.todayEntries().map { ($0, "Today") } }
        list += recentAppEntries()
        if prefs.data.showRecentFiles != false, prefs.data.isEnabled(.file) {
            for url in recentFiles {
                // Files only: the folders in the home folder are always "recent" and would crowd the list.
                let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isFolder { continue }
                list.append((fileEntry(url, isFolder: false, score: nil, prefix: "recent", rememberable: false), "Recent files"))
            }
        }
        // What was searched for before, when the person keeps a history: choosing one puts it back in the box.
        let history = SearchHistoryStore.shared
        if history.isEnabled {
            for item in history.history.recent(6) {
                list.append((PaletteEntry(id: "history:\(item.id)", title: item.text, subtitle: "Search again", symbol: "clock.arrow.circlepath", rememberable: false, run: {}), "Recent searches"))
            }
        }
        return list
    }

    // MARK: Commands that take an argument

    /// What a word followed by a space turns into: a search site, a quicklink, a script, a workflow or "ask".
    func token(for word: String) -> ArgumentToken? {
        if let found = tools?.token(for: word) { return found }
        if let engine = WebSearch.engines.first(where: { $0.keyword == word }) {
            return ArgumentToken(keyword: word, title: engine.name, symbol: engine.symbol, placeholder: "Search \(engine.name) for…")
        }
        if ["ask", "ai"].contains(word), let intelligence, intelligence.service.isAvailable, prefs.data.isEnabled(.intelligence) {
            return ArgumentToken(keyword: word, title: "Apple Intelligence", symbol: "sparkles", placeholder: "Ask a question…")
        }
        if ["research", "lookup"].contains(word), let intelligence, intelligence.service.isAvailable, intelligence.service.settings.webResearchOn == true, !LocalOnly.isOn, prefs.data.isEnabled(.intelligence) {
            return ArgumentToken(keyword: word, title: "Web research", symbol: "globe", placeholder: "Ask something to look up…")
        }
        if ["define", "def"].contains(word) {
            return ArgumentToken(keyword: word, title: "Dictionary", symbol: "character.book.closed", placeholder: "Look up a word…")
        }
        // A short name given to a workflow takes what follows as its input.
        if let id = prefs.data.aliases[word], id.hasPrefix("workflow:"), let name = workflowTitle(String(id.dropFirst("workflow:".count))) {
            return ArgumentToken(keyword: word, title: name, symbol: "gearshape.2", placeholder: "Text for “\(name)”…")
        }
        return nil
    }

    /// A short name followed by words, for a workflow, a script or a quicklink: runs it with those words.
    private func argumentEntries(_ text: String) -> [PaletteEntry] {
        guard let (word, rest) = LauncherExtraMatch.split(text), !rest.isEmpty else { return dictionaryEntries(text) }
        var found: [PaletteEntry] = dictionaryEntries(text)
        if let id = prefs.data.aliases[word], id.hasPrefix("workflow:") {
            let workflowID = String(id.dropFirst("workflow:".count))
            if let name = workflowTitle(workflowID) {
                found.append(PaletteEntry(
                    id: "workflow-arg:\(workflowID):\(rest)", title: "Run “\(name)” with “\(Self.oneLine(rest))”", subtitle: "Workflow", symbol: "gearshape.2", category: .workflow,
                    rememberable: false, queryScore: 985
                ) { [weak self] in self?.runWorkflow(workflowID, rest) })
            }
        }
        return found
    }

    // MARK: The dictionary

    /// "define serendipity": the Mac's own dictionary. Nothing is sent anywhere.
    private func dictionaryEntries(_ text: String) -> [PaletteEntry] {
        guard prefs.data.isEnabled(.tools), let (word, rest) = LauncherExtraMatch.split(text), ["define", "def"].contains(word), !rest.isEmpty, rest.count <= 60 else { return [] }
        let range = CFRange(location: 0, length: (rest as NSString).length)
        guard let definition = DCSCopyTextDefinition(nil, rest as CFString, range)?.takeRetainedValue() as String? else {
            return [PaletteEntry(id: "define:none:\(rest)", title: "No definition for “\(rest)”", subtitle: "Dictionary", symbol: "character.book.closed", category: .tools, rememberable: false, queryScore: 960) {}]
        }
        let short = definition.replacingOccurrences(of: "\n", with: " ")
        return [PaletteEntry(
            id: "define:\(rest)", title: String(short.prefix(120)), subtitle: "Definition of “\(rest)” · Return opens the Dictionary", symbol: "character.book.closed", category: .tools,
            rememberable: false, queryScore: 960,
            actions: [PaletteAction(title: "Copy the Definition", symbol: "doc.on.doc") { Self.copy(definition) }]
        ) {
            if let url = URL(string: "dict://" + (rest.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? rest)) { NSWorkspace.shared.open(url) }
        }]
    }

    // MARK: Text selected in another app

    /// What to do with the selected text: Apple Intelligence tasks, text changes, searches and the converters.
    func selectionEntries(_ text: String) -> [PaletteEntry] {
        var list: [PaletteEntry] = []
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        let short = Self.oneLine(clean)
        func entry(_ id: String, _ title: String, _ subtitle: String, _ symbol: String, score: Int, actions: [PaletteAction] = [], run: @escaping () -> Void) -> PaletteEntry {
            PaletteEntry(id: "sel:\(id)", title: title, subtitle: subtitle, symbol: symbol, category: .tools, rememberable: false, queryScore: score, actions: actions, run: run)
        }
        list.append(entry("copy", "Copy the text", short, "doc.on.doc", score: 990) { Self.copy(clean) })
        if let intelligence, intelligence.service.isAvailable, intelligence.service.settings.inLauncher {
            let tasks: [(String, IntelligenceTask, String)] = [
                ("Summarize", .summarize, "text.append"), ("Explain", .explain, "questionmark.bubble"), ("Fix grammar", .fixGrammar, "checkmark.circle"),
                ("Make it professional", .professional, "briefcase"), ("Make it friendlier", .friendlier, "face.smiling"), ("Make it concise", .concise, "scissors"), ("Write a reply", .reply, "arrowshape.turn.up.left"),
            ]
            for (index, item) in tasks.enumerated() {
                list.append(entry("ai:\(item.0)", item.0, "With Apple Intelligence, on this Mac", item.2, score: 980 - index) { [weak intelligence] in intelligence?.perform(item.1, on: clean) })
            }
        }
        let verbs: [(String, String, String)] = [
            ("upper", "Make it UPPER CASE", "textformat"), ("lower", "Make it lower case", "textformat"), ("title", "Make it Title Case", "textformat"), ("slug", "Make a URL slug", "link"),
            ("count", "Count words and characters", "number"), ("base64", "Base64 encode", "lock"), ("base64 decode", "Base64 decode", "lock.open"),
            ("urlencode", "URL encode", "percent"), ("urldecode", "URL decode", "percent"), ("sha256", "SHA-256 of the text", "number"), ("json", "Format as JSON", "curlybraces"),
        ]
        for (index, verb) in verbs.enumerated() {
            guard let result = TextTool.answer("\(verb.0) \(clean)").first else { continue }
            list.append(entry("text:\(verb.0)", verb.1, String(result.title.prefix(80)).replacingOccurrences(of: "\n", with: " "), verb.2, score: 900 - index) { Self.copy(result.copy) })
        }
        if let address = WebSearch.address(in: clean) {
            list.append(entry("open", "Open the address", address.absoluteString, "safari", score: 975) { NSWorkspace.shared.open(address) })
        }
        if let links = tools?.extras.quicklinks {
            for (index, link) in links.enumerated() where link.takesQuery {
                guard let url = link.url(for: clean) else { continue }
                list.append(entry("link:\(link.id)", "Search \(link.name) for it", short, "link", score: 700 - index) { NSWorkspace.shared.open(url) })
            }
        }
        for (index, engine) in WebSearch.general.enumerated() {
            guard let url = WebSearch.url(for: engine, query: clean) else { continue }
            list.append(entry("web:\(engine.id)", "Search \(engine.name) for it", short, engine.symbol, score: 800 - index) { NSWorkspace.shared.open(url) })
        }
        if let tools { list += tools.queryEntries(clean).filter { !$0.id.hasPrefix("quicklink:") && !$0.id.hasPrefix("script:") } }
        return list
    }

    // MARK: Quit, the front app's menu, contacts

    /// "quit safari", "force quit safari" and "kill safari": the running apps that match.
    private func quitEntries(_ text: String) -> [PaletteEntry] {
        guard prefs.data.isEnabled(.app), let (name, force) = LauncherSystemCommands.quitRequest(in: text) else { return [] }
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0.bundleIdentifier != "com.apple.finder" }
        return running.compactMap { app -> PaletteEntry? in
            guard let appName = app.localizedName, let score = FuzzyMatcher.score(name, in: appName) else { return nil }
            return PaletteEntry(
                id: "quit:\(force ? "force:" : "")\(app.bundleIdentifier ?? appName)", title: "\(force ? "Force quit" : "Quit") \(appName)", subtitle: force ? "Ends it at once; unsaved work is lost" : "Asks to save first", symbol: force ? "xmark.octagon" : "xmark.circle",
                category: .app, iconPath: app.bundleURL?.path, rememberable: false, queryScore: 800 + score / 10
            ) { if force { app.forceTerminate() } else { app.terminate() } }
        }
    }

    /// "menu paste" or "> paste": the front app's menu items, which run when chosen.
    private func menuEntries(_ text: String) -> [PaletteEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var rest: String?
        if trimmed.lowercased().hasPrefix("menu ") { rest = String(trimmed.dropFirst(5)) } else if trimmed.hasPrefix(">") { rest = String(trimmed.dropFirst()) }
        guard prefs.data.isEnabled(.command), let query = rest?.trimmingCharacters(in: .whitespaces) else { return [] }
        let (appName, items) = frontMenu.snapshot()
        guard !items.isEmpty else {
            return [PaletteEntry(id: "menu:none", title: AXIsProcessTrusted() ? "No menu items found" : "Allow Accessibility to search menus", subtitle: appName, symbol: "filemenu.and.selection", category: .command, rememberable: false, queryScore: 900) {}]
        }
        let scored: [(MenuItemRef, Int)] = items.compactMap { item in
            if query.isEmpty { return (item, 100) }
            guard let score = FuzzyMatcher.best(query, in: [(item.path as NSString).lastPathComponent.isEmpty ? item.path : item.path.components(separatedBy: " › ").last ?? item.path, item.path]) else { return nil }
            return (item, score)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(12).map { item, score in
            PaletteEntry(
                id: "menu:\(item.path)", title: item.path.components(separatedBy: " › ").last ?? item.path, subtitle: "\(appName) › \(item.path)" + (item.shortcut.map { "  \($0)" } ?? ""),
                symbol: "filemenu.and.selection", category: .command, rememberable: false, queryScore: 850 + score / 10
            ) { AppMenuItems.press(item) }
        }
    }

    /// People from Contacts, when the person turned that on.
    private func contactEntries(_ text: String) -> [PaletteEntry] {
        guard prefs.data.searchContacts == true, contacts.isAllowed, prefs.data.isEnabled(.tools) else { return [] }
        return contacts.search(text).map { person in
            var actions: [PaletteAction] = []
            if let email = person.emails.first {
                actions.append(PaletteAction(title: "Email \(email)", symbol: "envelope") { if let url = URL(string: "mailto:\(email)") { NSWorkspace.shared.open(url) } })
                actions.append(PaletteAction(title: "Copy the Email", symbol: "doc.on.doc") { Self.copy(email) })
            }
            if let phone = person.phones.first {
                let digits = phone.filter { $0.isNumber || $0 == "+" }
                actions.append(PaletteAction(title: "Call \(phone)", symbol: "phone") { if let url = URL(string: "tel:\(digits)") { NSWorkspace.shared.open(url) } })
                actions.append(PaletteAction(title: "FaceTime", symbol: "video") { if let url = URL(string: "facetime:\(digits)") { NSWorkspace.shared.open(url) } })
                actions.append(PaletteAction(title: "Message", symbol: "message") { if let url = URL(string: "sms:\(digits)") { NSWorkspace.shared.open(url) } })
                actions.append(PaletteAction(title: "Copy the Number", symbol: "doc.on.doc") { Self.copy(phone) })
            }
            let first = person.emails.first ?? person.phones.first ?? ""
            return PaletteEntry(
                id: "contact:\(person.id)", title: person.name, subtitle: first, symbol: "person.crop.circle", category: .tools, rememberable: false, queryScore: 400, actions: actions
            ) { if !first.isEmpty { Self.copy(first) } else { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Contacts.app")) } }
        }
    }

    // MARK: Apple Intelligence

    /// "ask what is a monad" or "ai what is a monad" or "? what is a monad", as the question that follows.
    /// "research who directed Baahubali": a question to look up on the web, when the person allowed that.
    static func researchQuestion(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["research ", "lookup "] where trimmed.lowercased().hasPrefix(prefix) {
            let rest = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.count >= 3 ? String(rest.prefix(WebResearch.maxQuestionCharacters)) : nil
        }
        return nil
    }

    static func question(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["ask ", "ai ", "? "] where trimmed.lowercased().hasPrefix(prefix) {
            let rest = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.count >= 3 ? String(rest.prefix(500)) : nil
        }
        return nil
    }

    /// What the clipboard holds, as text, unless it is something that must not go anywhere: marked secret by the app that
    /// copied it, or looking like a password, key or card number.
    static func plainClipboardText(from board: NSPasteboard = .general) -> String? {
        let concealed = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"].map(NSPasteboard.PasteboardType.init(rawValue:))
        if board.types?.contains(where: { concealed.contains($0) }) == true { return nil }
        guard let text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !clipLooksSensitive(text: text) else { return nil }
        return text
    }

    /// Work on whatever is on the clipboard now: summarize it, fix it, explain it.
    private func intelligenceEntries() -> [PaletteEntry] {
        guard prefs.data.isEnabled(.intelligence), let intelligence, intelligence.service.isAvailable, intelligence.service.settings.inLauncher else { return [] }
        let jobs: [(id: String, task: IntelligenceTask, symbol: String)] = [
            ("summarize", .summarize, "text.append"), ("fix", .fixGrammar, "checkmark.circle"), ("explain", .explain, "questionmark.bubble"),
            ("professional", .professional, "briefcase"), ("concise", .concise, "arrow.down.right.and.arrow.up.left"),
        ]
        return jobs.map { job in
            PaletteEntry(
                id: "ai:clipboard:\(job.id)", title: "\(intelligenceTitle(task: job.task)) the clipboard text", subtitle: "Apple Intelligence, on this Mac", symbol: job.symbol, category: .intelligence
            ) { [weak intelligence] in
                guard let text = Self.plainClipboardText() else {
                    Toast().show("The clipboard has no text to work on, or it looks like a secret.", isError: true)
                    return
                }
                intelligence?.perform(job.task, on: text)
            }
        }
    }

    /// Things Apple Intelligence can do with a clipboard item, for the actions menu. Never for an item labelled sensitive.
    private func intelligenceActions(for item: ClipItem) -> [PaletteAction] {
        guard let intelligence, intelligence.service.isAvailable, intelligence.service.settings.onClipboardItems, prefs.data.isEnabled(.intelligence),
              !item.sensitive, item.kind == .text || item.kind == .richText || item.kind == .url,
              let text = clipboard.store.blob(item.id)?.plain, !text.isEmpty else { return [] }
        return [
            PaletteAction(title: "Summarize with Apple Intelligence", symbol: "sparkles") { [weak intelligence] in intelligence?.perform(.summarize, on: text) },
            PaletteAction(title: "Explain with Apple Intelligence", symbol: "questionmark.bubble") { [weak intelligence] in intelligence?.perform(.explain, on: text) },
            PaletteAction(title: "Fix Grammar with Apple Intelligence", symbol: "checkmark.circle") { [weak intelligence] in intelligence?.perform(.fixGrammar, on: text) },
        ]
    }

    // MARK: Helpers

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A clipboard item on one line, cut to fit.
    static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > 90 ? String(flat.prefix(90)) + "…" : flat
    }
}
