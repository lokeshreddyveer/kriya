import Foundation

/// The second way of reading a request, used only when the fixed patterns could not read it and the person asked for it (a leading “?”,
/// the “Understand with AI” row, or the setting “Understand natural-language requests”).
///
/// A model is never trusted to act. It is asked for one small JSON object in a fixed shape; the answer is parsed here, anything outside
/// the shape is thrown away, and what is left goes through the same checks and the same confirmation as a request read by pattern.
/// Names (apps, devices, workflows, commands) are resolved on this Mac, so the model never needs, or invents, an identifier.
enum IntentAI {
    /// What a model may answer with, and the arguments each one takes (`?` marks one that may be left out).
    static let allowed: [String: (required: Set<String>, optional: Set<String>)] = [
        "search": (["query"], []),
        "openApp": (["app"], []),
        "openFile": (["path"], []),
        "searchFiles": (["query"], ["range"]),
        "searchNotes": (["query"], []),
        "searchClipboard": (["query"], []),
        "searchBrowserTabs": (["query"], []),
        "webSearch": (["query"], ["engine"]),
        "startTimer": (["seconds"], ["label"]),
        "startFocusSession": (["minutes"], []),
        "runWorkflow": (["name"], []),
        "runCommand": (["command"], ["arguments"]),
        "setVolume": (["percent"], ["app"]),
        "muteApp": ([], ["app", "seconds"]),
        "unmuteApp": ([], ["app"]),
        "muteAllExcept": (["app"], []),
        "chooseAudioOutput": ([], ["device"]),
        "moveWindow": (["placement"], []),
        "capture": (["mode"], ["action"]),
        "openSettings": (["pane"], ["tab"]),
    ]

    /// The JSON schema handed to a provider that supports structured output.
    static var schema: JSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([.string("intent"), .string("args")]),
            "properties": .object([
                "intent": .object(["type": .string("string"), "enum": .array(allowed.keys.sorted().map { .string($0) })]),
                "args": .object(["type": .string("object")]),
            ]),
        ])
    }

    static var systemPrompt: String {
        let lines = allowed.keys.sorted().map { name -> String in
            let spec = allowed[name]!
            let required = spec.required.sorted().map { $0 }.joined(separator: ", ")
            let optional = spec.optional.sorted().map { "\($0)?" }.joined(separator: ", ")
            return "- \(name)(\([required, optional].filter { !$0.isEmpty }.joined(separator: ", ")))"
        }.joined(separator: "\n")
        return """
        You turn one request typed into a Mac launcher into one JSON object: {"intent": <name>, "args": {...}}. Answer with that object only.
        Use only these intents and arguments:
        \(lines)
        Rules: app, device, workflow and command are names as the person said them, never identifiers. seconds and minutes are numbers. percent is 0 to 400. \
        placement is words like "left half", "top right", "maximize". mode is region, window or screen. range is today, yesterday, this week, last week, \
        this month or last month. If the request is not one of these, answer {"intent": "search", "args": {"query": <the request>}}. \
        Never write shell commands, scripts, file paths you were not given, or anything to execute.
        """
    }

    /// Hides secrets and personal details before anything leaves this Mac. Returns the text to send and how many things were hidden.
    static func prepare(_ request: String) -> (text: String, hidden: Int) {
        let result = SecretRedactor.redact(request, includePersonal: true)
        return (result.text, result.count)
    }

    /// A model's answer, checked. Anything outside the allowed shape is refused, with the reason.
    static func decode(_ answer: String, world: IntentWorld) -> IntentParseResult {
        guard let object = jsonObject(in: answer) else { return .rejected(reason: "The answer was not in the expected form, so nothing was done.") }
        guard Set(object.keys) == ["intent", "args"] || Set(object.keys) == ["intent"] else { return .rejected(reason: "The answer had extra parts, so nothing was done.") }
        guard let name = object["intent"] as? String, let spec = allowed[name] else {
            return .rejected(reason: "The answer asked for something Kriya does not do from a request, so nothing was done.")
        }
        let args = object["args"] as? [String: Any] ?? [:]
        let keys = Set(args.keys)
        if let unknown = keys.subtracting(spec.required.union(spec.optional)).sorted().first { return .rejected(reason: "The answer used an unknown argument (“\(unknown.prefix(20))”), so nothing was done.") }
        if let missing = spec.required.subtracting(keys).sorted().first { return .rejected(reason: "The answer left out “\(missing)”, so nothing was done.") }
        for (_, value) in args {
            if let text = value as? String, IntentText.looksLikeShell(text) { return .rejected(reason: "The answer contained shell text, which is never run.") }
            if let nested = value as? [String: Any], nested.values.contains(where: { ($0 as? String).map(IntentText.looksLikeShell) ?? false }) {
                return .rejected(reason: "The answer contained shell text, which is never run.")
            }
        }
        func string(_ key: String) -> String? { (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        func number(_ key: String) -> Double? { (args[key] as? NSNumber).flatMap { $0 === kCFBooleanTrue || $0 === kCFBooleanFalse ? nil : $0.doubleValue } }
        func finish(_ intent: LauncherIntent, _ title: String, _ detail: String, confidence: Double = 0.8) -> IntentParseResult {
            if let problem = IntentValidator.validate(intent, world: world) { return .rejected(reason: problem) }
            return .intent(ResolvedIntent(intent: intent, title: title, detail: detail, why: "read by AI as “\(name)”", risk: IntentPolicy.risk(of: intent, world: world), source: .ai, confidence: confidence, shortcutHint: nil))
        }
        func app(_ key: String, _ build: (IntentApp) -> IntentParseResult) -> IntentParseResult {
            guard let spoken = string(key), !spoken.isEmpty else { return .rejected(reason: "The answer did not name an app.") }
            switch world.resolveApp(spoken) {
            case .none: return .rejected(reason: "I could not find an app named “\(spoken)”.")
            case .one(let a, _): return build(a)
            case .many(let apps):
                let choices = apps.compactMap { if case .intent(let r) = build($0) { return r }; return nil }
                return .ambiguous(question: "“\(spoken)” could be \(apps.prefix(4).map(\.name).joined(separator: ", ")).", choices: choices)
            }
        }
        func appOrSystem(_ key: String, _ build: (String, String) -> IntentParseResult) -> IntentParseResult {
            guard let spoken = string(key), !spoken.isEmpty, !["system", "all", "everything", "sound", "audio", "mac"].contains(spoken.lowercased()) else { return build(IntentWorld.systemApp, "all sound") }
            return app(key) { build($0.bundleID, $0.name) }
        }

        switch name {
        case "search":
            return finish(.search(string("query") ?? ""), "Search for “\(string("query") ?? "")”", "Normal launcher search.")
        case "openApp":
            return app("app") { finish(.openApp(bundleID: $0.bundleID), "Open \($0.name)", "Opens or switches to it.") }
        case "openFile":
            guard let path = string("path") else { return .rejected(reason: "The answer gave no file.") }
            let url = URL(fileURLWithPath: path.hasPrefix("~/") ? world.homeDirectory.path + path.dropFirst(1) : path)
            return finish(.openFile(url), "Open \(url.lastPathComponent)", "Opens the file with the app that handles it.")
        case "searchFiles":
            var range: IntentDateRange?
            if let phrase = string("range") {
                guard let found = IntentParser.dateRange(in: phrase)?.range else { return .rejected(reason: "“\(phrase)” is not a date range I know.") }
                range = found
            }
            let query = string("query") ?? ""
            return finish(.searchFiles(query: query, range: range), "Find files: “\(query)”", "Searches your files with Spotlight.")
        case "searchNotes": return finish(.searchNotes(string("query") ?? ""), "Search notes for “\(string("query") ?? "")”", "Looks through your notes.")
        case "searchClipboard": return finish(.searchClipboard(string("query") ?? ""), "Search the clipboard for “\(string("query") ?? "")”", "Looks through what you copied.")
        case "searchBrowserTabs": return finish(.searchBrowserTabs(string("query") ?? ""), "Find a browser tab: “\(string("query") ?? "")”", "Looks through your open tabs.")
        case "webSearch":
            let spoken = (string("engine") ?? world.defaultEngine).lowercased()
            guard let engine = WebSearch.engines.first(where: { $0.id == spoken || $0.name.lowercased() == spoken || $0.keyword == spoken }) else { return .rejected(reason: "“\(spoken)” is not a search site Kriya knows.") }
            return finish(.webSearch(engine: engine.id, query: string("query") ?? ""), "Search \(engine.name) for “\(string("query") ?? "")”", "Opens the search in your browser.")
        case "startTimer":
            guard let seconds = number("seconds") else { return .rejected(reason: "The timer had no length.") }
            return finish(.startTimer(seconds: seconds, label: string("label")), "Start a \(LauncherTimerParser.describe(seconds)) timer", "You will hear a sound when it ends.")
        case "startFocusSession":
            guard let minutes = number("minutes"), minutes == minutes.rounded() else { return .rejected(reason: "The focus session had no length in whole minutes.") }
            return finish(.startFocusSession(minutes: Int(minutes)), "Start a \(Int(minutes)) minute focus session", "Applies your focus settings for that long.")
        case "runWorkflow":
            guard let spoken = string("name") else { return .rejected(reason: "The answer named no workflow.") }
            switch world.resolveWorkflow(spoken) {
            case .none: return .rejected(reason: "The requested workflow does not exist.")
            case .one(let wf, _): return finish(.runWorkflow(id: wf.id), "Run “\(wf.name)”", "Runs the workflow once.")
            case .many(let list):
                return .ambiguous(question: "More than one workflow fits “\(spoken)”.", choices: list.compactMap { if case .intent(let r) = finish(.runWorkflow(id: $0.id), "Run “\($0.name)”", "Runs the workflow once.", confidence: 0.5) { return r }; return nil })
            }
        case "runCommand":
            guard let command = string("command") else { return .rejected(reason: "The answer named no command.") }
            var arguments: [String: String] = [:]
            if let raw = args["arguments"] {
                guard let dictionary = raw as? [String: Any] else { return .rejected(reason: "The command's arguments were not in the expected form.") }
                for (key, value) in dictionary { guard let text = value as? String else { return .rejected(reason: "A command argument was not text.") }; arguments[key] = text }
            }
            return finish(.runCommand(command, arguments: arguments), "Run the command “\(command)”", "A command Kriya already has.")
        case "setVolume":
            guard let percent = number("percent") else { return .rejected(reason: "The answer gave no volume.") }
            return appOrSystem("app") { id, label in finish(.setVolume(appID: id, value: percent / 100), "Set \(label) to \(Int(percent.rounded()))%", "Changes the volume.") }
        case "muteApp":
            let seconds = number("seconds")
            return appOrSystem("app") { id, label in finish(.muteApp(appID: id, seconds: seconds), "Mute \(label)\(seconds.map { " for \(LauncherTimerParser.describe($0))" } ?? "")", "Silences it.") }
        case "unmuteApp":
            return appOrSystem("app") { id, label in finish(.unmuteApp(appID: id), "Unmute \(label)", "Brings the sound back.") }
        case "muteAllExcept":
            return app("app") { finish(.muteAllExcept(appID: $0.bundleID), "Mute everything except \($0.name)", "Silences every other app.") }
        case "chooseAudioOutput":
            guard let spoken = string("device"), !spoken.isEmpty else { return .needsInput(question: "Which output device should I use?", choices: outputChoices(world)) }
            switch world.resolveDevice(spoken) {
            case .one(let d, _): return finish(.chooseAudioOutput(deviceUID: d.uid), "Play sound on \(d.name)", "All sound will play there.")
            case .many, .none: return .needsInput(question: "Which output device should I use?", choices: outputChoices(world))
            }
        case "moveWindow":
            guard let phrase = string("placement"), let layout = IntentParser.placement(phrase.lowercased()) else { return .rejected(reason: "That is not a place Kriya can move a window to.") }
            return finish(.moveWindow(layout), "Move this window: \(layout.title)", "Moves the window in front.")
        case "capture":
            guard let mode = CaptureMode(rawValue: (string("mode") ?? "").lowercased()) else { return .rejected(reason: "That is not a capture mode.") }
            let spoken = (string("action") ?? "normal").lowercased()
            let actions: [String: CaptureAction] = ["normal": .normal, "text": .text, "qr": .qr, "record": mode == .window ? .recordWindow : .recordScreen, "redacted": .redacted]
            guard let action = actions[spoken] else { return .rejected(reason: "“\(spoken)” is not a capture action.") }
            return finish(.capture(mode, action: action), "Capture: \(mode.title)", "Captures it the way your capture settings say.")
        case "openSettings":
            guard let spoken = string("pane"), let pane = IntentParser.pane(named: spoken.lowercased()) ?? SettingsPane(rawValue: spoken) else { return .rejected(reason: "That is not a settings screen.") }
            return finish(.openSettings(pane, tab: string("tab")), "Open \(pane.title) settings", "Opens that part of Kriya's settings.")
        default:
            return .rejected(reason: "The answer asked for something Kriya does not do from a request, so nothing was done.")
        }
    }

    private static func outputChoices(_ world: IntentWorld) -> [ResolvedIntent] {
        world.devices.map { d in
            ResolvedIntent(intent: .chooseAudioOutput(deviceUID: d.uid), title: "Play sound on \(d.name)", detail: "All sound will play there.", why: "a sound output", risk: IntentPolicy.risk(of: .chooseAudioOutput(deviceUID: d.uid), world: world), source: .ai, confidence: 0.5, shortcutHint: nil)
        }
    }

    /// The first JSON object in the text, even if the model wrapped it in a code fence or a sentence.
    static func jsonObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parsed
    }
}
