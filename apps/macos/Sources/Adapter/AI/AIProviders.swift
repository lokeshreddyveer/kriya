import Foundation
import NaturalLanguage

/// A provider reached over HTTP with one of the wire formats.
struct HTTPProvider: AIProvider {
    let config: AIProviderConfig
    let wire: AIWire
    let transport: HTTPTransport
    /// Read when a request is made, so a replaced or revoked key takes effect at once, and no copy is kept here.
    let key: () -> String?

    var id: String { config.id }

    private func check(_ response: HTTPURLResponse, _ data: Data) throws {
        guard (200..<300).contains(response.statusCode) else { throw AIErrorMapper.fromStatus(response.statusCode, data) }
    }

    private func needKey() throws -> String? {
        let k = key()
        if config.kind.needsKey && (k ?? "").isEmpty { throw AIError.noKey }
        return k
    }

    func models() async throws -> [AIModel] {
        do {
            let (data, response) = try await transport.send(try wire.modelsRequest(config, key: try needKey()))
            try check(response, data)
            return try wire.parseModels(data)
        } catch { throw AIErrorMapper.map(error) }
    }

    func generate(_ request: AIRequest) async throws -> AIResponse {
        do {
            let (data, response) = try await transport.send(try wire.chatRequest(config, key: try needKey(), request, stream: false))
            try check(response, data)
            return try wire.parseChat(data)
        } catch { throw AIErrorMapper.map(error) }
    }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let built = try wire.chatRequest(config, key: try needKey(), request, stream: true)
                    var parser = wire.streamParser()
                    for try await line in transport.lines(built) { for event in parser.feed(line) { continuation.yield(event) } }
                    for event in parser.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch { continuation.finish(throwing: AIErrorMapper.map(error)) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func embed(_ request: EmbeddingRequest) async throws -> EmbeddingResponse {
        do {
            let (data, response) = try await transport.send(try wire.embeddingsRequest(config, key: try needKey(), request))
            try check(response, data)
            return try wire.parseEmbeddings(data)
        } catch { throw AIErrorMapper.map(error) }
    }
}

/// Apple Intelligence's on-device model behind the same interface. It has no tools and no structured output, and its embeddings are
/// the system's English sentence embeddings, which also run on this Mac.
struct AppleProvider: AIProvider {
    let model: TextModel
    var id: String { AIProviderStore.appleID }

    func models() async throws -> [AIModel] { [AIModel(id: "on-device", name: "Apple Intelligence (on this Mac)", supportsVision: false, supportsTools: false)] }

    func generate(_ request: AIRequest) async throws -> AIResponse {
        guard request.tools.isEmpty, request.responseSchema == nil else { throw AIError.unsupported("tools or structured output") }
        guard model.availability().isAvailable else { throw AIError.notConfigured(model.availability().title) }
        let prompt = request.messages.filter { $0.role != .system }.map(\.content).joined(separator: "\n\n")
        let system = ([request.system] + request.messages.filter { $0.role == .system }.map(\.content)).filter { !$0.isEmpty }.joined(separator: "\n\n")
        do { return AIResponse(text: try await model.respond(instructions: system, prompt: prompt, rewriting: true)) } catch { throw error }
    }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do { continuation.yield(.text(try await generate(request).text)); continuation.yield(.done); continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func embed(_ request: EmbeddingRequest) async throws -> EmbeddingResponse {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { throw AIError.unsupported("on-device embeddings on this Mac") }
        let vectors: [[Float]] = request.inputs.map { text in (embedding.vector(for: text) ?? []).map(Float.init) }
        guard vectors.allSatisfy({ !$0.isEmpty }) else { throw AIError.badResponse }
        return EmbeddingResponse(vectors: vectors, usage: nil)
    }
}
