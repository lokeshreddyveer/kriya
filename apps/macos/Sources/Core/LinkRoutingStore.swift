import Combine
import Foundation

/// One line of the link log.
struct LinkLogEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var original: String
    var final: String
    var source: String?
    var rule: String?
    var outcome: String
    var changes: [String]
}

/// Link routing settings, and a short log of what was done with each link.
final class LinkRoutingStore: ObservableObject {
    @Published private(set) var config = LinkRoutingConfig(
        enabled: false, rules: [], fallback: .open(appId: "com.apple.Safari", profile: nil), stripTracking: true,
        extraTrackingParams: [], expandRedirects: true, askModifier: KeyModifiers.option, logEnabled: true
    )
    @Published private(set) var log: [LinkLogEntry] = []
    @Published var lastError: String?

    private let core: KriyaCore
    private let logFile: URL
    private let lock = NSLock()
    private var snapshot: LinkRoutingConfig?      // guarded by lock, for the code that opens links
    private var pendingSave: DispatchWorkItem?
    private static let maxLog = 200

    init(core: KriyaCore, logFile: URL) {
        self.core = core
        self.logFile = logFile
        reload()
        if let data = try? Data(contentsOf: logFile), let saved = try? JSONDecoder().decode([LinkLogEntry].self, from: data) {
            log = saved
        }
    }

    func reload() {
        do {
            config = try core.linkRoutingConfig()
        } catch {
            Log.error("Links", "Could not load link routing: \(error.userMessage)")
        }
        lock.lock()
        snapshot = config
        lock.unlock()
    }

    var current: LinkRoutingConfig {
        lock.lock()
        defer { lock.unlock() }
        return snapshot ?? config
    }

    func update(_ change: (inout LinkRoutingConfig) -> Void) {
        var next = config
        change(&next)
        do {
            try core.saveLinkRoutingConfig(config: next)
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
        reload()
    }

    func upsert(_ rule: LinkRule) {
        update { config in
            if let index = config.rules.firstIndex(where: { $0.id == rule.id }) {
                config.rules[index] = rule
            } else {
                config.rules.append(rule)
            }
        }
    }

    func delete(_ id: String) { update { $0.rules.removeAll { $0.id == id } } }
    func move(from source: IndexSet, to destination: Int) { update { $0.rules.move(fromOffsets: source, toOffset: destination) } }

    func newRule() -> LinkRule {
        LinkRule(
            id: UUID().uuidString, name: "", enabled: true, matchKind: .domain, pattern: "", sourceAppIds: [], modifiers: 0,
            target: .open(appId: "", profile: nil)
        )
    }

    // MARK: The log

    func record(_ entry: LinkLogEntry) {
        guard current.logEnabled else { return }
        DispatchQueue.main.async { [self] in
            log.insert(entry, at: 0)
            if log.count > Self.maxLog { log.removeLast(log.count - Self.maxLog) }
            scheduleSave()
        }
    }

    func clearLog() {
        log.removeAll()
        scheduleSave()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let data = try? JSONEncoder().encode(self.log) else { return }
            try? data.write(to: self.logFile, options: .atomic)
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
