import AppKit
import Combine

/// The one place settings live. Views bind to `settings`; every change is saved through the core and applied
/// (appearance, Dock icon, log level) here, so nothing else needs to remember to.
final class ConfigStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            persist()
            apply(previous: oldValue)
        }
    }

    private let core: KriyaCore

    init(core: KriyaCore) {
        self.core = core
        settings = (try? core.settings()) ?? AppSettings.defaults
    }

    func isEnabled(_ feature: FeatureId) -> Bool {
        settings.enabledFeatures.contains(feature)
    }

    func setEnabled(_ feature: FeatureId, _ enabled: Bool) {
        var features = settings.enabledFeatures.filter { $0 != feature }
        if enabled { features.append(feature) }
        settings.enabledFeatures = features
    }

    /// Re-reads the saved settings, after a restore.
    func reload() {
        if let saved = try? core.settings() { settings = saved }
        apply(previous: nil)
    }

    private func persist() {
        do {
            try core.saveSettings(settings: settings)
        } catch {
            Log.error("Config", "Could not save settings: \(error.userMessage)")
        }
    }

    /// Applies what the settings describe to the running app.
    func apply(previous: AppSettings?) {
        if previous?.appearance != settings.appearance { applyAppearance() }
        if previous?.logLevel != settings.logLevel { Log.shared.setLevel(settings.logLevel) }
        if previous?.showAppIcon != settings.showAppIcon { applyActivationPolicy() }
    }

    func applyAppearance() {
        switch settings.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// With no Dock icon the app lives in the menu bar. While the settings window is open it still needs a Dock
    /// icon so the window can be reached with Cmd-Tab; `forWindowOpen` covers that.
    func applyActivationPolicy(forWindowOpen: Bool = false) {
        NSApp.setActivationPolicy(settings.showAppIcon || forWindowOpen ? .regular : .accessory)
    }
}
