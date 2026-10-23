import AppKit

/// One entry in the AI activity history. It records that a request happened and how big it was, never what was in it.
struct AIActivity: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var at: Date
    var feature: String
    var provider: String
    var model: String
    var inputCharacters: Int
    var outputCharacters: Int
    var tokens: Int
    var secretsHidden: Int
    var status: String
    var note: String?
}

/// Every AI feature goes through this and nothing else reaches a provider. It checks the rules (provider switched on for the
/// feature, local-only mode, size, rate, daily budget), sends the request, limits the answer, and writes a redacted history entry.
final class AIGateway: ObservableObject {
    static let shared = AIGateway(store: .shared)
    private static let historyKey = "ai.activity.v1"
    private static let ledgerKey = "ai.ledger.v1"
    static let historyLimit = 200

    let store: AIProviderStore
    var transport: HTTPTransport
    var appleModel: TextModel = SystemTextModel()
    private let defaults: UserDefaults

    @Published private(set) var history: [AIActivity]
    @Published private(set) var inFlight = 0
    private var ledger: AIUsageLedger
    private var limiter = AIRateLimiter()
    private let lock = NSLock()

    init(store: AIProviderStore, transport: HTTPTransport = URLSessionTransport.shared, defaults: UserDefaults = .standard) {
        self.store = store
        self.transport = transport
        self.defaults = defaults
        history = defaults.data(forKey: Self.historyKey).flatMap { try? JSONDecoder().decode([AIActivity].self, from: $0) } ?? []
        ledger = defaults.data(forKey: Self.ledgerKey).flatMap { try? JSONDecoder().decode(AIUsageLedger.self, from: $0) } ?? AIUsageLedger()
    }

    func provider(for config: AIProviderConfig) -> AIProvider {
        if config.kind == .appleIntelligence { return AppleProvider(model: appleModel) }
        let store = self.store
        return HTTPProvider(config: config, wire: AIWires.wire(for: config.kind) ?? OpenAIWire(kind: .openAICompatible), transport: transport, key: { store.key(for: config) })
    }

    /// The provider to use, and whether it is allowed to be used for this feature right now. Nil if there is none.
    func resolve(feature: AIFeature, providerID: String? = nil) -> AIProviderConfig? {
        if let providerID { return store.config(providerID) }
        return store.provider(for: feature)
    }

    func usageToday(_ providerID: String) -> AIUsageLedger.Day { ledger.today(providerID) }

    /// Whether anything is set up to answer for this feature.
    func isAvailable(for feature: AIFeature) -> Bool {
        guard let config = resolve(feature: feature) else { return false }
        if config.kind == .appleIntelligence { return appleModel.availability().isAvailable }
        return config.problems.isEmpty && (!config.kind.needsKey || store.hasKey(config))
    }

    // MARK: Models and tests

    func models(for config: AIProviderConfig) async throws -> [AIModel] {
        try preflightNoContent(config)
        return try await provider(for: config).models()
    }

    /// A small real request, to show the key and address work. Sends the word "ping" and nothing else.
    func testConnection(_ config: AIProviderConfig) async -> Result<String, AIError> {
        do {
            try preflightNoContent(config)
            if config.kind == .appleIntelligence { return appleModel.availability().isAvailable ? .success("Apple Intelligence is ready.") : .failure(.notConfigured(appleModel.availability().title)) }
            let models = try await provider(for: config).models()
            return .success("Connected. \(models.count) model\(models.count == 1 ? "" : "s") available.")
        } catch { return .failure(AIErrorMapper.map(error)) }
    }

    private func preflightNoContent(_ config: AIProviderConfig) throws {
        if !config.problems.isEmpty { throw AIError.notConfigured(config.problems[0]) }
        if LocalOnly.isOn && !config.isOnThisMac { throw AIError.blockedByLocalOnly }
    }

    // MARK: Generating

    func generate(feature: AIFeature, providerID: String? = nil, _ request: AIRequest, secretsHidden: Int = 0) async throws -> AIResponse {
        guard let config = resolve(feature: feature, providerID: providerID) else { throw AIError.notConfigured("no provider is switched on for \(feature.title)") }
        do {
            return try await run(config, feature, request, secretsHidden: secretsHidden)
        } catch let error as AIError where error == .offline || error == .timeout {
            // The provider could not be reached. The on-device model is tried instead when the person allowed that and nothing
            // in the request needs a tool or a schema.
            guard store.fallbackOnDevice, config.kind != .appleIntelligence, request.tools.isEmpty, request.responseSchema == nil,
                  let apple = store.config(AIProviderStore.appleID), apple.enabled, apple.enabledFeatures.contains(feature) else { throw error }
            var fallback = request
            fallback.model = ""
            return try await run(apple, feature, fallback, secretsHidden: secretsHidden, note: "\(config.name) could not be reached; answered on this Mac")
        }
    }

    private func run(_ config: AIProviderConfig, _ feature: AIFeature, _ request: AIRequest, secretsHidden: Int, note: String? = nil) async throws -> AIResponse {
        var prepared = request
        if prepared.model.isEmpty { prepared.model = config.model }
        prepared.maxTokens = min(prepared.maxTokens, config.maxTokens)
        prepared.timeout = min(prepared.timeout, config.timeout)
        if !config.supportsTools && config.kind != .appleIntelligence { prepared.tools = [] }
        try admit(config, feature, prepared)
        await MainActor.run { inFlight += 1 }
        defer { Task { @MainActor in self.inFlight = max(0, self.inFlight - 1) } }
        do {
            var response = try await provider(for: config).generate(prepared)
            if response.text.count > AIPolicy.maxOutputCharacters { response.text = String(response.text.prefix(AIPolicy.maxOutputCharacters)) }
            finish(config, feature, prepared, response: response, status: "ok", secretsHidden: secretsHidden, note: note)
            return response
        } catch {
            let mapped = AIErrorMapper.map(error)
            finish(config, feature, prepared, response: nil, status: String((mapped.errorDescription ?? "error").prefix(120)), secretsHidden: secretsHidden, note: note)
            // The on-device model's own errors keep their kind, which the callers use to decide whether to try again with less text.
            if error is IntelligenceError { throw error }
            throw mapped
        }
    }

    func stream(feature: AIFeature, providerID: String? = nil, _ request: AIRequest, secretsHidden: Int = 0) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let config = resolve(feature: feature, providerID: providerID) else { continuation.finish(throwing: AIError.notConfigured("no provider is switched on for \(feature.title)")); return }
                var prepared = request
                if prepared.model.isEmpty { prepared.model = config.model }
                prepared.maxTokens = min(prepared.maxTokens, config.maxTokens)
                prepared.timeout = min(prepared.timeout, config.timeout)
                if !config.supportsTools && config.kind != .appleIntelligence { prepared.tools = [] }
                do {
                    try admit(config, feature, prepared)
                    var output = 0
                    var usage: AIUsage?
                    for try await event in provider(for: config).stream(prepared) {
                        if case .text(let t) = event { output += t.count; if output > AIPolicy.maxOutputCharacters { throw AIError.outputTooLarge } }
                        if case .usage(let u) = event { usage = u }
                        continuation.yield(event)
                    }
                    finish(config, feature, prepared, response: AIResponse(text: String(repeating: " ", count: output), usage: usage), status: "ok", secretsHidden: secretsHidden, note: nil)
                    continuation.finish()
                } catch {
                    let mapped = AIErrorMapper.map(error)
                    finish(config, feature, prepared, response: nil, status: String((mapped.errorDescription ?? "error").prefix(120)), secretsHidden: secretsHidden, note: nil)
                    continuation.finish(throwing: mapped)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func embed(feature: AIFeature = .search, providerID: String? = nil, _ request: EmbeddingRequest) async throws -> EmbeddingResponse {
        guard let config = resolve(feature: feature, providerID: providerID ?? store.embeddingProviderID) else { throw AIError.notConfigured("no embedding provider is chosen") }
        if !config.isOnThisMac && !store.allowCloudEmbeddings { throw AIError.providerOffForFeature("embeddings (cloud embeddings are off)") }
        var prepared = request
        if prepared.model.isEmpty { prepared.model = config.embeddingModel }
        if prepared.model.isEmpty && config.kind != .appleIntelligence { throw AIError.notConfigured("choose an embedding model") }
        let size = prepared.inputs.reduce(0) { $0 + $1.count }
        try admit(config, feature, AIRequest(messages: [AIMessage(.user, String(repeating: " ", count: size))]))
        do {
            let response = try await provider(for: config).embed(prepared)
            finish(config, feature, AIRequest(model: prepared.model, messages: []), response: AIResponse(text: "", usage: response.usage), status: "ok", secretsHidden: 0, note: "embeddings: \(prepared.inputs.count) text(s), input \(size) characters", inputOverride: size)
            return response
        } catch {
            let mapped = AIErrorMapper.map(error)
            finish(config, feature, AIRequest(model: prepared.model, messages: []), response: nil, status: String((mapped.errorDescription ?? "error").prefix(120)), secretsHidden: 0, note: "embeddings", inputOverride: size)
            throw mapped
        }
    }

    // MARK: Rules and records

    private func admit(_ config: AIProviderConfig, _ feature: AIFeature, _ request: AIRequest) throws {
        lock.lock(); defer { lock.unlock() }
        let input = AIPolicyInput(config: config, feature: feature, localOnlyMode: LocalOnly.isOn, inputCharacters: request.inputCharacters,
                                  usageToday: ledger.today(config.id), requestsInLastMinute: limiter.count())
        if let refusal = AIPolicy.check(input) { throw refusal }
        limiter.record()
    }

    private func finish(_ config: AIProviderConfig, _ feature: AIFeature, _ request: AIRequest, response: AIResponse?, status: String, secretsHidden: Int, note: String?, inputOverride: Int? = nil) {
        let input = inputOverride ?? request.inputCharacters
        lock.lock()
        ledger.record(provider: config.id, usage: response?.usage, config: config, estimatedInputTokens: AIPolicy.estimateTokens(characters: input))
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: Self.ledgerKey) }
        lock.unlock()
        let entry = AIActivity(at: Date(), feature: feature.title, provider: config.name, model: request.model, inputCharacters: input, outputCharacters: response?.text.count ?? 0,
                               tokens: response?.usage?.total ?? 0, secretsHidden: secretsHidden, status: status, note: note)
        DispatchQueue.main.async {
            self.history.insert(entry, at: 0)
            if self.history.count > Self.historyLimit { self.history.removeLast(self.history.count - Self.historyLimit) }
            if let data = try? JSONEncoder().encode(self.history) { self.defaults.set(data, forKey: Self.historyKey) }
        }
    }

    func deleteHistory() {
        history = []
        defaults.removeObject(forKey: Self.historyKey)
        lock.lock(); ledger.clear(); defaults.removeObject(forKey: Self.ledgerKey); lock.unlock()
    }
}

/// The on-device text model's place in the old code: the existing selection, clipboard and launcher features still call a
/// `TextModel`, and this one sends the request through the gateway to whichever provider the person chose for the feature.
struct GatewayTextModel: TextModel {
    let gateway: AIGateway
    var feature: AIFeature = .selection

    func availability() -> IntelligenceAvailability {
        guard let config = gateway.resolve(feature: feature) else { return gateway.appleModel.availability() }
        if config.kind == .appleIntelligence { return gateway.appleModel.availability() }
        return gateway.isAvailable(for: feature) ? .available : gateway.appleModel.availability()
    }

    func respond(instructions: String, prompt: String, rewriting: Bool) async throws -> String {
        let config = gateway.resolve(feature: feature)
        let remote = !(config?.isOnThisMac ?? true)
        // The text is made safe before it leaves this Mac: secrets are replaced when the provider is not on this Mac.
        let safe = remote ? SecretRedactor.redact(prompt, includePersonal: gateway.store.redactPersonal) : SecretRedactor.Result(text: prompt, found: [:])
        let system = instructions + "\n" + AIContextBuilder.untrustedRule
        let request = AIRequest(system: system, messages: [AIMessage(.user, safe.text)], temperature: 0.3, maxTokens: 900)
        do { return try await gateway.generate(feature: feature, request, secretsHidden: safe.count).text }
        catch let error as AIError { throw IntelligenceError.provider(error.errorDescription ?? "The AI provider could not answer.") }
    }
}
