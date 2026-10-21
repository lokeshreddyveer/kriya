import AppKit
import Combine

/// App profiles. The core stores them and decides which features are off for an app; this class keeps the list for the
/// interface and follows the app in front. `isFeatureActive` is safe to call from the event tap's thread.
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    /// The bundle id of the app in front, ignoring Kriya itself so its own windows do not change the active profile.
    @Published private(set) var frontmostAppID: String?

    private let core: KriyaCore
    private let lock = NSLock()
    private var disabledNow: Set<FeatureId> = []   // guarded by lock
    private var observer: NSObjectProtocol?

    init(core: KriyaCore) {
        self.core = core
        reload()
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func start() {
        guard observer == nil else { return }
        setFrontmost(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.setFrontmost(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    var defaultProfile: Profile? { profiles.first { $0.isDefault } }
    var appProfiles: [Profile] { profiles.filter { !$0.isDefault } }

    /// The profile in effect for the app in front.
    var activeProfile: Profile? {
        if let id = frontmostAppID,
           let match = profiles.first(where: { !$0.isDefault && $0.isEnabled && $0.appId == id }) {
            return match
        }
        return defaultProfile
    }

    /// Whether a feature should act right now, given the app in front. Cheap and thread-safe.
    func isFeatureActive(_ feature: FeatureId) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !disabledNow.contains(feature)
    }

    func reload() {
        do {
            profiles = try core.profiles()
        } catch {
            Log.error("Profiles", "Could not load profiles: \(error.userMessage)")
        }
        recompute()
    }

    // MARK: Editing

    func addProfile(forApplicationAt url: URL) throws {
        guard let bundle = Bundle(url: url), let appID = bundle.bundleIdentifier else {
            throw CoreError.Invalid(message: "That is not an app Kriya can recognise.")
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let profile = Profile(
            id: UUID().uuidString,
            name: name,
            appId: appID,
            isDefault: false,
            isEnabled: true,
            featureOverrides: [],
            sortOrder: Int64(appProfiles.count + 1)
        )
        try save(profile)
    }

    func save(_ profile: Profile) throws {
        try core.saveProfile(profile: profile)
        reload()
    }

    func delete(_ profile: Profile) throws {
        try core.deleteProfile(id: profile.id)
        reload()
    }

    /// Sets a feature to on, off, or (with `nil`) back to inheriting from the default profile.
    func setOverride(_ feature: FeatureId, to value: Bool?, in profile: Profile) {
        var updated = profile
        updated.featureOverrides.removeAll { $0.feature == feature }
        if let value { updated.featureOverrides.append(FeatureOverride(feature: feature, enabled: value)) }
        do {
            try save(updated)
        } catch {
            Log.error("Profiles", "Could not save profile: \(error.userMessage)")
        }
    }

    // MARK: Following the front app

    private func setFrontmost(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        frontmostAppID = app.bundleIdentifier
        recompute()
    }

    private func recompute() {
        let off = Set(disabledFeatures(profiles: profiles, appId: frontmostAppID))
        lock.lock()
        disabledNow = off
        lock.unlock()
    }
}
