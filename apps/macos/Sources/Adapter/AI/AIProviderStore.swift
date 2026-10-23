import AppKit
import LocalAuthentication

/// The AI providers the person set up, which one each part of Kriya uses, and the keys. Settings are saved in preferences;
/// keys only in the Keychain, never in preferences, backups, exports, logs or reports.
final class AIProviderStore: ObservableObject {
    static let shared = AIProviderStore()
    static let appleID = "apple"
    private static let key = "ai.settings.v1"

    private struct File: Codable {
        var providers: [AIProviderConfig]
        var featureProvider: [String: String]
        var toolSettings: AIToolSettings
        var fallbackOnDevice: Bool
        var redactPersonal: Bool
        var embeddingProviderID: String?
        var allowCloudEmbeddings: Bool
    }

    @Published var providers: [AIProviderConfig] { didSet { save() } }
    /// Which provider a feature uses, by the feature's name. A feature without one uses the first provider that is switched on for it.
    @Published var featureProvider: [String: String] { didSet { save() } }
    @Published var toolSettings: AIToolSettings { didSet { save() } }
    /// If a provider cannot be reached, try the on-device model instead (only for requests without tools).
    @Published var fallbackOnDevice: Bool { didSet { save() } }
    @Published var redactPersonal: Bool { didSet { save() } }
    @Published var embeddingProviderID: String? { didSet { save() } }
    @Published var allowCloudEmbeddings: Bool { didSet { save() } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let file = try? JSONDecoder().decode(File.self, from: data) {
            providers = file.providers
            featureProvider = file.featureProvider
            toolSettings = file.toolSettings
            fallbackOnDevice = file.fallbackOnDevice
            redactPersonal = file.redactPersonal
            embeddingProviderID = file.embeddingProviderID
            allowCloudEmbeddings = file.allowCloudEmbeddings
        } else {
            providers = []
            featureProvider = [:]
            toolSettings = AIToolSettings()
            fallbackOnDevice = true
            redactPersonal = false
            embeddingProviderID = nil
            allowCloudEmbeddings = false
        }
        if !providers.contains(where: { $0.id == Self.appleID }) {
            providers.insert(AIProviderConfig(id: Self.appleID, name: "Apple Intelligence", kind: .appleIntelligence, enabledFeatures: Set(AIFeature.allCases)), at: 0)
        }
    }

    private func save() {
        let file = File(providers: providers, featureProvider: featureProvider, toolSettings: toolSettings, fallbackOnDevice: fallbackOnDevice,
                        redactPersonal: redactPersonal, embeddingProviderID: embeddingProviderID, allowCloudEmbeddings: allowCloudEmbeddings)
        if let data = try? JSONEncoder().encode(file) { defaults.set(data, forKey: Self.key) }
    }

    func config(_ id: String) -> AIProviderConfig? { providers.first { $0.id == id } }

    /// The provider a feature should use: the one chosen, else the first switched on for it (Apple Intelligence first).
    func provider(for feature: AIFeature) -> AIProviderConfig? {
        if let id = featureProvider[feature.rawValue], let chosen = config(id), chosen.enabled, chosen.enabledFeatures.contains(feature) { return chosen }
        return providers.first { $0.enabled && $0.enabledFeatures.contains(feature) }
    }

    func update(_ config: AIProviderConfig) {
        if let index = providers.firstIndex(where: { $0.id == config.id }) { providers[index] = config } else { providers.append(config) }
    }

    // MARK: Keys

    func key(for config: AIProviderConfig) -> String? { KeychainSecrets.get(config.keyAccount) }
    func hasKey(_ config: AIProviderConfig) -> Bool { key(for: config) != nil }

    @discardableResult
    func saveKey(_ key: String, for config: AIProviderConfig) -> Bool {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 400, !clean.contains("\n") else { return false }
        let ok = KeychainSecrets.set(clean, for: config.keyAccount)
        if ok { AuditLog.shared.record(.setting, "AI key saved for \(config.name)") }
        objectWillChange.send()
        return ok
    }

    func revokeKey(_ config: AIProviderConfig) {
        KeychainSecrets.delete(config.keyAccount)
        AuditLog.shared.record(.setting, "AI key removed for \(config.name)")
        objectWillChange.send()
    }

    /// Removes the provider, its key and what it was chosen for.
    func forget(_ config: AIProviderConfig) {
        guard config.id != Self.appleID else { return }
        revokeKey(config)
        providers.removeAll { $0.id == config.id }
        featureProvider = featureProvider.filter { $0.value != config.id }
        if embeddingProviderID == config.id { embeddingProviderID = nil }
    }

    /// Every AI key Kriya holds, including the fixed ones for OpenAI, Anthropic and Gemini.
    func deleteAllCredentials() {
        for kind in [AIProviderKind.openAI, .anthropic, .gemini] { KeychainSecrets.delete(AIProviderConfig(name: "", kind: kind).keyAccount) }
        for config in providers { KeychainSecrets.delete(config.keyAccount) }
        AuditLog.shared.record(.setting, "All AI keys deleted")
        objectWillChange.send()
    }

    /// The key, shown only after the person proves it is them (Touch ID or the Mac's password).
    func reveal(_ config: AIProviderConfig, completion: @escaping (String?) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { completion(nil); return }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show the API key for \(config.name)") { ok, _ in
            DispatchQueue.main.async { completion(ok ? self.key(for: config) : nil) }
        }
    }

    // MARK: Export

    func exportSettings() throws -> Data { try AIProviderExport.data(providers.filter { $0.id != Self.appleID }) }

    func importSettings(_ data: Data) -> Int {
        guard let list = AIProviderExport.configs(from: data) else { return 0 }
        var added = 0
        for var config in list where config.id != Self.appleID {
            if providers.contains(where: { $0.id == config.id }) { config.id = UUID().uuidString }
            providers.append(config)
            added += 1
        }
        return added
    }
}
