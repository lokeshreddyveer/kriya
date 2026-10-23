import Foundation

/// What the Safari extension leaves for the app. Safari's extension is sandboxed and cannot start Kriya or read its secret, so it
/// writes each request as a small file in a folder only this user can reach, and the app picks the files up and checks them
/// with the same rules as every other browser request.
enum SafariInbox {
    /// Under Application Support/Kriya.
    static let folderName = "Safari-Inbox"
    static let maxFileBytes = PageCapture.maxMessageBytes
    /// Files this old are removed unread, so nothing waits in the folder for ever.
    static let maxAge: TimeInterval = 600

    enum Request: Equatable {
        case open(URL, title: String?)
        case selection(text: String, page: URL?)
        case page(PageClip, PageAction)
    }

    static func isInboxName(_ name: String) -> Bool {
        name.range(of: #"^safari-[0-9a-f]{32}\.json$"#, options: .regularExpression) != nil
    }

    static func newName() -> String { "safari-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".json" }

    /// Reads one file's contents the way the browser bridge reads a message.
    static func interpret(_ data: Data) -> Result<Request, BridgeError> {
        guard data.count <= maxFileBytes else { return .failure(.invalid("The message was too big.")) }
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let type = message["type"] as? String else {
            return .failure(.invalid("The message could not be read."))
        }
        switch type {
        case "open":
            guard let url = BridgeProtocol.webURL(message["url"]) else { return .failure(.invalid("That is not a web address Kriya can open.")) }
            return .success(.open(url, title: BridgeProtocol.clipped(message["title"], BridgeProtocol.maxTitleLength)))
        case "selection":
            guard let text = BridgeProtocol.clipped(message["text"], BridgeProtocol.maxTextLength) else { return .failure(.invalid("There was no text to show.")) }
            return .success(.selection(text: text, page: BridgeProtocol.webURL(message["url"])))
        case "page":
            switch PageCapture.clip(from: message) {
            case .success(let result): return .success(.page(result.clip, result.action))
            case .failure(let error): return .failure(error)
            }
        default:
            return .failure(.invalid("Kriya does not know that request."))
        }
    }

    /// Whether a file should be read at all: a name we would have written, not too big, not too old, not a link, and owned by
    /// this user.
    static func isAcceptable(name: String, size: Int, age: TimeInterval, isRegular: Bool, ownedByUser: Bool) -> Bool {
        isInboxName(name) && size <= maxFileBytes && age <= maxAge && isRegular && ownedByUser
    }
}
