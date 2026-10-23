import AppKit

// MARK: - Recent applications

/// Remembers which apps came to the front lately (on this Mac only), so the launcher can offer them when the box is empty.
final class RecentAppsTracker {
    static let shared = RecentAppsTracker()

    private(set) var apps: RecentApps
    private let defaults: UserDefaults
    private let key = "recentApps.v1"
    private var observer: NSObjectProtocol?
    private let ignored: Set<String> = [Bundle.main.bundleIdentifier ?? "", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver", "com.apple.notificationcenterui", "com.apple.controlcenter"]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        apps = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(RecentApps.self, from: $0) } ?? RecentApps()
    }

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.activationPolicy == .regular else { return }
            self.apps.record(app.bundleIdentifier, ignoring: self.ignored)
            if let data = try? JSONEncoder().encode(self.apps) { self.defaults.set(data, forKey: self.key) }
        }
    }
}

// MARK: - Music

/// Runs a command in Music or Spotify with AppleScript. The first time, macOS asks to let Kriya control the app.
enum MusicRunner {
    static func runningPlayers() -> [MusicControl.Player] {
        MusicControl.running(Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)))
    }

    static func run(_ command: MusicControl.Command, player: MusicControl.Player, toast: Toast) {
        DispatchQueue.global(qos: .userInitiated).async {
            let output = try? ToolRunner.run("/usr/bin/osascript", ["-e", MusicControl.script(command, player: player)], timeout: 6)
            guard command == .nowPlaying else { return }
            DispatchQueue.main.async {
                if let playing = output.flatMap(MusicControl.parse) { toast.show("\(player.rawValue): \(playing.text)") } else { toast.show("Nothing is playing in \(player.rawValue).") }
            }
        }
    }

    /// For commands from shortcuts and workflows: the first player that is running.
    static func runOnFirstPlayer(_ command: MusicControl.Command) {
        guard let player = runningPlayers().first else { Toast().show("Music and Spotify are not open.", isError: true); return }
        run(command, player: player, toast: Toast())
    }
}

extension LauncherSources {
    /// Play, pause and skip for the music apps that are open.
    func musicEntries() -> [PaletteEntry] {
        guard prefs.data.isEnabled(.command) else { return [] }
        let toast = Toast()
        var entries: [PaletteEntry] = []
        for player in MusicRunner.runningPlayers() {
            for command in MusicControl.Command.allCases {
                entries.append(PaletteEntry(
                    id: "music:\(player.rawValue):\(command.rawValue)", title: "\(player.rawValue): \(command.title)", subtitle: "Controls \(player.rawValue)", symbol: command.symbol, category: .command,
                    keywords: ["music", "song", "track", "play", "pause", "skip", player.rawValue.lowercased()]
                ) { MusicRunner.run(command, player: player, toast: toast) })
            }
        }
        return entries
    }

    /// Apps used lately, offered when the box is empty.
    func recentAppEntries(limit: Int = 6) -> [(entry: PaletteEntry, section: String)] {
        guard prefs.data.isEnabled(.app) else { return [] }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return RecentAppsTracker.shared.apps.recent(limit, excluding: front).compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            var entry = appEntry(name: name, id: id, url: url, running: running.contains(id))
            entry.rememberable = false
            return (entry, "Recent apps")
        }
    }
}

// MARK: - 1Password

/// Items from the 1Password command-line tool, kept only in memory. Passwords are never read until you choose to copy one; the
/// tool asks 1Password to unlock (Touch ID) itself.
final class OnePasswordIndex: ObservableObject {
    static let shared = OnePasswordIndex()

    private(set) var items: [PasswordItem] = []
    @Published private(set) var lastProblem: String?
    private var loadedAt: Date?
    private var loading = false
    var onChange: () -> Void = {}

    static var cliPath: String? {
        ["/opt/homebrew/bin/op", "/usr/local/bin/op"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isInstalled: Bool { Self.cliPath != nil }

    func refreshIfNeeded() {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 120 { return }
        guard !loading, let path = Self.cliPath else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try ToolRunner.run(path, ["item", "list", "--format", "json"], timeout: 20) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                self.loadedAt = Date()
                switch result {
                case .success(let json):
                    self.items = PasswordItems.parse(Data(json.utf8))
                    self.lastProblem = nil
                    self.onChange()
                case .failure:
                    self.lastProblem = "1Password did not answer. Open 1Password, turn on “Integrate with 1Password CLI” in its Developer settings, and unlock it."
                }
            }
        }
    }

    /// Copies one field of an item to the clipboard, marked secret, and takes it off again after 30 seconds if nothing else was
    /// copied meanwhile.
    func copy(_ field: PasswordItems.Field, of item: PasswordItem, toast: Toast) {
        guard let path = Self.cliPath, let arguments = PasswordItems.arguments(for: field, id: item.id) else { return }
        AuditLog.shared.record(.script, "1Password: copied a \(field.rawValue)")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ToolRunner.run(path, arguments, timeout: 30) }
            DispatchQueue.main.async {
                guard case .success(let output) = result, !output.isEmpty else {
                    toast.show("1Password did not give the \(field == .otp ? "code" : field.rawValue). Unlock 1Password and try again.", isError: true)
                    return
                }
                let board = NSPasteboard.general
                board.clearContents()
                board.setString(output, forType: .string)
                board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                let count = board.changeCount
                toast.show("Copied the \(field == .otp ? "one-time code" : field.rawValue). It leaves the clipboard in \(Int(SecretClipboard.seconds)) seconds.")
                DispatchQueue.main.asyncAfter(deadline: .now() + SecretClipboard.seconds) {
                    if SecretClipboard.shouldClear(changeCountAtCopy: count, now: NSPasteboard.general.changeCount) { NSPasteboard.general.clearContents() }
                }
            }
        }
    }
}

extension LauncherSources {
    /// Logins from 1Password, found by name, user name or address, when the person turned this on.
    func passwordEntries(_ text: String) -> [PaletteEntry] {
        guard prefs.data.searchPasswords == true, prefs.data.isEnabled(.tools), OnePasswordIndex.shared.isInstalled else { return [] }
        let index = OnePasswordIndex.shared
        index.onChange = { [weak palette] in palette?.model.refresh() }
        index.refreshIfNeeded()
        let toast = Toast()
        return PasswordItems.search(text, in: index.items).map { item in
            var actions = [
                PaletteAction(title: "Copy the User Name", symbol: "person") { index.copy(.username, of: item, toast: toast) },
                PaletteAction(title: "Copy the One-Time Code", symbol: "clock.badge.checkmark") { index.copy(.otp, of: item, toast: toast) },
            ]
            if let first = item.urls.first, let url = URL(string: first) { actions.append(PaletteAction(title: "Open the Website", symbol: "safari") { NSWorkspace.shared.open(url) }) }
            return PaletteEntry(
                id: "1password:\(item.id)", title: item.title, subtitle: ["1Password", item.vault, item.username].filter { !$0.isEmpty }.joined(separator: " · "), symbol: "key.fill", category: .tools,
                rememberable: false, queryScore: 700, actions: actions
            ) { index.copy(.password, of: item, toast: toast) }
        }
    }
}
