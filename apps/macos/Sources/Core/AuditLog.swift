import Foundation

/// A plain record of the things Kriya did that reach outside itself: network requests, scripts and commands run, files changed
/// by rules, installs and backups. It keeps what happened and where, never the words typed, file contents or keys.
final class AuditLog: ObservableObject {
    static let shared = AuditLog()

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case network, script, files, install, backup, setting
        var id: String { rawValue }
        var title: String {
            switch self {
            case .network: return "Network"
            case .script: return "Scripts and commands"
            case .files: return "Files"
            case .install: return "Installs"
            case .backup: return "Backups"
            case .setting: return "Settings"
            }
        }
        var symbol: String {
            switch self {
            case .network: return "network"
            case .script: return "terminal"
            case .files: return "doc.on.doc"
            case .install: return "shippingbox"
            case .backup: return "externaldrive"
            case .setting: return "switch.2"
            }
        }
    }

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID().uuidString
        var kind: Kind
        var summary: String
        var at: Date
    }

    static let capacity = 400

    @Published private(set) var entries: [Entry] = []
    private let defaults: UserDefaults
    private let key = "auditLog.v1"
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    /// Notes something. Safe from any thread. The summary is cut short, so a long line cannot carry much.
    func record(_ kind: Kind, _ summary: String, at date: Date = Date()) {
        let text = String(summary.replacingOccurrences(of: "\n", with: " ").prefix(160))
        lock.lock()
        var next = entries
        next.insert(Entry(kind: kind, summary: text, at: date), at: 0)
        if next.count > Self.capacity { next.removeLast(next.count - Self.capacity) }
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: key) }
        lock.unlock()
        if Thread.isMainThread { entries = next } else { DispatchQueue.main.async { self.entries = next } }
    }

    func clear() {
        lock.lock()
        defaults.removeObject(forKey: key)
        lock.unlock()
        if Thread.isMainThread { entries = [] } else { DispatchQueue.main.async { self.entries = [] } }
    }

    /// The entries of these kinds (all when none are named), newest first, as plain text for copying.
    func text(kinds: Set<Kind> = []) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return entries.filter { kinds.isEmpty || kinds.contains($0.kind) }
            .map { "\(formatter.string(from: $0.at))  [\($0.kind.title)]  \($0.summary)" }.joined(separator: "\n")
    }
}
