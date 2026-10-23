import Foundation
import Network
import Security

/// The parts of a request that decide whether it may be answered. Pure, so the rules can be tested without a socket.
enum LoopbackRequestRules {
    static let maxBytes = 1_100_000

    enum Verdict: Equatable {
        case allow
        case reject(status: Int, reason: String)
    }

    /// `headers` has lower-case names. The secret must arrive as a bearer token; a request that names an Origin (so it came from a
    /// web page) or a Host other than this machine's address is refused, which also stops DNS-rebinding tricks.
    static func judge(method: String, path: String, headers: [String: String], secret: String, port: UInt16, allowedPaths: Set<String>) -> Verdict {
        let host = (headers["host"] ?? "").lowercased()
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else { return .reject(status: 403, reason: "Wrong host.") }
        if headers["origin"] != nil { return .reject(status: 403, reason: "Requests from web pages are not accepted.") }
        guard method == "POST" else { return .reject(status: 405, reason: "Use POST.") }
        guard allowedPaths.contains(path) else { return .reject(status: 404, reason: "Not found.") }
        let auth = headers["authorization"] ?? ""
        guard auth.hasPrefix("Bearer "), BridgeProtocol.constantTimeEqual(String(auth.dropFirst(7)), secret), !secret.isEmpty else { return .reject(status: 401, reason: "A valid bearer token is required.") }
        return .allow
    }

    /// Splits a raw request into method, path, headers and body. Nil if it is not complete yet, `.failure` if it can never be valid.
    static func parse(_ data: Data) -> Result<(method: String, path: String, headers: [String: String], body: Data)?, Error> {
        guard data.count <= maxBytes else { return .failure(AIError.inputTooLarge(maxBytes)) }
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return .success(nil) }
        let head = String(decoding: data[..<range.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ").map(String.init)
        guard start.count == 3 else { return .failure(AIError.badResponse) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxBytes else { return .failure(AIError.inputTooLarge(maxBytes)) }
        let body = data[range.upperBound...]
        if body.count < length { return .success(nil) }
        return .success((start[0], start[1], headers, Data(body.prefix(length))))
    }
}

/// A server on this Mac's loopback address only (127.0.0.1) that answers MCP requests at /mcp, and a few Kriya commands at
/// /api/run. Every request needs a random secret in an Authorization header; nothing else gets an answer. Off until turned on.
final class MCPHTTPServer: ObservableObject {
    static let shared = MCPHTTPServer()
    private static let enabledKey = "mcpServer.enabled"
    private static let portKey = "mcpServer.port"
    static let defaultPort: UInt16 = 47615

    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); FeatureActivity.shared.changed("mcpServer", enabled ? "Turned on" : "Turned off"); enabled ? start() : stop() } }
    @Published var port: UInt16 { didSet { UserDefaults.standard.set(Int(port), forKey: Self.portKey); if enabled { stop(); start() } } }
    @Published private(set) var status: String?
    @Published private(set) var requests = 0

    var engine: AIToolEngine = .shared
    var secretFile: URL = AppPaths.live.support.appendingPathComponent("mcp-token")
    private var listener: NWListener?
    private var limiter = AIRateLimiter()
    private let queue = DispatchQueue(label: "app.kriya.mcp-server")

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let saved = UserDefaults.standard.integer(forKey: Self.portKey)
        port = saved > 1024 && saved < 65536 ? UInt16(saved) : Self.defaultPort
    }

    /// The secret clients must send. Made once; a new one can be made at any time, which locks out every client.
    var secret: String {
        if let existing = try? String(contentsOf: secretFile, encoding: .utf8), existing.count >= 32 { return existing.trimmingCharacters(in: .whitespacesAndNewlines) }
        return regenerateSecret()
    }

    @discardableResult
    func regenerateSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: secretFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? token.write(to: secretFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretFile.path)
        objectWillChange.send()
        return token
    }

    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    func start() {
        guard enabled, listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? 47615)
        do {
            let l = try NWListener(using: parameters)
            l.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready: self?.status = "Listening on 127.0.0.1:\(self?.port ?? 0)"
                    case .failed(let error): self?.status = "Could not listen: \(error.localizedDescription). Try another port."; self?.listener = nil
                    default: break
                    }
                }
            }
            l.start(queue: queue)
            listener = l
            _ = secret
        } catch {
            status = "Could not listen: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        status = nil
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        // Only this Mac's loopback address can have reached the listener, but a connection from anywhere else is dropped anyway.
        if case .hostPort(let host, _) = connection.endpoint, !(host == .ipv4(.loopback) || host == .ipv6(.loopback)) { connection.cancel(); return }
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + 15, execute: deadline)
        receive(connection, buffer: Data(), deadline: deadline)
    }

    private func receive(_ connection: NWConnection, buffer: Data, deadline: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var all = buffer
            if let data { all.append(data) }
            switch LoopbackRequestRules.parse(all) {
            case .failure: self.reply(connection, 413, "The request is not acceptable.", deadline: deadline)
            case .success(let parsed):
                if let parsed { Task { await self.respond(connection, parsed, deadline: deadline) } }
                else if error != nil || isComplete { connection.cancel() }
                else { self.receive(connection, buffer: all, deadline: deadline) }
            }
        }
    }

    private func respond(_ connection: NWConnection, _ request: (method: String, path: String, headers: [String: String], body: Data), deadline: DispatchWorkItem) async {
        let verdict = LoopbackRequestRules.judge(method: request.method, path: request.path, headers: request.headers, secret: secret, port: port, allowedPaths: ["/mcp", "/api/run"])
        if case .reject(let status, let reason) = verdict { reply(connection, status, reason, deadline: deadline); return }
        if limiter.count() >= 60 { reply(connection, 429, "Too many requests.", deadline: deadline); return }
        limiter.record()
        await MainActor.run { requests += 1 }
        FeatureActivity.shared.used("mcpServer")
        if request.path == "/api/run" { reply(connection, 200, await runCommand(request.body), json: true, deadline: deadline); return }
        let version = SystemInfo.appVersion
        let answer = await MCPServerCore.handle(request.body, tools: engine.registryForOutsideClients, serverVersion: version) { [engine] call in
            let result = await engine.run(call, context: AIToolContext(feature: .launcher, localOnlyMode: LocalOnly.isOn, suspectedInjection: false, fromExternalClient: true), requester: "A program connected to Kriya")
            return MCPToolResult(text: result.content, isError: result.isError)
        }
        if let answer { reply(connection, 200, String(decoding: answer, as: UTF8.self), json: true, deadline: deadline) }
        else { reply(connection, 202, "", deadline: deadline) }
    }

    /// `{"type":"command|action|workflow","id":"…"}` to the same paths `kriya://` uses, with the same name checks.
    private func runCommand(_ body: Data) async -> String {
        guard let json = JSONValue.parse(String(decoding: body, as: UTF8.self)), let type = json["type"]?.stringValue, let id = json["id"]?.stringValue, RemoteCommand.isValidID(id) else {
            return #"{"ok":false,"error":"Send {\"type\":\"command|action|workflow\",\"id\":\"…\"}."}"#
        }
        let command: RemoteCommand
        switch type {
        case "command": command = .command(id)
        case "action": command = .action(id)
        case "workflow": command = .workflow(id)
        default: return #"{"ok":false,"error":"Unknown type."}"#
        }
        await MainActor.run { RemoteCommands.shared?.perform(command) }
        return #"{"ok":true}"#
    }

    private func reply(_ connection: NWConnection, _ status: Int, _ body: String, json: Bool = false, deadline: DispatchWorkItem) {
        let text = HTTPURLResponse.localizedString(forStatusCode: status)
        let payload = json ? body : (body.isEmpty ? "" : #"{"error":"\#(body.replacingOccurrences(of: "\"", with: "'"))"}"#)
        let head = "HTTP/1.1 \(status) \(text)\r\nContent-Type: application/json\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        connection.send(content: Data((head + payload).utf8), completion: .contentProcessed { _ in
            deadline.cancel()
            connection.cancel()
        })
    }
}

extension AIToolEngine {
    /// What an outside program is shown: Kriya's own tools, not the ones from other servers Kriya is connected to.
    var registryForOutsideClients: [AITool] { KriyaTools.all }
}
