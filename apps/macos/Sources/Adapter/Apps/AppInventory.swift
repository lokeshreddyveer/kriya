import AppKit
import Combine
import CoreServices

/// An app installed on this Mac, with what can be told about where it came from.
struct InstalledApp: Identifiable, Hashable {
    enum Source: Hashable {
        case appStore
        case sparkle(URL)
        case homebrew
        case other
    }

    let url: URL
    let name: String
    let bundleID: String
    let version: String
    let build: String
    let source: Source
    /// When the app was last opened, as Spotlight knows it. Nil when it never has been.
    let lastUsed: Date?
    var id: String { url.path }
    var isProtected: Bool {
        bundleID.hasPrefix("com.apple.") || bundleID == Bundle.main.bundleIdentifier || bundleID.isEmpty
    }
}

/// A file or folder that belongs to an app and could go to the Trash with it.
struct Leftover: Identifiable, Hashable {
    let url: URL
    let bytes: Int64
    /// Something outside the person's own Library cannot be moved without an administrator, so it is listed but kept.
    let needsAdmin: Bool
    var id: String { url.path }
}

struct AppUpdate: Identifiable, Hashable {
    let appName: String
    let installed: String
    let latest: String
    /// Where it can be fetched or what runs the update.
    let action: Action
    var id: String { appName }

    enum Action: Hashable {
        case open(URL)
        case brew(String)
        case appStore
    }
}

/// Reads the installed apps, finds the files they leave around and checks for newer versions. Nothing is deleted: files
/// go to the Trash, so every removal can be undone from there.
final class AppInventory: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    /// How much room each app takes, filled in after the list appears.
    @Published private(set) var sizes: [String: Int64] = [:]
    @Published private(set) var isScanning = false
    @Published private(set) var updates: [AppUpdate] = []
    @Published private(set) var isCheckingUpdates = false
    @Published private(set) var updateNote: String?
    /// Which source the check is waiting on, while it runs ("Homebrew apps…").
    @Published private(set) var checkStage: String?
    /// The last time a check ran and could not reach anything, with why. Shown beside the last good time.
    @Published private(set) var lastFailedCheck: (at: Date, note: String)?
    @Published var ignoredUpdates: Set<String> {
        didSet { UserDefaults.standard.set(Array(ignoredUpdates), forKey: "ignoredAppUpdates") }
    }

    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser

    /// Upgrade Homebrew apps by themselves when an update is found. On unless turned off.
    @Published var upgradeHomebrewAutomatically: Bool {
        didSet { UserDefaults.standard.set(upgradeHomebrewAutomatically, forKey: Self.upgradeKey) }
    }
    /// What the automatic upgrades did, newest last, for the person to read.
    @Published private(set) var activity: [String] = []
    @Published private(set) var lastUpdateCheck: Date?
    @Published private(set) var orphanList: [Leftover] = []
    @Published private(set) var isFindingLeftovers = false

    private static let upgradeKey = "upgradeHomebrewAppsAutomatically"
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var rescanWork: DispatchWorkItem?
    private var updateTimer: Timer?
    private var started = false
    /// The Homebrew apps being upgraded right now, so the list can show it.
    @Published private(set) var upgrading = Set<String>()
    private var checkTask: Task<Void, Never>?
    private var checkCancel: CancelToken?
    /// For tests: a stand-in program used instead of the real Homebrew.
    var brewExecutableOverride: String?

    init() {
        ignoredUpdates = Set(UserDefaults.standard.stringArray(forKey: "ignoredAppUpdates") ?? [])
        upgradeHomebrewAutomatically = UserDefaults.standard.object(forKey: Self.upgradeKey) as? Bool ?? true
    }

    /// Starts keeping everything up to date: the list of apps follows the Applications folders, leftovers are found again
    /// whenever the list changes, and updates are looked for now and then every hour. Safe to call more than once.
    func startWatching() {
        guard !started else { return }
        started = true
        scan()
        for folder in ["/Applications", NSHomeDirectory() + "/Applications"] where FileManager.default.fileExists(atPath: folder) {
            let descriptor = open(folder, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .link], queue: .main)
            source.setEventHandler { [weak self] in self?.foldersChanged() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watchers.append(source)
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkUpdates() }
        updateTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in self?.checkUpdates() }
    }

    /// Stops watching the Applications folders and the hourly check.
    func stopWatching() {
        for watcher in watchers { watcher.cancel() }
        watchers.removeAll()
        updateTimer?.invalidate()
        updateTimer = nil
        rescanWork?.cancel()
        started = false
    }

    private func foldersChanged() {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    /// Finds leftovers of apps that are no longer installed, in the background.
    func refreshLeftovers() {
        guard !isFindingLeftovers, !apps.isEmpty else { return }
        isFindingLeftovers = true
        DispatchQueue.global(qos: .utility).async { [self] in
            let found = orphans()
            DispatchQueue.main.async {
                self.orphanList = found
                self.isFindingLeftovers = false
            }
        }
    }

    // MARK: Installed apps

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Utilities"), home.appendingPathComponent("Applications")]
            var found: [InstalledApp] = []
            for root in roots {
                let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                for url in entries where url.pathExtension == "app" {
                    if let app = Self.read(url) { found.append(app) }
                }
            }
            found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                let changed = found.map(\.id) != self.apps.map(\.id)
                self.apps = found
                self.isScanning = false
                self.measure(found)
                // A different set of apps means different leftovers.
                if changed { self.refreshLeftovers() }
            }
        }
    }

    /// Works out each app's size one after another in the background, so the list is never held up by it.
    private func measure(_ list: [InstalledApp]) {
        DispatchQueue.global(qos: .utility).async { [self] in
            var batch: [String: Int64] = [:]
            for (index, app) in list.enumerated() {
                batch[app.id] = Self.size(of: app.url)
                if batch.count >= 8 || index == list.count - 1 {
                    let ready = batch
                    batch.removeAll()
                    DispatchQueue.main.async { self.sizes.merge(ready) { _, new in new } }
                }
            }
        }
    }

    private static func read(_ url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let source: InstalledApp.Source
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt").path) {
            source = .appStore
        } else if let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)) {
            source = .sparkle(feed)
        } else {
            source = .other
        }
        let lastUsed = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL).flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
        return InstalledApp(
            url: url, name: name, bundleID: id, version: (info["CFBundleShortVersionString"] as? String) ?? "",
            build: (info["CFBundleVersion"] as? String) ?? "", source: source, lastUsed: lastUsed
        )
    }

    // MARK: Leftovers

    /// Folders in the person's Library where apps keep their files.
    private var libraryFolders: [URL] {
        ["Application Support", "Caches", "Preferences", "Containers", "Group Containers", "Saved Application State", "Logs",
         "LaunchAgents", "Application Scripts", "WebKit", "HTTPStorages", "Cookies"].map { home.appendingPathComponent("Library/\($0)") }
    }

    /// Everything of an app's that sits in the person's Library, found by its identifier and exact name.
    func leftovers(for app: InstalledApp) -> [Leftover] {
        guard !app.isProtected else { return [] }
        let id = app.bundleID.lowercased()
        let name = app.name.lowercased()
        let nameUsable = name.count >= 4
        var result: [Leftover] = []
        for folder in libraryFolders {
            for entry in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])) ?? [] {
                let file = entry.lastPathComponent.lowercased()
                let stem = (file as NSString).deletingPathExtension
                let byID = file == id || file.hasPrefix(id + ".") || stem == id || file.hasSuffix("." + id)
                let byName = nameUsable && (file == name || stem == name) && folder.lastPathComponent != "Preferences"
                guard byID || byName else { continue }
                result.append(Leftover(url: entry, bytes: Self.size(of: entry), needsAdmin: false))
            }
        }
        // Items outside the user's Library are only listed.
        for path in ["/Library/Application Support/\(app.name)", "/Library/LaunchAgents/\(app.bundleID).plist", "/Library/LaunchDaemons/\(app.bundleID).plist", "/Library/Preferences/\(app.bundleID).plist"] where fm.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            result.append(Leftover(url: url, bytes: Self.size(of: url), needsAdmin: true))
        }
        return result.sorted { $0.url.path < $1.url.path }
    }

    /// Files in the person's Library named like an app's identifier, for apps that are no longer installed.
    func orphans() -> [Leftover] {
        let installed = Set(apps.map { $0.bundleID.lowercased() })
        let pattern = try? NSRegularExpression(pattern: #"^[a-z0-9-]+(\.[a-z0-9-]+){2,}"#)
        var result: [Leftover] = []
        for folder in libraryFolders where folder.lastPathComponent != "Group Containers" {
            for entry in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])) ?? [] {
                var name = entry.lastPathComponent.lowercased()
                if name.hasSuffix(".plist") { name = String(name.dropLast(6)) }
                if name.hasSuffix(".savedstate") { name = String(name.dropLast(11)) }
                guard pattern?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil else { continue }
                // Apple's own, and anything that belongs to an installed app, is left alone.
                if name.hasPrefix("com.apple.") || name.hasPrefix("group.com.apple.") { continue }
                if installed.contains(where: { name == $0 || name.hasPrefix($0 + ".") }) { continue }
                if Self.isRunningOrSystemID(name) { continue }
                result.append(Leftover(url: entry, bytes: Self.size(of: entry), needsAdmin: false))
            }
        }
        return result.sorted { $0.bytes > $1.bytes }
    }

    private static func isRunningOrSystemID(_ id: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { ($0.bundleIdentifier ?? "").lowercased() == id }
    }

    static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        var total: Int64 = 0
        if let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else { return 0 }
        var seen = 0
        for case let item as URL in walker {
            seen += 1
            if seen > 50_000 { break }
            if let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    // MARK: Removing

    /// Moves the app (when `includeApp`) and the chosen leftovers to the Trash. Returns what could not be moved.
    @discardableResult
    func trash(app: InstalledApp?, leftovers: [Leftover]) -> [String] {
        var failures: [String] = []
        if let app {
            if app.isProtected { return ["“\(app.name)” is part of the system or of Kriya and is not removed."] }
            for running in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID) { running.terminate() }
            do { try fm.trashItem(at: app.url, resultingItemURL: nil) } catch { failures.append("\(app.name): \(error.localizedDescription)") }
        }
        for item in leftovers where !item.needsAdmin {
            // Only things inside the person's own Library are ever touched.
            guard item.url.path.hasPrefix(home.appendingPathComponent("Library").path + "/") else { continue }
            do { try fm.trashItem(at: item.url, resultingItemURL: nil) } catch { failures.append("\(item.url.lastPathComponent): \(error.localizedDescription)") }
        }
        Log.info("Apps", "Moved \(app?.name ?? "leftover files") to the Trash")
        if app != nil { scan() }
        return failures
    }

    // MARK: Updates

    /// Stops a check in progress. What it had found so far is dropped, and the old list stays.
    func cancelCheck() {
        checkCancel?.cancel()
        checkTask?.cancel()
        isCheckingUpdates = false
        checkStage = nil
        updateNote = "Stopped."
    }

    func checkUpdates() {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        updateNote = nil
        checkStage = "Apps that update themselves…"
        let apps = self.apps
        let cancel = CancelToken()
        checkCancel = cancel
        checkTask = Task {
            var found: [AppUpdate] = []
            var attempts = 0
            var failures = 0
            await withTaskGroup(of: CheckResult.self) { group in
                for app in apps {
                    if case .sparkle(let feed) = app.source {
                        group.addTask { await Self.sparkleUpdate(for: app, feed: feed) }
                    }
                }
                for await result in group {
                    switch result {
                    case .update(let update): attempts += 1; found.append(update)
                    case .upToDate: attempts += 1
                    case .failed: attempts += 1; failures += 1
                    case .skipped: break
                    }
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { self.checkStage = "Homebrew apps (Homebrew updates itself first, this can take a minute)…" }
            let brew = await Self.brewOutdated(cancel: cancel)
            guard !Task.isCancelled else { return }
            if brew.attempted { attempts += 1 }
            if brew.failed { failures += 1 }
            found.append(contentsOf: brew.updates)
            var notes: [String] = []
            let storeApps = apps.filter { $0.source == .appStore }.count
            if storeApps > 0 { notes.append("\(storeApps) App Store app\(storeApps == 1 ? "" : "s"): updates come from the App Store.") }
            if failures > 0 { notes.append(Self.failureNote(attempts: attempts, failures: failures)) }
            let sorted = found.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
            let record = Self.shouldRecordCheck(attempts: attempts, failures: failures)
            await MainActor.run {
                self.updates = sorted
                self.updateNote = notes.isEmpty ? nil : notes.joined(separator: " ")
                self.isCheckingUpdates = false
                self.checkStage = nil
                // A check where every source failed is not shown as done: the time shown is the last one that worked.
                if record { self.lastUpdateCheck = Date() }
                if failures > 0 { self.lastFailedCheck = (Date(), Self.failureNote(attempts: attempts, failures: failures)) } else { self.lastFailedCheck = nil }
                self.upgradeAutomatically(sorted)
            }
        }
    }

    enum CheckResult {
        case update(AppUpdate)
        case upToDate
        case failed
        /// Not something that can be checked (no usable address), so it counts neither way.
        case skipped
    }

    /// Whether a round of checks counts as done: at least one source answered, or there was nothing to ask.
    static func shouldRecordCheck(attempts: Int, failures: Int) -> Bool {
        attempts == 0 || failures < attempts
    }

    static func failureNote(attempts: Int, failures: Int) -> String {
        failures >= attempts ? "Could not reach any update source, so nothing could be checked." : "Could not reach \(failures) of \(attempts) update sources."
    }

    private static func sparkleUpdate(for app: InstalledApp, feed: URL) async -> CheckResult {
        guard feed.scheme == "https" || feed.scheme == "http" else { return .skipped }
        var request = URLRequest(url: feed)
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return .failed }
        let parser = AppcastReader(data: data)
        guard let latest = parser.latest, !latest.isEmpty else { return .failed }
        let installed = app.version.isEmpty ? app.build : app.version
        guard latest.compare(installed, options: .numeric) == .orderedDescending else { return .upToDate }
        return .update(AppUpdate(appName: app.name, installed: installed, latest: latest, action: parser.link.map { .open($0) } ?? .open(feed)))
    }

    /// What `brew outdated` says. `attempted` is false when Homebrew is not installed, and `failed` when it was asked and
    /// could not answer.
    private static func brewOutdated(cancel: CancelToken) async -> (updates: [AppUpdate], attempted: Bool, failed: Bool) {
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return ([], false, false) }
        // The same environment the installs use: an app started from Finder has almost no PATH, and Homebrew needs it. It also
        // updates its own list first, which can take a while, so it is given time.
        guard let output = try? ToolRunner.run(brew, ["outdated", "--cask", "--json=v2"], environment: HomebrewManager.environment, timeout: 180, cancel: cancel),
              let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]] else { return ([], true, true) }
        let list: [AppUpdate] = casks.compactMap { cask in
            guard let token = cask["name"] as? String else { return nil }
            let installed = (cask["installed_versions"] as? [String])?.first ?? (cask["installed_versions"] as? String) ?? ""
            return AppUpdate(appName: token, installed: installed, latest: (cask["current_version"] as? String) ?? "", action: .brew(token))
        }
        return (list, true, false)
    }

    /// Upgrades the Homebrew apps that have an update, one at a time, unless the person ignores them or turned this off.
    private func upgradeAutomatically(_ list: [AppUpdate]) {
        guard upgradeHomebrewAutomatically else { return }
        for update in list {
            guard case .brew(let token) = update.action, HomebrewParsing.isValidToken(token),
                  !ignoredUpdates.contains(update.appName), !upgrading.contains(token) else { continue }
            note("Updating \(token)…")
            runBrewUpgrade(token) { [weak self] result in self?.note(result) }
        }
    }

    private func note(_ line: String) {
        activity.append("\(Date().formatted(date: .omitted, time: .shortened))  \(line)")
        if activity.count > 40 { activity.removeFirst(activity.count - 40) }
    }

    /// Upgrades one Homebrew app. Upgrades (and installs) run one after another on a single queue, never side by side.
    func runBrewUpgrade(_ token: String, done: @escaping (String) -> Void) {
        guard HomebrewParsing.isValidToken(token) else {
            done("“\(token)” is not a name Homebrew would use.")
            return
        }
        guard !upgrading.contains(token) else {
            done("Already updating \(token).")
            return
        }
        upgrading.insert(token)
        let override = brewExecutableOverride
        HomebrewQueue.shared.async {
            guard let brew = override ?? ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                DispatchQueue.main.async { self.upgrading.remove(token); done("Homebrew was not found.") }
                return
            }
            let result: String
            do {
                _ = try ToolRunner.run(brew, ["upgrade", "--cask", token], environment: HomebrewManager.environment, timeout: 1200)
                result = "Updated \(token)."
            } catch {
                result = error.localizedDescription
            }
            DispatchQueue.main.async { self.upgrading.remove(token); done(result); self.scan() }
        }
    }
}

/// Reads the newest entry of a Sparkle update feed.
private final class AppcastReader: NSObject, XMLParserDelegate {
    private(set) var latest: String?
    private(set) var link: URL?
    private var inFirstItem = false
    private var seenItem = false
    private var element = ""
    private var text = ""

    init(data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        element = name
        text = ""
        if name == "item", !seenItem { inFirstItem = true; seenItem = true }
        if inFirstItem, name == "enclosure" {
            let version = attributes["sparkle:shortVersionString"] ?? attributes["sparkle:version"]
            if latest == nil { latest = version }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard inFirstItem else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "sparkle:shortVersionString", !value.isEmpty { latest = value }
        if name == "sparkle:version", latest == nil, !value.isEmpty { latest = value }
        if name == "link", link == nil { link = URL(string: value) }
        if name == "item" { inFirstItem = false }
    }
}
