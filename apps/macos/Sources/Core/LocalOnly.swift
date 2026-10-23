import Foundation

/// One switch that keeps Kriya itself off the network. While it is on, Kriya makes no requests of its own: no update checks,
/// currency rates, API commands, iCloud backup or Homebrew lookups. Opening a web address in your browser is still your browser's
/// doing, and Homebrew is only run when you ask for an install.
enum LocalOnly {
    static let key = "localOnlyMode"
    static let changed = Notification.Name("app.kriya.localOnlyChanged")

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            guard newValue != isOn else { return }
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
            AuditLog.shared.record(.setting, newValue ? "Local-only mode turned on" : "Local-only mode turned off")
        }
    }

    static let blockedMessage = "Local-only mode is on, so Kriya makes no network requests. Turn it off in General."

    /// What it stops, for the settings text.
    static let stopped = ["Update checks for Kriya", "Update checks for your apps (feeds and Homebrew)", "Currency rates in the launcher", "API commands", "iCloud Drive backup", "Searching and installing Homebrew apps"]
}
