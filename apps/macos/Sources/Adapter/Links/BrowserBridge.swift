import AppKit
import Foundation
import Security

// The browser extensions talk to Kriya like this: the browser starts Kriya's own program in a special mode (the native
// host below), hands it one small message, and the host turns that into a `kriya://browser/...` address with a secret
// the app checks. The secret is a file only this Mac user can read, so a web page cannot make the same request. Nothing
// here uses the network, and nothing a person copied or selected is ever written to the log.

enum BridgeError: Error, Equatable, LocalizedError {
    case invalid(String)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .unauthorized: return "Kriya did not recognise that request."
        }
    }
}

/// What a browser extension can ask Kriya to do.
enum BridgeRequest: Equatable {
    case open(URL, title: String?)
    case selection(text: String, page: URL?)
    /// A page the browser read, waiting in the inbox folder under this file name.
    case page(file: String, action: PageAction)
}

enum BridgeProtocol {
    static let hostName = "app.kriya.bridge"
    static let maxURLLength = 4096
    static let maxTitleLength = 300
    static let maxTextLength = 8000

    /// An address Kriya may open for a browser: http or https, with a host, and not absurdly long.
    static func webURL(_ raw: Any?) -> URL? {
        guard let text = raw as? String, text.count <= maxURLLength, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Trimmed text, cut to `limit`, or nil when there is nothing in it.
    static func clipped(_ raw: Any?, _ limit: Int) -> String? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(limit))
    }

    /// The host's side: checks a message from the browser and builds the address Kriya is asked to open.
    static func address(for message: [String: Any], token: String) -> Result<URL, BridgeError> {
        guard let type = message["type"] as? String else { return .failure(.invalid("The message had no type.")) }
        var components = URLComponents()
        components.scheme = "kriya"
        components.host = "browser"
        var items = [URLQueryItem(name: "t", value: token)]
        switch type {
        case "open":
            guard let url = webURL(message["url"]) else { return .failure(.invalid("That is not a web address Kriya can open.")) }
            components.path = "/open"
            items.append(URLQueryItem(name: "u", value: url.absoluteString))
            if let title = clipped(message["title"], maxTitleLength) { items.append(URLQueryItem(name: "n", value: title)) }
        case "selection":
            guard let text = clipped(message["text"], maxTextLength) else { return .failure(.invalid("There was no text to send.")) }
            components.path = "/selection"
            items.append(URLQueryItem(name: "x", value: text))
            if let page = webURL(message["url"]) { items.append(URLQueryItem(name: "u", value: page.absoluteString)) }
        default:
            return .failure(.invalid("Kriya does not know that request."))
        }
        components.queryItems = items
        guard let url = components.url else { return .failure(.invalid("The request could not be built.")) }
        return .success(url)
    }

    /// The host's side, for a page: the address that tells the app which file in the inbox to take, and what to do with it.
    static func pageAddress(file: String, action: PageAction, token: String) -> URL? {
        var components = URLComponents()
        components.scheme = "kriya"
        components.host = "browser"
        components.path = "/page"
        components.queryItems = [URLQueryItem(name: "t", value: token), URLQueryItem(name: "f", value: file), URLQueryItem(name: "a", value: action.rawValue)]
        return components.url
    }

    /// The app's side: checks an address and its secret, and says what was asked.
    static func request(from url: URL, token: String) -> Result<BridgeRequest, BridgeError> {
        guard url.scheme?.lowercased() == "kriya", url.host?.lowercased() == "browser",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.invalid("That is not a browser request."))
        }
        let pairs = (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } }
        let query = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        guard !token.isEmpty, let given = query["t"], constantTimeEqual(given, token) else { return .failure(.unauthorized) }
        switch components.path {
        case "/open":
            guard let link = webURL(query["u"]) else { return .failure(.invalid("That is not a web address Kriya can open.")) }
            return .success(.open(link, title: clipped(query["n"], maxTitleLength)))
        case "/selection":
            guard let text = clipped(query["x"], maxTextLength) else { return .failure(.invalid("There was no text to show.")) }
            return .success(.selection(text: text, page: webURL(query["u"])))
        case "/page":
            guard let file = query["f"], PageCapture.isInboxName(file), let action = query["a"].flatMap(PageAction.init(rawValue:)) else {
                return .failure(.invalid("That page request was not understood."))
            }
            return .success(.page(file: file, action: action))
        default:
            return .failure(.invalid("Kriya does not know that request."))
        }
    }

    /// Compares two secrets without stopping at the first difference.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<x.count { difference |= x[index] ^ y[index] }
        return difference == 0
    }
}

/// The secret shared between the app and the host the browser starts. A file only this Mac user can read.
enum BridgeToken {
    static func fileURL(in support: URL) -> URL { support.appendingPathComponent("browser-bridge-token") }

    /// The host's side: reads it, never makes one (if Kriya has never run there is nothing to talk to).
    static func read(in support: URL) -> String? {
        guard let text = try? String(contentsOf: fileURL(in: support), encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.count == 64 ? token : nil
    }

    static func loadOrCreate(in support: URL) -> String {
        if let existing = read(in: support) { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = fileURL(in: support)
        try? token.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return token
    }
}

/// Receives what the browser extensions send. Links go through the same rules as any other link; selected text goes to the
/// selection bar. What was sent is never logged.
final class BrowserBridge: ObservableObject {
    @Published private(set) var lastRequest: Date?
    @Published private(set) var handled = 0
    @Published private(set) var refused = 0

    private let token: String
    var openLink: (URL) -> Void = { _ in }
    var showSelection: (String) -> Void = { _ in }
    /// Takes the page waiting under this file name in the inbox and does the action with it.
    var savePage: (String, PageAction) -> Void = { _, _ in }

    init(support: URL) {
        token = BridgeToken.loadOrCreate(in: support)
    }

    @discardableResult
    func handle(_ url: URL) -> Bool {
        switch BridgeProtocol.request(from: url, token: token) {
        case .failure(let error):
            refused += 1
            Log.warning("Browser", "A browser request was refused: \(error.localizedDescription)")
            return false
        case .success(let request):
            handled += 1
            lastRequest = Date()
            switch request {
            case .open(let link, _): openLink(link)
            case .selection(let text, _): showSelection(text)
            case .page(let file, let action): savePage(file, action)
            }
            return true
        }
    }
}
