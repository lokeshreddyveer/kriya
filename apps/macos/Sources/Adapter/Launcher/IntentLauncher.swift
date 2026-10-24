import AppKit

/// Puts the natural-language layer in the launcher. It reads what was typed (`IntentParser`), shows the reading as one row above the
/// results, and when that row is chosen it asks first if the request needs it (`IntentPolicy`) and then hands the request to the
/// commands, actions and windows Kriya already has. Nothing here has a way to act that those do not.
///
/// Normal search is never replaced: the row is added to what the launcher already finds, only for text that reads as a request.
final class IntentLauncher {
    /// What an intent is carried out with. Each is wired to the existing feature in `AppEnvironment`; none is new machinery.
    struct Hooks {
        var startTimer: (TimeInterval, String?) -> Void = { _, _ in }
        var startFocus: (Int) -> Void = { _ in }
        var runCommand: (String) -> Void = { _ in }
        var runWorkflow: (String) -> Void = { _ in }
        var setVolume: (String, Double) -> Void = { _, _ in }
        var mute: (String, TimeInterval?) -> Void = { _, _ in }
        var unmute: (String) -> Void = { _ in }
        var muteAllExcept: (String) -> Void = { _ in }
        var chooseOutput: (String) -> Bool = { _ in false }
        var moveWindow: (String) -> Void = { _ in }
        var addToShelf: ([URL]) -> Void = { _ in }
        var openSettings: (SettingsPane, String?) -> Void = { _, _ in }
        var prefill: (String) -> Void = { _ in }
        var message: (String, Bool) -> Void = { _, _ in }
        var excludedFolders: () -> [String] = { [] }
        var browserTabsOn: () -> Bool = { false }
    }

    var hooks = Hooks()
    /// The launcher's saved choices (the two switches for this layer).
    var prefs: () -> LauncherPrefsData = { LauncherPrefsData() }
    /// Rebuilt for every request from the real apps, devices, workflows and command registry.
    var world: () -> IntentWorld = { IntentWorld() }
    /// Asks the person; replaced in tests.
    var confirm: (ResolvedIntent, String) -> Bool = IntentLauncher.askPerson
    var choose: (String, [ResolvedIntent]) -> ResolvedIntent? = IntentLauncher.askWhich
    /// Runs the model for a request that patterns could not read. Replaced in tests.
    var askModel: (String, IntentWorld) async -> IntentParseResult = IntentLauncher.askProvider
    var audit: (String) -> Void = { AuditLog.shared.record(.setting, $0) }

    // MARK: Rows in the launcher

    /// The rows for what was typed: none for ordinary text.
    func entries(for text: String) -> [PaletteEntry] {
        let data = prefs()
        guard data.interpretsRequests || data.understandsRequests else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("?") {
            let question = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            return question.isEmpty ? [] : [understandRow(question, score: 990)]
        }
        guard data.interpretsRequests else {
            return data.understandsRequests && looksLikeSentence(trimmed) ? [understandRow(trimmed, score: 120)] : []
        }
        let w = world()
        switch IntentParser.parse(trimmed, world: w) {
        case .notAnIntent:
            return data.understandsRequests && looksLikeSentence(trimmed) ? [understandRow(trimmed, score: 120)] : []
        case .intent(let resolved):
            return [row(resolved, score: 990)]
        case .ambiguous(let question, let choices), .needsInput(let question, let choices):
            var rows = [infoRow(question, "Choose one", symbol: "questionmark.circle", score: 992)]
            rows += choices.prefix(8).enumerated().map { row($0.element, score: 990 - $0.offset) }
            return rows
        case .rejected(let reason):
            return [infoRow(reason, "Nothing was done", symbol: "exclamationmark.triangle", score: 990)]
        }
    }

    private func looksLikeSentence(_ text: String) -> Bool {
        text.split(separator: " ").count >= 3 && text.count <= 200 && !IntentText.looksLikeShell(text)
    }

    private func row(_ resolved: ResolvedIntent, score: Int) -> PaletteEntry {
        let status: String
        switch resolved.risk {
        case .safe: status = "Runs now"
        case .confirm: status = "Asks first"
        }
        let confidence = resolved.confidence < 0.9 ? " · matched loosely" : ""
        var entry = PaletteEntry(
            id: "intent:\(resolved.intent.kind):\(resolved.title)", title: resolved.title, subtitle: "\(resolved.detail) (\(status)\(confidence))",
            symbol: resolved.risk.needsConfirmation ? "questionmark.circle" : "sparkles", category: .command, rememberable: false, queryScore: score
        ) { [weak self] in self?.run(resolved) }
        var actions = [PaletteAction(title: "Why this?", symbol: "info.circle") { [weak self] in self?.explain(resolved) }]
        if let hint = resolved.shortcutHint {
            actions.append(PaletteAction(title: "Set a shortcut for this…", symbol: "keyboard") { [weak self] in self?.hooks.openSettings(.keyboard, "Shortcuts"); self?.hooks.message("Look for “\(hint)” in the command list.", false) })
        }
        entry.actions = actions
        return entry
    }

    private func infoRow(_ title: String, _ subtitle: String, symbol: String, score: Int) -> PaletteEntry {
        PaletteEntry(id: "intent:info:\(title)", title: title, subtitle: subtitle, symbol: symbol, category: .command, rememberable: false, queryScore: score) {}
    }

    private func understandRow(_ request: String, score: Int) -> PaletteEntry {
        let local = LocalOnly.isOn
        return PaletteEntry(
            id: "intent:ai:\(request)", title: "Understand with AI: \(request.count > 60 ? String(request.prefix(60)) + "…" : request)",
            subtitle: local ? "Local-only mode is on, so nothing is sent" : "Press Return to send this, with secrets hidden, to your AI provider",
            symbol: "sparkle.magnifyingglass", category: .command, rememberable: false, queryScore: score
        ) { [weak self] in self?.understand(request) }
    }

    // MARK: Running

    /// Confirms if the request needs it, then carries it out. A request is judged by what it does, not by how it was read.
    func run(_ resolved: ResolvedIntent) {
        if case .confirm(let reason) = resolved.risk {
            guard confirm(resolved, reason) else {
                audit("Launcher request \(resolved.intent.kind) (\(resolved.source.rawValue)): cancelled at the confirmation")
                return
            }
        }
        perform(resolved.intent)
        audit("Launcher request \(resolved.intent.kind) (\(resolved.source.rawValue)): run, confirmation \(resolved.risk.needsConfirmation ? "given" : "not needed")")
    }

    func perform(_ intent: LauncherIntent) {
        switch intent {
        case .search(let text): hooks.prefill(text)
        case .openApp(let id):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
            else { hooks.message("That app could not be found.", true) }
        case .openFile(let url): NSWorkspace.shared.open(url)
        case .searchFiles(let query, let range): searchFiles(query: query, range: range)
        case .searchNotes(let text): hooks.prefill(text)
        case .searchClipboard(let text): hooks.prefill("clip: \(text)")
        case .searchBrowserTabs(let text):
            if hooks.browserTabsOn() { hooks.prefill(text) } else { hooks.message("Browser tab search is off. Turn it on in Settings › Launcher.", true) }
        case .webSearch(let engine, let query):
            if let url = WebSearch.url(for: WebSearch.engine(id: engine), query: query) { NSWorkspace.shared.open(url) }
        case .askAI(let question): understand(question)
        case .startTimer(let seconds, let label): hooks.startTimer(seconds, label)
        case .startFocusSession(let minutes): hooks.startFocus(minutes)
        case .runWorkflow(let id): hooks.runWorkflow(id)
        case .runCommand(let name, _): hooks.runCommand(name)
        case .setVolume(let id, let value): hooks.setVolume(id, value)
        case .muteApp(let id, let seconds): hooks.mute(id, seconds)
        case .unmuteApp(let id): hooks.unmute(id)
        case .muteAllExcept(let id): hooks.muteAllExcept(id)
        case .chooseAudioOutput(let uid):
            guard let uid else { return }
            if !hooks.chooseOutput(uid) { hooks.message("macOS did not let the sound output change.", true) }
        case .moveWindow(let layout): hooks.moveWindow(layout.command)
        case .capture(let mode, let action):
            if let entry = CaptureSettings.commands.first(where: { $0.mode == mode && $0.action == action }) { hooks.runCommand(entry.command) }
            else { hooks.message("That kind of capture has no command.", true) }
        case .addToShelf(let urls): hooks.addToShelf(urls)
        case .openSettings(let pane, let tab): hooks.openSettings(pane, tab)
        case .sequence(let steps): for step in steps { perform(step) }
        }
    }

    // MARK: Files

    /// Searches with Spotlight (`mdfind`, with fixed arguments, never through a shell) and shows what it found in Finder.
    private func searchFiles(query: String, range: IntentDateRange?) {
        let w = world()
        let predicate = Self.spotlightPredicate(query: query, range: range, now: w.now, calendar: w.calendar)
        let excluded = hooks.excludedFolders()
        let home = w.homeDirectory.path
        DispatchQueue.global(qos: .userInitiated).async { [hooks] in
            let found = Self.spotlight(predicate: predicate, in: home)
                .filter { !$0.contains("/Library/") && !$0.contains("/.Trash/") && !$0.contains("/node_modules/") && !FileSearchFilter.isExcluded($0, folders: excluded) }
                .prefix(60).map { URL(fileURLWithPath: $0) }
            DispatchQueue.main.async {
                if found.isEmpty { hooks.message("No files matched.", false) } else { NSWorkspace.shared.activateFileViewerSelecting(Array(found)) }
            }
        }
    }

    private static let kinds: [String: String] = [
        "pdf": "com.adobe.pdf", "pdfs": "com.adobe.pdf", "image": "public.image", "images": "public.image", "photo": "public.image", "photos": "public.image",
        "picture": "public.image", "pictures": "public.image", "video": "public.movie", "videos": "public.movie", "spreadsheet": "public.spreadsheet",
        "spreadsheets": "public.spreadsheet", "presentation": "public.presentation", "presentations": "public.presentation", "screenshot": "public.image", "screenshots": "public.image",
    ]

    /// The Spotlight query for words and a date range: every word must be in the name; a kind word asks for that kind of file.
    static func spotlightPredicate(query: String, range: IntentDateRange?, now: Date, calendar: Calendar) -> String {
        var parts: [String] = []
        for word in query.split(separator: " ").map(String.init) {
            if let uti = kinds[word] {
                parts.append("kMDItemContentTypeTree == \"\(uti)\"")
                if word.hasPrefix("screenshot") { parts.append("kMDItemDisplayName == \"*Screen*\"cd") }
            } else {
                let safe = word.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "*", with: "")
                if !safe.isEmpty { parts.append("kMDItemDisplayName == \"*\(safe)*\"cd") }
            }
        }
        if let range {
            let interval = range.interval(now: now, calendar: calendar)
            let format = ISO8601DateFormatter()
            parts.append("kMDItemFSContentChangeDate >= $time.iso(\(format.string(from: interval.start))) && kMDItemFSContentChangeDate < $time.iso(\(format.string(from: interval.end)))")
        }
        return parts.isEmpty ? "kMDItemDisplayName == \"*\"" : parts.joined(separator: " && ")
    }

    private static func spotlight(predicate: String, in folder: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", folder, predicate]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    // MARK: Asking an AI provider

    /// Sends one request, with secrets hidden, to the provider the person chose for the launcher, and shows what came back for approval.
    /// Never runs while typing: only from the row, on Return.
    func understand(_ request: String) {
        let w = world()
        guard !w.localOnly, !LocalOnly.isOn else {
            hooks.message("Local-only mode is on, so nothing is sent to an AI provider.", true)
            audit("Launcher request sent to AI: blocked by Local-only mode")
            return
        }
        guard !IntentText.looksLikeShell(request) else {
            hooks.message("That looks like shell text, which I do not send or run.", true)
            return
        }
        let prepared = IntentAI.prepare(request)
        Task { [weak self] in
            guard let self else { return }
            let result = await askModel(prepared.text, w)
            await MainActor.run {
                self.audit("Launcher request sent to AI: \(self.kind(of: result)), \(prepared.hidden) item(s) hidden before sending")
                self.present(result)
            }
        }
    }

    private func kind(of result: IntentParseResult) -> String {
        switch result {
        case .intent(let r): return r.intent.kind
        case .ambiguous: return "ambiguous"
        case .needsInput: return "needs input"
        case .rejected: return "rejected"
        case .notAnIntent: return "not a request"
        }
    }

    /// What an AI-read request becomes. It is always shown first, even if the same words read by pattern would have run at once.
    private func present(_ result: IntentParseResult) {
        switch result {
        case .notAnIntent: hooks.message("I could not read that as a request.", true)
        case .rejected(let reason): hooks.message(reason, true)
        case .intent(let resolved):
            let reason = resolved.risk.needsConfirmation ? { if case .confirm(let r) = resolved.risk { return r }; return "" }() : "An AI read this request, so it is shown to you before it runs."
            if confirm(resolved, reason) {
                perform(resolved.intent)
                audit("Launcher request \(resolved.intent.kind) (ai): run after confirmation")
            } else {
                audit("Launcher request \(resolved.intent.kind) (ai): cancelled at the confirmation")
            }
        case .ambiguous(let question, let choices), .needsInput(let question, let choices):
            if let picked = choose(question, choices) { present(.intent(picked)) }
        }
    }

    private static func askProvider(_ text: String, _ world: IntentWorld) async -> IntentParseResult {
        let gateway = AIGateway.shared
        guard gateway.isAvailable(for: .launcher) else { return .rejected(reason: "No AI provider is switched on for the launcher. Choose one in Settings › Apple Intelligence.") }
        let request = AIRequest(system: IntentAI.systemPrompt, messages: [AIMessage(.user, text)], responseSchema: IntentAI.schema, temperature: 0, maxTokens: 300, timeout: 20)
        do {
            let response = try await gateway.generate(feature: .launcher, request, secretsHidden: 0)
            return IntentAI.decode(response.text, world: world)
        } catch {
            return .rejected(reason: "The AI provider did not answer: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    // MARK: Dialogs

    private func explain(_ resolved: ResolvedIntent) {
        let alert = NSAlert()
        alert.messageText = resolved.title
        var lines = ["Read as: \(resolved.why)", "Found by: \(resolved.source == .ai ? "an AI provider" : "fixed patterns on this Mac")"]
        if resolved.confidence < 0.9 { lines.append("A name was matched loosely (\(Int(resolved.confidence * 100))% sure).") }
        switch resolved.risk {
        case .safe: lines.append("It runs as soon as you choose it.")
        case .confirm(let reason): lines.append("It asks first: \(reason)")
        }
        if let hint = resolved.shortcutHint { lines.append("The same thing is the command “\(hint)”, which can have a shortcut.") }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func askPerson(_ resolved: ResolvedIntent, _ reason: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = resolved.title + "?"
        alert.informativeText = "\(resolved.detail)\n\n\(reason)"
        alert.alertStyle = .warning
        // Cancel is the default, so a stray Return does not run it.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Run")
        return alert.runModal() == .alertSecondButtonReturn
    }

    static func askWhich(_ question: String, _ choices: [ResolvedIntent]) -> ResolvedIntent? {
        guard !choices.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = "Choose one. Nothing runs until you do."
        let shown = Array(choices.prefix(3))
        for choice in shown { alert.addButton(withTitle: choice.title) }
        alert.addButton(withTitle: "Cancel")
        let answer = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return shown.indices.contains(answer) ? shown[answer] : nil
    }
}
