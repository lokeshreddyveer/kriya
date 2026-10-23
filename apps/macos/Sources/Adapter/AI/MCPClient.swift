import Foundation

/// The MCP servers the person connected, and the tools they offer. A server only gets what is written in its settings: the tools in
/// its allowed list, the hosts in its network scope, and a minimal environment. It cannot ask Kriya for files, the clipboard, the
/// Keychain or a shell; requests a server makes of Kriya are answered "not found".
final class MCPClientManager: ObservableObject {
    static let shared = MCPClientManager()
    private static let key = "mcpClients.v1"

    @Published var servers: [MCPServerConfig] { didSet { save() } }
    /// Tools each server listed, by server id, before the allowed list is applied.
    @Published private(set) var listed: [String: [AITool]] = [:]
    @Published private(set) var problems: [String: String] = [:]

    private var sessions: [String: MCPSession] = [:]
    var transport: HTTPTransport = URLSessionTransport.shared

    private init() {
        servers = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([MCPServerConfig].self, from: $0) } ?? []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func token(for config: MCPServerConfig) -> String? { config.usesToken ? KeychainSecrets.get(config.tokenAccount) : nil }

    /// The tools of the servers that are switched on, limited to each one's allowed list.
    var tools: [AITool] {
        servers.filter { $0.enabled && $0.problems.isEmpty }.flatMap { $0.aiTools(from: listed[$0.id] ?? []) }
    }

    /// Asks a server what tools it has. The list is only used for the settings screen and for the allowed list; nothing is offered
    /// to a model until the person allows it.
    func refresh(_ config: MCPServerConfig) async {
        do {
            let result = try await request(config, method: "tools/list", params: .object([:]))
            await MainActor.run { listed[config.id] = MCPClientRules.tools(from: result); problems[config.id] = nil }
        } catch {
            await MainActor.run { problems[config.id] = (error as? AIError)?.errorDescription ?? error.localizedDescription }
        }
    }

    func callTool(exposedName: String, arguments: [String: JSONValue]) async throws -> String {
        guard let (config, tool) = servers.lazy.compactMap({ s -> (MCPServerConfig, AITool)? in
            guard s.enabled else { return nil }
            return (listed[s.id] ?? []).first(where: { s.isToolAllowed($0.name) && MCPServerConfig.exposedName(slug: s.slug, tool: $0.name) == exposedName }).map { (s, $0) }
        }).first else { throw ToolUnavailable(name: exposedName) }
        let result = try await request(config, method: "tools/call", params: .object(["name": .string(tool.name), "arguments": .object(arguments)]))
        let parsed = MCPClientRules.text(from: result)
        await MainActor.run { touch(config.id) }
        if parsed.isError { throw AIError.provider(String(parsed.text.prefix(200))) }
        return parsed.text
    }

    /// Reads a resource, only if its address starts with one the person allowed for that server.
    func readResource(_ uri: String, from config: MCPServerConfig) async throws -> String {
        guard config.enabled, config.isResourceAllowed(uri) else { throw AIError.providerOffForFeature("that resource") }
        let result = try await request(config, method: "resources/read", params: .object(["uri": .string(uri)]))
        let texts = (result["contents"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
        return String(texts.joined(separator: "\n").prefix(MCPClientRules.maxResultCharacters))
    }

    private func touch(_ id: String) {
        if let i = servers.firstIndex(where: { $0.id == id }) { servers[i].lastUsed = Date() }
    }

    func disconnect(_ id: String) { sessions[id]?.stop(); sessions[id] = nil }
    func disconnectAll() { sessions.values.forEach { $0.stop() }; sessions = [:] }

    private func request(_ config: MCPServerConfig, method: String, params: JSONValue) async throws -> JSONValue {
        if let first = config.problems.first { throw AIError.notConfigured(first) }
        switch config.transport {
        case .http:
            if LocalOnly.isOn && !AIProviderConfig.isLoopback(config.host) { throw AIError.blockedByLocalOnly }
            let session = (sessions[config.id] as? MCPHTTPSession) ?? MCPHTTPSession(config: config, token: token(for: config), transport: transport)
            sessions[config.id] = session
            return try await session.send(method: method, params: params)
        case .stdio:
            let session = (sessions[config.id] as? MCPStdioSession) ?? MCPStdioSession(config: config)
            sessions[config.id] = session
            return try await session.send(method: method, params: params)
        }
    }
}

protocol MCPSession: AnyObject {
    func send(method: String, params: JSONValue) async throws -> JSONValue
    func stop()
}

/// JSON-RPC over HTTP POST. Redirects are not followed; a body may be JSON or an event stream.
final class MCPHTTPSession: MCPSession {
    let config: MCPServerConfig
    private let token: String?
    private let transport: HTTPTransport
    private var nextID = 1
    private var sessionID: String?
    private var initialized = false

    init(config: MCPServerConfig, token: String?, transport: HTTPTransport) { self.config = config; self.token = token; self.transport = transport }

    func send(method: String, params: JSONValue) async throws -> JSONValue {
        if !initialized {
            _ = try await post(method: "initialize", params: .object(["protocolVersion": .string(MCPServerCore.supportedVersions[0]), "capabilities": .object([:]),
                                                                    "clientInfo": .object(["name": .string("Kriya"), "version": .string(SystemInfo.appVersion)])]))
            try await notify("notifications/initialized")
            initialized = true
        }
        return try await post(method: method, params: params)
    }

    private func build(_ body: [String: Any]) throws -> URLRequest {
        guard let url = URL(string: config.url) else { throw AIError.notConfigured("the address is not valid") }
        var request = try AIWireSupport.post(url, body: body, timeout: 30)
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        return request
    }

    private func notify(_ method: String) async throws {
        let (_, response) = try await transport.send(try build(["jsonrpc": "2.0", "method": method]))
        guard (200..<300).contains(response.statusCode) else { throw AIErrorMapper.fromStatus(response.statusCode, Data()) }
    }

    private func post(method: String, params: JSONValue) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        do {
            let (data, response) = try await transport.send(try build(["jsonrpc": "2.0", "id": id, "method": method, "params": params.any]))
            guard (200..<300).contains(response.statusCode) else { throw AIErrorMapper.fromStatus(response.statusCode, data) }
            if let header = response.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = header }
            guard let message = MCPClientRules.message(withID: id, in: String(decoding: data, as: UTF8.self)) else { throw AIError.badResponse }
            if let error = message["error"] { throw AIError.provider(AIErrorMapper.clean(error["message"]?.stringValue ?? "error")) }
            return message["result"] ?? .null
        } catch { throw AIErrorMapper.map(error) }
    }

    func stop() {}
}

/// JSON-RPC over a program's standard input and output, one message per line. The program gets a minimal environment, not
/// Kriya's, and runs with the user's own access: there is no sandbox, so only programs the person trusts should be added.
final class MCPStdioSession: MCPSession {
    let config: MCPServerConfig
    private var process: Process?
    private var input: FileHandle?
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var buffer = Data()
    private var nextID = 1
    private var initialized = false
    private let lock = NSLock()

    init(config: MCPServerConfig) { self.config = config }

    private func start() throws {
        if process?.isRunning == true { return }
        guard FileManager.default.isExecutableFile(atPath: config.command) else { throw AIError.notConfigured("the program cannot be run") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.command)
        p.arguments = config.arguments
        var environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "HOME": NSHomeDirectory()]
        for (k, v) in config.environment { environment[k] = v }
        p.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { self?.failAll(AIError.provider("The server closed.")); handle.readabilityHandler = nil; return }
            self?.received(data)
        }
        p.terminationHandler = { [weak self] _ in self?.failAll(AIError.provider("The server stopped.")) }
        try p.run()
        process = p
        input = stdin.fileHandleForWriting
        initialized = false
    }

    private func received(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var messages: [JSONValue] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            if let value = JSONValue.parse(String(decoding: line, as: UTF8.self)) { messages.append(value) }
        }
        if buffer.count > 4_000_000 { buffer = Data() }
        lock.unlock()
        for message in messages {
            if let id = message["id"]?.numberValue.map(Int.init), message["method"] == nil {
                lock.lock(); let continuation = pending.removeValue(forKey: id); lock.unlock()
                if let error = message["error"] { continuation?.resume(throwing: AIError.provider(AIErrorMapper.clean(error["message"]?.stringValue ?? "error"))) }
                else { continuation?.resume(returning: message["result"] ?? .null) }
            } else if let id = message["id"], message["method"] != nil {
                // The server is asking Kriya for something (sampling, roots, …). Kriya offers none of it.
                write(["jsonrpc": "2.0", "id": id.any, "error": ["code": -32601, "message": "Not supported"]])
            }
        }
    }

    private func failAll(_ error: Error) {
        lock.lock(); let all = pending; pending = [:]; lock.unlock()
        all.values.forEach { $0.resume(throwing: error) }
    }

    private func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        try? input?.write(contentsOf: data)
    }

    func send(method: String, params: JSONValue) async throws -> JSONValue {
        try start()
        if !initialized {
            initialized = true
            _ = try await rpc("initialize", .object(["protocolVersion": .string(MCPServerCore.supportedVersions[0]), "capabilities": .object([:]),
                                                      "clientInfo": .object(["name": .string("Kriya"), "version": .string(SystemInfo.appVersion)])]))
            write(["jsonrpc": "2.0", "method": "notifications/initialized"])
        }
        return try await rpc(method, params)
    }

    private func rpc(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        lock.lock(); let id = nextID; nextID += 1; lock.unlock()
        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { [self] in
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock(); pending[id] = continuation; lock.unlock()
                    write(["jsonrpc": "2.0", "id": id, "method": method, "params": params.any])
                }
            }
            group.addTask { [self] in
                try await Task.sleep(nanoseconds: 30_000_000_000)
                lock.lock(); let continuation = pending.removeValue(forKey: id); lock.unlock()
                continuation?.resume(throwing: AIError.timeout)
                throw AIError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AIError.badResponse }
            return first
        }
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        failAll(AIError.cancelled)
    }
}
