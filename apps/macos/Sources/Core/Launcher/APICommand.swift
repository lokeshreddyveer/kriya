import Foundation

/// A web request the person defines, run from the launcher: "weather paris" calls a URL with the words in it and shows part of
/// the answer. Only the words typed after the keyword go into the request, and only when the result is chosen.
struct APICommand: Codable, Identifiable, Equatable {
    enum Method: String, Codable, CaseIterable, Identifiable {
        case get = "GET", post = "POST", put = "PUT", delete = "DELETE"
        var id: String { rawValue }
        var sendsBody: Bool { self != .get && self != .delete }
    }

    /// What is done with the answer.
    enum Output: String, Codable, CaseIterable, Identifiable {
        case message, clipboard, open
        var id: String { rawValue }
        var title: String {
            switch self {
            case .message: return "Show it"
            case .clipboard: return "Copy it"
            case .open: return "Open it as a web address"
            }
        }
    }

    var id = UUID().uuidString
    var name: String
    var keyword: String
    var method: Method = .get
    /// An https address (http only for this Mac). `{query}` stands for the words typed, encoded for an address.
    var url: String
    /// Header names. Their values are kept in the keychain, never here, since they are often keys.
    var headerNames: [String] = []
    /// The body for POST and PUT. `{query}` stands for the words typed, escaped for JSON text.
    var body: String = ""
    /// Which part of a JSON answer to use: `data.items.0.name`. Empty uses the whole answer.
    var resultPath: String = ""
    var output: Output = .message

    static let placeholder = "{query}"
    static let maxHeaders = 10
    static let maxResponseBytes = 1_000_000
    static let timeout: TimeInterval = 15

    var takesQuery: Bool { url.contains(Self.placeholder) || body.contains(Self.placeholder) }

    /// The host the request goes to, to show before it is chosen.
    var host: String? { URL(string: url.replacingOccurrences(of: Self.placeholder, with: "x"))?.host }

    /// Why this cannot be saved, or nil.
    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a name." }
        let word = keyword.trimmingCharacters(in: .whitespaces)
        if word.isEmpty { return "Give it a keyword to type." }
        if word.contains(" ") { return "The keyword is one word." }
        if word.count > 12 { return "The keyword is at most 12 letters." }
        if WebSearch.engines.contains(where: { $0.keyword == word.lowercased() }) { return "“\(word)” already searches a site. Pick another word." }
        guard let sample = URL(string: url.replacingOccurrences(of: Self.placeholder, with: "x")), let scheme = sample.scheme?.lowercased(), let host = sample.host, !host.isEmpty else {
            return "The address must start with https://."
        }
        if scheme != "https" && !(scheme == "http" && Self.isThisMac(host)) { return "Only https:// addresses are used (http:// works for localhost)." }
        if headerNames.count > Self.maxHeaders { return "Up to \(Self.maxHeaders) headers." }
        if let bad = headerNames.first(where: { !Self.isHeaderName($0) }) { return "“\(bad)” is not a header name." }
        if body.utf8.count > 100_000 { return "The body is too long." }
        return nil
    }

    static func isThisMac(_ host: String) -> Bool { host == "localhost" || host == "127.0.0.1" || host == "::1" }

    static func isHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 60 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// A header that carries a login. Shown hidden in the editor.
    static func looksSecret(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["authorization", "token", "key", "secret", "cookie", "password"].contains { lower.contains($0) }
    }

    /// The request for these words. Nil if the address does not come out as a valid web address.
    func request(for query: String, headerValues: [String: String]) -> URLRequest? {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard words.count <= 500 else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#?/;:@$,")
        guard let encoded = words.addingPercentEncoding(withAllowedCharacters: allowed),
              let target = URL(string: url.replacingOccurrences(of: Self.placeholder, with: encoded)),
              let scheme = target.scheme?.lowercased(), scheme == "https" || (scheme == "http" && Self.isThisMac(target.host ?? "")) else { return nil }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = method.rawValue
        for name in headerNames {
            if let value = headerValues[name], !value.isEmpty { request.setValue(value, forHTTPHeaderField: name) }
        }
        if method.sendsBody, !body.isEmpty {
            request.httpBody = Data(body.replacingOccurrences(of: Self.placeholder, with: Self.jsonEscaped(words)).utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        }
        return request
    }

    /// Text made safe to sit inside a JSON string.
    static func jsonEscaped(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text), let quoted = String(data: data, encoding: .utf8) else { return "" }
        return String(quoted.dropFirst().dropLast())
    }
}

/// Picks one part out of a JSON answer by a dotted path, and turns it into text.
enum JSONResult {
    /// `data.items.0.name`: names go into objects, numbers into lists. Empty path means the whole answer. A plain-text answer
    /// that is not JSON is returned as it is when there is no path.
    static func extract(_ data: Data, path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return trimmed.isEmpty ? String(data: data, encoding: .utf8) : nil
        }
        var current: Any = root
        if !trimmed.isEmpty {
            for part in trimmed.split(separator: ".").map(String.init) {
                if let object = current as? [String: Any], let next = object[part] {
                    current = next
                } else if let list = current as? [Any], let index = Int(part), list.indices.contains(index) {
                    current = list[index]
                } else {
                    return nil
                }
            }
        }
        return text(of: current)
    }

    static func text(of value: Any) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        case is NSNull: return "null"
        default:
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
}
