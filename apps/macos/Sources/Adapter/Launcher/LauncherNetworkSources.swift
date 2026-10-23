import AppKit
import Foundation

/// Runs an API command: builds the request from what was typed, sends it, and shows or copies part of the answer.
enum APICommandRunner {
    static func account(_ command: APICommand, header: String) -> String { "api.\(command.id).\(header)" }

    /// The header values for a command, read from the keychain.
    static func headerValues(for command: APICommand) -> [String: String] {
        var values: [String: String] = [:]
        for name in command.headerNames { values[name] = KeychainSecrets.get(account(command, header: name)) ?? "" }
        return values
    }

    /// Runs the request and reports the outcome in a toast. Only the words typed go into it.
    static func run(_ command: APICommand, query: String, toast: Toast, session: URLSession = .shared) {
        guard !LocalOnly.isOn else { toast.show(LocalOnly.blockedMessage, isError: true); return }
        // Asks first (once for this exact request) if the person wants that.
        let summary = "\(command.method.rawValue) \(command.url)\nHeaders: \(command.headerNames.isEmpty ? "none" : command.headerNames.joined(separator: ", "))" + (command.body.isEmpty ? "" : "\nBody:\n\(command.body)")
        guard LauncherApprovals.shared.ensureApproved(kind: "api", label: command.name, content: summary, detail: "This command sends your typed words to \(command.host ?? "a web address"). Check where it goes. Kriya sends it again without asking until it changes.") else { return }
        guard let request = command.request(for: query, headerValues: headerValues(for: command)) else {
            toast.show("“\(command.name)”: the address could not be built from those words.", isError: true)
            return
        }
        toast.show("Calling \(command.host ?? command.name)…")
        AuditLog.shared.record(.network, "API command “\(command.name)”: \(command.method.rawValue) \(command.host ?? "?")")
        Task {
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    await MainActor.run { toast.show("“\(command.name)” answered \(status).", isError: true) }
                    return
                }
                guard data.count <= APICommand.maxResponseBytes else {
                    await MainActor.run { toast.show("“\(command.name)”: the answer is too big to use.", isError: true) }
                    return
                }
                guard let text = JSONResult.extract(data, path: command.resultPath) else {
                    await MainActor.run { toast.show("“\(command.name)”: the answer has no “\(command.resultPath)”.", isError: true) }
                    return
                }
                await MainActor.run { deliver(text, for: command, toast: toast) }
            } catch {
                await MainActor.run { toast.show("“\(command.name)” failed: \(error.localizedDescription)", isError: true) }
            }
        }
    }

    @MainActor
    private static func deliver(_ text: String, for command: APICommand, toast: Toast) {
        switch command.output {
        case .message:
            toast.show(text.count > 300 ? String(text.prefix(300)) + "…" : text)
        case .clipboard:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            toast.show("Copied the answer")
        case .open:
            if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https" || url.scheme == "http" {
                NSWorkspace.shared.open(url)
            } else {
                toast.show("The answer is not a web address.", isError: true)
            }
        }
    }
}

/// The open tabs of the browsers that are running, asked for with AppleScript and kept for a few seconds. Only browsers that
/// are already running are asked, and only when the person turned tab search on. The first ask makes macOS ask permission.
final class BrowserTabIndex {
    private let queue = DispatchQueue(label: "app.kriya.tabs", qos: .userInitiated)
    private var tabs: [BrowserTab] = []
    private var refreshedAt: Date?
    private var refreshing = false
    /// Called on the main thread when new tabs arrived, so the open list can show them.
    var onChange: () -> Void = {}

    /// The tabs found last time; starts a fresh look in the background if that was a while ago.
    func tabs(matching query: String) -> [BrowserTab] {
        if refreshedAt.map({ Date().timeIntervalSince($0) > 4 }) ?? true { refresh() }
        return BrowserTabs.matching(tabs, query: query)
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        queue.async { [self] in
            var found: [BrowserTab] = []
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            for browser in BrowserTab.Browser.allCases where running.contains(browser.bundleID) {
                if let output = Self.runScript(BrowserTabs.listScript(for: browser)) { found += BrowserTabs.parse(output, browser: browser) }
            }
            DispatchQueue.main.async {
                let changed = found != self.tabs
                self.tabs = found
                self.refreshedAt = Date()
                self.refreshing = false
                if changed { self.onChange() }
            }
        }
    }

    func activate(_ tab: BrowserTab) {
        queue.async { _ = Self.runScript(BrowserTabs.activateScript(for: tab)) }
    }

    private static func runScript(_ source: String) -> String? {
        try? ToolRunner.run("/usr/bin/osascript", ["-e", source], timeout: 6)
    }
}
