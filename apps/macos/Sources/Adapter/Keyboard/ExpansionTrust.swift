import Foundation

/// Apps where text expansion may run even though Kriya cannot look at the focused field (the app does not answer Accessibility
/// questions). Everywhere else, a field that cannot be checked gets no expansion. Also remembers the last app where that happened, so
/// the pane can offer to allow it.
final class ExpansionTrust: ObservableObject {
    static let shared = ExpansionTrust()
    private static let key = "keyboard.expansionTrusted.v1"

    @Published private(set) var trusted: [String]
    /// The app where the last expansion was skipped because its field could not be checked.
    @Published private(set) var lastSkipped: String?
    private let lock = NSLock()
    private var trustedSet: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: Self.key) ?? []
        trusted = saved
        trustedSet = Set(saved)
    }

    /// Safe to ask from the event tap's thread.
    func isTrusted(_ appID: String?) -> Bool {
        guard let appID else { return false }
        lock.lock()
        defer { lock.unlock() }
        return trustedSet.contains(appID)
    }

    func setTrusted(_ appID: String, _ on: Bool) {
        lock.lock()
        if on { trustedSet.insert(appID) } else { trustedSet.remove(appID) }
        let list = trustedSet.sorted()
        lock.unlock()
        defaults.set(list, forKey: Self.key)
        DispatchQueue.main.async { [weak self] in
            self?.trusted = list
            if on, self?.lastSkipped == appID { self?.lastSkipped = nil }
        }
    }

    func noteSkipped(_ appID: String?) {
        DispatchQueue.main.async { [weak self] in self?.lastSkipped = appID }
    }

    func clearSkipped() { DispatchQueue.main.async { [weak self] in self?.lastSkipped = nil } }
}
