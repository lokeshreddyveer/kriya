import Foundation

/// The person's folder rules, kept in the app's preferences.
final class FolderRulesStore: ObservableObject {
    static let maxRules = 40

    @Published private(set) var rules: [FolderRule]
    /// Pauses every rule at once without switching each off.
    @Published var paused: Bool { didSet { defaults.set(paused, forKey: "folderRules.paused") } }
    private let defaults: UserDefaults
    private let key = "folderRules.v1"
    private let folderExists: (String) -> Bool

    init(defaults: UserDefaults = .standard, folderExists: @escaping (String) -> Bool = { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }) {
        self.defaults = defaults
        self.folderExists = folderExists
        paused = defaults.bool(forKey: "folderRules.paused")
        rules = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([FolderRule].self, from: $0) } ?? []
    }

    /// Saves a rule (new or changed). A rule that is not safe is refused, and the reason is returned. A changed rule is switched
    /// off again, so a new condition is never acted on before it has been previewed.
    @discardableResult
    func save(_ rule: FolderRule) -> String? {
        if let problem = FolderRuleEngine.problem(for: rule, folderExists: folderExists) { return problem }
        var saved = rule
        saved.name = rule.name.trimmingCharacters(in: .whitespaces)
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            // Only a change to what the rule does switches it off; a new name or switch position does not.
            var before = rules[index]
            before.enabled = saved.enabled
            before.name = saved.name
            if before != saved { saved.enabled = false }
            rules[index] = saved
        } else {
            guard rules.count < Self.maxRules else { return "That is as many rules as can be kept." }
            saved.enabled = false
            rules.append(saved)
        }
        persist()
        return nil
    }

    /// Switches a rule on or off. A rule with a problem (its folder was deleted) cannot be switched on.
    @discardableResult
    func setEnabled(_ id: String, _ on: Bool) -> String? {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return nil }
        if on, let problem = FolderRuleEngine.problem(for: rules[index], folderExists: folderExists) { return problem }
        rules[index].enabled = on
        persist()
        return nil
    }

    func delete(_ id: String) {
        rules.removeAll { $0.id == id }
        persist()
    }

    /// The rules as a file to keep or share.
    func exported() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(rules.map { var r = $0; r.enabled = false; return r })
    }

    /// Adds rules from a file. They come in switched off with new ids, and any that is not safe here (its folder is missing, or
    /// it names a system folder) is left out. Returns how many were added and how many were skipped.
    @discardableResult
    func importRules(_ data: Data) -> (added: Int, skipped: Int)? {
        guard let incoming = try? JSONDecoder().decode([FolderRule].self, from: data) else { return nil }
        var added = 0, skipped = 0
        for var rule in incoming.prefix(Self.maxRules) {
            rule.id = UUID().uuidString
            rule.enabled = false
            if save(rule) == nil { added += 1 } else { skipped += 1 }
        }
        return (added, skipped + max(incoming.count - Self.maxRules, 0))
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: key) }
    }
}
