import Foundation

/// The person's folder rules, kept in the app's preferences.
final class FolderRulesStore: ObservableObject {
    static let maxRules = 40

    @Published private(set) var rules: [FolderRule]
    private let defaults: UserDefaults
    private let key = "folderRules.v1"
    private let folderExists: (String) -> Bool

    init(defaults: UserDefaults = .standard, folderExists: @escaping (String) -> Bool = { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }) {
        self.defaults = defaults
        self.folderExists = folderExists
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

    private func persist() {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: key) }
    }
}
