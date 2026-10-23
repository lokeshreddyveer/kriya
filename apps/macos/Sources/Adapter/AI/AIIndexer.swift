import AppKit

struct SearchHit: Identifiable, Equatable {
    var id: String { documentID }
    var documentID: String
    var title: String
    var source: IndexSource
    var snippet: String
    var target: String
    var score: Double
}

/// Fills the local index from the parts of Kriya the person switched on, and searches it by keywords and by meaning. The keyword
/// half needs no AI at all; the meaning half needs an embedding provider the person chose (on this Mac by default).
final class AIIndexer: ObservableObject {
    static let shared = AIIndexer()
    private static let enabledKey = "ai.search.enabled"
    private static let consentKey = "ai.search.embeddingConsent.v1"

    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); FeatureActivity.shared.changed("semanticSearch", enabled ? "Turned on" : "Turned off"); if enabled { Task { await refresh() } } } }
    @Published private(set) var status: String?
    @Published private(set) var busy = false
    @Published private(set) var counts: (documents: Int, chunks: Int, embedded: Int) = (0, 0, 0)

    /// What each source offers, set by the app. Each is called on the main thread.
    var providers: [IndexSource: () -> [IndexDocument]] = [:]
    let gateway: AIGateway
    private(set) var index: AIIndex?
    private var timer: Timer?

    init(gateway: AIGateway = .shared, index: AIIndex? = try? AIIndex()) {
        self.gateway = gateway
        self.index = index
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        counts = index?.counts() ?? (0, 0, 0)
    }

    func start() {
        guard enabled, timer == nil else { return }
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in Task { await self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { await refresh() }
    }

    func isSourceOn(_ source: IndexSource) -> Bool { index?.isSourceEnabled(source) ?? source.defaultOn }

    func setSource(_ source: IndexSource, on: Bool) {
        try? index?.setSource(source, enabled: on)
        counts = index?.counts() ?? counts
        objectWillChange.send()
        if on { Task { await refresh() } }
    }

    func deleteIndex() {
        try? index?.deleteAll()
        counts = index?.counts() ?? (0, 0, 0)
        status = "The index was emptied."
    }

    // MARK: Building

    func refresh() async {
        guard enabled, let index, !busy else { return }
        await MainActor.run { busy = true; status = "Updating the index…" }
        let enabledSources = index.enabledSources
        for source in IndexSource.allCases where enabledSources.contains(source) {
            guard let provider = providers[source] else { continue }
            let documents = await MainActor.run { provider() }
            var ids = Set<String>()
            for raw in documents {
                guard let doc = IndexPolicy.prepare(raw, enabled: enabledSources) else { continue }
                ids.insert(doc.id)
                try? index.upsert(doc)
            }
            try? index.prune(source, keeping: ids)
            index.markIndexed(source)
        }
        await embedPending()
        await MainActor.run { counts = index.counts(); busy = false; if status == "Updating the index…" { status = "Up to date." } }
    }

    /// The model name the vectors are stored under, so vectors from another model are never compared.
    private func embeddingTarget() -> (config: AIProviderConfig, model: String)? {
        guard let config = gateway.resolve(feature: .search, providerID: gateway.store.embeddingProviderID ?? AIProviderStore.appleID) else { return nil }
        let model = config.kind == .appleIntelligence ? "apple-sentence-en" : config.embeddingModel
        return model.isEmpty ? nil : (config, "\(config.id):\(model)")
    }

    private func embedPending() async {
        guard let index, let target = embeddingTarget() else { return }
        index.dropVectors(notFrom: target.model)
        guard await confirmRemoteEmbedding(target.config, sources: index.enabledSources) else {
            await MainActor.run { status = "Search by meaning is waiting for your permission to send text to \(target.config.name)." }
            return
        }
        let providerModel = target.config.kind == .appleIntelligence ? "" : target.config.embeddingModel
        while true {
            let pieces = index.piecesNeedingVectors(model: target.model, limit: 32)
            if pieces.isEmpty { break }
            do {
                let response = try await gateway.embed(providerID: target.config.id, EmbeddingRequest(model: providerModel, inputs: pieces.map { String($0.text.prefix(1500)) }))
                guard response.vectors.count == pieces.count else { break }
                try index.store(vectors: zip(pieces, response.vectors).map { (chunk: $0.0.id, vector: $0.1) }, model: target.model)
            } catch {
                await MainActor.run { status = "Search by meaning is not available: \((error as? AIError)?.errorDescription ?? error.localizedDescription) Keyword search still works." }
                FeatureActivity.shared.failed("semanticSearch", (error as? AIError)?.errorDescription ?? "Embedding failed")
                break
            }
        }
    }

    /// Before text goes to a provider that is not on this Mac, the person is told what and to whom, once for each combination.
    private func confirmRemoteEmbedding(_ config: AIProviderConfig, sources: Set<IndexSource>) async -> Bool {
        if config.isOnThisMac { return true }
        let key = config.id + "|" + sources.map(\.rawValue).sorted().joined(separator: ",")
        var given = UserDefaults.standard.stringArray(forKey: Self.consentKey) ?? []
        if given.contains(key) { return true }
        let allowed = await MainActor.run { () -> Bool in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Send your indexed text to \(config.name)?"
            alert.informativeText = "To search by meaning, the text of these will be sent to \(config.name), which is not on this Mac:\n\n" + sources.sorted { $0.rawValue < $1.rawValue }.map { "• " + $0.title }.joined(separator: "\n") + "\n\nSecrets are hidden first. You can turn a source off in AI settings."
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Don't Send")
            NSApp.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertFirstButtonReturn
        }
        if allowed { given.append(key); UserDefaults.standard.set(given, forKey: Self.consentKey) }
        return allowed
    }

    // MARK: Searching

    func search(_ query: String, limit: Int = 12) async -> [SearchHit] {
        guard enabled, let index else { return [] }
        FeatureActivity.shared.used("semanticSearch")
        let clean = String(SecretRedactor.redact(query).text.prefix(300))
        let keyword = index.keywordSearch(clean)
        var vector: [(match: AIIndex.Match, similarity: Float)] = []
        if let target = embeddingTarget(), index.counts().embedded > 0 {
            if let response = try? await gateway.embed(providerID: target.config.id, EmbeddingRequest(model: target.config.kind == .appleIntelligence ? "" : target.config.embeddingModel, inputs: [clean])),
               let q = response.vectors.first {
                vector = index.vectorSearch(q, model: target.model)
            }
        }
        var byID: [String: AIIndex.Match] = [:]
        for m in keyword + vector.map(\.match) where byID[m.documentID] == nil { byID[m.documentID] = m }
        let ranked = HybridRanker.rank(keyword: keyword.map(\.documentID), vector: vector.map { ($0.match.documentID, $0.similarity) },
                                       updated: byID.mapValues(\.updated), favorites: Set(byID.values.filter(\.favorite).map(\.documentID)), limit: limit)
        return ranked.compactMap { hit in
            guard let m = byID[hit.id] else { return nil }
            return SearchHit(documentID: m.documentID, title: m.title, source: m.source, snippet: m.snippet, target: m.target, score: hit.score)
        }
    }

    /// The start of a document's text, for giving a model the most relevant documents.
    func text(of documentID: String, limit: Int = 3000) -> String {
        let pieces = (try? index?.rows("SELECT text FROM chunks WHERE document_id = ? ORDER BY idx LIMIT 6", [.text(documentID)]) { AIIndex.text($0, 0) }) ?? []
        return String(pieces.joined(separator: "\n").prefix(limit))
    }
}

/// Answers a question from what the index holds, with numbered sources, or by asking the model to use Kriya's tools.
final class AIAssistant {
    let indexer: AIIndexer
    let gateway: AIGateway

    init(indexer: AIIndexer = .shared, gateway: AIGateway = .shared) { self.indexer = indexer; self.gateway = gateway }

    struct Answer { var text: String; var sources: [SearchHit]; var redactions: Int }

    func answer(_ question: String, feature: AIFeature = .launcher) async throws -> Answer {
        guard let config = gateway.resolve(feature: feature) else { throw AIError.notConfigured("no provider is switched on for \(feature.title)") }
        let hits = Array(await indexer.search(question, limit: 5))
        let items = hits.map { hit in
            AIContextItem(source: Self.aiSource(hit.source), title: hit.title, text: indexer.text(of: hit.documentID), permission: .indexed, sensitivity: .normal, age: nil, citation: hit.title)
        }
        let policy = AIContextPolicy(maxCharacters: 9000, redactSecrets: true, redactPersonal: gateway.store.redactPersonal, providerIsOnThisMac: config.isOnThisMac)
        let context: AIContext
        if items.isEmpty { context = AIContext(blocks: [], citations: [], redactions: [:], truncated: false, injectionWarnings: [], sources: []) }
        else {
            switch AIContextBuilder.build(items, policy: policy) {
            case .success(let c): context = c
            case .failure(let refusal): throw AIError.provider(refusal.errorDescription ?? "Nothing could be sent.")
            }
        }
        let system = "You answer questions for the user of a Mac utility. Use the numbered sources when they help and cite them like [1]. If they do not contain the answer, say so plainly instead of guessing."
        let allowed = Set(gateway.store.toolSettings.toolsByFeature[feature.rawValue] ?? [])
        let tools = config.supportsTools ? AIToolEngine.shared.registry.filter { allowed.contains($0.name) || $0.risk == .readOnly } : []
        let text: String
        if tools.isEmpty {
            let prompt = (context.rendered.isEmpty ? "" : context.rendered + "\n\n") + "Question: " + SecretRedactor.redact(question).text
            text = try await gateway.generate(feature: feature, AIRequest(system: system + "\n" + AIContextBuilder.untrustedRule, messages: [AIMessage(.user, prompt)], maxTokens: 700), secretsHidden: context.redactionCount).text
        } else {
            text = try await AIAgentLoop().run(feature: feature, system: system, context: context, question: SecretRedactor.redact(question).text, tools: tools)
        }
        return Answer(text: text, sources: hits, redactions: context.redactionCount)
    }

    static func aiSource(_ s: IndexSource) -> AISource {
        switch s {
        case .notes: return .notes
        case .savedPages: return .browserPage
        case .clipboard: return .clipboard
        case .workflows: return .workflow
        case .actions, .bookmarks: return .launcher
        case .activity: return .diagnostics
        }
    }
}
