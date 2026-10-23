import Foundation

/// How a request is written for, and an answer read from, each kind of provider. These are pure: they build and read bytes, and
/// never touch the network or the Keychain. The key is passed in and goes only into a header, never into an address.
protocol AIWire {
    func modelsRequest(_ c: AIProviderConfig, key: String?) throws -> URLRequest
    func parseModels(_ data: Data) throws -> [AIModel]
    func chatRequest(_ c: AIProviderConfig, key: String?, _ r: AIRequest, stream: Bool) throws -> URLRequest
    func parseChat(_ data: Data) throws -> AIResponse
    func streamParser() -> AIStreamParser
    func embeddingsRequest(_ c: AIProviderConfig, key: String?, _ r: EmbeddingRequest) throws -> URLRequest
    func parseEmbeddings(_ data: Data) throws -> EmbeddingResponse
}

protocol AIStreamParser {
    /// One line of the event stream.
    mutating func feed(_ line: String) -> [AIEvent]
    /// The end of the stream: whatever was still being built.
    mutating func finish() -> [AIEvent]
}

enum AIWireSupport {
    static func url(_ base: String, _ path: String) throws -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + path), let scheme = url.scheme, scheme == "http" || scheme == "https" else { throw AIError.notConfigured("the address is not valid") }
        return url
    }

    static func post(_ url: URL, body: [String: Any], timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw AIError.badResponse }
        return object
    }

    /// The provider's own error message, if the body is an error.
    static func errorMessage(_ object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] { return (error["message"] as? String) ?? "error" }
        if let error = object["error"] as? String { return error }
        return nil
    }

    static func arguments(_ any: Any?) -> [String: JSONValue] {
        if let text = any as? String { return JSONValue.parse(text)?.objectValue ?? [:] }
        return JSONValue.from(any).objectValue ?? [:]
    }

    static func floats(_ any: Any?) -> [Float]? {
        (any as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue }
    }

    static func newCallID() -> String { "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased() }
}

// MARK: - OpenAI and everything that speaks like it (Ollama, LM Studio, custom, proxies)

struct OpenAIWire: AIWire {
    let kind: AIProviderKind

    private func authorize(_ request: inout URLRequest, _ key: String?) {
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    }

    func modelsRequest(_ c: AIProviderConfig, key: String?) throws -> URLRequest {
        var request = URLRequest(url: try AIWireSupport.url(c.baseURL, "/models"), timeoutInterval: c.timeout)
        authorize(&request, key)
        return request
    }

    func parseModels(_ data: Data) throws -> [AIModel] {
        let object = try AIWireSupport.object(data)
        if let message = AIWireSupport.errorMessage(object) { throw AIError.provider(message) }
        let list = (object["data"] as? [[String: Any]]) ?? (object["models"] as? [[String: Any]]) ?? []
        return list.compactMap { entry in
            guard let id = (entry["id"] as? String) ?? (entry["name"] as? String) else { return nil }
            return AIModel(id: id, name: id, supportsVision: nil, supportsTools: nil)
        }
    }

    func chatRequest(_ c: AIProviderConfig, key: String?, _ r: AIRequest, stream: Bool) throws -> URLRequest {
        var messages: [[String: Any]] = []
        if !r.system.isEmpty { messages.append(["role": "system", "content": r.system]) }
        for m in r.messages {
            switch m.role {
            case .system, .user: messages.append(["role": m.role.rawValue, "content": m.content])
            case .assistant:
                var entry: [String: Any] = ["role": "assistant", "content": m.content]
                if let calls = m.toolCalls, !calls.isEmpty {
                    entry["tool_calls"] = calls.map { call in
                        ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": JSONValue.object(call.arguments).text]] as [String: Any]
                    }
                }
                messages.append(entry)
            case .tool:
                messages.append(["role": "tool", "tool_call_id": m.toolCallID ?? "", "content": m.content])
            }
        }
        var body: [String: Any] = ["model": r.model, "messages": messages, "temperature": r.temperature, "stream": stream]
        body[kind == .openAI ? "max_completion_tokens" : "max_tokens"] = r.maxTokens
        if kind == .openAI && stream { body["stream_options"] = ["include_usage": true] }
        if !r.tools.isEmpty {
            body["tools"] = r.tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters.any]] as [String: Any] }
        }
        if let schema = r.responseSchema {
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "response", "schema": schema.any, "strict": true]] as [String: Any]
        }
        var request = try AIWireSupport.post(try AIWireSupport.url(c.baseURL, "/chat/completions"), body: body, timeout: r.timeout)
        authorize(&request, key)
        return request
    }

    func parseChat(_ data: Data) throws -> AIResponse {
        let object = try AIWireSupport.object(data)
        if let message = AIWireSupport.errorMessage(object) { throw AIError.provider(message) }
        guard let choice = (object["choices"] as? [[String: Any]])?.first, let message = choice["message"] as? [String: Any] else { throw AIError.badResponse }
        var text = ""
        if let content = message["content"] as? String { text = content }
        else if let parts = message["content"] as? [[String: Any]] { text = parts.compactMap { $0["text"] as? String }.joined() }
        let calls: [AIToolCall] = ((message["tool_calls"] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let function = entry["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
            return AIToolCall(id: (entry["id"] as? String) ?? AIWireSupport.newCallID(), name: name, arguments: AIWireSupport.arguments(function["arguments"]))
        }
        var usage: AIUsage?
        if let u = object["usage"] as? [String: Any] { usage = AIUsage(inputTokens: (u["prompt_tokens"] as? Int) ?? 0, outputTokens: (u["completion_tokens"] as? Int) ?? 0) }
        return AIResponse(text: text, toolCalls: calls, usage: usage, finishReason: choice["finish_reason"] as? String)
    }

    func streamParser() -> AIStreamParser { OpenAIStreamParser() }

    func embeddingsRequest(_ c: AIProviderConfig, key: String?, _ r: EmbeddingRequest) throws -> URLRequest {
        var request = try AIWireSupport.post(try AIWireSupport.url(c.baseURL, "/embeddings"), body: ["model": r.model, "input": r.inputs], timeout: r.timeout)
        authorize(&request, key)
        return request
    }

    func parseEmbeddings(_ data: Data) throws -> EmbeddingResponse {
        let object = try AIWireSupport.object(data)
        if let message = AIWireSupport.errorMessage(object) { throw AIError.provider(message) }
        guard let list = object["data"] as? [[String: Any]] else { throw AIError.badResponse }
        let ordered = list.sorted { (($0["index"] as? Int) ?? 0) < (($1["index"] as? Int) ?? 0) }
        let vectors = ordered.compactMap { AIWireSupport.floats($0["embedding"]) }
        guard vectors.count == list.count else { throw AIError.badResponse }
        var usage: AIUsage?
        if let u = object["usage"] as? [String: Any] { usage = AIUsage(inputTokens: (u["prompt_tokens"] as? Int) ?? 0, outputTokens: 0) }
        return EmbeddingResponse(vectors: vectors, usage: usage)
    }
}

struct OpenAIStreamParser: AIStreamParser {
    private struct Partial { var id = ""; var name = ""; var arguments = "" }
    private var partials: [Int: Partial] = [:]
    private var usage: AIUsage?
    private var finished = false

    mutating func feed(_ line: String) -> [AIEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return finish() }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return [] }
        var events: [AIEvent] = []
        if let u = object["usage"] as? [String: Any], let input = u["prompt_tokens"] as? Int {
            usage = AIUsage(inputTokens: input, outputTokens: (u["completion_tokens"] as? Int) ?? 0)
        }
        guard let delta = ((object["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any] else { return events }
        if let text = delta["content"] as? String, !text.isEmpty { events.append(.text(text)) }
        for call in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
            let index = (call["index"] as? Int) ?? 0
            var partial = partials[index] ?? Partial()
            if let id = call["id"] as? String { partial.id = id }
            if let function = call["function"] as? [String: Any] {
                if let name = function["name"] as? String { partial.name += name }
                if let arguments = function["arguments"] as? String { partial.arguments += arguments }
            }
            partials[index] = partial
        }
        return events
    }

    mutating func finish() -> [AIEvent] {
        guard !finished else { return [] }
        finished = true
        var events: [AIEvent] = partials.keys.sorted().compactMap { index in
            guard let p = partials[index], !p.name.isEmpty else { return nil }
            return .toolCall(AIToolCall(id: p.id.isEmpty ? AIWireSupport.newCallID() : p.id, name: p.name, arguments: AIWireSupport.arguments(p.arguments)))
        }
        if let usage { events.append(.usage(usage)) }
        events.append(.done)
        return events
    }
}

// MARK: - Anthropic

struct AnthropicWire: AIWire {
    static let version = "2023-06-01"
    static let structuredToolName = "respond_with_json"

    private func headers(_ request: inout URLRequest, _ key: String?) {
        if let key, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
        request.setValue(Self.version, forHTTPHeaderField: "anthropic-version")
    }

    func modelsRequest(_ c: AIProviderConfig, key: String?) throws -> URLRequest {
        var request = URLRequest(url: try AIWireSupport.url(c.baseURL, "/v1/models"), timeoutInterval: c.timeout)
        headers(&request, key)
        return request
    }

    func parseModels(_ data: Data) throws -> [AIModel] {
        let object = try AIWireSupport.object(data)
        if let message = AIWireSupport.errorMessage(object) { throw AIError.provider(message) }
        return ((object["data"] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return AIModel(id: id, name: (entry["display_name"] as? String) ?? id, supportsVision: true, supportsTools: true)
        }
    }

    func chatRequest(_ c: AIProviderConfig, key: String?, _ r: AIRequest, stream: Bool) throws -> URLRequest {
        var system = r.system
        var messages: [[String: Any]] = []
        var pendingResults: [[String: Any]] = []
        func flushResults() {
            if !pendingResults.isEmpty { messages.append(["role": "user", "content": pendingResults]); pendingResults = [] }
        }
        for m in r.messages {
            switch m.role {
            case .system: system += (system.isEmpty ? "" : "\n\n") + m.content
            case .user: flushResults(); messages.append(["role": "user", "content": m.content])
            case .assistant:
                flushResults()
                var blocks: [[String: Any]] = []
                if !m.content.isEmpty { blocks.append(["type": "text", "text": m.content]) }
                for call in m.toolCalls ?? [] { blocks.append(["type": "tool_use", "id": call.id, "name": call.name, "input": JSONValue.object(call.arguments).any]) }
                messages.append(["role": "assistant", "content": blocks.isEmpty ? [["type": "text", "text": " "]] : blocks])
            case .tool:
                pendingResults.append(["type": "tool_result", "tool_use_id": m.toolCallID ?? "", "content": m.content])
            }
        }
        flushResults()
        var body: [String: Any] = ["model": r.model, "messages": messages, "max_tokens": r.maxTokens, "temperature": r.temperature, "stream": stream]
        if !system.isEmpty { body["system"] = system }
        var tools: [[String: Any]] = r.tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.parameters.any] }
        if let schema = r.responseSchema {
            // Structured output is asked for as a tool the model must call, whose input is the answer.
            tools.append(["name": Self.structuredToolName, "description": "Give the final answer as JSON in this shape.", "input_schema": schema.any])
            if r.tools.isEmpty { body["tool_choice"] = ["type": "tool", "name": Self.structuredToolName] }
        }
        if !tools.isEmpty { body["tools"] = tools }
        var request = try AIWireSupport.post(try AIWireSupport.url(c.baseURL, "/v1/messages"), body: body, timeout: r.timeout)
        headers(&request, key)
        return request
    }

    func parseChat(_ data: Data) throws -> AIResponse {
        let object = try AIWireSupport.object(data)
        if let message = AIWireSupport.errorMessage(object) { throw AIError.provider(message) }
        guard let blocks = object["content"] as? [[String: Any]] else { throw AIError.badResponse }
        var text = ""
        var calls: [AIToolCall] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text": text += (block["text"] as? String) ?? ""
            case "tool_use":
                let arguments = JSONValue.from(block["input"]).objectValue ?? [:]
                if (block["name"] as? String) == Self.structuredToolName { text = JSONValue.object(arguments).text }
                else if let name = block["name"] as? String { calls.append(AIToolCall(id: (block["id"] as? String) ?? AIWireSupport.newCallID(), name: name, arguments: arguments)) }
            default: break
            }
        }
        var usage: AIUsage?
        if let u = object["usage"] as? [String: Any] { usage = AIUsage(inputTokens: (u["input_tokens"] as? Int) ?? 0, outputTokens: (u["output_tokens"] as? Int) ?? 0) }
        return AIResponse(text: text, toolCalls: calls, usage: usage, finishReason: object["stop_reason"] as? String)
    }

    func streamParser() -> AIStreamParser { AnthropicStreamParser() }

    func embeddingsRequest(_ c: AIProviderConfig, key: String?, _ r: EmbeddingRequest) throws -> URLRequest { throw AIError.unsupported("embeddings") }
    func parseEmbeddings(_ data: Data) throws -> EmbeddingResponse { throw AIError.unsupported("embeddings") }
}

struct AnthropicStreamParser: AIStreamParser {
    private struct Partial { var id = ""; var name = ""; var json = "" }
    private var current: Partial?
    private var inputTokens = 0
    private var outputTokens = 0
    private var finished = false

    mutating func feed(_ line: String) -> [AIEvent] {
        guard line.hasPrefix("data:"), let object = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8))) as? [String: Any] else { return [] }
        var events: [AIEvent] = []
        switch object["type"] as? String {
        case "message_start":
            if let usage = (object["message"] as? [String: Any])?["usage"] as? [String: Any] { inputTokens = (usage["input_tokens"] as? Int) ?? 0 }
        case "content_block_start":
            if let block = object["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
                current = Partial(id: (block["id"] as? String) ?? "", name: (block["name"] as? String) ?? "", json: "")
            }
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any] else { break }
            if let text = delta["text"] as? String, !text.isEmpty, current == nil { events.append(.text(text)) }
            if let part = delta["partial_json"] as? String { current?.json += part }
        case "content_block_stop":
            if let p = current {
                let arguments = AIWireSupport.arguments(p.json.isEmpty ? "{}" : p.json)
                if p.name == AnthropicWire.structuredToolName { events.append(.text(JSONValue.object(arguments).text)) }
                else { events.append(.toolCall(AIToolCall(id: p.id.isEmpty ? AIWireSupport.newCallID() : p.id, name: p.name, arguments: arguments))) }
                current = nil
            }
        case "message_delta":
            if let usage = object["usage"] as? [String: Any] { outputTokens = (usage["output_tokens"] as? Int) ?? outputTokens }
        case "message_stop":
            events += finish()
        default: break
        }
        return events
    }

    mutating func finish() -> [AIEvent] {
        guard !finished else { return [] }
        finished = true
        return [.usage(AIUsage(inputTokens: inputTokens, outputTokens: outputTokens)), .done]
    }
}

// MARK: - Gemini

struct GeminiWire: AIWire {
    private func headers(_ request: inout URLRequest, _ key: String?) {
        // The key goes in a header. Google also accepts it in the address; Kriya never puts a key in an address.
        if let key, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
    }

    private func modelPath(_ model: String) -> String { "/models/" + model.replacingOccurrences(of: "models/", with: "") }

    func modelsRequest(_ c: AIProviderConfig, key: String?) throws -> URLRequest {
        var request = URLRequest(url: try AIWireSupport.url(c.baseURL, "/models"), timeoutInterval: c.timeout)
        headers(&request, key)
        return request
    }

    func parseModels(_ data: Data) throws -> [AIModel] {
        let object = try AIWireSupport.object(data)
        if let message = AIWireSupport.errorMessage(object) { throw AIError.provider(message) }
        return ((object["models"] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let id = name.replacingOccurrences(of: "models/", with: "")
            return AIModel(id: id, name: (entry["displayName"] as? String) ?? id, supportsVision: nil, supportsTools: nil)
        }
    }

    func chatRequest(_ c: AIProviderConfig, key: String?, _ r: AIRequest, stream: Bool) throws -> URLRequest {
        var system = r.system
        var contents: [[String: Any]] = []
        for m in r.messages {
            switch m.role {
            case .system: system += (system.isEmpty ? "" : "\n\n") + m.content
            case .user: contents.append(["role": "user", "parts": [["text": m.content]]])
            case .assistant:
                var parts: [[String: Any]] = []
                if !m.content.isEmpty { parts.append(["text": m.content]) }
                for call in m.toolCalls ?? [] { parts.append(["functionCall": ["name": call.name, "args": JSONValue.object(call.arguments).any]]) }
                contents.append(["role": "model", "parts": parts.isEmpty ? [["text": " "]] : parts])
            case .tool:
                contents.append(["role": "user", "parts": [["functionResponse": ["name": m.toolName ?? "tool", "response": ["result": m.content]]]]])
            }
        }
        var config: [String: Any] = ["temperature": r.temperature, "maxOutputTokens": r.maxTokens]
        if let schema = r.responseSchema { config["responseMimeType"] = "application/json"; config["responseSchema"] = schema.any }
        var body: [String: Any] = ["contents": contents, "generationConfig": config]
        if !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
        if !r.tools.isEmpty {
            body["tools"] = [["functionDeclarations": r.tools.map { ["name": $0.name, "description": $0.description, "parameters": $0.parameters.any] as [String: Any] }]]
        }
        let path = modelPath(r.model) + (stream ? ":streamGenerateContent?alt=sse" : ":generateContent")
        var request = try AIWireSupport.post(try AIWireSupport.url(c.baseURL, path), body: body, timeout: r.timeout)
        headers(&request, key)
        return request
    }

    static func parseCandidate(_ object: [String: Any]) -> (text: String, calls: [AIToolCall], usage: AIUsage?, finish: String?) {
        var text = ""
        var calls: [AIToolCall] = []
        let candidate = (object["candidates"] as? [[String: Any]])?.first
        for part in ((candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? [] {
            if let t = part["text"] as? String { text += t }
            if let call = part["functionCall"] as? [String: Any], let name = call["name"] as? String {
                calls.append(AIToolCall(id: AIWireSupport.newCallID(), name: name, arguments: JSONValue.from(call["args"]).objectValue ?? [:]))
            }
        }
        var usage: AIUsage?
        if let u = object["usageMetadata"] as? [String: Any] { usage = AIUsage(inputTokens: (u["promptTokenCount"] as? Int) ?? 0, outputTokens: (u["candidatesTokenCount"] as? Int) ?? 0) }
        return (text, calls, usage, candidate?["finishReason"] as? String)
    }

    func parseChat(_ data: Data) throws -> AIResponse {
        let object = try AIWireSupport.object(data)
        if let message = AIWireSupport.errorMessage(object) { throw AIError.provider(message) }
        guard object["candidates"] != nil else { throw AIError.badResponse }
        let parsed = Self.parseCandidate(object)
        return AIResponse(text: parsed.text, toolCalls: parsed.calls, usage: parsed.usage, finishReason: parsed.finish)
    }

    func streamParser() -> AIStreamParser { GeminiStreamParser() }

    func embeddingsRequest(_ c: AIProviderConfig, key: String?, _ r: EmbeddingRequest) throws -> URLRequest {
        let model = "models/" + r.model.replacingOccurrences(of: "models/", with: "")
        let requests = r.inputs.map { ["model": model, "content": ["parts": [["text": $0]]]] as [String: Any] }
        var request = try AIWireSupport.post(try AIWireSupport.url(c.baseURL, modelPath(r.model) + ":batchEmbedContents"), body: ["requests": requests], timeout: r.timeout)
        headers(&request, key)
        return request
    }

    func parseEmbeddings(_ data: Data) throws -> EmbeddingResponse {
        let object = try AIWireSupport.object(data)
        if let message = AIWireSupport.errorMessage(object) { throw AIError.provider(message) }
        guard let list = object["embeddings"] as? [[String: Any]] else { throw AIError.badResponse }
        let vectors = list.compactMap { AIWireSupport.floats($0["values"]) }
        guard vectors.count == list.count else { throw AIError.badResponse }
        return EmbeddingResponse(vectors: vectors, usage: nil)
    }
}

struct GeminiStreamParser: AIStreamParser {
    private var usage: AIUsage?
    private var finished = false

    mutating func feed(_ line: String) -> [AIEvent] {
        guard line.hasPrefix("data:"), let object = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8))) as? [String: Any] else { return [] }
        let parsed = GeminiWire.parseCandidate(object)
        if let u = parsed.usage { usage = u }
        var events: [AIEvent] = []
        if !parsed.text.isEmpty { events.append(.text(parsed.text)) }
        events += parsed.calls.map { .toolCall($0) }
        return events
    }

    mutating func finish() -> [AIEvent] {
        guard !finished else { return [] }
        finished = true
        return (usage.map { [AIEvent.usage($0)] } ?? []) + [.done]
    }
}

enum AIWires {
    static func wire(for kind: AIProviderKind) -> AIWire? {
        switch kind.wire {
        case .apple: return nil
        case .openAI: return OpenAIWire(kind: kind)
        case .anthropic: return AnthropicWire()
        case .gemini: return GeminiWire()
        }
    }
}
