import Foundation

/// Whether macOS's Spotlight still owns ⌘Space. Until it lets go, a shortcut of Kriya's on the same keys never fires, because
/// the system answers first. Spotlight's own setting is read from macOS's list of system shortcuts (number 64).
enum SpotlightShortcut {
    static let symbolicID = "64"
    static let finderSearchID = "65"

    /// `table` is the "AppleSymbolicHotKeys" dictionary. A shortcut missing from it has never been changed, so it is on.
    static func isEnabled(_ id: String = symbolicID, in table: [String: Any]?) -> Bool {
        guard let entry = table?[id] as? [String: Any] else { return true }
        if let enabled = entry["enabled"] as? Bool { return enabled }
        if let enabled = entry["enabled"] as? Int { return enabled != 0 }
        return true
    }

    /// Whether Spotlight's ⌘Space is on right now.
    static func currentlyEnabled() -> Bool {
        let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys")
        return isEnabled(in: defaults?.dictionary(forKey: "AppleSymbolicHotKeys"))
    }

    /// Where Spotlight's shortcut is turned off: System Settings › Keyboard › Keyboard Shortcuts.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
}
