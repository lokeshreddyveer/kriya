import XCTest
@testable import Kriya

final class KriyaToolsTests: XCTestCase {
    func testEveryToolIsNamedShapedAndRatedSensibly() {
        for tool in KriyaTools.all {
            XCTAssertNotNil(tool.name.range(of: AIToolPolicy.namePattern, options: .regularExpression), tool.name)
            XCTAssertEqual(tool.parameters["type"]?.stringValue, "object", tool.name)
            XCTAssertEqual(tool.parameters["additionalProperties"], .bool(false), "\(tool.name) accepts only the named arguments")
        }
        XCTAssertEqual(Set(KriyaTools.all.map(\.name)).count, KriyaTools.all.count)
        for name in ["kriya.move_file", "kriya.delete_file", "kriya.install_app", "kriya.run_script", "kriya.execute_workflow", "kriya.change_shortcut", "kriya.export_clipboard"] {
            XCTAssertGreaterThanOrEqual(KriyaTools.tool(named: name)?.risk ?? .readOnly, .destructive, "\(name) must always ask")
        }
        for name in ["kriya.search_clipboard", "kriya.get_selected_text"] { XCTAssertEqual(KriyaTools.tool(named: name)?.risk, .sensitiveRead) }
        XCTAssertEqual(KriyaTools.tool(named: "kriya.list_windows")?.risk, .readOnly)
    }

    func testNoToolTakesTextThatCouldBeRunAsACommand() {
        // The only text arguments that reach a shell-like place are names and ids with strict patterns.
        let run = KriyaTools.tool(named: "kriya.run_script")!
        XCTAssertFalse(JSONSchemaValidator.validate(.object(["script_id": .string("x; rm -rf ~")]), against: run.parameters).isEmpty)
        XCTAssertFalse(JSONSchemaValidator.validate(.object(["script_id": .string("ok"), "script": .string("echo hi")]), against: run.parameters).isEmpty, "there is no argument for script text")
        XCTAssertTrue(JSONSchemaValidator.validate(.object(["script_id": .string("backup.nightly")]), against: run.parameters).isEmpty)
        let install = KriyaTools.tool(named: "kriya.install_app")!
        XCTAssertFalse(JSONSchemaValidator.validate(.object(["cask": .string("firefox && curl evil")]), against: install.parameters).isEmpty)
        XCTAssertTrue(JSONSchemaValidator.validate(.object(["cask": .string("visual-studio-code")]), against: install.parameters).isEmpty)
        let move = KriyaTools.tool(named: "kriya.move_file")!
        XCTAssertFalse(JSONSchemaValidator.validate(.object(["from": .string("relative/path"), "to": .string("/Users/me")]), against: move.parameters).isEmpty, "paths must be absolute")
    }
}

final class MCPServerCoreTests: XCTestCase {
    private let tools = [KriyaTools.tool(named: "kriya.list_windows")!, KriyaTools.tool(named: "kriya.delete_file")!]
    private func send(_ json: String, call: @escaping (AIToolCall) async -> MCPToolResult = { _ in MCPToolResult(text: "ok", isError: false) }) async -> JSONValue? {
        guard let data = await MCPServerCore.handle(Data(json.utf8), tools: tools, serverVersion: "1.2.3", call: call) else { return nil }
        return JSONValue.parse(String(decoding: data, as: UTF8.self))
    }

    func testTheHandshakeNegotiatesAVersionAndOnlyOffersTools() async throws {
        let reply = try XCTUnwrap(await send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#))
        XCTAssertEqual(reply["result"]?["protocolVersion"]?.stringValue, "2024-11-05")
        XCTAssertNotNil(reply["result"]?["capabilities"]?["tools"])
        XCTAssertNil(reply["result"]?["capabilities"]?["resources"])
        XCTAssertEqual(reply["result"]?["serverInfo"]?["version"]?.stringValue, "1.2.3")
        let unknown = try XCTUnwrap(await send(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        XCTAssertEqual(unknown["result"]?["protocolVersion"]?.stringValue, MCPServerCore.supportedVersions[0])
        let nilReply = await send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(nilReply, "a notification gets no answer")
    }

    func testToolsAreListedWithTheirHints() async throws {
        let reply = try XCTUnwrap(await send(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#))
        let list = try XCTUnwrap(reply["result"]?["tools"]?.arrayValue)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0]["annotations"]?["readOnlyHint"], .bool(true))
        XCTAssertEqual(list[1]["annotations"]?["destructiveHint"], .bool(true))
        XCTAssertNotNil(list[1]["inputSchema"])
    }

    func testCallsGoToTheCallbackAndItsAnswerIsWrapped() async throws {
        var seen: AIToolCall?
        let reply = try XCTUnwrap(await send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"kriya.delete_file","arguments":{"path":"/Users/me/x"}}}"#) { call in seen = call; return MCPToolResult(text: "refused", isError: true) })
        XCTAssertEqual(seen?.name, "kriya.delete_file")
        XCTAssertEqual(seen?.arguments["path"], .string("/Users/me/x"))
        XCTAssertEqual(reply["result"]?["isError"], .bool(true))
        XCTAssertEqual(reply["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "refused")
    }

    func testBadInputGetsStandardErrors() async throws {
        XCTAssertEqual(try XCTUnwrap(await send("{not json"))["error"]?["code"], .number(-32700))
        XCTAssertEqual(try XCTUnwrap(await send(#"{"jsonrpc":"2.0","id":5,"method":"nope"}"#))["error"]?["code"], .number(-32601))
        XCTAssertEqual(try XCTUnwrap(await send(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{}}"#))["error"]?["code"], .number(-32602))
        XCTAssertEqual(try XCTUnwrap(await send(#"{"id":7,"method":"ping"}"#))["error"]?["code"], .number(-32600), "not JSON-RPC 2.0")
        XCTAssertEqual(try XCTUnwrap(await send("[]"))["error"]?["code"], .number(-32600))
        let batch = try XCTUnwrap(await send(#"[{"jsonrpc":"2.0","id":8,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#))
        XCTAssertEqual(batch.arrayValue?.count, 1)
        let huge = String(repeating: " ", count: MCPServerCore.maxRequestBytes + 1)
        XCTAssertNotNil(try XCTUnwrap(await send(huge))["error"])
    }
}

final class LoopbackRulesTests: XCTestCase {
    private let secret = String(repeating: "ab", count: 16)
    private func judge(_ method: String = "POST", path: String = "/mcp", headers: [String: String]) -> LoopbackRequestRules.Verdict {
        LoopbackRequestRules.judge(method: method, path: path, headers: headers, secret: secret, port: 47615, allowedPaths: ["/mcp", "/api/run"])
    }
    private var good: [String: String] { ["host": "127.0.0.1:47615", "authorization": "Bearer \(secret)"] }

    func testOnlyAnAuthenticatedLoopbackPostIsAnswered() {
        XCTAssertEqual(judge(headers: good), .allow)
        XCTAssertEqual(judge(headers: ["host": "127.0.0.1:47615"]), .reject(status: 401, reason: "A valid bearer token is required."))
        XCTAssertEqual(judge(headers: good.merging(["authorization": "Bearer wrong"]) { $1 }), .reject(status: 401, reason: "A valid bearer token is required."))
        XCTAssertEqual(judge(headers: good.merging(["host": "evil.example.com:47615"]) { $1 }), .reject(status: 403, reason: "Wrong host."), "DNS rebinding")
        XCTAssertEqual(judge(headers: good.merging(["origin": "https://evil.example.com"]) { $1 }), .reject(status: 403, reason: "Requests from web pages are not accepted."))
        XCTAssertEqual(judge("GET", headers: good), .reject(status: 405, reason: "Use POST."))
        XCTAssertEqual(judge(path: "/other", headers: good), .reject(status: 404, reason: "Not found."))
        XCTAssertEqual(LoopbackRequestRules.judge(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:47615", "authorization": "Bearer "], secret: "", port: 47615, allowedPaths: ["/mcp"]), .reject(status: 401, reason: "A valid bearer token is required."), "an empty secret never matches")
    }

    func testRequestsAreParsedOnlyWhenComplete() throws {
        let body = #"{"a":1}"#
        let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47615\r\nContent-Length: \(body.utf8.count)\r\nAuthorization: Bearer x\r\n\r\n"
        XCTAssertNil(try LoopbackRequestRules.parse(Data(head.utf8)).get(), "body still to come")
        let parsed = try XCTUnwrap(LoopbackRequestRules.parse(Data((head + body).utf8)).get())
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/mcp")
        XCTAssertEqual(parsed.headers["authorization"], "Bearer x")
        XCTAssertEqual(String(decoding: parsed.body, as: UTF8.self), body)
        XCTAssertNil(try LoopbackRequestRules.parse(Data("POST /mcp HT".utf8)).get())
        if case .success = LoopbackRequestRules.parse(Data("garbage\r\n\r\n".utf8)) { XCTFail() }
        if case .success = LoopbackRequestRules.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) { XCTFail() }
    }
}

final class MCPClientRulesTests: XCTestCase {
    func testOnlyAllowedToolsAreOfferedUnderSafeNames() {
        var config = MCPServerConfig(name: "My GitHub!", transport: .http, url: "https://mcp.example.com/mcp", allowedTools: ["list_issues"], approval: .autoForReadOnly)
        config.toolRisk["list_issues"] = .readOnly
        let listed = [AITool(name: "list_issues", description: "d", parameters: .object(["type": .string("object")]), risk: .privileged),
                      AITool(name: "delete_repo", description: "d", parameters: .object(["type": .string("object")]), risk: .privileged)]
        let offered = config.aiTools(from: listed)
        XCTAssertEqual(offered.map(\.name), ["mcp.mygithub.list_issues"])
        XCTAssertEqual(offered[0].risk, .readOnly)
        XCTAssertNotNil(offered[0].name.range(of: AIToolPolicy.namePattern, options: .regularExpression))
        XCTAssertEqual(MCPServerConfig.exposedName(slug: "s", tool: "do thing/now"), "mcp.s.do_thing_now")
        XCTAssertTrue(MCPServerConfig.exposedName(slug: "s", tool: String(repeating: "a", count: 200)).count <= 64)
    }

    func testApprovalSettingsOnlyRaiseRisk() {
        var config = MCPServerConfig(name: "s", transport: .stdio, command: "/bin/echo", allowedTools: ["t"])
        config.toolRisk["t"] = .readOnly
        config.approval = .askEveryTime
        XCTAssertGreaterThanOrEqual(config.risk(of: "t"), .destructive, "ask every time cannot be turned off by the engine's always setting")
        config.approval = .askFirstTime
        XCTAssertEqual(config.risk(of: "t"), .write)
        config.approval = .autoForReadOnly
        XCTAssertEqual(config.risk(of: "t"), .readOnly)
        XCTAssertEqual(config.risk(of: "unmarked"), .privileged, "a program's unmarked tool is treated as running programs")
        config.transport = .http
        XCTAssertEqual(config.risk(of: "unmarked"), .externalNetwork)
    }

    func testSettingsAreValidated() {
        XCTAssertFalse(MCPServerConfig(name: "x", transport: .stdio, command: "node server.js").problems.isEmpty, "a shell line is not a program path")
        XCTAssertTrue(MCPServerConfig(name: "x", transport: .stdio, command: "/usr/local/bin/server").problems.isEmpty)
        XCTAssertFalse(MCPServerConfig(name: "x", transport: .stdio, command: "/bin/x", environment: ["PATH": "/tmp"]).problems.isEmpty)
        XCTAssertFalse(MCPServerConfig(name: "x", transport: .stdio, command: "/bin/x", environment: ["DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"]).problems.isEmpty)
        XCTAssertFalse(MCPServerConfig(name: "x", transport: .http, url: "http://example.com/mcp").problems.isEmpty, "plain http to another machine")
        XCTAssertTrue(MCPServerConfig(name: "x", transport: .http, url: "http://localhost:3000/mcp").problems.isEmpty)
        XCTAssertFalse(MCPServerConfig(name: "x", transport: .http, url: "https://user:pw@example.com/mcp").problems.isEmpty)
        XCTAssertFalse(MCPServerConfig(name: "x", transport: .http, url: "https://a.example.com/mcp", networkScope: ["b.example.com"]).problems.isEmpty)
    }

    func testResourcesAreReadableOnlyUnderAllowedPrefixes() {
        let config = MCPServerConfig(name: "x", allowedResources: ["notion://workspace/"])
        XCTAssertTrue(config.isResourceAllowed("notion://workspace/page-1"))
        XCTAssertFalse(config.isResourceAllowed("file:///etc/passwd"))
        XCTAssertFalse(MCPServerConfig(name: "x", allowedResources: [""]).isResourceAllowed("anything"))
        XCTAssertFalse(MCPServerConfig(name: "x").isResourceAllowed("notion://workspace/page-1"), "none allowed by default")
    }

    func testResultsAndListsAreReadSafely() {
        let result = JSONValue.parse(#"{"content":[{"type":"text","text":"hello"},{"type":"image","data":"AAAA"}],"isError":false}"#)!
        let text = MCPClientRules.text(from: result)
        XCTAssertEqual(text.text, "hello\n[image omitted]")
        XCTAssertFalse(text.isError)
        let list = JSONValue.parse(#"{"tools":[{"name":"ok_tool","description":"d","inputSchema":{"type":"object"}},{"name":"bad name!","inputSchema":{"type":"object"}},{"name":"no_schema_type","inputSchema":{"type":"string"}}]}"#)!
        XCTAssertEqual(MCPClientRules.tools(from: list).map(\.name), ["ok_tool"])
        let sse = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"a\":1}}\n\n"
        XCTAssertEqual(MCPClientRules.message(withID: 3, in: sse)?["result"]?["a"], .number(1))
        XCTAssertNil(MCPClientRules.message(withID: 4, in: sse))
        XCTAssertNotNil(MCPClientRules.message(withID: 1, in: #"{"jsonrpc":"2.0","id":1,"result":{}}"#))
    }
}

final class AIToolEngineTests: XCTestCase {
    final class Host: KriyaToolHost {
        var ran: [String] = []
        func execute(_ tool: AITool, arguments: [String: JSONValue]) async throws -> String {
            ran.append(tool.name)
            return "result with key sk-abcdefghijklmnopqrstuvwxyz"
        }
    }
    struct Prompter: ApprovalPrompter {
        var answer = true
        var remember = false
        func confirm(tool: AITool, arguments: String, reason: String, requester: String, allowRemember: Bool) async -> (allowed: Bool, remember: Bool) { (answer, remember && allowRemember) }
    }

    private func engine(host: Host, prompter: Prompter, tools: [String: [String]] = ["launcher": ["kriya.list_windows", "kriya.set_audio_profile", "kriya.delete_file"]]) -> AIToolEngine {
        let defaults = UserDefaults(suiteName: "kriya-engine-\(UUID().uuidString)")!
        let store = AIProviderStore(defaults: defaults)
        store.toolSettings.toolsByFeature = tools
        let engine = AIToolEngine()
        engine.host = host
        engine.prompter = prompter
        engine.store = store
        return engine
    }
    private let context = AIToolContext(feature: .launcher, localOnlyMode: false, suspectedInjection: false)

    func testReadOnlyToolsRunAtOnceAndTheirAnswerIsCleaned() async {
        let host = Host()
        let result = await engine(host: host, prompter: Prompter(answer: false)).run(AIToolCall(id: "1", name: "kriya.list_windows", arguments: [:]), context: context)
        XCTAssertTrue(result.ran)
        XCTAssertEqual(host.ran, ["kriya.list_windows"])
        XCTAssertFalse(result.content.contains("sk-abcdefgh"))
        XCTAssertTrue(result.content.hasPrefix("<untrusted_content"))
    }

    func testRefusalMeansNothingRuns() async {
        let host = Host()
        let e = engine(host: host, prompter: Prompter(answer: false))
        let result = await e.run(AIToolCall(id: "1", name: "kriya.delete_file", arguments: ["path": .string("/Users/me/a.txt")]), context: context)
        XCTAssertFalse(result.ran)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(host.ran.isEmpty)
    }

    func testBadCallsNeverReachTheHost() async {
        let host = Host()
        let e = engine(host: host, prompter: Prompter())
        for call in [AIToolCall(id: "1", name: "rm", arguments: [:]), AIToolCall(id: "2", name: "kriya.nope", arguments: [:]),
                     AIToolCall(id: "3", name: "kriya.delete_file", arguments: ["path": .string("relative")]),
                     AIToolCall(id: "4", name: "kriya.delete_file", arguments: [:]),
                     AIToolCall(id: "5", name: "kriya.run_script", arguments: ["script_id": .string("a")])] {
            let result = await e.run(call, context: context)
            XCTAssertFalse(result.ran, call.name)
        }
        XCTAssertTrue(host.ran.isEmpty)
    }

    func testAnApprovedWriteRunsAndDestructiveToolsAlwaysAskEvenWhenRemembered() async {
        let host = Host()
        let e = engine(host: host, prompter: Prompter(answer: true, remember: true))
        let write = await e.run(AIToolCall(id: "1", name: "kriya.set_audio_profile", arguments: ["name": .string("Meeting")]), context: context)
        XCTAssertTrue(write.ran)
        XCTAssertEqual(e.store.toolSettings.perTool["kriya.set_audio_profile"], .always, "remembered for a tool that may be")
        let destroy = await e.run(AIToolCall(id: "2", name: "kriya.delete_file", arguments: ["path": .string("/Users/me/a.txt")]), context: context)
        XCTAssertTrue(destroy.ran)
        XCTAssertNil(e.store.toolSettings.perTool["kriya.delete_file"], "a destructive tool cannot be set to never ask")
    }

    func testLocalOnlyAndUnlistedFeaturesBlockTools() async {
        let host = Host()
        let e = engine(host: host, prompter: Prompter(), tools: [:])
        let result = await e.run(AIToolCall(id: "1", name: "kriya.set_audio_profile", arguments: ["name": .string("x")]), context: context)
        XCTAssertFalse(result.ran, "no tools were given to this feature")
        let readOnly = await e.run(AIToolCall(id: "2", name: "kriya.list_windows", arguments: [:]), context: context)
        XCTAssertTrue(readOnly.ran, "reading public information needs no list")
    }
}
