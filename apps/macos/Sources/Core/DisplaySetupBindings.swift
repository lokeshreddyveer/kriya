import Foundation

/// Which saved layout comes back by itself when a particular set of displays is connected: "laptop on its own" gets one,
/// "docked with two monitors" another. Kept by the display set's key, so it is the same whatever order they connect in.
struct DisplaySetupBindings {
    private let defaults: UserDefaults
    private let key = "displaySetupBindings.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var map: [String: String] {
        get { defaults.dictionary(forKey: key) as? [String: String] ?? [:] }
        nonmutating set { defaults.set(newValue, forKey: key) }
    }

    func layoutID(forSetup setKey: String) -> String? { map[setKey] }

    func isBound(layout id: String, to setKey: String) -> Bool { map[setKey] == id }

    /// Binds the layout to the setup (replacing any other for that setup), or clears it if it was already bound.
    func toggle(layout id: String, setup setKey: String) {
        var m = map
        if m[setKey] == id { m[setKey] = nil } else { m[setKey] = id }
        map = m
    }

    /// Forgets bindings to layouts that no longer exist.
    func prune(existing ids: Set<String>) {
        map = map.filter { ids.contains($0.value) }
    }
}
