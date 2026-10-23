import AppKit
import CryptoKit

/// What the person approved to run from the launcher: scripts and API commands. Each is approved by its exact content, so
/// changing a script or pointing a command at another address asks again. Kept on this Mac.
final class LauncherApprovals: ObservableObject {
    static let shared = LauncherApprovals()

    struct Approved: Codable, Equatable, Identifiable {
        var fingerprint: String
        var label: String
        var kind: String
        var at: Date
        var id: String { fingerprint }
    }

    @Published private(set) var approved: [Approved]
    /// Asks before the first run of a script or API command. On unless turned off.
    @Published var asksFirst: Bool { didSet { defaults.set(asksFirst, forKey: askKey) } }
    private let defaults: UserDefaults
    private let key = "launcherApprovals.v1"
    private let askKey = "launcherAskBeforeRunning"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        approved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Approved].self, from: $0) } ?? []
        asksFirst = defaults.object(forKey: askKey) as? Bool ?? true
    }

    /// A fingerprint of what would run: the kind and the exact content.
    static func fingerprint(kind: String, content: String) -> String {
        SHA256.hash(data: Data((kind + "\u{0}" + content).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func isApproved(kind: String, content: String) -> Bool {
        !asksFirst || approved.contains { $0.fingerprint == Self.fingerprint(kind: kind, content: content) }
    }

    func approve(kind: String, content: String, label: String, now: Date = Date()) {
        let print = Self.fingerprint(kind: kind, content: content)
        guard !approved.contains(where: { $0.fingerprint == print }) else { return }
        approved.append(Approved(fingerprint: print, label: String(label.prefix(80)), kind: kind, at: now))
        if approved.count > 300 { approved.removeFirst(approved.count - 300) }
        save()
    }

    func revoke(_ fingerprint: String) {
        approved.removeAll { $0.fingerprint == fingerprint }
        save()
    }

    func revokeAll() {
        approved = []
        save()
    }

    /// Asks (once) before something runs for the first time, showing exactly what it will do. Returns whether it may run. Call it on
    /// the main thread.
    @discardableResult
    func ensureApproved(kind: String, label: String, content: String, detail: String) -> Bool {
        if isApproved(kind: kind, content: content) { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow “\(label)” to run?"
        alert.informativeText = detail
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 170))
        text.string = content
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Approve and Run")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        approve(kind: kind, content: content, label: label)
        AuditLog.shared.record(.setting, "Approved launcher \(kind) “\(label)”")
        return true
    }

    private func save() {
        if let data = try? JSONEncoder().encode(approved) { defaults.set(data, forKey: key) }
    }
}
