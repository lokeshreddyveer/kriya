import Foundation

struct MCPToolResult: Equatable {
    var text: String
    var isError: Bool
}

/// The server side of the Model Context Protocol: JSON-RPC 2.0 messages in, messages out. It only offers tools, and each call is
/// passed to `call`, which applies Kriya's own validation and approval; this code decides nothing about safety.
enum MCPServerCore {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let maxRequestBytes = 1_000_000
    static let instructions = "Kriya's tools. Some change things on the user's Mac and ask the user to confirm first; do not retry a refused call."

    private static func result(_ id: JSONValue?, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id ?? .null, "result": result])
    }

    private static func failure(_ id: JSONValue?, _ code: Int, _ message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id ?? .null, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }

    static func toolDescription(_ tool: AITool) -> JSONValue {
        .object([
            "name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.parameters,
            "annotations": .object([
                "title": .string(tool.name),
                "readOnlyHint": .bool(tool.risk == .readOnly || tool.risk == .sensitiveRead),
                "destructiveHint": .bool(tool.risk >= .destructive),
                "openWorldHint": .bool(tool.risk == .externalNetwork),
            ]),
        ])
    }

    /// The answer to one request body, or nil when nothing is to be sent back (only notifications were received).
    static func handle(_ body: Data, tools: [AITool], serverName: String = "Kriya", serverVersion: String, call: @escaping (AIToolCall) async -> MCPToolResult) async -> Data? {
        guard body.count <= maxRequestBytes else { return encode(failure(nil, -32600, "The request is too large.")) }
        guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: body) else { return encode(failure(nil, -32700, "Parse error")) }
        if case .array(let batch) = parsed {
            guard !batch.isEmpty, batch.count <= 20 else { return encode(failure(nil, -32600, "Invalid batch")) }
            var out: [JSONValue] = []
            for message in batch { if let r = await handleOne(message, tools: tools, serverName: serverName, serverVersion: serverVersion, call: call) { out.append(r) } }
            return out.isEmpty ? nil : encode(.array(out))
        }
        return await handleOne(parsed, tools: tools, serverName: serverName, serverVersion: serverVersion, call: call).flatMap(encode)
    }

    private static func encode(_ value: JSONValue) -> Data? { try? JSONEncoder().encode(value) }

    private static func handleOne(_ message: JSONValue, tools: [AITool], serverName: String, serverVersion: String, call: @escaping (AIToolCall) async -> MCPToolResult) async -> JSONValue? {
        guard case .object = message, message["jsonrpc"]?.stringValue == "2.0", let method = message["method"]?.stringValue else {
            return message["id"] != nil ? failure(message["id"], -32600, "Invalid request") : nil
        }
        let id = message["id"]
        let params = message["params"]
        let isNotification = id == nil
        switch method {
        case "initialize":
            let asked = params?["protocolVersion"]?.stringValue ?? ""
            let version = supportedVersions.contains(asked) ? asked : supportedVersions[0]
            return result(id, .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string(serverName), "version": .string(serverVersion)]),
                "instructions": .string(instructions),
            ]))
        case "ping":
            return isNotification ? nil : result(id, .object([:]))
        case "tools/list":
            return isNotification ? nil : result(id, .object(["tools": .array(tools.map(toolDescription))]))
        case "tools/call":
            if isNotification { return nil }
            guard let name = params?["name"]?.stringValue else { return failure(id, -32602, "A tool name is required.") }
            let arguments = params?["arguments"]?.objectValue ?? [:]
            let outcome = await call(AIToolCall(id: AIWireSupport.newCallID(), name: name, arguments: arguments))
            return result(id, .object(["content": .array([.object(["type": .string("text"), "text": .string(outcome.text)])]), "isError": .bool(outcome.isError)]))
        default:
            // Notifications such as "notifications/initialized" and "notifications/cancelled" need no answer.
            return isNotification ? nil : failure(id, -32601, "Method not found: \(method)")
        }
    }
}

// MARK: - Connecting to other MCP servers

struct MCPServerConfig: Codable, Equatable, Identifiable {
    enum Transport: String, Codable, CaseIterable, Identifiable {
        case stdio, http
        var id: String { rawValue }
        var title: String { self == .stdio ? "Program on this Mac" : "Web address" }
    }

    enum Approval: String, Codable, CaseIterable, Identifiable {
        /// Every call asks.
        case askEveryTime
        /// The first call of each tool asks; the person may then allow it.
        case askFirstTime
        /// Tools the person marked read-only run without asking.
        case autoForReadOnly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .askEveryTime: return "Ask every time"
            case .askFirstTime: return "Ask the first time"
            case .autoForReadOnly: return "Don't ask for tools marked read-only"
            }
        }
    }

    var id: String
    var name: String
    var transport: Transport
    /// For a program: the full path of the executable. Never a shell line.
    var command: String
    var arguments: [String]
    /// Names and values given to the program, in addition to a minimal environment. Do not put secrets here.
    var environment: [String: String]
    var url: String
    /// A bearer token is kept in the Keychain under `tokenAccount`.
    var usesToken: Bool
    /// Only these tools are offered to the model. Empty means none.
    var allowedTools: [String]
    /// Only addresses starting with one of these can be read as resources. Empty means none.
    var allowedResources: [String]
    var approval: Approval
    /// What the person marked as how risky each tool is. A tool not listed is treated as reaching the network (a web address) or as privileged (a program).
    var toolRisk: [String: AIRisk]
    /// Hosts this server may be contacted at. A web address must be at one of them.
    var networkScope: [String]
    var enabled: Bool
    var lastUsed: Date?

    init(id: String = UUID().uuidString, name: String, transport: Transport = .stdio, command: String = "", arguments: [String] = [], environment: [String: String] = [:], url: String = "",
         usesToken: Bool = false, allowedTools: [String] = [], allowedResources: [String] = [], approval: Approval = .askEveryTime, toolRisk: [String: AIRisk] = [:],
         networkScope: [String] = [], enabled: Bool = false, lastUsed: Date? = nil) {
        self.id = id; self.name = name; self.transport = transport; self.command = command; self.arguments = arguments; self.environment = environment; self.url = url
        self.usesToken = usesToken; self.allowedTools = allowedTools; self.allowedResources = allowedResources; self.approval = approval; self.toolRisk = toolRisk
        self.networkScope = networkScope; self.enabled = enabled; self.lastUsed = lastUsed
    }

    var tokenAccount: String { "kriya.ai.mcp.\(id).token" }

    /// The name used in tool names: letters and digits only, up to 16.
    var slug: String {
        let cleaned = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return String((cleaned.isEmpty ? "server" : cleaned).prefix(16))
    }

    var host: String? { URL(string: url)?.host?.lowercased() }

    var problems: [String] {
        var out: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Give the server a name.") }
        switch transport {
        case .stdio:
            if !command.hasPrefix("/") || command.contains("\0") || command.count > 1024 { out.append("Give the full path of the program, starting with /.") }
            if arguments.contains(where: { $0.contains("\0") }) { out.append("An argument contains an invalid character.") }
            for key in environment.keys where key.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,63}$"#, options: .regularExpression) == nil { out.append("“\(key)” is not a valid environment variable name.") }
            if environment.keys.contains(where: { ["PATH", "HOME", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "LD_PRELOAD"].contains($0.uppercased()) }) { out.append("PATH, HOME and library-loading variables cannot be set here.") }
        case .http:
            guard let u = URL(string: url), let scheme = u.scheme?.lowercased(), let host = u.host else { out.append("The address is not a web address."); break }
            if u.user != nil || u.password != nil || u.query != nil { out.append("The address must not hold a user name, password or query. Use the token field.") }
            if scheme != "https" && !(scheme == "http" && AIProviderConfig.isLoopback(host)) { out.append("Use https (plain http only for an address on this Mac).") }
            if !networkScope.isEmpty && !networkScope.map({ $0.lowercased() }).contains(host.lowercased()) { out.append("The address is not in the allowed hosts.") }
        }
        return out
    }

    func isToolAllowed(_ tool: String) -> Bool { allowedTools.contains(tool) }

    func isResourceAllowed(_ uri: String) -> Bool { allowedResources.contains { !$0.isEmpty && uri.hasPrefix($0) } }

    /// The risk a tool is treated as having. A server's approval setting can only raise it.
    func risk(of tool: String) -> AIRisk {
        let base = toolRisk[tool] ?? (transport == .http ? .externalNetwork : .privileged)
        switch approval {
        case .askEveryTime: return max(base, .destructive)
        case .askFirstTime: return max(base, .write)
        case .autoForReadOnly: return base
        }
    }

    /// The tools of this server that the model may use, named so they cannot collide with Kriya's own.
    func aiTools(from listed: [AITool]) -> [AITool] {
        listed.filter { isToolAllowed($0.name) }.map { tool in
            AITool(name: Self.exposedName(slug: slug, tool: tool.name), description: "[\(name)] " + tool.description, parameters: tool.parameters, risk: risk(of: tool.name))
        }
    }

    static func exposedName(slug: String, tool: String) -> String {
        let safe = tool.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }
        return String(("mcp." + slug + "." + String(safe)).prefix(64))
    }
}

enum MCPClientRules {
    static let maxResultCharacters = 20_000
    static let maxTools = 100
    static let maxSchemaBytes = 20_000
    static let maxSchemaDepth = 8

    /// A tool description made safe to put in front of a model: one line, no control characters, and cut short. Wording that tries to
    /// give the model orders is flagged separately so the person can see it before allowing the tool.
    static func cleanDescription(_ text: String) -> String {
        String(String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(300))
    }

    static func descriptionWarnings(_ text: String) -> [String] { InjectionDetector.warnings(in: text) }

    static func depth(_ value: JSONValue) -> Int {
        switch value {
        case .object(let o): return 1 + (o.values.map(depth).max() ?? 0)
        case .array(let a): return 1 + (a.map(depth).max() ?? 0)
        default: return 0
        }
    }

    /// An MCP tool result as plain text. Pictures and other kinds are named, not passed along.
    static func text(from result: JSONValue) -> (text: String, isError: Bool) {
        let isError = result["isError"] == .bool(true)
        let parts = (result["content"]?.arrayValue ?? []).map { block -> String in
            if block["type"]?.stringValue == "text" { return block["text"]?.stringValue ?? "" }
            return "[\(block["type"]?.stringValue ?? "content") omitted]"
        }
        return (String(parts.joined(separator: "\n").prefix(maxResultCharacters)), isError)
    }

    /// The tools a server listed, as Kriya's tool type. Names and schemas that are not valid are dropped.
    static func tools(from result: JSONValue) -> [AITool] {
        (result["tools"]?.arrayValue ?? []).prefix(maxTools).compactMap { entry in
            guard let name = entry["name"]?.stringValue, name.range(of: #"^[A-Za-z0-9_.\-]{1,64}$"#, options: .regularExpression) != nil else { return nil }
            let schema = entry["inputSchema"] ?? .object(["type": .string("object")])
            guard schema["type"]?.stringValue == "object", schema.text.utf8.count <= maxSchemaBytes, depth(schema) <= maxSchemaDepth else { return nil }
            return AITool(name: name, description: cleanDescription(entry["description"]?.stringValue ?? ""), parameters: schema, risk: .privileged)
        }
    }

    /// Reads the first JSON-RPC message with the given id out of a Server-Sent Events body or a plain JSON body.
    static func message(withID id: Int, in body: String) -> JSONValue? {
        var candidates: [String] = []
        if body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") || body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") { candidates = [body] }
        else { candidates = body.split(separator: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) } }
        for text in candidates {
            guard let value = JSONValue.parse(text) else { continue }
            let list = value.arrayValue ?? [value]
            if let match = list.first(where: { $0["id"]?.numberValue == Double(id) }) { return match }
        }
        return nil
    }
}
