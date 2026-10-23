import AppKit
import SwiftUI

// MARK: - Results

/// Hits from a search by meaning, in a small window, each with a way to open it.
final class SemanticResultsWindow {
    static let shared = SemanticResultsWindow()
    private var window: NSWindow?

    func show(query: String, hits: [SearchHit]) {
        let view = SemanticResultsView(query: query, hits: hits)
        let host = NSHostingController(rootView: view)
        let w = window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Search by meaning"
        w.contentViewController = host
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

private struct SemanticResultsView: View {
    let query: String
    let hits: [SearchHit]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("“\(query)”").font(.headline).padding(12)
            Divider()
            if hits.isEmpty {
                Text("Nothing in the index matches. Check that the sources you want are switched on in AI settings, and update the index.").foregroundStyle(.secondary).padding(16)
            } else {
                List(hits) { hit in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.title.isEmpty ? "Untitled" : hit.title).font(.headline)
                            Text(hit.source.title).font(.caption).foregroundStyle(.secondary)
                            if !hit.snippet.isEmpty { Text(hit.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
                        }
                        Spacer()
                        if let open = AIResultOpener.action(for: hit) { Button(open.title, action: open.run).controlSize(.small) }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

enum AIResultOpener {
    /// What the button on a result does. Opening a file or address only opens it; a command is only offered to be run by the person pressing the button.
    static func action(for hit: SearchHit) -> (title: String, run: () -> Void)? {
        switch hit.source {
        case .notes, .savedPages:
            guard hit.target.hasPrefix("/") else { return nil }
            return ("Open", { NSWorkspace.shared.open(URL(fileURLWithPath: hit.target)) })
        case .bookmarks:
            guard let url = BridgeProtocol.webURL(hit.target) else { return nil }
            return ("Open", { NSWorkspace.shared.open(url) })
        case .workflows:
            return ("Find in Launcher", { RemoteCommands.shared?.perform(.launcher(hit.title)) })
        case .actions:
            guard RemoteCommand.isValidID(hit.target) else { return nil }
            return ("Run", { RemoteCommands.shared?.perform(.command(hit.target)) })
        case .clipboard, .activity:
            return nil
        }
    }
}

// MARK: - Launcher entries

extension LauncherSources {
    /// `? …` searches by meaning or asks a question of what is indexed; the other rows work on the clipboard and the workflow draft.
    func aiEntries(_ text: String) -> [PaletteEntry] {
        guard prefs.data.isEnabled(.command) else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        var entries: [PaletteEntry] = []
        func make(_ id: String, _ title: String, _ subtitle: String, _ symbol: String, score: Int = 760, run: @escaping () -> Void) -> PaletteEntry {
            var e = PaletteEntry(id: id, title: title, subtitle: subtitle, symbol: symbol, rememberable: false, run: run)
            e.queryScore = score
            return e
        }
        if trimmed.hasPrefix("?"), trimmed.count > 2 {
            let question = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            let indexer = AIIndexer.shared
            if indexer.enabled {
                entries.append(make("ai.search", "Search by meaning: \(String(question.prefix(60)))", "Notes, workflows and the other sources you switched on", "sparkle.magnifyingglass") {
                    Task { let hits = await indexer.search(question); await MainActor.run { SemanticResultsWindow.shared.show(query: question, hits: hits) } }
                })
            }
            if AIGateway.shared.isAvailable(for: .launcher) {
                entries.append(make("ai.ask", "Ask AI: \(String(question.prefix(60)))", "Answers from what is indexed, with numbered sources", "sparkles", score: 750) {
                    let toast = Toast()
                    toast.show("Thinking…")
                    Task {
                        do {
                            let answer = try await AIAssistant().answer(question)
                            let sources = answer.sources.enumerated().map { "[\($0.offset + 1)] \($0.element.title) (\($0.element.source.title))" }.joined(separator: "\n")
                            await MainActor.run { ScriptOutputWindow.show(title: "Ask AI", text: answer.text + (sources.isEmpty ? "" : "\n\nSources:\n" + sources)) }
                        } catch {
                            await MainActor.run { toast.show((error as? AIError)?.errorDescription ?? error.localizedDescription, isError: true) }
                        }
                    }
                })
            }
        }
        if ["redact clipboard", "hide secrets", "redact secrets", "remove secrets from clipboard"].contains(lower) {
            entries.append(make("ai.redact", "Hide secrets in the clipboard text", "Replaces keys, tokens, passwords and card numbers with a label", "eye.slash") { AIClipboardTools.redactClipboard() })
        }
        if ["find secrets", "scan clipboard", "clipboard secrets", "check clipboard for secrets"].contains(lower) {
            entries.append(make("ai.scan", "Check the clipboard for secrets", "Says what kinds were found, without showing them", "magnifyingglass.circle") { AIClipboardTools.scanClipboard() })
        }
        if ["update ai index", "update index", "reindex", "update search index"].contains(lower), AIIndexer.shared.enabled {
            entries.append(make("ai.reindex", "Update the AI search index", "Reads the sources you switched on", "arrow.triangle.2.circlepath") { Task { await AIIndexer.shared.refresh() } })
        }
        return entries
    }
}

enum AIClipboardTools {
    static func redactClipboard() {
        let toast = Toast()
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { toast.show("The clipboard has no text.", isError: true); return }
        let result = SecretRedactor.redact(text, includePersonal: AIProviderStore.shared.redactPersonal)
        guard result.count > 0 else { toast.show("No secrets were found."); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.text, forType: .string)
        toast.show("Hid \(result.count) secret\(result.count == 1 ? "" : "s"): " + result.found.keys.sorted().joined(separator: ", "))
    }

    static func scanClipboard() {
        let toast = Toast()
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { toast.show("The clipboard has no text.", isError: true); return }
        let result = SecretRedactor.redact(text, includePersonal: true)
        toast.show(result.count == 0 ? "No secrets or personal details found." : "Found: " + result.found.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))
    }
}

// MARK: - Workflow drafts and diagnostics

enum AIWorkflowDrafter {
    static let instructions = """
    You design small automations for a Mac utility. Reply with JSON only, in the shape you were given. Use only these step types: \
    notify (show a message), delay (wait up to 60 seconds), copy_text, set_variable, confirm (ask the user to continue), ask (ask for a line of text and keep it under a variable), \
    open_url (http or https), open_app and activate_app (an app's bundle identifier such as com.apple.Safari). Keep variable names to letters, digits and underscores. \
    Use {{name}} to use a variable in text. Do not invent other step types: anything else is rejected. Keep it as short as it can be.
    """

    /// Asks the model for a draft and builds the workflow. The workflow is switched off, starts by hand, and needs no authorization
    /// because it cannot contain a step that runs code or presses keys. The person sees and edits it before it is saved.
    static func draft(from description: String, gateway: AIGateway = .shared) async throws -> Workflow {
        let schema = JSONValue.parse(workflowDraftSchema())
        let clean = SecretRedactor.redact(String(description.prefix(2000))).text
        let response = try await gateway.generate(feature: .automation, AIRequest(system: instructions, messages: [AIMessage(.user, "Describe this as a workflow: " + clean)], responseSchema: schema, temperature: 0.2, maxTokens: 1200))
        let json = extractJSON(response.text)
        return try workflowFromDraft(json: json, id: UUID().uuidString.lowercased(), now: SystemInfo.nowSeconds)
    }

    /// Models sometimes wrap JSON in a code fence or a sentence.
    static func extractJSON(_ text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return text }
        return String(text[start...end])
    }
}

enum AIDiagnosticsExplainer {
    static let instructions = "You help a person fix problems with a Mac utility called Kriya. You are given a diagnostic report with personal details already removed. Explain in plain words what is wrong, most likely cause first, and the safest thing to try. Do not tell the person to run commands they do not understand. If the report does not show a problem, say so."

    /// Explains a report. The report is cleaned of personal details and secrets before it leaves this Mac.
    static func explain(report: String, question: String, gateway: AIGateway = .shared) async throws -> String {
        let scrubbed = SecretRedactor.redact(SupportScrubber.scrub(report), includePersonal: true).text
        let items = [AIContextItem(source: .diagnostics, title: "Kriya diagnostic report", text: String(scrubbed.suffix(30_000)), permission: .userAction, sensitivity: .normal, age: 0, citation: "report")]
        let config = gateway.resolve(feature: .diagnostics)
        let policy = AIContextPolicy(maxCharacters: 14_000, redactSecrets: true, redactPersonal: true, providerIsOnThisMac: config?.isOnThisMac ?? true)
        switch AIContextBuilder.build(items, policy: policy) {
        case .failure(let refusal): throw AIError.provider(refusal.errorDescription ?? "Nothing could be sent.")
        case .success(let context):
            let ask = question.isEmpty ? "What is wrong, and what should I try?" : SecretRedactor.redact(question).text
            return try await gateway.generate(feature: .diagnostics, AIRequest(system: instructions + "\n" + AIContextBuilder.untrustedRule, messages: [AIMessage(.user, context.rendered + "\n\n" + ask)], maxTokens: 700), secretsHidden: context.redactionCount).text
        }
    }
}
