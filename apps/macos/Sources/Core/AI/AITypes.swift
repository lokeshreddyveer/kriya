import Foundation

struct AIModel: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var supportsVision: Bool?
    var supportsTools: Bool?
}

enum AIRole: String, Codable, Equatable {
    case system, user, assistant, tool
}

struct AIToolCall: Codable, Equatable {
    var id: String
    var name: String
    var arguments: [String: JSONValue]
}

struct AIMessage: Codable, Equatable {
    var role: AIRole
    var content: String
    /// For a tool's answer: which call it answers, and the tool's name.
    var toolCallID: String?
    var toolName: String?
    /// For an assistant message that asked for tools.
    var toolCalls: [AIToolCall]?

    init(_ role: AIRole, _ content: String, toolCallID: String? = nil, toolName: String? = nil, toolCalls: [AIToolCall]? = nil) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.toolCalls = toolCalls
    }
}

/// How much harm a tool can do. Decides whether the person is asked first.
enum AIRisk: String, Codable, CaseIterable, Comparable {
    case readOnly, sensitiveRead, externalNetwork, write, destructive, privileged

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    static func < (a: AIRisk, b: AIRisk) -> Bool { a.rank < b.rank }

    var title: String {
        switch self {
        case .readOnly: return "Reads public information"
        case .sensitiveRead: return "Reads private content"
        case .externalNetwork: return "Contacts the network"
        case .write: return "Changes settings or content"
        case .destructive: return "Deletes or moves things"
        case .privileged: return "Runs scripts or controls apps"
        }
    }
}

struct AITool: Equatable {
    var name: String
    var description: String
    /// A JSON schema of type "object".
    var parameters: JSONValue
    var risk: AIRisk
}

struct AIRequest: Equatable {
    var model: String
    var system: String
    var messages: [AIMessage]
    var tools: [AITool]
    var responseSchema: JSONValue?
    var temperature: Double
    var maxTokens: Int
    var timeout: TimeInterval

    init(model: String = "", system: String = "", messages: [AIMessage], tools: [AITool] = [], responseSchema: JSONValue? = nil,
         temperature: Double = 0.3, maxTokens: Int = 1024, timeout: TimeInterval = 60) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.responseSchema = responseSchema
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.timeout = timeout
    }

    /// Everything that would be sent, in characters, for the size checks.
    var inputCharacters: Int { system.count + messages.reduce(0) { $0 + $1.content.count } }
}

struct AIUsage: Equatable, Codable {
    var inputTokens: Int
    var outputTokens: Int
    var total: Int { inputTokens + outputTokens }
}

struct AIResponse: Equatable {
    var text: String
    var toolCalls: [AIToolCall] = []
    var usage: AIUsage?
    var finishReason: String?
}

enum AIEvent: Equatable {
    case text(String)
    case toolCall(AIToolCall)
    case usage(AIUsage)
    case done
}

struct EmbeddingRequest: Equatable {
    var model: String
    var inputs: [String]
    var timeout: TimeInterval = 60
}

struct EmbeddingResponse: Equatable {
    var vectors: [[Float]]
    var usage: AIUsage?
}

enum AIError: Error, Equatable, LocalizedError {
    case notConfigured(String)
    case noKey
    case unauthorized
    case blockedByLocalOnly
    case providerOffForFeature(String)
    case offline
    case timeout
    case rateLimited
    case budgetExceeded(String)
    case inputTooLarge(Int)
    case outputTooLarge
    case provider(String)
    case badResponse
    case unsupported(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured(let why): return "The AI provider is not set up: \(why)"
        case .noKey: return "No API key is saved for this provider."
        case .unauthorized: return "The provider refused the key. Replace it in AI settings."
        case .blockedByLocalOnly: return "Local-only mode is on, and this provider is not on this Mac."
        case .providerOffForFeature(let feature): return "This provider is not allowed to be used for \(feature)."
        case .offline: return "Kriya could not reach the provider. Check the connection, or choose an on-device provider."
        case .timeout: return "The provider took too long to answer."
        case .rateLimited: return "Too many AI requests in a short time. Wait a moment."
        case .budgetExceeded(let what): return "The daily \(what) limit for this provider has been reached."
        case .inputTooLarge(let limit): return "That is more text than Kriya will send (\(limit) characters)."
        case .outputTooLarge: return "The answer was larger than Kriya allows and was cut off."
        case .provider(let message): return "The provider said: \(message)"
        case .badResponse: return "The provider's answer could not be understood."
        case .unsupported(let what): return "This provider does not support \(what)."
        case .cancelled: return "Cancelled."
        }
    }
}

/// Every AI feature talks to the gateway, and the gateway talks to providers through this. Nothing else reaches a provider.
protocol AIProvider {
    var id: String { get }
    func models() async throws -> [AIModel]
    func generate(_ request: AIRequest) async throws -> AIResponse
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error>
    func embed(_ request: EmbeddingRequest) async throws -> EmbeddingResponse
}
