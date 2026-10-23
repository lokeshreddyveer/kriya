import AppKit
import ApplicationServices

struct ToolUnavailable: Error, LocalizedError {
    let name: String
    var errorDescription: String? { "\(name) is not available in this version of Kriya." }
}

struct AIToolResult: Equatable {
    /// What the model is shown: cut, with secrets hidden, and marked as data.
    var content: String
    var isError: Bool
    var ran: Bool
}

/// Asks the person. Replaced in tests.
protocol ApprovalPrompter {
    /// `allowRemember` is offered only for tools that may be allowed for good.
    func confirm(tool: AITool, arguments: String, reason: String, requester: String, allowRemember: Bool) async -> (allowed: Bool, remember: Bool)
}

struct AlertPrompter: ApprovalPrompter {
    func confirm(tool: AITool, arguments: String, reason: String, requester: String, allowRemember: Bool) async -> (allowed: Bool, remember: Bool) {
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = tool.risk >= .destructive ? .critical : .warning
            alert.messageText = "\(requester) wants to use “\(tool.name)”"
            alert.informativeText = "\(tool.description)\n\n\(reason)\n\nWith: \(arguments)"
            alert.addButton(withTitle: "Allow Once")
            alert.addButton(withTitle: "Don't Allow")
            var checkbox: NSButton?
            if allowRemember {
                let box = NSButton(checkboxWithTitle: "Don't ask again for this tool", target: nil, action: nil)
                alert.accessoryView = box
                checkbox = box
            }
            NSApp.activate(ignoringOtherApps: true)
            let allowed = alert.runModal() == .alertFirstButtonReturn
            return (allowed, allowed && checkbox?.state == .on)
        }
    }
}

/// What a tool does when it runs. Kriya's own implementation is `LiveToolHost`; the engine never runs anything itself.
protocol KriyaToolHost {
    func execute(_ tool: AITool, arguments: [String: JSONValue]) async throws -> String
}

/// Every tool call goes through here: the name and arguments are checked, the risk decides whether to ask, the person is asked if
/// needed, the host runs it, and the answer is cut and cleaned before the model sees it. Every call is written to the activity log.
final class AIToolEngine {
    static let shared = AIToolEngine()

    var host: KriyaToolHost = LiveToolHost()
    var prompter: ApprovalPrompter = AlertPrompter()
    var store: AIProviderStore = .shared
    /// Tools from connected MCP servers, added to Kriya's own.
    var extraTools: () -> [AITool] = { [] }
    var extraHost: (AITool, [String: JSONValue]) async throws -> String = { tool, _ in throw ToolUnavailable(name: tool.name) }

    var registry: [AITool] { KriyaTools.all + extraTools() }

    func run(_ call: AIToolCall, context: AIToolContext, requester: String = "Kriya's AI") async -> AIToolResult {
        let tool: AITool
        switch AIToolPolicy.validate(call, registry: registry) {
        case .failure(let problem): return fail(problem.errorDescription ?? "The call was not valid.", call: call, ran: false)
        case .success(let found): tool = found
        }
        switch AIToolPolicy.decide(tool, settings: store.toolSettings, context: context) {
        case .deny(let reason): return fail("Not allowed: \(reason)", call: call, ran: false)
        case .allow: break
        case .confirm(let reason):
            let summary = String(SecretRedactor.redact(JSONValue.object(call.arguments).text).text.prefix(400))
            let decision = await prompter.confirm(tool: tool, arguments: summary, reason: reason, requester: requester, allowRemember: tool.risk < .destructive)
            guard decision.allowed else { return fail("The user did not allow this.", call: call, ran: false) }
            if decision.remember { await MainActor.run { store.toolSettings.perTool[tool.name] = .always } }
        }
        do {
            let output = KriyaTools.tool(named: tool.name) != nil
                ? try await host.execute(tool, arguments: call.arguments)
                : try await extraHost(tool, call.arguments)
            AuditLog.shared.record(.script, "AI tool \(tool.name) ran")
            return AIToolResult(content: AIContextBuilder.sanitizedToolResult(output), isError: false, ran: true)
        } catch {
            return fail(error.localizedDescription, call: call, ran: true)
        }
    }

    private func fail(_ message: String, call: AIToolCall, ran: Bool) -> AIToolResult {
        AuditLog.shared.record(.script, "AI tool \(call.name.prefix(60)) did not run: \(message.prefix(80))")
        return AIToolResult(content: AIContextBuilder.sanitizedToolResult(message), isError: true, ran: ran)
    }
}

/// Kriya's tools, done with Kriya's own pieces. A piece that is not connected says so rather than guessing.
final class LiveToolHost: KriyaToolHost {
    var searchNotes: (String, Int) -> [String] = { query, limit in
        let path = UserDefaults.standard.string(forKey: NotesModel.folderKey)
        let store = NoteStore(folder: path.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? NoteStore.defaultFolder)
        return store.search(query).prefix(limit).map { $0.title }
    }
    var searchClipboard: (String, Int) -> [String] = { _, _ in [] }
    var isExcludedApp: (String) -> Bool = { _ in false }
    var describeWorkflow: (String) -> String? = { _ in nil }
    var diagnostics: () -> String = { "Kriya \(SystemInfo.appVersion), macOS \(SystemInfo.osVersion)" }
    var toggleSoundMode: (String) -> String? = { _ in nil }
    var openLauncher: (String?) -> Void = { _ in }
    var runWorkflow: (String) -> Void = { _ in }
    var runScript: ((String) -> String?)?
    var installCask: ((String) -> Void)?
    var changeShortcut: ((String, String) -> String?)?
    var exportClipboard: ((Int) -> String?)?

    func execute(_ tool: AITool, arguments a: [String: JSONValue]) async throws -> String {
        let text = a["query"]?.stringValue ?? ""
        let limit = Int(a["limit"]?.numberValue ?? 10)
        switch tool.name {
        case "kriya.search_apps": return Self.lines(Self.apps(matching: text, limit: limit))
        case "kriya.search_files": return Self.lines(try Self.files(matching: text, limit: limit))
        case "kriya.search_notes": return Self.lines(searchNotes(text, limit))
        case "kriya.search_clipboard": return Self.lines(searchClipboard(text, limit))
        case "kriya.get_selected_text":
            if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, isExcludedApp(front) { return "The app in front is excluded, so its text is not shared." }
            return Self.selectedText() ?? "Nothing is selected, or Kriya does not have Accessibility permission."
        case "kriya.open_launcher": DispatchQueue.main.async { self.openLauncher(a["query"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }) }; return "Opened."
        case "kriya.set_audio_profile":
            guard let message = toggleSoundMode(a["name"]?.stringValue ?? "") else { throw NSError(domain: "Kriya", code: 1, userInfo: [NSLocalizedDescriptionKey: "There is no sound mode with that name."]) }
            return message
        case "kriya.list_windows": return Self.lines(Self.windows())
        case "kriya.preview_workflow":
            guard let text = describeWorkflow(a["workflow_id"]?.stringValue ?? "") else { throw NSError(domain: "Kriya", code: 2, userInfo: [NSLocalizedDescriptionKey: "There is no workflow with that id."]) }
            return text
        case "kriya.get_diagnostics": return SupportScrubber.scrub(diagnostics())
        case "kriya.move_file": return try Self.move(a["from"]?.stringValue ?? "", into: a["to"]?.stringValue ?? "")
        case "kriya.delete_file": return try Self.trash(a["path"]?.stringValue ?? "")
        case "kriya.install_app":
            guard let installCask else { throw ToolUnavailable(name: tool.name) }
            let cask = a["cask"]?.stringValue ?? ""
            DispatchQueue.main.async { installCask(cask) }
            return "Started installing \(cask). Progress is in Kriya's Apps settings."
        case "kriya.run_script":
            guard let runScript else { throw ToolUnavailable(name: tool.name) }
            guard let output = runScript(a["script_id"]?.stringValue ?? "") else { throw NSError(domain: "Kriya", code: 3, userInfo: [NSLocalizedDescriptionKey: "There is no script with that id."]) }
            return output
        case "kriya.execute_workflow":
            let id = a["workflow_id"]?.stringValue ?? ""
            guard describeWorkflow(id) != nil else { throw NSError(domain: "Kriya", code: 2, userInfo: [NSLocalizedDescriptionKey: "There is no workflow with that id."]) }
            DispatchQueue.main.async { self.runWorkflow(id) }
            return "Started. Kriya's own authorization and limits for workflows still apply."
        case "kriya.change_shortcut":
            guard let changeShortcut else { throw ToolUnavailable(name: tool.name) }
            guard let message = changeShortcut(a["command"]?.stringValue ?? "", a["shortcut"]?.stringValue ?? "") else { throw NSError(domain: "Kriya", code: 4, userInfo: [NSLocalizedDescriptionKey: "That shortcut could not be set."]) }
            return message
        case "kriya.export_clipboard":
            guard let exportClipboard else { throw ToolUnavailable(name: tool.name) }
            return exportClipboard(limit) ?? "Nothing was exported."
        default: throw ToolUnavailable(name: tool.name)
        }
    }

    static func lines(_ items: [String]) -> String { items.isEmpty ? "No results." : items.joined(separator: "\n") }

    static func apps(matching query: String, limit: Int) -> [String] {
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", NSHomeDirectory() + "/Applications"]
        let q = query.lowercased()
        var found: [String] = []
        for folder in folders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".app") {
                let title = String(name.dropLast(4))
                if title.lowercased().contains(q) { found.append(title) }
            }
        }
        return Array(Set(found)).sorted().prefix(limit).map { $0 }
    }

    /// Names of files in the home folder, found through Spotlight, without Library or hidden folders. Paths shown start with ~.
    static func files(matching query: String, limit: Int) throws -> [String] {
        let home = NSHomeDirectory()
        let output = try ToolRunner.run("/usr/bin/mdfind", ["-onlyin", home, "-name", query], timeout: 6)
        return output.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix(home + "/Library/") && !$0.contains("/.") }
            .prefix(limit).map { "~" + $0.dropFirst(home.count) }
    }

    static func selectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success, let element = focused else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success, let text = value as? String, !text.isEmpty else { return nil }
        return String(text.prefix(8000))
    }

    static func windows() -> [String] {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0, let owner = info[kCGWindowOwnerName as String] as? String else { return nil }
            let title = (info[kCGWindowName as String] as? String) ?? ""
            return title.isEmpty ? owner : "\(owner): \(title)"
        }
    }

    /// Items inside the home folder only, never the home folder itself or a system folder.
    static func safeURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        guard url.path.hasPrefix(home + "/"), !ProtectedPaths.isProtected(url.path), !url.path.hasPrefix(home + "/Library/") else {
            throw NSError(domain: "Kriya", code: 5, userInfo: [NSLocalizedDescriptionKey: "That path is outside the folders Kriya will change for an AI."])
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw NSError(domain: "Kriya", code: 6, userInfo: [NSLocalizedDescriptionKey: "That item does not exist."]) }
        return url
    }

    static func trash(_ path: String) throws -> String {
        let url = try safeURL(path)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        AuditLog.shared.record(.files, "AI moved “\(url.lastPathComponent)” to the Trash")
        return "Moved “\(url.lastPathComponent)” to the Trash."
    }

    static func move(_ from: String, into folder: String) throws -> String {
        let source = try safeURL(from)
        let destination = try safeURL(folder)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: "Kriya", code: 7, userInfo: [NSLocalizedDescriptionKey: "The destination is not a folder."])
        }
        let target = destination.appendingPathComponent(source.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw NSError(domain: "Kriya", code: 8, userInfo: [NSLocalizedDescriptionKey: "Something with that name is already there."]) }
        try FileManager.default.moveItem(at: source, to: target)
        AuditLog.shared.record(.files, "AI moved “\(source.lastPathComponent)” to “\(destination.lastPathComponent)”")
        return "Moved “\(source.lastPathComponent)” into “\(destination.lastPathComponent)”."
    }
}

/// A conversation in which the model may use tools: ask, run what it asks for through the engine, give back the answers, and
/// repeat a few times. It stops at the first refusal that matters, and never runs anything itself.
final class AIAgentLoop {
    static let maxRounds = 5

    let gateway: AIGateway
    let engine: AIToolEngine

    init(gateway: AIGateway = .shared, engine: AIToolEngine = .shared) { self.gateway = gateway; self.engine = engine }

    func run(feature: AIFeature, system: String, context: AIContext, question: String, tools: [AITool], providerID: String? = nil, requester: String = "Kriya's AI") async throws -> String {
        var messages = [AIMessage(.user, context.rendered.isEmpty ? question : context.rendered + "\n\n" + question)]
        let toolContext = AIToolContext(feature: feature, localOnlyMode: LocalOnly.isOn, suspectedInjection: context.suspectedInjection)
        for _ in 0..<Self.maxRounds {
            let response = try await gateway.generate(feature: feature, providerID: providerID,
                                                      AIRequest(system: system + "\n" + AIContextBuilder.untrustedRule, messages: messages, tools: tools), secretsHidden: context.redactionCount)
            guard !response.toolCalls.isEmpty else { return response.text }
            messages.append(AIMessage(.assistant, response.text, toolCalls: response.toolCalls))
            var anyRan = false
            for call in response.toolCalls {
                let result = await engine.run(call, context: toolContext, requester: requester)
                anyRan = anyRan || result.ran
                messages.append(AIMessage(.tool, result.content, toolCallID: call.id, toolName: call.name))
            }
            _ = anyRan
        }
        return "The AI kept asking for tools and did not finish. Nothing more was run."
    }
}
