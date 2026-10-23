import AppKit
import FinderSync

/// One line of the right-click menu check: what was looked at, whether it is fine, and what to do if not.
struct FinderCheckResult: Identifiable, Equatable {
    let id: Int
    let title: String
    let ok: Bool
    let detail: String
}

extension FinderService {
    /// Looks at each link between the Finder and Kriya, so a menu that does not work can say which one is broken. It
    /// changes nothing and runs no action.
    func selfCheck() -> [FinderCheckResult] {
        var results: [FinderCheckResult] = []
        func add(_ title: String, _ ok: Bool, _ good: String, _ bad: String) {
            results.append(FinderCheckResult(id: results.count, title: title, ok: ok, detail: ok ? good : bad))
        }

        add("The right-click menu is switched on in Kriya", isActive, "On.", "It is off. Turn it on at the top of this pane.")

        refreshExtensionStatus()
        add("The Finder extension is switched on", extensionEnabled, "On.",
            "It is off. In System Settings › Login Items & Extensions › Finder, switch on “Kriya”, then restart the extension below.")

        let fileURL = store.menuFile
        let file = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(FinderMenuFile.self, from: $0) }
        if let file {
            add("The menu file the extension reads is there", file.version == 1 && !file.items.isEmpty, "\(file.items.count) actions are published.",
                "It holds no actions. Turn on at least one action in the list.")
            add("The menu file carries Kriya's current secret", file.token == store.token, "It matches.",
                "It does not match, so the app would ignore every request. Turn the right-click menu off and on again.")
            let forFile = FinderMenuFile.Selection(count: 1, folders: 0, extensions: ["txt"], isBackground: false)
            let forEmptySpace = FinderMenuFile.Selection(count: 1, folders: 1, extensions: [""], isBackground: true)
            let fileItems = file.visibleItems(for: forFile).count
            let spaceItems = file.visibleItems(for: forEmptySpace).count
            add("A selected file would show actions", fileItems > 0, "\(fileItems) actions.", "None of the enabled actions applies to a file.")
            add("The empty space of a folder would show actions", spaceItems > 0, "\(spaceItems) actions.", "None of the enabled actions applies to a folder's empty space (try New Folder).")
        } else {
            add("The menu file the extension reads is there", false, "", "It is missing or unreadable at \(fileURL.path). Turn the right-click menu off and on again.")
        }

        let probe = URL(string: "kriya://finder/run")!
        let opener = NSWorkspace.shared.urlForApplication(toOpen: probe)
        let mine = Bundle.main.bundleURL.standardizedFileURL
        add("macOS sends Kriya's addresses to this copy of Kriya", opener?.standardizedFileURL == mine, "Yes.",
            opener == nil ? "No app is registered for them." : "Another copy of Kriya is registered (\(opener?.path ?? "")). Remove old copies and open this one.")

        let request = FinderRequest(item: "copy-name", token: store.token, paths: ["/tmp"])
        let understood = request.url.flatMap { FinderRequest(url: $0) }?.token == store.token
        add("A request from the extension is understood", understood, "Yes.", "The request could not be read back. This is a bug; please report it.")

        let running = (try? ToolRunner.run("/usr/bin/pgrep", ["-x", "KriyaFinder"])) ?? ""
        let count = running.split(whereSeparator: \.isNewline).count
        add("The extension is running once", count <= 1, count == 0 ? "Finder starts it when needed." : "One copy.",
            "\(count) copies are running, usually left from an update. Restart the extension below.")
        return results
    }

    /// Ends the extension's process; Finder starts a fresh one the next time it needs the menu.
    func restartExtension() {
        _ = try? ToolRunner.run("/usr/bin/killall", ["KriyaFinder"])
    }
}
