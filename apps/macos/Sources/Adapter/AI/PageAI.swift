import AppKit

/// Which sites the person let Kriya send to an AI provider, and which it must never. Hostnames only.
final class PageAIPermissions: ObservableObject {
    static let shared = PageAIPermissions()
    private static let allowedKey = "pageAI.allowedHosts"
    private static let blockedKey = "pageAI.blockedHosts"

    @Published private(set) var allowed: Set<String>
    @Published private(set) var blocked: Set<String>

    private init() {
        allowed = Set(UserDefaults.standard.stringArray(forKey: Self.allowedKey) ?? [])
        blocked = Set(UserDefaults.standard.stringArray(forKey: Self.blockedKey) ?? [])
    }

    func allow(_ host: String) { allowed.insert(host); blocked.remove(host); save() }
    func block(_ host: String) { blocked.insert(host); allowed.remove(host); save() }
    func forget(_ host: String) { allowed.remove(host); blocked.remove(host); save() }
    func clear() { allowed = []; blocked = []; save() }

    private func save() {
        UserDefaults.standard.set(allowed.sorted(), forKey: Self.allowedKey)
        UserDefaults.standard.set(blocked.sorted(), forKey: Self.blockedKey)
    }
}

/// Summaries and questions about a page the person chose to send from their browser. The page is read in the browser, from the tab
/// they chose it in; whether its text may go to an AI provider is decided here, per site.
enum PageAI {
    static func run(_ action: PageAction, on clip: PageClip) {
        let gateway = AIGateway.shared
        guard let config = gateway.resolve(feature: .browser), let url = URL(string: clip.url) else {
            Toast().show("No AI provider is switched on for browser pages. Switch one on in Apple Intelligence settings.", isError: true)
            return
        }
        let permissions = PageAIPermissions.shared
        let decision = PageAIPolicy.decide(url: url, isPrivateWindow: clip.isPrivate == true, providerIsOnThisMac: config.isOnThisMac, allowedHosts: permissions.allowed, blockedHosts: permissions.blocked)
        let host = url.host?.lowercased() ?? ""
        switch decision {
        case .refuse(let reason):
            Toast().show(reason, isError: true)
            return
        case .askFirst(let reason):
            let sensitive = PageAIPolicy.looksSensitive(url: url) || PageAIPolicy.isInternal(host: host)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Send this page to \(config.name)?"
            alert.informativeText = "\(reason)\n\nThe page's text (with secrets hidden) would be sent to \(config.name)\(config.isOnThisMac ? " on this Mac" : ", which is not on this Mac"). Page: \(host)"
            alert.addButton(withTitle: "Send Once")
            if !sensitive { alert.addButton(withTitle: "Always Allow \(host)") }
            alert.addButton(withTitle: "Never for \(host)")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            let result = alert.runModal()
            let always = !sensitive && result == .alertSecondButtonReturn
            let never = result == (sensitive ? .alertSecondButtonReturn : .alertThirdButtonReturn)
            if never { permissions.block(host); return }
            if always { permissions.allow(host) }
            guard result == .alertFirstButtonReturn || always else { return }
        case .allow:
            break
        }
        var question = "Summarize this page in at most six short bullet points, then say what kind of page it is."
        if action == .ask {
            let alert = NSAlert()
            alert.messageText = "Ask about “\(clip.title.prefix(60))”"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            field.placeholderString = "Your question"
            alert.accessoryView = field
            alert.addButton(withTitle: "Ask")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            question = String(field.stringValue.prefix(400))
        }
        let toast = Toast()
        toast.show("Thinking…")
        FeatureActivity.shared.used("aiProviders")
        Task {
            do {
                let item = AIContextItem(source: .browserPage, title: clip.title, text: String(clip.markdown.prefix(20_000)), permission: .userAction, sensitivity: .normal, age: 0, citation: clip.url)
                let out = try await AIRun.ask(feature: .browser, system: "You answer questions about a web page the user is reading. Use only the page. If the page does not say, say so. Cite nothing outside the page.", items: [item], question: question, maxTokens: 700)
                let warning = out.context?.suspectedInjection == true ? "\n\n⚠ This page contains wording that looks like instructions to an AI. It was treated as page text only." : ""
                AIResultWindow.shared.show(title: clip.title.isEmpty ? "Page" : String(clip.title.prefix(60)), text: out.text + warning + "\n\n— \(out.provider.name) · \(host)")
            } catch { AIRun.toast(error) }
        }
    }
}
