import AppKit
import Combine

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
    @Published private(set) var isScanning = false
    @Published private(set) var updates: [AppUpdate] = []
    @Published private(set) var isCheckingUpdates = false
    @Published private(set) var updateNote: String?
    @Published var ignoredUpdates: Set<String> {
        didSet { UserDefaults.standard.set(Array(ignoredUpdates), forKey: "ignoredAppUpdates") }
    }

    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser

    init() {
        ignoredUpdates = Set(UserDefaults.standard.stringArray(forKey: "ignoredAppUpdates") ?? [])
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
                self.apps = found
                self.isScanning = false
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
        return InstalledApp(
            url: url, name: name, bundleID: id, version: (info["CFBundleShortVersionString"] as? String) ?? "",
            build: (info["CFBundleVersion"] as? String) ?? "", source: source
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

    func checkUpdates() {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        updateNote = nil
        let apps = self.apps
        Task {
            var found: [AppUpdate] = []
            await withTaskGroup(of: AppUpdate?.self) { group in
                for app in apps {
                    if case .sparkle(let feed) = app.source {
                        group.addTask { await Self.sparkleUpdate(for: app, feed: feed) }
                    }
                }
                for await update in group { if let update { found.append(update) } }
            }
            let brew = await Self.brewOutdated()
            found.append(contentsOf: brew)
            let storeApps = apps.filter { $0.source == .appStore }.count
            let note = storeApps > 0 ? "\(storeApps) App Store app\(storeApps == 1 ? "" : "s"): updates come from the App Store." : nil
            let sorted = found.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
            await MainActor.run {
                self.updates = sorted
                self.updateNote = note
                self.isCheckingUpdates = false
            }
        }
    }

    private static func sparkleUpdate(for app: InstalledApp, feed: URL) async -> AppUpdate? {
        guard feed.scheme == "https" || feed.scheme == "http" else { return nil }
        var request = URLRequest(url: feed)
        request.timeoutInterval = 12
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let parser = AppcastReader(data: data)
        guard let latest = parser.latest, !latest.isEmpty else { return nil }
        let installed = app.version.isEmpty ? app.build : app.version
        guard latest.compare(installed, options: .numeric) == .orderedDescending else { return nil }
        return AppUpdate(appName: app.name, installed: installed, latest: latest, action: parser.link.map { .open($0) } ?? .open(feed))
    }

    private static func brewOutdated() async -> [AppUpdate] {
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
        guard let output = try? ToolRunner.run(brew, ["outdated", "--cask", "--json=v2"], timeout: 60),
              let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]] else { return [] }
        return casks.compactMap { cask in
            guard let token = cask["name"] as? String else { return nil }
            let installed = (cask["installed_versions"] as? [String])?.first ?? (cask["installed_versions"] as? String) ?? ""
            return AppUpdate(appName: token, installed: installed, latest: (cask["current_version"] as? String) ?? "", action: .brew(token))
        }
    }

    func runBrewUpgrade(_ token: String, done: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                DispatchQueue.main.async { done("Homebrew was not found.") }
                return
            }
            let result: String
            do {
                _ = try ToolRunner.run(brew, ["upgrade", "--cask", token], timeout: 1200)
                result = "Updated \(token)."
            } catch {
                result = error.localizedDescription
            }
            DispatchQueue.main.async { done(result); self.scan() }
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
