import Combine
import Foundation
import Sparkle

/// Automatic updates through Sparkle. Updates are signed with a key only the publisher holds; the matching public key is
/// set at build time (`SPARKLE_PUBLIC_KEY`). Until it is set the updater stays off, so a build without a key never
/// shows a confusing error.
final class UpdateManager: ObservableObject {
    @Published private(set) var isConfigured: Bool
    private var controller: SPUStandardUpdaterController?
    private var cancellable: AnyCancellable?

    init(config: ConfigStore) {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = !key.trimmingCharacters(in: .whitespaces).isEmpty
        guard isConfigured else {
            Log.info("Updates", "No update signing key in this build; the updater is off")
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = config.settings.automaticallyCheckForUpdates
        self.controller = controller
        cancellable = config.$settings
            .map(\.automaticallyCheckForUpdates)
            .removeDuplicates()
            .sink { [weak controller] on in controller?.updater.automaticallyChecksForUpdates = on }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
