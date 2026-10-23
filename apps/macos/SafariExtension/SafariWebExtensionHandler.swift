import SafariServices

/// The native side of Kriya's Safari extension. Safari hands it one small message from the extension; it checks the size and the
/// kind, writes it as a file in the inbox folder, and answers. The Kriya app picks the file up and checks it again. This code has
/// no network access and reads nothing but the message it is given.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let maxBytes = 2_000_000
    private static let kinds: Set<String> = ["open", "selection", "page"]

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        let reply: [String: Any] = Self.store(message) ?? ["ok": true]
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    /// Nil when stored; otherwise the answer to give back.
    private static func store(_ message: [String: Any]?) -> [String: Any]? {
        guard let message, let type = message["type"] as? String, kinds.contains(type),
              JSONSerialization.isValidJSONObject(message), let data = try? JSONSerialization.data(withJSONObject: message), data.count <= maxBytes else {
            return ["ok": false, "error": "Kriya could not use that message."]
        }
        // In the sandbox this is the real Application Support folder through the one exception in the entitlements.
        // The sandbox gives the extension its own home; the real one is in the user database.
        guard let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir else { return ["ok": false, "error": "No folder."] }
        let home = URL(fileURLWithPath: String(cString: path))
        let root = home.appendingPathComponent("Library/Application Support/Kriya/Safari-Inbox", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let name = "safari-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".json"
            let file = root.appendingPathComponent(name)
            try data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return nil
        } catch {
            return ["ok": false, "error": "Kriya could not keep the message."]
        }
    }
}
