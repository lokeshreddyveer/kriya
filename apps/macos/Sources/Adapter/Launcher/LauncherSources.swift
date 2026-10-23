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
    private let files = LauncherFileSearch()
    private weak var inventory: AppInventory?
    private let clipboard: ClipboardService
    private let prefs: LauncherPrefs
    private let queue = DispatchQueue(label: "app.kriya.launcher.windows", qos: .userInitiated)
    private let lock = NSLock()
    private var windows: [OpenWindow] = []
    private var systemApps: (list: [(name: String, id: String, url: URL)], at: Date)?
    private weak var palette: CommandPalette?

    init(inventory: AppInventory, clipboard: ClipboardService, prefs: LauncherPrefs) {
        self.inventory = inventory
        self.clipboard = clipboard
        self.prefs = prefs
    }

    func register(in palette: CommandPalette) {
        self.palette = palette
        palette.addProvider { [weak self] in self?.appEntries() ?? [] }
        palette.addProvider { [weak self] in self?.windowEntries() ?? [] }
        palette.addProvider { [weak self] in self?.systemEntries() ?? [] }
        palette.addProvider { [weak self] in self?.runningTimerEntries() ?? [] }
        palette.addProvider { [weak self] in self?.intelligenceEntries() ?? [] }
        palette.addQueryProvider { [weak self] text in self?.queryEntries(text) ?? [] }
        palette.willShow = { [weak self] in self?.prepare() }
        files.onResults = { [weak palette] in palette?.model.refresh() }
    }

    /// Gathers what takes a moment (the open windows) as the launcher opens.
    private func prepare() {
        files.cancel()
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

    private func appEntry(name: String, id: String, url: URL, running: Bool) -> PaletteEntry {
        var actions = [
            PaletteAction(title: "Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) },
            PaletteAction(title: "Copy Path", symbol: "doc.on.doc") { Self.copy(url.path) },
        ]
        if running {
            actions.append(PaletteAction(title: "Hide \(name)", symbol: "eye.slash") { NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.hide() })
            actions.append(PaletteAction(title: "Quit \(name)", symbol: "xmark.circle") { NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.terminate() })
        }
        return PaletteEntry(id: "app:\(id)", title: name, subtitle: running ? "Running" : "Application", symbol: "app", category: .app, iconPath: url.path, actions: actions) {
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
        return list
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
                id: "ai:ask:\(question)", title: "Ask Apple Intelligence: \(Self.oneLine(question))", subtitle: "Answered on this Mac, in a small window", symbol: "sparkles",
                category: .intelligence, rememberable: false, queryScore: 900
            ) { [weak intelligence] in intelligence?.ask(question) })
        }
        if data.isEnabled(.clipboard) { found.append(contentsOf: clipboardEntries(text)) }
        if data.isEnabled(.file) { found.append(contentsOf: fileEntries(text)) }
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
        let engine = WebSearch.engine(id: engineID)
        if let url = WebSearch.url(for: engine, query: trimmed) {
            let others = WebSearch.engines.filter { $0.id != engine.id }.compactMap { other -> PaletteAction? in
                guard let target = WebSearch.url(for: other, query: trimmed) else { return nil }
                return PaletteAction(title: "Search \(other.name)", symbol: other.symbol) { NSWorkspace.shared.open(target) }
            }
            found.append(PaletteEntry(
                id: "web:\(engine.id):all:\(trimmed)", title: "Search \(engine.name) for “\(Self.oneLine(trimmed))”", subtitle: "Opens in your browser", symbol: engine.symbol,
                category: .web, rememberable: false, queryScore: 10, actions: others
            ) { NSWorkspace.shared.open(url) })
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
        return files.results(for: text).map { url in
            let name = url.lastPathComponent
            let place = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let score = 150 + min(100, (FuzzyMatcher.score(text, in: name) ?? 0) / 10)
            return PaletteEntry(
                id: "file:\(url.path)", title: name, subtitle: place, symbol: isFolder ? "folder" : "doc", category: .file, iconPath: url.path, queryScore: score,
                actions: [
                    PaletteAction(title: "Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) },
                    PaletteAction(title: "Copy Path", symbol: "doc.on.doc") { Self.copy(url.path) },
                ]
            ) { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: Apple Intelligence

    /// "ask what is a monad" or "ai what is a monad" or "? what is a monad", as the question that follows.
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
