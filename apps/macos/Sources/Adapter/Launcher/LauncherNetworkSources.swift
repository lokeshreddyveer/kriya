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
            var attempt = 1
            while true {
                var failure: RetryPolicy.Failure = .other
                var message = ""
                do {
                    let (data, response) = try await session.data(for: request)
                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 0
                    if !(200..<300).contains(status) {
                        failure = .status(status, retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
                        message = "“\(command.name)” answered \(status)."
                    } else if data.count > APICommand.maxResponseBytes {
                        await MainActor.run { toast.show("“\(command.name)”: the answer is too big to use.", isError: true) }
                        return
                    } else if let text = JSONResult.extract(data, path: command.resultPath) {
                        await MainActor.run { deliver(text, for: command, toast: toast, raw: data) }
                        return
                    } else {
                        await MainActor.run { toast.show("“\(command.name)”: the answer has no “\(command.resultPath)”.", isError: true) }
                        return
                    }
                } catch {
                    failure = (error as? URLError).map { .urlError($0.errorCode) } ?? .other
                    message = "“\(command.name)” failed: \(error.localizedDescription)"
                }
                if let wait = RetryPolicy.delay(after: failure, attempt: attempt, method: command.method.rawValue) {
                    attempt += 1
                    await MainActor.run { toast.show("“\(command.name)” had a problem; trying again in \(Int(wait)) s (try \(attempt) of \(RetryPolicy.maxAttempts))…") }
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                await MainActor.run { toast.show(message + (attempt > 1 ? " Gave up after \(attempt) tries." : ""), isError: true) }
                return
            }
        }
    }

    /// Shows the answer (cleaned of anything that looks like a key, and cut short) and asks before it is copied or opened.
    @MainActor
    private static func confirmAfterPreview(_ command: APICommand, raw: Data, text: String) -> Bool {
        let preview = ResponsePreview.make(raw)
        let alert = NSAlert()
        alert.messageText = "“\(command.name)” answered"
        alert.informativeText = (preview.redactedCount > 0 ? "\(preview.redactedCount) value\(preview.redactedCount == 1 ? "" : "s") that look like keys are hidden here.\n\n" : "") + preview.text + (preview.truncated ? "\n…" : "")
        alert.addButton(withTitle: command.output == .open ? "Open" : command.output == .clipboard ? "Copy" : "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private static func deliver(_ text: String, for command: APICommand, toast: Toast, raw: Data) {
        if command.previewFirst == true, !confirmAfterPreview(command, raw: raw, text: text) { return }
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


/// Checks that quick links still work: one bounded request each, a few at a time, never opening anything.
final class LinkChecker: ObservableObject {
    static let shared = LinkChecker()
    @Published private(set) var results: [String: LinkHealth] = [:]
    @Published private(set) var running = false

    private final class Redirects: NSObject, URLSessionTaskDelegate {
        var final: URL?
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            final = request.url
            completionHandler(request)
        }
    }

    func check(_ links: [Quicklink]) {
        guard !running, !LocalOnly.isOn else { return }
        running = true
        results = [:]
        Task {
            await withTaskGroup(of: (String, LinkHealth).self) { group in
                var started = 0
                for link in links {
                    // At most four at once.
                    if started >= 4 { if let done = await group.next() { await MainActor.run { self.results[done.0] = done.1 } } }
                    let check = LinkHealth.checkable(template: link.template)
                    guard let url = check.url else {
                        await MainActor.run { self.results[link.id] = LinkHealth(state: .skipped(check.skip ?? ""), milliseconds: 0) }
                        continue
                    }
                    started += 1
                    group.addTask { (link.id, await Self.probe(url)) }
                }
                for await done in group { await MainActor.run { self.results[done.0] = done.1 } }
            }
            await MainActor.run { self.running = false }
        }
    }

    private static func probe(_ url: URL) async -> LinkHealth {
        let redirects = Redirects()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "HEAD"
        let start = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        do {
            var (_, response) = try await URLSession.shared.data(for: request, delegate: redirects)
            // Some sites refuse HEAD; ask once more with GET before calling the link broken.
            if let http = response as? HTTPURLResponse, [403, 405, 501].contains(http.statusCode) {
                request.httpMethod = "GET"
                (_, response) = try await URLSession.shared.data(for: request, delegate: redirects)
            }
            let http = response as? HTTPURLResponse
            return LinkHealth.classify(status: http?.statusCode, error: nil, finalURL: http?.url ?? redirects.final, original: url, milliseconds: ms())
        } catch {
            return LinkHealth.classify(status: nil, error: (error as? URLError)?.localizedDescription ?? error.localizedDescription, finalURL: nil, original: url, milliseconds: ms())
        }
    }
}
