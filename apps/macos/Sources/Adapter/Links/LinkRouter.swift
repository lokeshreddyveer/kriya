import AppKit

extension LinkRule: Identifiable {}

/// The browsers on this Mac, and the profiles some of them offer.
enum Browsers {
    struct Browser: Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// Every app that can open a web address, other than Kriya, by name.
    static func installed() -> [Browser] {
        guard let probe = URL(string: "https://example.com") else { return [] }
        var seen = Set<String>()
        var list: [Browser] = []
        for url in NSWorkspace.shared.urlsForApplications(toOpen: probe) {
            guard let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { continue }
            list.append(Browser(id: id, name: AppChoice.name(for: id)))
        }
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Where each Chromium-based browser keeps its profiles, under Application Support.
    private static let chromiumFolders: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.google.Chrome.canary": "Google/Chrome Canary",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "org.chromium.Chromium": "Chromium",
    ]

    /// The profiles of a Chromium-based browser (id is the folder name the browser takes on its command line).
    static func profiles(for bundleID: String) -> [Browser] {
        guard let folder = chromiumFolders[bundleID],
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return [] }
        let state = support.appendingPathComponent(folder).appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: state),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [] }
        return cache.compactMap { key, value -> Browser? in
            let name = (value as? [String: Any])?["name"] as? String ?? key
            return Browser(id: key, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func supportsProfiles(_ bundleID: String) -> Bool { chromiumFolders[bundleID] != nil }
}

/// Receives web links (Kriya is a browser the system can hand links to), decides where each goes and opens it there. A link
/// is never lost: when anything cannot be done, it opens in Safari.
final class LinkRouter: NSObject {
    private let store: LinkRoutingStore
    private let toast = Toast()
    private var pending: URL?

    init(store: LinkRoutingStore) {
        self.store = store
    }

    /// Routes one link. `sourceAppID` is the app it came from, when the system says.
    func open(_ url: URL, sourceAppID: String?) {
        let decision = resolveLink(config: store.current, url: url.absoluteString, sourceAppId: sourceAppID, modifiers: Self.heldModifiers())
        let target = describe(decision.target)
        store.record(LinkLogEntry(
            original: decision.original, final: decision.url, source: sourceAppID.map(AppChoice.name(for:)),
            rule: decision.ruleName, outcome: target, changes: decision.changes
        ))
        let final = URL(string: decision.url) ?? url
        switch decision.target {
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(final.absoluteString, forType: .string)
            toast.show("Link copied")
        case .ask:
            choose(for: final)
        case .open(let appID, let profile):
            launch(final, appID: appID, profile: profile)
        }
    }

    /// Takes the first web address from the clipboard, cleans it as links are cleaned, and asks which browser should open it.
    func chooseBrowserForClipboardLink() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        guard let found = detector?.firstMatch(in: text, options: [], range: range)?.url,
              let scheme = found.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            toast.show("There is no web link on the clipboard", isError: true)
            return
        }
        let decision = resolveLink(config: store.current, url: found.absoluteString, sourceAppId: nil, modifiers: 0)
        choose(for: URL(string: decision.url) ?? found)
    }

    /// The keys held right now, as the core counts them.
    static func heldModifiers() -> UInt64 {
        let flags = NSEvent.modifierFlags
        var bits: UInt64 = 0
        if flags.contains(.shift) { bits |= KeyModifiers.shift }
        if flags.contains(.control) { bits |= KeyModifiers.control }
        if flags.contains(.option) { bits |= KeyModifiers.option }
        if flags.contains(.command) { bits |= KeyModifiers.command }
        return bits
    }

    func describe(_ target: LinkTarget) -> String {
        switch target {
        case .open(let appID, let profile): return "Open in \(AppChoice.name(for: appID))" + (profile.map { " (\($0))" } ?? "")
        case .ask: return "Ask which browser"
        case .copy: return "Copy the link"
        }
    }

    // MARK: Opening

    func launch(_ url: URL, appID: String, profile: String?) {
        // Never hand a link back to Kriya: it would only come straight round again.
        let safe = appID == Bundle.main.bundleIdentifier ? "com.apple.Safari" : appID
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: safe)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            toast.show("No browser was found to open the link.", isError: true)
            return
        }
        if let profile, Browsers.supportsProfiles(safe) {
            // A new instance, started with the profile: a browser that is already open takes the link into that profile.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", "-b", safe, "--args", "--profile-directory=\(profile)", url.absoluteString]
            do { try process.run(); return } catch { Log.warning("Links", "Could not start the browser with a profile: \(error.localizedDescription)") }
        }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if let error { self?.toast.show("Could not open the link: \(error.localizedDescription)", isError: true) }
        }
    }

    // MARK: Asking

    /// A small menu of browsers at the pointer.
    private func choose(for url: URL) {
        pending = url
        let menu = NSMenu()
        menu.autoenablesItems = false
        let host = NSMenuItem(title: url.host ?? url.absoluteString, action: nil, keyEquivalent: "")
        host.isEnabled = false
        menu.addItem(host)
        menu.addItem(.separator())
        for browser in Browsers.installed() {
            let entry = NSMenuItem(title: browser.name, action: #selector(chosen(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = browser.id
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.id) {
                let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                icon.size = NSSize(width: 16, height: 16)
                entry.image = icon
            }
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let copy = NSMenuItem(title: "Copy Link", action: #selector(copyChosen), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func chosen(_ sender: NSMenuItem) {
        guard let url = pending, let id = sender.representedObject as? String else { return }
        pending = nil
        launch(url, appID: id, profile: nil)
    }

    @objc private func copyChosen() {
        guard let url = pending else { return }
        pending = nil
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        toast.show("Link copied")
    }
}
