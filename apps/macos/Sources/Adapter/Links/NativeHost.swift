import AppKit
import Foundation

/// The program a browser starts to talk to Kriya ("native messaging"). It is Kriya's own executable, started with an
/// extra argument; it reads one length-prefixed JSON message at a time from the browser, checks it, and asks the running
/// app to act on it. It never opens a window and exits when the browser closes the pipe.
enum NativeHost {
    /// A message from a browser is a few hundred bytes. Anything bigger is refused.
    static let maxMessageBytes = 64 * 1024

    /// Chrome starts the host with the extension's address, Firefox with the path of the host's manifest.
    static func isRequested(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains {
            $0 == "--native-host" || $0.hasPrefix("chrome-extension://") || $0.hasSuffix("\(BridgeProtocol.hostName).json")
        }
    }

    /// A message with a whole page in it may be this big; every other kind stays within `maxMessageBytes`.
    static var maxPageMessageBytes: Int { PageCapture.maxMessageBytes }

    static func run() -> Never {
        let support = AppPaths.live.support
        while let body = readMessage(from: FileHandle.standardInput) {
            write(reply(to: body, support: support), to: FileHandle.standardOutput)
        }
        exit(0)
    }

    // MARK: Framing

    /// A message as the browser sends it: four bytes of length (this machine's byte order), then the JSON.
    static func frame(_ body: Data) -> Data {
        var length = UInt32(body.count)
        return Data(bytes: &length, count: 4) + body
    }

    /// Splits one message off the front of `data`. Nil when there is not a whole one, or it is too big.
    static func unframe(_ input: Data) -> (message: Data, rest: Data)? {
        // A slice of a larger Data does not start at zero, so it is copied into one that does before it is indexed.
        let data = Data(input)
        guard data.count >= 4 else { return nil }
        let length = Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard length > 0, length <= maxMessageBytes, data.count >= 4 + length else { return nil }
        return (data.subdata(in: 4..<(4 + length)), Data(data.dropFirst(4 + length)))
    }

    private static func readMessage(from handle: FileHandle) -> Data? {
        let header = handle.readData(ofLength: 4)
        guard header.count == 4 else { return nil }
        let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard length > 0, length <= maxPageMessageBytes else { return nil }
        let body = handle.readData(ofLength: length)
        return body.count == length ? body : nil
    }

    private static func write(_ body: Data, to handle: FileHandle) {
        handle.write(frame(body))
    }

    // MARK: Answering

    static func reply(to body: Data, support: URL, open: (URL) -> Bool = launch) -> Data {
        func answer(_ ok: Bool, _ error: String? = nil) -> Data {
            var object: [String: Any] = ["ok": ok]
            if let error { object["error"] = error }
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data(#"{"ok":false}"#.utf8)
        }
        guard let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return answer(false, "The message was not understood.")
        }
        guard let token = BridgeToken.read(in: support) else {
            return answer(false, "Open Kriya once on this Mac first.")
        }
        if (message["type"] as? String) == "page" {
            return page(message, support: support, token: token, open: open, answer: answer)
        }
        // Only a page may be big.
        guard body.count <= maxMessageBytes else { return answer(false, "The message was too big.") }
        switch BridgeProtocol.address(for: message, token: token) {
        case .failure(let error):
            return answer(false, error.localizedDescription)
        case .success(let address):
            return open(address) ? answer(true) : answer(false, "Kriya could not be started.")
        }
    }

    /// A page: the text is put in a file only this user can read, in the inbox, and the app is told its name. The text never
    /// travels in an address.
    private static func page(_ message: [String: Any], support: URL, token: String, open: (URL) -> Bool, answer: (Bool, String?) -> Data) -> Data {
        switch PageCapture.clip(from: message) {
        case .failure(let error):
            return answer(false, error.localizedDescription)
        case .success(let result):
            let inbox = support.appendingPathComponent("Inbox", isDirectory: true)
            let name = PageCapture.inboxName()
            do {
                try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let file = inbox.appendingPathComponent(name)
                try JSONEncoder().encode(result.clip).write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch {
                return answer(false, "Kriya could not keep the page.")
            }
            guard let address = BridgeProtocol.pageAddress(file: name, action: result.action, token: token) else { return answer(false, "The request could not be built.") }
            return open(address) ? answer(true, nil) : answer(false, "Kriya could not be started.")
        }
    }

    /// Hands the address to the system, which gives it to the running Kriya (or starts it) without bringing it forward.
    private static func launch(_ address: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", address.absoluteString]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// The browsers Kriya can connect to, and the file each needs so it will start the host.
struct BrowserChoice: Identifiable, Hashable {
    enum Kind { case chromium, firefox }

    let id: String
    let name: String
    let kind: Kind
    /// Under ~/Library/Application Support.
    let folder: String
}

enum NativeHostInstaller {
    static let chromiumExtensionID = "nnedjokfckklekcnohdlmaphhahcjhli"
    static let firefoxExtensionID = "kriya-bridge@kriya.app"

    static let browsers: [BrowserChoice] = [
        BrowserChoice(id: "com.google.Chrome", name: "Google Chrome", kind: .chromium, folder: "Google/Chrome"),
        BrowserChoice(id: "com.microsoft.edgemac", name: "Microsoft Edge", kind: .chromium, folder: "Microsoft Edge"),
        BrowserChoice(id: "com.brave.Browser", name: "Brave", kind: .chromium, folder: "BraveSoftware/Brave-Browser"),
        BrowserChoice(id: "com.vivaldi.Vivaldi", name: "Vivaldi", kind: .chromium, folder: "Vivaldi"),
        BrowserChoice(id: "org.chromium.Chromium", name: "Chromium", kind: .chromium, folder: "Chromium"),
        BrowserChoice(id: "org.mozilla.firefox", name: "Firefox", kind: .firefox, folder: "Mozilla"),
    ]

    /// The browsers that are on this Mac.
    static func installedBrowsers() -> [BrowserChoice] {
        browsers.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    /// The file that tells a browser how to start the host.
    static func manifest(for browser: BrowserChoice, executable: String) -> Data {
        var object: [String: Any] = [
            "name": BridgeProtocol.hostName,
            "description": "Kriya, on this Mac",
            "path": executable,
            "type": "stdio",
        ]
        switch browser.kind {
        case .chromium: object["allowed_origins"] = ["chrome-extension://\(chromiumExtensionID)/"]
        case .firefox: object["allowed_extensions"] = [firefoxExtensionID]
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static func manifestURL(for browser: BrowserChoice, applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent(browser.folder, isDirectory: true)
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent("\(BridgeProtocol.hostName).json")
    }

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Whether the connection is in place and points at this copy of Kriya.
    static func isInstalled(_ browser: BrowserChoice, executable: String, applicationSupport: URL = applicationSupport) -> Bool {
        guard let data = try? Data(contentsOf: manifestURL(for: browser, applicationSupport: applicationSupport)),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return object["path"] as? String == executable
    }

    static func install(_ browser: BrowserChoice, executable: String, applicationSupport: URL = applicationSupport) throws {
        let url = manifestURL(for: browser, applicationSupport: applicationSupport)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manifest(for: browser, executable: executable).write(to: url, options: .atomic)
    }

    static func remove(_ browser: BrowserChoice, applicationSupport: URL = applicationSupport) {
        try? FileManager.default.removeItem(at: manifestURL(for: browser, applicationSupport: applicationSupport))
    }

    /// Puts the extension folders where a person can load them, outside the app, so the path stays the same after an update.
    @discardableResult
    static func prepareExtensions(into support: URL) -> URL? {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("Extensions", isDirectory: true),
              FileManager.default.fileExists(atPath: source.path) else { return nil }
        let target = support.appendingPathComponent("Browser Extensions", isDirectory: true)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: source, to: target)
            return target
        } catch {
            return nil
        }
    }
}
