import Foundation

/// Reads a request typed in plain words into a typed `LauncherIntent`, on this Mac, with fixed patterns and no AI.
///
/// The order is always the same: tidy the text, leave explicit keyword commands to the launcher, match a pattern, find the apps, devices,
/// workflows and files it names, check the arguments, and judge whether it needs confirming. Anything that is not clearly a request is
/// `.notAnIntent`, and normal search carries on as if this had not run. Nothing here acts on anything.
enum IntentParser {
    /// Words the launcher already reads as commands; a request starting with one is left to it.
    static let explicitKeywords: Set<String> = Set(["timer", "note", "calc", "define", "convert"]).union(WebSearch.engines.map(\.keyword))

    /// The first words of a request. Text that starts with anything else is not read, which keeps this off the typing path of ordinary searches.
    private static let verbs: Set<String> = [
        "mute", "unmute", "silence", "quiet", "set", "turn", "make", "change", "put", "lower", "raise", "adjust", "bring", "volume", "switch", "choose",
        "pick", "select", "use", "route", "send", "play", "move", "snap", "maximize", "maximise", "center", "centre", "fullscreen", "start", "begin",
        "search", "google", "look", "find", "show", "open", "launch", "run", "trigger", "execute", "take", "grab", "capture", "screenshot", "record",
        "copy", "read", "extract", "scan", "add", "drop", "remind", "focus", "ask", "how", "what", "delete", "remove", "erase", "wipe", "format",
        "trash", "uninstall", "install", "kill", "rename", "go", "tile", "resize", "shift", "push", "activate", "enable", "create", "stop",
    ]

    /// A cheap test that runs on every keystroke, before the apps, devices and workflows are gathered for a full reading: text that does
    /// not start like a request is never read further.
    static func couldBeRequest(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 300, !trimmed.hasPrefix("?") else { return false }
        let t = IntentText.normalize(trimmed)
        guard let first = t.split(separator: " ").first.map(String.init), t.contains(" ") else { return false }
        if explicitKeywords.contains(first) { return false }
        return verbs.contains(first) || t.contains("volume")
    }

    static func parse(_ raw: String, world: IntentWorld) -> IntentParseResult {
        guard couldBeRequest(raw) else { return .notAnIntent }
        let t = IntentText.normalize(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if let sequence = parseSequence(t, world) { return sequence }
        return parseSingle(t, world) ?? .notAnIntent
    }

    // MARK: Several things in one sentence

    private static func parseSequence(_ t: String, _ world: IntentWorld) -> IntentParseResult? {
        guard t.contains(" and ") || t.contains(" then ") else { return nil }
        let parts = split(t, pattern: #"\s+(?:and then|then|and)\s+"#)
        guard (2...3).contains(parts.count), parts.allSatisfy({ part in part.split(separator: " ").first.map { verbs.contains(String($0)) } ?? false }) else { return nil }
        var steps: [ResolvedIntent] = []
        for part in parts {
            guard let result = parseSingle(part, world) else { return nil }
            switch result {
            case .intent(let r): steps.append(r)
            case .notAnIntent: return nil
            default: return result
            }
        }
        let intent = LauncherIntent.sequence(steps.map(\.intent))
        if let problem = IntentValidator.validate(intent, world: world) { return .rejected(reason: problem) }
        return .intent(ResolvedIntent(
            intent: intent, title: steps.map(\.title).joined(separator: ", then "), detail: steps.map(\.detail).joined(separator: " Then: "),
            why: "\(steps.count) requests in one sentence, done in order", risk: IntentPolicy.risk(of: intent, world: world), source: .pattern,
            confidence: steps.map(\.confidence).min() ?? 1, shortcutHint: nil))
    }

    // MARK: One request

    private static func parseSingle(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        let readers: [(String, IntentWorld) -> IntentParseResult?] = [
            refuse, volume, mute, output, window, capture, shelf, timer, focus, workflow, diskSpace, askAssistant,
            notes, clipboard, tabs, web, files, settings, open,
        ]
        for read in readers { if let result = read(t, w) { return result } }
        return nil
    }

    // MARK: Building results

    private static func make(_ intent: LauncherIntent, _ title: String, _ detail: String, why: String, confidence: Double = 1, hint: String? = nil, _ w: IntentWorld) -> IntentParseResult {
        if let problem = IntentValidator.validate(intent, world: w) { return .rejected(reason: problem) }
        return .intent(ResolvedIntent(intent: intent, title: title, detail: detail, why: why, risk: IntentPolicy.risk(of: intent, world: w), source: .pattern, confidence: confidence, shortcutHint: hint))
    }

    private static var cache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = cache[pattern] { return cached }
        guard let made = try? NSRegularExpression(pattern: pattern) else { return nil }
        cache[pattern] = made
        return made
    }

    /// The captured groups of a pattern that must match the whole text; "" for a group that did not take part. Nil if it does not match.
    private static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let re = regex("^" + pattern + "$") else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<max(m.numberOfRanges, 1)).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    private static func split(_ text: String, pattern: String) -> [String] {
        guard let re = regex(pattern) else { return [text] }
        let ns = text as NSString
        var parts: [String] = [], last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: last))
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static let numberWords = ["", "", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

    /// Finds the app a name means. One app builds the result; several give a list to choose from; none says so.
    private static func withApp(_ spoken: String, _ w: IntentWorld, _ build: (IntentApp, Double) -> IntentParseResult) -> IntentParseResult {
        switch w.resolveApp(spoken) {
        case .none:
            return .rejected(reason: "I could not find an app named “\(spoken)”.")
        case .one(let app, let confidence):
            return build(app, confidence)
        case .many(let apps):
            var choices: [ResolvedIntent] = []
            for app in apps { if case .intent(var r) = build(app, 0.5) { r.title += apps.filter({ $0.name == app.name }).count > 1 ? " (\(app.bundleID))" : ""; choices.append(r) } }
            let names = Set(apps.map(\.name))
            let question: String
            if names.count == 1, apps.count < numberWords.count {
                question = "I found \(numberWords[apps.count]) apps named \(apps[0].name)."
            } else {
                question = "“\(spoken)” could be \(apps.prefix(4).map(\.name).joined(separator: ", "))."
            }
            return .ambiguous(question: question, choices: choices)
        }
    }

    private static func appRef(_ spoken: String, _ w: IntentWorld, system: [String] = ["", "everything", "all", "all apps", "all sound", "all audio", "sound", "audio", "volume", "the mac", "mac", "my mac", "computer", "system", "all volume", "everything else"]) -> String? {
        system.contains(IntentWorld.cleanName(spoken)) ? IntentWorld.systemApp : nil
    }

    // MARK: Refusals

    private static let fileVerbs = ["delete", "remove", "erase", "wipe", "format", "trash", "rename"]

    private static func refuse(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        let words = t.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        if first == "uninstall" || (first == "remove" && words.contains("app")) {
            return make(.openSettings(.apps, tab: "Installed"), "Open Apps to remove it", "Apps shows what an app leaves behind and asks before removing anything.", why: "“\(first)” opens Apps, where removal is confirmed", w)
        }
        if first == "install", words.count > 1 {
            return make(.openSettings(.apps, tab: "Install"), "Open Apps to install it", "The Install tab searches Homebrew and shows what it will do before it does it.", why: "“install” opens the Install tab", w)
        }
        if fileVerbs.contains(first), words.count > 1 {
            return .rejected(reason: "I do not delete, erase, rename or move files from a typed request. Finder actions and Disk Map show what will change first.")
        }
        if (first == "run" || first == "execute"), IntentText.looksLikeShell(words.dropFirst().joined(separator: " ")) {
            return .rejected(reason: "I never run typed text as a command. Saved actions and workflows are run by name.")
        }
        if IntentText.looksLikeShell(t), words.count > 1, verbs.contains(first), ["run", "execute", "open", "launch", "start"].contains(first) {
            return .rejected(reason: "That looks like shell text, which I never run from a request.")
        }
        return nil
    }

    // MARK: Volume

    private static let volumeStop: Set<String> = ["set", "change", "turn", "make", "put", "adjust", "lower", "raise", "bring", "the", "volume", "of", "for", "on", "to", "level", "sound", "audio", "at", "up", "down", "a", "my", "its", "'s"]

    private static func volume(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        let hasWord = t.contains("volume") || t.contains(" sound ") || t.hasSuffix(" sound") || t.contains(" audio")
        // "turn it up" / "lower the volume": the front app, a step at a time, with the command that already does that.
        if let g = groups(#"(?:turn|make|bring|put)?\s*(?:the )?(?:volume )?(up|down)(?: a bit| a little| some)?"#, t) ?? groups(#"(?:turn|make|bring|put)\s+(up|down)\s+(?:the )?volume(?: a bit| a little| some)?"#, t), t.contains("volume") || t.hasPrefix("turn") {
            let up = g[0] == "up"
            return make(.runCommand(up ? "sound.front.volume_up" : "sound.front.volume_down", arguments: [:]), up ? "Turn the front app up" : "Turn the front app down", "Changes the volume of the app in front by 10 points.", why: "“turn \(g[0])” + the front app", hint: up ? "sound.front.volume_up" : "sound.front.volume_down", w)
        }
        guard let percent = IntentText.extractPercent(from: t) else { return nil }
        guard hasWord || t.contains("%") || t.contains("percent") else { return nil }
        let first = t.split(separator: " ").first.map(String.init) ?? ""
        guard hasWord || ["set", "turn", "make", "put", "lower", "raise", "change", "adjust", "bring"].contains(first) else { return nil }
        let name = percent.remainder.split(separator: " ").map(String.init).filter { !volumeStop.contains($0) }.joined(separator: " ")
        let level = percent.value / 100
        func build(_ id: String, _ label: String, _ confidence: Double) -> IntentParseResult {
            make(.setVolume(appID: id, value: level), "Set \(label) to \(Int(percent.value.rounded()))%", id == IntentWorld.systemApp ? "Changes the volume of all sound from this Mac." : "Changes only \(label)'s volume; other apps are left alone.", why: "“volume” + \(id == IntentWorld.systemApp ? "all sound" : "an app") + a level", confidence: confidence, w)
        }
        if let system = appRef(name, w) { return build(system, "the volume", 1) }
        if !hasWord, case .none = w.resolveApp(name) { return nil }
        return withApp(name, w) { app, c in build(app.bundleID, app.name, c) }
    }

    // MARK: Muting

    private static func mute(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        if let g = groups(#"(?:mute|silence|quiet)\s+(?:everything|all(?: apps| sound| audio| the apps)?|the mac|my mac|everyone)?\s*(?:except|but|besides|apart from)\s+(.+)"#, t) {
            return withApp(g[0], w) { app, c in
                make(.muteAllExcept(appID: app.bundleID), "Mute everything except \(app.name)", "Silences every other app until you turn them back on.", why: "“mute” + all apps + “except” + an app", confidence: c, w)
            }
        }
        if t == "turn off the sound" || t == "turn the sound off" || t == "turn off sound" || t == "turn the volume off" {
            return make(.muteApp(appID: IntentWorld.systemApp, seconds: nil), "Mute all sound", "Silences everything until you unmute.", why: "“turn off the sound”", w)
        }
        if let g = groups(#"(?:turn|switch)\s+(?:the )?(?:sound|audio|volume)\s+(?:back )?on"#, t) {
            _ = g
            return make(.unmuteApp(appID: IntentWorld.systemApp), "Unmute all sound", "Brings the sound back.", why: "“turn the sound back on”", w)
        }
        if let g = groups(#"unmute\s+(.*)"#, t) {
            if let system = appRef(g[0], w) { return make(.unmuteApp(appID: system), "Unmute all sound", "Brings the sound back.", why: "“unmute”", w) }
            return withApp(g[0], w) { app, c in
                make(.unmuteApp(appID: app.bundleID), "Unmute \(app.name)", "Brings \(app.name)'s sound back.", why: "“unmute” + an app", confidence: c, w)
            }
        }
        guard let g = groups(#"(?:mute|silence|quiet)\s+(.*)"#, t) else { return nil }
        var rest = g[0], seconds: TimeInterval?
        if let duration = IntentText.extractDuration(from: rest, now: w.now, calendar: w.calendar) {
            guard (IntentText.shortest...IntentText.longest).contains(duration.value) else { return .rejected(reason: "Muting can be for 1 second to 24 hours.") }
            seconds = duration.value
            rest = duration.remainder
        }
        let forText = seconds.map { " for \(LauncherTimerParser.describe($0))" } ?? ""
        let why = "“mute” + " + (seconds == nil ? "an app" : "an app + a time")
        if let system = appRef(rest, w) {
            return make(.muteApp(appID: system, seconds: seconds), "Mute all sound\(forText)", seconds == nil ? "Silences everything until you unmute." : "Silences everything, then brings it back by itself.", why: why, w)
        }
        return withApp(rest, w) { app, c in
            make(.muteApp(appID: app.bundleID, seconds: seconds), "Mute \(app.name)\(forText)", seconds == nil ? "Silences \(app.name) until you unmute it." : "Silences \(app.name), then brings it back by itself.", why: why, confidence: c, w)
        }
    }

    // MARK: Sound output

    private static func output(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        var spoken: String?
        if let g = groups(#"(?:switch|change|set|choose|pick|select|use|route|send)\s+(?:the )?(?:sound|audio|output|sound output|audio output|speakers|sound device|audio device)(?:\s+(?:output|device))?\s*(?:(?:to|over to|onto|on)(?:\s+|$))?(.*)"#, t) { spoken = g[0] }
        else if let g = groups(#"play\s+(?:the )?(?:sound|audio)\s+(?:on|to|through|via|over)\s+(.+)"#, t) { spoken = g[0] }
        else if let g = groups(#"(?:use|switch to|change to|choose)\s+(.+?)\s+(?:for|as)\s+(?:the )?(?:sound|audio|output|speakers)"#, t) { spoken = g[0] }
        guard let spoken else { return nil }
        func choice(_ d: IntentDevice, _ c: Double) -> IntentParseResult {
            make(.chooseAudioOutput(deviceUID: d.uid), "Play sound on \(d.name)", "All sound from this Mac will play on \(d.name).", why: "“sound output” + a device", confidence: c, w)
        }
        let all = w.devices.compactMap { d -> ResolvedIntent? in if case .intent(let r) = choice(d, 0.5) { return r }; return nil }
        if IntentWorld.cleanName(spoken).isEmpty {
            return all.isEmpty ? .rejected(reason: "No sound output is connected.") : .needsInput(question: "Which output device should I use?", choices: all)
        }
        switch w.resolveDevice(spoken) {
        case .one(let device, let c): return choice(device, c)
        case .many(let devices):
            return .ambiguous(question: "“\(spoken)” could be \(devices.prefix(4).map(\.name).joined(separator: " or ")).", choices: devices.compactMap { d in if case .intent(let r) = choice(d, 0.5) { return r }; return nil })
        case .none:
            return all.isEmpty ? .rejected(reason: "I could not find a sound output named “\(spoken)”.") : .needsInput(question: "I could not find an output named “\(spoken)”. Which one should I use?", choices: all)
        }
    }

    // MARK: Window places

    private static let placeWords: Set<String> = ["left", "right", "top", "bottom", "half", "third", "thirds", "quarter", "corner", "center", "centre", "middle", "first", "last", "two", "2", "3", "sixth", "of", "the", "side", "screen", "and", "upper", "lower", "maximize", "maximise", "full", "fullscreen", "whole", "a", "window", "this", "it", "app", "to", "on", "into", "at", "over", "in", "current", "my"]

    static func placement(_ phrase: String) -> WindowLayout? {
        let words = phrase.split(separator: " ").map(String.init)
        guard !words.isEmpty, words.allSatisfy({ placeWords.contains($0) }) else { return nil }
        let has = { (w: String) in words.contains(w) }
        let top = has("top") || has("upper"), bottom = has("bottom") || has("lower"), left = has("left"), right = has("right")
        let isThird = has("third") || has("thirds"), isSixth = has("sixth")
        if has("maximize") || has("maximise") || has("fullscreen") || (has("full") && has("screen")) || has("whole") { return .maximize }
        if isSixth {
            if top && left { return .topLeftSixth }; if top && right { return .topRightSixth }; if top { return .topCenterSixth }
            if bottom && left { return .bottomLeftSixth }; if bottom && right { return .bottomRightSixth }; if bottom { return .bottomCenterSixth }
            return nil
        }
        if isThird {
            if has("two") || has("2") { return right || has("last") ? .lastTwoThirds : .firstTwoThirds }
            if has("center") || has("centre") || has("middle") { return .centerThird }
            if has("last") || right { return .lastThird }
            if has("first") || left { return .firstThird }
            return nil
        }
        if (top || bottom) && (left || right) {
            if top && left { return .topLeft }; if top && right { return .topRight }
            if bottom && left { return .bottomLeft }; return .bottomRight
        }
        if left { return .leftHalf }
        if right { return .rightHalf }
        if top { return .topHalf }
        if bottom { return .bottomHalf }
        if has("center") || has("centre") || has("middle") { return .center }
        return nil
    }

    private static func window(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        var phrase: String?
        if let g = groups(#"(?:move|snap|put|send|place|tile|push|resize|make|shift|set)\s+(?:the |this |my |current )?(?:window|it|this|app)?\s*(?:(?:to|on|into|at|over to|in)\s+)?(.+)"#, t) { phrase = g[0] }
        else if let g = groups(#"(maximi[sz]e|center|centre|fullscreen)(?: the)?(?: window)?"#, t) { phrase = g[0] }
        guard let phrase, let layout = placement(phrase) else { return nil }
        return make(.moveWindow(layout), "Move this window: \(layout.title)", "Moves the window that was in front when you opened the launcher.", why: "“move” + the front window + a place", hint: layout.command, w)
    }

    // MARK: Screenshots and recordings

    private static func captureTarget(_ word: String) -> CaptureMode {
        switch word {
        case "screen", "display", "desktop", "everything", "whole screen": return .screen
        case "window": return .window
        default: return .region
        }
    }

    private static func capture(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        func result(_ mode: CaptureMode, _ action: CaptureAction, _ title: String, _ detail: String, _ command: String) -> IntentParseResult {
            make(.capture(mode, action: action), title, detail, why: "a capture request", hint: command, w)
        }
        if let g = groups(#"(?:take|grab|capture|make)\s+(?:a |an |the )?(scrolling |full page )(?:screenshot|screen shot|capture)(?: of)?(?: the| this| my)?\s*(?:page|window)?"#, t), !g.isEmpty {
            return result(.window, .scroll, "Capture the whole page of this window", "Scrolls the window in front and joins the pieces into one picture.", "capture.scroll")
        }
        if let g = groups(#"(?:take|grab|capture|make)\s+(?:a |an |the )?(?:screenshot|screen shot|capture|picture|snapshot)(?: of)?(?: the| my| this)?\s*(screen|window|area|region|selection|display|desktop)?"#, t) {
            let mode = captureTarget(g[0])
            return result(mode, .normal, "Take a screenshot of the \(mode.title.lowercased())", "Captures it the way your capture settings say.", mode == .screen ? "capture.screen" : mode == .window ? "capture.window" : "capture.region")
        }
        if let g = groups(#"screenshot(?: of)?(?: the| my| this)?\s*(screen|window|area|region|selection|display)?"#, t) {
            let mode = captureTarget(g[0])
            return result(mode, .normal, "Take a screenshot of the \(mode.title.lowercased())", "Captures it the way your capture settings say.", mode == .screen ? "capture.screen" : mode == .window ? "capture.window" : "capture.region")
        }
        if let g = groups(#"capture\s+(?:the |my |a |an )?(screen|window|area|region|selection|display)"#, t) {
            let mode = captureTarget(g[0])
            return result(mode, .normal, "Capture the \(mode.title.lowercased())", "Captures it the way your capture settings say.", mode == .screen ? "capture.screen" : mode == .window ? "capture.window" : "capture.region")
        }
        if let g = groups(#"(?:record|start recording|begin recording)(?: the| my| a)?\s*(screen|window|display|desktop)?"#, t) {
            let mode = captureTarget(g[0].isEmpty ? "screen" : g[0])
            return result(mode, mode == .window ? .recordWindow : .recordScreen, "Record the \(mode == .window ? "window" : "screen")", "Starts a recording. Stop it from the menu bar or with the same shortcut.", mode == .window ? "capture.rec.window" : "capture.rec.screen")
        }
        if groups(#"(?:copy|grab|read|extract|get)\s+(?:the )?(?:text|words)\s+(?:from|on|in)\s+(?:the |my |a )?(?:screen|window|selection|area|region|picture|image)"#, t) != nil || t == "ocr" || t == "ocr the screen" {
            return result(.region, .text, "Copy text from part of the screen", "Drag over the text; it is read on this Mac and copied.", "capture.text")
        }
        if groups(#"(?:scan|read)\s+(?:a |the )?qr(?: code)?"#, t) != nil {
            return result(.region, .qr, "Read a QR code", "Drag over the code; what it holds is copied.", "capture.qr")
        }
        return nil
    }

    // MARK: The shelf

    private static func shelf(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        if groups(#"(?:show|open|toggle)\s+(?:the |my )?(?:file )?shelf"#, t) != nil {
            return make(.runCommand("shelf.toggle", arguments: [:]), "Show the file shelf", "Opens the shelf, or closes it if it is open.", why: "“shelf”", hint: "shelf.toggle", w)
        }
        guard let g = groups(#"(?:add|put|drop|send|move)\s+(?:the |my )?(?:latest|last|newest|most recent|recent)\s+(screenshot|download|file|capture)\s+(?:to|on|onto|into)\s+(?:the )?(?:file )?shelf"#, t) else { return nil }
        let kind = g[0] == "download" || g[0] == "file" ? "download" : "screenshot"
        guard let url = w.recentFile(kind) else { return .rejected(reason: "I could not find a recent \(kind).") }
        return make(.addToShelf([url]), "Put \(url.lastPathComponent) on the shelf", "Adds the file to the shelf; it is not moved or changed.", why: "“add” + the latest \(kind) + “shelf”", w)
    }

    // MARK: Timers and focus

    private static func timer(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        var rest: String?
        var label: String?
        if let g = groups(#"remind me\s+(?:in\s+)?(.+?)(?:\s+(?:to|about)\s+(.+))?"#, t) {
            rest = g[0]; label = g[1].isEmpty ? nil : g[1]
        } else if groups(#"(?:set|start|create|begin|make|add)\s+.*\btimer\b.*"#, t) != nil {
            // The whole sentence is read for the time, so “a 10 minute timer” and “a timer for 10 minutes” are the same.
            rest = t
        }
        guard var rest else { return nil }
        if let named = groups(#"(.*?)\s*\b(?:called|named|labell?ed)\s+(.+)"#, rest) {
            rest = named[0]; label = named[1]
        }
        guard let duration = IntentText.extractDuration(from: rest, now: w.now, calendar: w.calendar) else {
            return .rejected(reason: "How long should the timer run? For example, “set a timer for 5 minutes”.")
        }
        guard (IntentText.shortest...IntentText.longest).contains(duration.value) else { return .rejected(reason: "A timer can be from 1 second to 24 hours.") }
        let how = LauncherTimerParser.describe(duration.value)
        return make(.startTimer(seconds: duration.value, label: label), "Start a \(how) timer\(label.map { " (\($0))" } ?? "")", "You will hear a sound and see a message when it ends.", why: "“timer” + a time", w)
    }

    private static func focus(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        guard t.contains("focus"), !(t.hasPrefix("turn off") || t.hasPrefix("stop") || t.hasPrefix("end")) else { return nil }
        // "start a 25 minute focus session", "focus for 45 minutes", "focus mode until 3pm": the time comes out, and what is left must be only
        // the request to focus, so “focus on writing” and the like are left to search.
        let duration = IntentText.extractDuration(from: t, now: w.now, calendar: w.calendar)
        let rest = duration?.remainder ?? t
        guard groups(#"(?:start|begin|set|turn on|enable|activate|go into|enter|create)?\s*(?:a |an |my |the )?focus(?: session| mode| time)?"#, rest) != nil else { return nil }
        guard let duration else {
            return make(.runCommand("focus.session", arguments: [:]), "Start a focus session", "Starts your usual focus session, or ends the one that is running.", why: "“focus”", hint: "focus.session", w)
        }
        let minutes = Int((duration.value / 60).rounded(.up))
        guard IntentValidator.focusMinutes.contains(minutes) else { return .rejected(reason: "A focus session can be from 1 to 480 minutes.") }
        return make(.startFocusSession(minutes: minutes), "Start a \(LauncherTimerParser.describe(TimeInterval(minutes * 60))) focus session", "Applies your focus settings for that long, then puts everything back.", why: "“focus” + a time", hint: "focus.session", w)
    }

    // MARK: Workflows

    private static func workflow(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        var spoken: String?
        var explicit = true
        if let g = groups(#"(?:run|start|launch|trigger|execute|play|fire)\s+(?:my |the |a )?(.+?)\s+(?:workflow|automation|macro)"#, t) { spoken = g[0] }
        else if let g = groups(#"(?:run|start|launch|trigger|execute|fire)\s+(?:the |my )?(?:workflow|automation|macro)\s+(.+)"#, t) { spoken = g[0] }
        else if let g = groups(#"(?:turn on|enable|start|activate|switch on|go into)\s+(?:my |the )?(.+?)\s+mode"#, t), !g[0].contains("focus") { spoken = g[0] + " mode"; explicit = false }
        guard let spoken else { return nil }
        func choice(_ wf: IntentWorkflow, _ c: Double) -> IntentParseResult {
            make(.runWorkflow(id: wf.id), "Run “\(wf.name)”", wf.isRisky ? "This workflow does more than move windows or sound, so it asks first." : "Runs the workflow once.", why: "“run” + a workflow", confidence: c, w)
        }
        switch w.resolveWorkflow(spoken) {
        case .one(let wf, let c): return choice(wf, c)
        case .many(let list):
            return .ambiguous(question: "I found \(list.count < numberWords.count ? numberWords[list.count] : String(list.count)) workflows that fit “\(spoken)”.", choices: list.compactMap { if case .intent(let r) = choice($0, 0.5) { return r }; return nil })
        case .none:
            return explicit ? .rejected(reason: "The requested workflow does not exist.") : nil
        }
    }

    // MARK: Disk space and questions

    private static func diskSpace(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        guard t.contains("disk") || t.contains("storage") || t.contains("free space") else { return nil }
        guard groups(#"(?:how much|what(?:'s| is| takes| uses)?|show|open|check|find what)\s+.*(?:disk|storage|space).*"#, t) != nil else { return nil }
        return make(.openSettings(.diskMap, tab: nil), "Open Disk Map", "Shows what is using your disk, and what is safe to clear.", why: "a question about disk space", w)
    }

    private static func askAssistant(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        guard let g = groups(#"ask\s+(?:ai|apple intelligence|the ai|an ai|the assistant|claude|chatgpt|gemini)\s*(?:(?:about|for|to)\s+|:\s*)?(.+)"#, t) else { return nil }
        if w.localOnly { return .rejected(reason: "Local-only mode is on, so nothing is sent to an AI provider. Apple Intelligence on this Mac can still answer in the launcher.") }
        return make(.askAI(g[0]), "Ask AI: \(g[0])", "Sends your question to the AI provider you chose, with secrets hidden first.", why: "“ask AI” + a question", w)
    }

    // MARK: Notes, clipboard, tabs, files

    private static func notes(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        guard let g = groups(#"(?:find|search|show|open|look up|look for|look through)\s+(?:in )?(?:my |the |all )?notes?\s*(?:(?:about|on|for|with|containing|mentioning|called|named)(?:\s+|$))?(.*)"#, t) else { return nil }
        if g[0].isEmpty {
            return make(.runCommand("notes.open", arguments: [:]), "Open Notes", "Opens your notes.", why: "“notes”", hint: "notes.open", w)
        }
        return make(.searchNotes(g[0]), "Search notes for “\(g[0])”", "Looks through your notes on this Mac.", why: "“search” + notes + words", w)
    }

    private static func clipboard(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        let g = groups(#"(?:find|search|show|look|look up|look through)\s+(?:in |through |for )?(?:my |the )?clipboard(?: history)?\s*(?:(?:for|about|with|containing)(?:\s+|$))?(.*)"#, t)
            ?? groups(#"what did i copy\s*(?:(?:about|with|containing|from)(?:\s+|$))?(.*)"#, t)
        guard let g else { return nil }
        return make(.searchClipboard(g[0]), g[0].isEmpty ? "Show clipboard history" : "Search the clipboard for “\(g[0])”", "Looks through what you copied. Secrets stay hidden.", why: "“search” + clipboard history", w)
    }

    private static func tabs(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        guard let g = groups(#"(?:find|search|show|go to|switch to|open|look for|look through)\s+(?:the |my |a |an )?(?:browser |open |chrome |safari )?tabs?\s*(?:(?:about|for|with|on|containing|named)(?:\s+|$))?(.*)"#, t), !g[0].isEmpty else { return nil }
        return make(.searchBrowserTabs(g[0]), "Find a browser tab: “\(g[0])”", "Looks through the tabs open in your browsers.", why: "“find” + browser tabs", w)
    }

    private static let fileWords: Set<String> = ["file", "files", "document", "documents", "pdf", "pdfs", "image", "images", "photo", "photos", "picture", "pictures", "screenshot", "screenshots", "video", "videos", "spreadsheet", "spreadsheets", "presentation", "presentations", "folder", "folders", "download", "downloads"]

    static func dateRange(in text: String) -> (range: IntentDateRange, remainder: String)? {
        let patterns: [(String, (String) -> IntentDateRange)] = [
            (#"\b(?:from |modified |created |edited |opened |made |changed |in |during |since |on )?(?:the )?last (\d+) days\b"#, { .lastDays(Int($0) ?? 7) }),
            (#"\b(?:from |modified |created |edited |opened |made |changed |in |during |since |on )?last week\b"#, { _ in .lastWeek }),
            (#"\b(?:from |modified |created |edited |opened |made |changed |in |during |since |on )?this week\b"#, { _ in .thisWeek }),
            (#"\b(?:from |modified |created |edited |opened |made |changed |in |during |since |on )?last month\b"#, { _ in .lastMonth }),
            (#"\b(?:from |modified |created |edited |opened |made |changed |in |during |since |on )?this month\b"#, { _ in .thisMonth }),
            (#"\b(?:from |modified |created |edited |opened |made |changed |in |during |since |on )?yesterday\b"#, { _ in .yesterday }),
            (#"\b(?:from |modified |created |edited |opened |made |changed |in |during |since |on )?today\b"#, { _ in .today }),
        ]
        for (pattern, make) in patterns {
            guard let re = regex(pattern) else { continue }
            let ns = text as NSString
            guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
            let value = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ""
            let remainder = ns.replacingCharacters(in: m.range, with: " ")
            return (make(value), remainder.split(separator: " ").joined(separator: " "))
        }
        return nil
    }

    private static let fileFiller: Set<String> = ["find", "search", "show", "look", "for", "locate", "me", "my", "the", "all", "any", "files", "file", "named", "called", "about", "containing", "with", "from", "that", "i", "made", "opened", "edited", "modified", "created", "in", "on", "of", "a", "an", "mentioning", "documents", "document"]

    private static func files(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        guard groups(#"(?:find|search|show|locate|look for|look up)\b.*"#, t) != nil else { return nil }
        let words = t.split(separator: " ").map(String.init)
        // Notes, clipboard and tabs have their own readings; the word “notes” or “tabs” is not a file request.
        if words.contains(where: { ["notes", "note", "clipboard", "tab", "tabs"].contains($0) }) { return nil }
        let range = dateRange(in: t)
        guard words.contains(where: { fileWords.contains($0) }) || range != nil else { return nil }
        var rest = range?.remainder ?? t
        // The kind of file stays in the search ("pdf budget"); the filler goes.
        rest = rest.split(separator: " ").map(String.init).filter { !fileFiller.contains($0) }.joined(separator: " ")
        let phrase = range.map { " from \($0.range.phrase)" } ?? ""
        let q = rest
        if q.isEmpty, range == nil { return nil }
        return make(.searchFiles(query: q, range: range?.range), q.isEmpty ? "Show files\(phrase)" : "Find files: “\(q)”\(phrase)", "Searches your files with Spotlight; nothing is opened until you choose.", why: "“find” + files" + (range == nil ? "" : " + a date"), w)
    }

    // MARK: The web

    private static let engineNames: [(names: [String], id: String)] = [
        (["duckduckgo", "duck duck go", "ddg"], "duckduckgo"), (["google"], "google"), (["bing"], "bing"), (["brave search", "brave"], "brave"), (["ecosia"], "ecosia"),
        (["youtube", "yt"], "youtube"), (["apple maps", "maps"], "maps"), (["github"], "github"), (["wikipedia", "wiki"], "wikipedia"), (["stack overflow", "stackoverflow"], "stackoverflow"),
    ]

    private static func web(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        var engine: String?
        var query: String?
        let alternatives = engineNames.flatMap(\.names).sorted { $0.count > $1.count }.joined(separator: "|")
        func idFor(_ name: String) -> String? { engineNames.first { $0.names.contains(name) }?.id }
        if let g = groups(#"(?:search|look up|lookup|find|look)\s+(?:the )?(web|internet|online)\s*(?:(?:for|about)\s+)?(.+)"#, t) { query = g[1]; engine = w.defaultEngine }
        else if let g = groups("(?:search|find|look up|lookup|look)\\s+(?:on |in |with )?(\(alternatives))\\s+(?:for |about )?(.+)", t) { engine = idFor(g[0]); query = g[1] }
        else if let g = groups("(?:search|find|look up|lookup|look for|look)\\s+(?:for\\s+)?(.+?)\\s+(?:on|in|with|using)\\s+(\(alternatives))", t) { engine = idFor(g[1]); query = g[0] }
        else if let g = groups("(google|bing|brave|ecosia|duckduckgo|youtube|wikipedia)\\s+(?:for\\s+)?(.+)", t), t.hasPrefix("google ") || t.hasPrefix("search") { engine = idFor(g[0]); query = g[1] }
        else if let g = groups(#"(?:search for|look up|lookup)\s+(.+?)\s+online"#, t) { engine = w.defaultEngine; query = g[0] }
        guard let engine, var query, !query.isEmpty else { return nil }
        query = query.trimmingCharacters(in: .whitespaces)
        if IntentText.looksLikeShell(query) { return .rejected(reason: "That looks like shell text, which I do not search for or run.") }
        let site = WebSearch.engine(id: engine)
        return make(.webSearch(engine: engine, query: query), "Search \(site.name) for “\(query)”", "Opens the search in your browser.", why: "“search” + \(site.name) + words", w)
    }

    // MARK: Settings and opening things

    private static let paneNames: [(words: [String], pane: SettingsPane)] = [
        (["sound", "audio", "volume", "mixer", "equaliser", "equalizer"], .sound), (["mouse", "trackpad", "scroll", "scrolling"], .mouse), (["keyboard", "keys", "remap"], .keyboard),
        (["shortcut map", "shortcuts", "conflicts"], .shortcutMap), (["window", "windows", "snapping"], .windows), (["workspace", "workspaces"], .workspaces),
        (["display", "displays", "monitor", "monitors", "hot corners"], .displays), (["finder"], .finder), (["clipboard"], .clipboard), (["selection bar", "selection"], .selection),
        (["capture", "screenshot", "screenshots", "screen capture", "recording"], .capture), (["links", "link routing", "browser", "browsers"], .links), (["shelf", "file shelf"], .shelf),
        (["apps", "applications"], .apps), (["launcher"], .launcher), (["ai", "intelligence", "apple intelligence", "providers", "mcp"], .intelligence),
        (["automation", "workflows"], .automation), (["actions"], .actions), (["profiles", "app profiles"], .profiles), (["focus", "focus sessions"], .focus),
        (["menu bar", "menubar", "popover"], .menuBar), (["system monitor", "system"], .system), (["disk", "disk map", "storage"], .diskMap), (["notes"], .notes),
        (["clock", "world clock"], .clock), (["power", "sleep", "keep awake"], .power), (["general"], .general), (["permissions", "privacy"], .permissions),
        (["backup", "restore"], .backup), (["diagnostics", "logs"], .diagnostics), (["about", "version"], .about), (["devices"], .devices), (["pointer", "cursor"], .pointer),
        (["folder rules"], .folderRules), (["window buttons", "traffic lights"], .buttons), (["overview", "features"], .features),
    ]

    static func pane(named spoken: String) -> SettingsPane? {
        let name = spoken.replacingOccurrences(of: "kriya", with: "").split(separator: " ").joined(separator: " ")
        return paneNames.first { $0.words.contains(name) }?.pane
    }

    private static func settings(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        var spoken: String?
        if let g = groups(#"(?:open|show|go to|take me to|launch)\s+(?:the |my |kriya )?(?:kriya )?(.+?)\s+(?:settings|preferences|options|pane|screen)"#, t) { spoken = g[0] }
        else if let g = groups(#"(?:open|show|go to|take me to)\s+(?:kriya )?(?:settings|preferences)\s*(?:(?:for|about|to)(?:\s+|$))?(.*)"#, t) { spoken = g[0].isEmpty ? "general" : g[0] }
        guard let spoken else { return nil }
        guard let pane = pane(named: spoken) else { return nil }
        return make(.openSettings(pane, tab: nil), "Open \(pane.title) settings", "Opens that part of Kriya's settings.", why: "“open” + settings + a name", w)
    }

    private static func open(_ t: String, _ w: IntentWorld) -> IntentParseResult? {
        guard let g = groups(#"(?:open|launch|start|run|switch to|go to|show|activate)\s+(?:the |my |up )?(.+)"#, t) else { return nil }
        let spoken = g[0].trimmingCharacters(in: .whitespaces)
        if ["downloads", "desktop", "documents", "home"].contains(spoken.replacingOccurrences(of: " folder", with: "")), let url = w.folders[spoken.replacingOccurrences(of: " folder", with: "")] {
            return make(.openFile(url), "Open the \(spoken.replacingOccurrences(of: " folder", with: "")) folder", "Opens it in Finder.", why: "“open” + a folder", w)
        }
        if spoken.hasPrefix("/") || spoken.hasPrefix("~/") {
            let path = spoken.hasPrefix("~/") ? w.homeDirectory.path + String(spoken.dropFirst(1)) : spoken
            let url = URL(fileURLWithPath: path)
            return make(.openFile(url), "Open \(url.lastPathComponent)", "Opens the file with the app that handles it.", why: "“open” + a path", w)
        }
        if IntentText.looksLikeShell(spoken) { return .rejected(reason: "That looks like shell text, which I never run from a request.") }
        // A word that is not an app is left to normal search: “open” can start any search.
        switch w.resolveApp(spoken) {
        case .none: return nil
        case .one(let app, let c):
            return make(.openApp(bundleID: app.bundleID), "Open \(app.name)", app.isRunning ? "Brings it to the front." : "Starts it.", why: "“open” + an app", confidence: c, w)
        case .many(let apps):
            let choices = apps.compactMap { app -> ResolvedIntent? in
                guard case .intent(var r) = make(.openApp(bundleID: app.bundleID), "Open \(app.name)", app.isRunning ? "Brings it to the front." : "Starts it.", why: "“open” + an app", confidence: 0.5, w) else { return nil }
                if apps.filter({ $0.name == app.name }).count > 1 { r.title += " (\(app.bundleID))" }
                return r
            }
            let names = Set(apps.map(\.name))
            let question = names.count == 1 && apps.count < numberWords.count ? "I found \(numberWords[apps.count]) apps named \(apps[0].name)." : "“\(spoken)” could be \(apps.prefix(4).map(\.name).joined(separator: ", "))."
            return .ambiguous(question: question, choices: choices)
        }
    }
}
