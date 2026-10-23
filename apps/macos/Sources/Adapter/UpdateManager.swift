import Combine
import Foundation
import Sparkle

/// Automatic updates through Sparkle. Updates are signed with a key only the publisher holds; the matching public key is
/// set at build time (`SPARKLE_PUBLIC_KEY`). Until it is set the updater stays off, so a build without a key never
/// shows a confusing error.
final class UpdateManager: ObservableObject {
    @Published private(set) var isConfigured: Bool
    @Published private(set) var lastChecked: Date?
    /// Kriya's own updates are downloaded and installed without asking, once they are checked as signed. On unless turned off.
    @Published var installAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(installAutomatically, forKey: Self.installKey)
            controller?.updater.automaticallyDownloadsUpdates = installAutomatically
        }
    }

    private static let installKey = "installKriyaUpdatesAutomatically"
    private var controller: SPUStandardUpdaterController?
    private var cancellable: AnyCancellable?

    init(config: ConfigStore) {
        installAutomatically = UserDefaults.standard.object(forKey: Self.installKey) as? Bool ?? true
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = !key.trimmingCharacters(in: .whitespaces).isEmpty
        guard isConfigured else {
            Log.info("Updates", "No update signing key in this build; the updater is off")
            return
        }
        // In local-only mode the updater is created but not started, so it makes no request.
        let controller = SPUStandardUpdaterController(startingUpdater: !LocalOnly.isOn, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = config.settings.automaticallyCheckForUpdates && !LocalOnly.isOn
        controller.updater.automaticallyDownloadsUpdates = installAutomatically
        controller.updater.updateCheckInterval = 3600
        self.controller = controller
        // Sparkle does the scheduling: it checks when it starts if one is due, and then every `updateCheckInterval`. Kriya adds no
        // timer of its own, so a check is never done twice.
        lastChecked = controller.updater.lastUpdateCheckDate
        cancellable = config.$settings
            .map(\.automaticallyCheckForUpdates)
            .removeDuplicates()
            .sink { [weak controller] on in controller?.updater.automaticallyChecksForUpdates = on && !LocalOnly.isOn }
        localOnlySub = NotificationCenter.default.publisher(for: LocalOnly.changed).sink { [weak self, weak controller] _ in
            guard let controller else { return }
            if LocalOnly.isOn {
                controller.updater.automaticallyChecksForUpdates = false
            } else {
                controller.startUpdater()
                controller.updater.automaticallyChecksForUpdates = config.settings.automaticallyCheckForUpdates
            }
            self?.objectWillChange.send()
        }
    }

    private var localOnlySub: AnyCancellable?

    /// When Sparkle last finished looking, which is what "last looked" shows. A failed look does not count.
    func refreshLastChecked() {
        lastChecked = controller?.updater.lastUpdateCheckDate
    }

}
