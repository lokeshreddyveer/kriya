import Foundation

enum AIProviderKind: String, Codable, CaseIterable, Identifiable {
    case appleIntelligence, openAI, anthropic, gemini, openAICompatible, ollama, lmStudio, localHTTP, enterpriseProxy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .openAICompatible: return "OpenAI-compatible endpoint"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .localHTTP: return "Local HTTP endpoint"
        case .enterpriseProxy: return "Enterprise proxy"
        }
    }

    /// How requests are written for it.
    enum Wire { case apple, openAI, anthropic, gemini }
    var wire: Wire {
        switch self {
        case .appleIntelligence: return .apple
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        default: return .openAI
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .appleIntelligence: return ""
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .openAICompatible: return "https://"
        case .ollama: return "http://127.0.0.1:11434/v1"
        case .lmStudio: return "http://127.0.0.1:1234/v1"
        case .localHTTP: return "http://127.0.0.1:8080/v1"
        case .enterpriseProxy: return "https://"
        }
    }

    /// Whether its requests stay on this Mac, by the kind of provider alone.
    var staysOnThisMac: Bool { self == .appleIntelligence || self == .ollama || self == .lmStudio || self == .localHTTP }
    var needsKey: Bool { self == .openAI || self == .anthropic || self == .gemini || self == .openAICompatible || self == .enterpriseProxy }
    var suggestedModel: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .anthropic: return "claude-haiku-4-5"
        case .gemini: return "gemini-2.0-flash"
        default: return ""
        }
    }
}

/// The parts of Kriya that may use a provider. A provider is used only for the ones it is switched on for.
enum AIFeature: String, Codable, CaseIterable, Identifiable {
    case launcher, selection, clipboard, finder, browser, automation, capture, audio, diagnostics, notes, search
    var id: String { rawValue }
    var title: String {
        switch self {
        case .launcher: return "Launcher"
        case .selection: return "Selection bar"
        case .clipboard: return "Clipboard"
        case .finder: return "Finder"
        case .browser: return "Browser pages"
        case .automation: return "Automation"
        case .capture: return "Capture"
        case .audio: return "Audio"
        case .diagnostics: return "Diagnostics"
        case .notes: return "Notes"
        case .search: return "Semantic search"
        }
    }
}

/// One provider's settings. The API key is not here: it lives only in the Keychain.
struct AIProviderConfig: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var kind: AIProviderKind
    var baseURL: String
    var model: String
    var embeddingModel: String
    var supportsVision: Bool
    var supportsTools: Bool
    /// The person's statement that this endpoint is on this Mac. Kriya checks that the address really is.
    var localOnly: Bool
    var timeout: TimeInterval
    var maxTokens: Int
    var dailyTokenLimit: Int?
    var dailyCostLimit: Double?
    /// Used to work out the cost of a request, per million tokens.
    var costPerMillionInput: Double?
    var costPerMillionOutput: Double?
    var enabledFeatures: Set<AIFeature>
    var enabled: Bool

    init(id: String = UUID().uuidString, name: String, kind: AIProviderKind, baseURL: String? = nil, model: String? = nil, embeddingModel: String = "",
         supportsVision: Bool = false, supportsTools: Bool = false, localOnly: Bool? = nil, timeout: TimeInterval = 60, maxTokens: Int = 1024,
         dailyTokenLimit: Int? = nil, dailyCostLimit: Double? = nil, costPerMillionInput: Double? = nil, costPerMillionOutput: Double? = nil,
         enabledFeatures: Set<AIFeature> = [], enabled: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.model = model ?? kind.suggestedModel
        self.embeddingModel = embeddingModel
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.localOnly = localOnly ?? kind.staysOnThisMac
        self.timeout = timeout
        self.maxTokens = maxTokens
        self.dailyTokenLimit = dailyTokenLimit
        self.dailyCostLimit = dailyCostLimit
        self.costPerMillionInput = costPerMillionInput
        self.costPerMillionOutput = costPerMillionOutput
        self.enabledFeatures = enabledFeatures
        self.enabled = enabled
    }

    static let timeoutRange: ClosedRange<TimeInterval> = 5...300
    static let maxTokensRange: ClosedRange<Int> = 16...32_000

    /// The address as a URL, if it is one Kriya would talk to.
    var url: URL? { URL(string: baseURL.trimmingCharacters(in: .whitespaces)) }

    static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasPrefix("127.")
    }

    /// Whether requests to this provider stay on this Mac: an on-device provider, or an endpoint at a loopback address that the
    /// person marked as local. A provider marked local at any other address is not treated as local.
    var isOnThisMac: Bool {
        if kind == .appleIntelligence { return true }
        return localOnly && Self.isLoopback(url?.host)
    }

    /// What is wrong with these settings, in words. Empty when they are fine.
    var problems: [String] {
        var out: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Give the provider a name.") }
        if kind == .appleIntelligence { return out }
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { out.append("The base address is not a web address."); return out }
        if url.user != nil || url.password != nil || url.query != nil { out.append("The address must not contain a user name, password or query. Put the key in the key field.") }
        if scheme != "https" && !(scheme == "http" && Self.isLoopback(host)) { out.append("Use https. Plain http is only allowed for an address on this Mac (localhost).") }
        if localOnly && !Self.isLoopback(host) { out.append("It is marked as running on this Mac, but the address is \(host). Use localhost, or turn that off.") }
        if model.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Choose a model.") }
        if !Self.timeoutRange.contains(timeout) { out.append("The time limit must be between 5 and 300 seconds.") }
        if !Self.maxTokensRange.contains(maxTokens) { out.append("The answer length must be between 16 and 32000 tokens.") }
        if let limit = dailyTokenLimit, limit < 1 { out.append("The daily token limit must be at least 1.") }
        if let limit = dailyCostLimit, limit <= 0 { out.append("The daily cost limit must be more than zero.") }
        return out
    }

    /// The Keychain account for this provider's key: a fixed one for the big three, one per provider otherwise.
    var keyAccount: String {
        switch kind {
        case .openAI: return "kriya.ai.provider.openai.api-key"
        case .anthropic: return "kriya.ai.provider.anthropic.api-key"
        case .gemini: return "kriya.ai.provider.gemini.api-key"
        default: return "kriya.ai.provider.custom.\(id).api-key"
        }
    }

    /// A copy for sharing or backing up: the settings, with nothing secret (there is nothing secret in a config, and this says so).
    var exportable: AIProviderConfig { self }
}

/// What a list of providers becomes when exported or backed up. It has no keys because configs never hold any; the check is a
/// guard against one being added by mistake.
enum AIProviderExport {
    static func data(_ configs: [AIProviderConfig]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(configs.map(\.exportable))
    }

    /// Settings read from a file. Providers come in switched off, so a file cannot start sending anything by itself.
    static func configs(from data: Data) -> [AIProviderConfig]? {
        guard data.count < 500_000, var list = try? JSONDecoder().decode([AIProviderConfig].self, from: data), list.count <= 50 else { return nil }
        for i in list.indices { list[i].enabled = false; list[i].enabledFeatures = [] }
        return list
    }
}

/// How much of each AI feature is actually connected to something the person can use. Shown next to the switches, so a provider is
/// not switched on for a part of Kriya that never calls it.
enum AIIntegrationLevel: String {
    case connected, partial, notConnected

    var title: String {
        switch self {
        case .connected: return "Connected"
        case .partial: return "Partly connected"
        case .notConnected: return "Not connected yet"
        }
    }
}

struct AIFeatureIntegration: Equatable {
    var level: AIIntegrationLevel
    /// What it can do now.
    var does: [String]
    /// What it cannot do yet.
    var lacks: [String]
}

extension AIFeature {
    var integration: AIFeatureIntegration {
        switch self {
        case .launcher: return AIFeatureIntegration(level: .connected, does: ["Ask AI (type ? and a question)", "Search by meaning", "Quick actions (type ai)"], lacks: [])
        case .selection: return AIFeatureIntegration(level: .connected, does: ["Summarize, rewrite, translate and explain selected text"], lacks: [])
        case .clipboard: return AIFeatureIntegration(level: .partial, does: ["Summarize, explain and fix text in history items", "Hide or find secrets (no AI needed)"], lacks: ["Classifying or tagging items", "Translating items"])
        case .finder: return AIFeatureIntegration(level: .connected, does: ["Suggest names (undoable)", "Summarize a file", "Suggest tags", "Suggest folder-rule ideas", "Plan moves, renames and trashing for approval"], lacks: ["Explaining duplicate groups"])
        case .browser: return AIFeatureIntegration(level: .connected, does: ["Summarize or ask about the page you are on, with a permission for each site"], lacks: ["Translating a page", "Acting on pages without you choosing it"])
        case .automation: return AIFeatureIntegration(level: .partial, does: ["Draft a workflow from words (safe steps only)"], lacks: ["Explaining a workflow", "Diagnosing a failed run"])
        case .capture: return AIFeatureIntegration(level: .partial, does: ["Explain, summarize, turn into Markdown, tidy the text, hide private text, name a capture (all from the text read from the picture)"], lacks: ["Looking at the picture itself", "Chapters or summaries of recordings"])
        case .audio: return AIFeatureIntegration(level: .connected, does: ["Check the sound settings and say what is wrong", "Draft a sound mode from connected devices"], lacks: ["Listening to audio"])
        case .diagnostics: return AIFeatureIntegration(level: .connected, does: ["Explain a redacted diagnostic report"], lacks: [])
        case .notes: return AIFeatureIntegration(level: .connected, does: ["Suggest tags", "Pull out tasks", "Tidy up", "Find related or duplicate notes", "Draft a workflow"], lacks: [])
        case .search: return AIFeatureIntegration(level: .connected, does: ["Search by meaning over the sources you switch on"], lacks: ["Indexing Finder files in general, browser tabs, recordings or screenshots"])
        }
    }
}
