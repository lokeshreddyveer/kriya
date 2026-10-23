import Foundation

/// What a model suggests is never applied as it comes. These read the suggestion, throw away whatever does not pass, and say why, so
/// the person is shown only things that are safe to apply and can see what was left out.
enum SuggestionProblem: Equatable {
    case notJSON
    case tooMany(Int)
    case rejected(String, why: String)
}

private func decodeObject(_ text: String) -> JSONValue? {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
    return JSONValue.parse(String(text[start...end]))
}

// MARK: - Renames

enum RenameSuggestions {
    static let maxFiles = 20
    static let maxNameLength = 120

    struct Result: Equatable {
        var renames: [(from: String, to: String)]
        var rejected: [SuggestionProblem]
        static func == (a: Result, b: Result) -> Bool { a.renames.map { [$0.from, $0.to] } == b.renames.map { [$0.from, $0.to] } && a.rejected == b.rejected }
    }

    static let schema: JSONValue = .object([
        "type": .string("object"), "additionalProperties": .bool(false), "required": .array([.string("renames")]),
        "properties": .object(["renames": .object(["type": .string("array"), "maxItems": .number(Double(maxFiles)), "items": .object([
            "type": .string("object"), "required": .array([.string("from"), .string("to")]),
            "properties": .object(["from": .object(["type": .string("string")]), "to": .object(["type": .string("string")])]),
        ])])]),
    ])

    /// `existing` is every name in the folder, so a new name cannot land on another file. The extension is kept: a model may not turn
    /// a document into a program by renaming it.
    static func validate(_ reply: String, files: [String], existing: Set<String>) -> Result {
        guard let json = decodeObject(reply), let list = json["renames"]?.arrayValue else { return Result(renames: [], rejected: [.notJSON]) }
        guard list.count <= maxFiles else { return Result(renames: [], rejected: [.tooMany(list.count)]) }
        var renames: [(String, String)] = []
        var rejected: [SuggestionProblem] = []
        var taken = existing
        var seenFrom = Set<String>()
        for item in list {
            guard let from = item["from"]?.stringValue, let to = item["to"]?.stringValue else { rejected.append(.rejected("?", why: "incomplete")); continue }
            guard files.contains(from), seenFrom.insert(from).inserted else { rejected.append(.rejected(from, why: "not one of the chosen files")); continue }
            var name = to.trimmingCharacters(in: .whitespacesAndNewlines)
            let ext = (from as NSString).pathExtension
            if !ext.isEmpty, (name as NSString).pathExtension.lowercased() != ext.lowercased() { name = (name as NSString).deletingPathExtension + "." + ext }
            if name == from { continue }
            if name.isEmpty || name.count > maxNameLength { rejected.append(.rejected(from, why: "the name is empty or too long")); continue }
            if name.hasPrefix(".") || name.contains("/") || name.contains(":") || name.contains("\0") || name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                rejected.append(.rejected(from, why: "the name has characters a file name cannot have")); continue
            }
            if taken.contains(name) && name.lowercased() != from.lowercased() { rejected.append(.rejected(from, why: "“\(name)” already exists")); continue }
            taken.remove(from)
            taken.insert(name)
            renames.append((from, name))
        }
        return Result(renames: renames, rejected: rejected)
    }
}

// MARK: - Tags, capture names, redaction words

enum TagSuggestions {
    static func clean(_ tags: [String], max: Int = 5) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in tags {
            let t = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "#,;"))).replacingOccurrences(of: "\n", with: " ")
            guard (1...30).contains(t.count), !t.contains("\0"), seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
            if out.count == max { break }
        }
        return out
    }

    static func fromReply(_ reply: String) -> [String] {
        if let json = decodeObject(reply), let tags = json["tags"]?.arrayValue { return clean(tags.compactMap(\.stringValue)) }
        return clean(reply.split(whereSeparator: { ",\n".contains($0) }).map(String.init))
    }
}

enum CaptureNameSuggestion {
    /// A short name for a picture, from what a model said: words only, no path characters, no extension.
    static func slug(from reply: String) -> String? {
        let first = reply.split(separator: "\n").first.map(String.init) ?? reply
        let words = first.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" ? Character($0) : " " }
        let cleaned = String(words).split(separator: " ").prefix(8).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard cleaned.count >= 3 else { return nil }
        return String(cleaned.prefix(50))
    }
}

enum RedactionSuggestions {
    /// Words and phrases a model says to hide in a screenshot. Each must really be in the text that was read from the picture, so it
    /// can be found and covered; invented ones are dropped.
    static func clean(_ reply: String, ocrText: String, max: Int = 30) -> [String] {
        let candidates: [String]
        if let json = decodeObject(reply), let list = json["hide"]?.arrayValue { candidates = list.compactMap(\.stringValue) }
        else { candidates = reply.split(separator: "\n").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "-•* \t\"")) } }
        var seen = Set<String>()
        var out: [String] = []
        for c in candidates {
            let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (3...80).contains(t.count), ocrText.contains(t), seen.insert(t).inserted else { continue }
            out.append(t)
            if out.count == max { break }
        }
        return out
    }
}

// MARK: - Finder plans

/// A set of file changes a model proposes for the person to read and approve. Only these operations exist, they only touch things
/// inside folders the person chose, nothing is overwritten, and there are never more than 50.
struct FinderPlan: Equatable {
    enum Operation: Equatable {
        case move(from: String, toFolder: String)
        case rename(path: String, to: String)
        case trash(path: String)

        var summary: String {
            switch self {
            case .move(let from, let to): return "Move “\((from as NSString).lastPathComponent)” into “\((to as NSString).lastPathComponent)”"
            case .rename(let path, let to): return "Rename “\((path as NSString).lastPathComponent)” to “\(to)”"
            case .trash(let path): return "Move “\((path as NSString).lastPathComponent)” to the Trash"
            }
        }
    }

    var operations: [Operation]
    var rejected: [SuggestionProblem]
    static let maxOperations = 50

    static let schema: JSONValue = .object([
        "type": .string("object"), "additionalProperties": .bool(false), "required": .array([.string("steps")]),
        "properties": .object(["steps": .object(["type": .string("array"), "maxItems": .number(Double(maxOperations)), "items": .object([
            "type": .string("object"), "required": .array([.string("op"), .string("path")]),
            "properties": .object(["op": .object(["type": .string("string"), "enum": .array([.string("move"), .string("rename"), .string("trash")])]),
                                   "path": .object(["type": .string("string")]), "to": .object(["type": .string("string")])]),
        ])])]),
    ])

    /// `allowed` says whether a path is inside the folders the person chose. `exists` and `isFolder` ask the file system.
    static func validate(_ reply: String, allowed: (String) -> Bool, exists: (String) -> Bool, isFolder: (String) -> Bool) -> FinderPlan {
        guard let json = decodeObject(reply), let steps = json["steps"]?.arrayValue else { return FinderPlan(operations: [], rejected: [.notJSON]) }
        guard steps.count <= maxOperations else { return FinderPlan(operations: [], rejected: [.tooMany(steps.count)]) }
        var ops: [Operation] = []
        var rejected: [SuggestionProblem] = []
        var touched = Set<String>()
        for step in steps {
            guard let op = step["op"]?.stringValue, let path = step["path"]?.stringValue else { rejected.append(.rejected("?", why: "incomplete")); continue }
            let name = (path as NSString).lastPathComponent
            guard path.hasPrefix("/"), !path.contains(".."), allowed(path), exists(path), touched.insert(path).inserted else { rejected.append(.rejected(name, why: "outside the chosen folders, missing, or used twice")); continue }
            switch op {
            case "trash":
                ops.append(.trash(path: path))
            case "move":
                guard let to = step["to"]?.stringValue, to.hasPrefix("/"), !to.contains(".."), allowed(to), isFolder(to), !to.hasPrefix(path + "/") else { rejected.append(.rejected(name, why: "the destination is not a chosen folder")); continue }
                guard !exists(to + "/" + name) else { rejected.append(.rejected(name, why: "something with that name is already in the destination")); continue }
                ops.append(.move(from: path, toFolder: to))
            case "rename":
                guard let to = step["to"]?.stringValue else { rejected.append(.rejected(name, why: "no new name")); continue }
                let check = RenameSuggestions.validate(#"{"renames":[{"from":"\#(name.replacingOccurrences(of: "\"", with: "\\\""))","to":"\#(to.replacingOccurrences(of: "\"", with: "\\\""))"}]}"#, files: [name], existing: [])
                guard let renamed = check.renames.first, !exists((path as NSString).deletingLastPathComponent + "/" + renamed.to) else { rejected.append(.rejected(name, why: "that new name is not allowed or already exists")); continue }
                ops.append(.rename(path: path, to: renamed.to))
            default:
                rejected.append(.rejected(name, why: "unknown operation"))
            }
        }
        return FinderPlan(operations: ops, rejected: rejected)
    }
}

// MARK: - Sound modes

enum SoundModeDraft {
    static let schema: JSONValue = .object([
        "type": .string("object"), "additionalProperties": .bool(false), "required": .array([.string("name"), .string("actions")]),
        "properties": .object([
            "name": .object(["type": .string("string"), "maxLength": .number(40)]),
            "actions": .object(["type": .string("array"), "maxItems": .number(8), "items": .object([
                "type": .string("object"), "required": .array([.string("type")]),
                "properties": .object([
                    "type": .object(["type": .string("string"), "enum": .array(["use_output", "use_input", "set_volume", "mute_mic", "mute_sound"].map { .string($0) })]),
                    "device": .object(["type": .string("string"), "maxLength": .number(80)]),
                    "percent": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(100)]),
                    "on": .object(["type": .string("boolean")]),
                ]),
            ])]),
        ]),
    ])

    enum Problem: Error, Equatable, LocalizedError {
        case unreadable, empty, noDevice(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The draft was not in the expected shape."
            case .empty: return "The draft had no usable steps."
            case .noDevice(let d): return "The draft names a sound device that is not connected: “\(d)”."
            }
        }
    }

    /// Builds a sound mode from a draft. Devices must be ones that are connected now, matched by name.
    static func parse(_ reply: String, outputs: [String], inputs: [String]) -> Result<SoundMode, Problem> {
        guard let json = decodeObject(reply), let name = json["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, let list = json["actions"]?.arrayValue else { return .failure(.unreadable) }
        func find(_ wanted: String?, in names: [String]) -> String? {
            guard let wanted = wanted?.lowercased(), !wanted.isEmpty else { return nil }
            return names.first { $0.lowercased() == wanted } ?? names.first { $0.lowercased().contains(wanted) || wanted.contains($0.lowercased()) }
        }
        var actions: [SoundAction] = []
        for item in list.prefix(8) {
            switch item["type"]?.stringValue {
            case "use_output":
                guard let device = find(item["device"]?.stringValue, in: outputs) else { return .failure(.noDevice(item["device"]?.stringValue ?? "")) }
                actions.append(.useOutput(nameContains: device))
            case "use_input":
                guard let device = find(item["device"]?.stringValue, in: inputs) else { return .failure(.noDevice(item["device"]?.stringValue ?? "")) }
                actions.append(.useInput(nameContains: device))
            case "set_volume":
                guard let p = item["percent"]?.numberValue, (0...100).contains(p) else { continue }
                actions.append(.setVolume(percent: Int(p)))
            case "mute_mic": if case .bool(let on)? = item["on"] { actions.append(.muteMic(on)) }
            case "mute_sound": if case .bool(let on)? = item["on"] { actions.append(.muteSound(on)) }
            default: continue
            }
        }
        guard !actions.isEmpty else { return .failure(.empty) }
        return .success(SoundMode(name: String(name.prefix(40)), symbol: "sparkles", actions: actions))
    }
}

// MARK: - Notes

enum NoteSimilarity {
    /// How alike two texts are, 0 to 1, by the three-word runs they share. Used to find duplicates and related notes without any AI.
    static func score(_ a: String, _ b: String) -> Double {
        func shingles(_ s: String) -> Set<String> {
            let words = s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            guard words.count >= 3 else { return Set(words) }
            return Set((0...(words.count - 3)).map { words[$0...$0 + 2].joined(separator: " ") })
        }
        let x = shingles(a), y = shingles(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    static func similar(to text: String, in others: [(title: String, text: String)], atLeast: Double = 0.35) -> [(title: String, score: Double)] {
        others.map { (title: $0.title, score: score(text, $0.text)) }.filter { $0.score >= atLeast }.sorted { $0.score > $1.score }
    }

    /// Tasks a model lists, as plain lines, without the bullets and boxes it added.
    static func tasks(from reply: String, max: Int = 30) -> [String] {
        reply.split(separator: "\n").map { line -> String in
            var t = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["- [ ]", "- [x]", "* [ ]", "-", "*", "•"] where t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces); break }
            if let dot = t.firstIndex(of: "."), t[..<dot].allSatisfy(\.isNumber), !t[..<dot].isEmpty { t = String(t[t.index(after: dot)...]).trimmingCharacters(in: .whitespaces) }
            return t
        }.filter { $0.count >= 3 && $0.count <= 200 }.prefix(max).map { $0 }
    }
}

// MARK: - Browser pages

enum PageAIPolicy {
    enum Decision: Equatable {
        case allow
        case askFirst(reason: String)
        case refuse(reason: String)
    }

    private static let sensitiveWords = ["bank", "banking", "paypal", "stripe.com/dashboard", "health", "mychart", "patient", "insurance", "tax", "mail.", "webmail", "outlook", "inbox", "accounts.", "account.", "login", "signin", "sign-in", "auth", "sso", "1password", "bitwarden", "lastpass", "wallet", "crypto", "admin", "vpn", "intranet"]

    /// A page on this Mac or inside a private network, which is not for sending anywhere.
    static func isInternal(host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".internal") || h.hasSuffix(".lan") || h.hasSuffix(".corp") || !h.contains(".") { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254)
    }

    static func looksSensitive(url: URL) -> Bool {
        let text = ((url.host ?? "") + url.path).lowercased()
        return sensitiveWords.contains { text.contains($0) }
    }

    /// Whether the text of a page may go to an AI provider. A private window is never read. A page on a private network, or one that
    /// looks like a bank, mail or sign-in page, asks every time. Any other site asks the first time and can be remembered.
    static func decide(url: URL, isPrivateWindow: Bool, providerIsOnThisMac: Bool, allowedHosts: Set<String>, blockedHosts: Set<String>) -> Decision {
        guard let host = url.host?.lowercased(), url.scheme == "https" || url.scheme == "http" else { return .refuse(reason: "This is not a web page.") }
        if isPrivateWindow { return .refuse(reason: "This is a private window, so Kriya does not read it.") }
        if blockedHosts.contains(host) { return .refuse(reason: "You told Kriya never to use \(host) with AI.") }
        if isInternal(host: host) && !providerIsOnThisMac { return .refuse(reason: "This page is on a private network, so it is not sent to a provider outside this Mac.") }
        if looksSensitive(url: url) && !providerIsOnThisMac { return .askFirst(reason: "\(host) looks like a bank, mail or sign-in page. Its text would go to an outside provider.") }
        if providerIsOnThisMac || allowedHosts.contains(host) { return .allow }
        return .askFirst(reason: "Kriya has not been allowed to send text from \(host) to an AI provider yet.")
    }
}

// MARK: - Audio facts

/// What is true about the Mac's sound right now, written as plain lines for a model to reason about. It holds device names, levels and
/// switches only: nothing that was played or heard.
enum AudioFacts {
    struct Device: Equatable { var name: String; var isOutput: Bool; var isInput: Bool }
    struct App: Equatable { var name: String; var volumePercent: Int; var muted: Bool; var output: String?; var equaliserChanged: Bool }

    static func render(output: String?, input: String?, volumePercent: Int?, outputMuted: Bool?, micMuted: Bool?, devices: [Device], apps: [App], modeOn: String?) -> String {
        var lines = ["Current output: \(output ?? "none")", "Current microphone: \(input ?? "none")"]
        if let v = volumePercent { lines.append("Output volume: \(v)%") }
        if let m = outputMuted { lines.append("Output muted: \(m ? "yes" : "no")") }
        if let m = micMuted { lines.append("Microphone muted: \(m ? "yes" : "no")") }
        if let modeOn { lines.append("Sound mode on: \(modeOn)") }
        lines.append("Devices: " + (devices.isEmpty ? "none" : devices.map { "\($0.name) (\($0.isOutput ? "output" : "")\($0.isOutput && $0.isInput ? "+" : "")\($0.isInput ? "input" : ""))" }.joined(separator: ", ")))
        if apps.isEmpty { lines.append("Apps with changed sound settings: none") }
        for app in apps.prefix(30) {
            var parts = ["volume \(app.volumePercent)%"]
            if app.muted { parts.append("MUTED") }
            if let o = app.output { parts.append("output \(o)") }
            if app.equaliserChanged { parts.append("equaliser changed") }
            lines.append("App \(app.name): " + parts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}
