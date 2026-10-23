import Foundation

/// What a `kriya://` address from the command-line tool, a script or the Shortcuts app asks Kriya to do. Every address
/// carries the secret in `t`; without it nothing happens, so a web page cannot trigger anything.
enum RemoteCommand: Equatable {
    case command(String)
    case action(String)
    case workflow(String)
    case launcher(String?)

    static let hosts: Set<String> = ["run", "action", "workflow", "launcher"]

    /// Ids are made of letters, digits and a few separators, never anything that could be mistaken for more than a name.
    static func isValidID(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9_.:@-]{1,100}$"#, options: .regularExpression) != nil
    }

    enum Failure: Error, Equatable { case notOurs, unauthorized, invalid }

    /// Reads an address. `token` is Kriya's secret.
    static func parse(_ url: URL, token: String) -> Result<RemoteCommand, Failure> {
        guard url.scheme?.lowercased() == "kriya", let host = url.host?.lowercased(), hosts.contains(host),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .failure(.notOurs) }
        let pairs = (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } }
        let query = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        guard !token.isEmpty, let given = query["t"], BridgeProtocol.constantTimeEqual(given, token) else { return .failure(.unauthorized) }
        switch host {
        case "run":
            guard let id = query["command"], isValidID(id) else { return .failure(.invalid) }
            return .success(.command(id))
        case "action":
            guard let id = query["id"], isValidID(id) else { return .failure(.invalid) }
            return .success(.action(id))
        case "workflow":
            guard let id = query["id"], isValidID(id) else { return .failure(.invalid) }
            return .success(.workflow(id))
        default:
            guard let text = query["q"] else { return .success(.launcher(nil)) }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count <= 200, !clean.contains("\0") else { return .failure(.invalid) }
            return .success(.launcher(clean.isEmpty ? nil : clean))
        }
    }

    /// The address that asks for this, for the Shortcuts actions and tests.
    func url(token: String) -> URL? {
        var components = URLComponents()
        components.scheme = "kriya"
        var items: [URLQueryItem] = []
        switch self {
        case .command(let id): components.host = "run"; items.append(URLQueryItem(name: "command", value: id))
        case .action(let id): components.host = "action"; items.append(URLQueryItem(name: "id", value: id))
        case .workflow(let id): components.host = "workflow"; items.append(URLQueryItem(name: "id", value: id))
        case .launcher(let text):
            components.host = "launcher"
            if let text { items.append(URLQueryItem(name: "q", value: text)) }
        }
        items.append(URLQueryItem(name: "t", value: token))
        components.queryItems = items
        return components.url
    }
}

/// The command-line tool shipped inside the app, and putting a copy where a shell finds it.
enum CommandLineTool {
    static var bundled: URL? { Bundle.main.resourceURL?.appendingPathComponent("CLI/kriya") }

    static var installFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true) }
    static var installedURL: URL { installFolder.appendingPathComponent("kriya") }

    /// Whether the folder is on the PATH a shell starts with, so “kriya” works without typing where it is.
    static func isOnPath(_ folder: URL, path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> Bool {
        path.split(separator: ":").contains { String($0) == folder.path }
    }

    /// Links the tool into ~/.local/bin. A link, not a copy, so an update of Kriya updates it. Returns a problem, or nil.
    @discardableResult
    static func install(source: URL? = bundled, into folder: URL = installFolder) -> String? {
        guard let source, FileManager.default.isExecutableFile(atPath: source.path) else { return "The tool is not inside this copy of Kriya." }
        let target = folder.appendingPathComponent("kriya")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Only something Kriya made is replaced: an existing program with that name is someone else's.
            if let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) {
                guard existing.hasSuffix("/CLI/kriya") else { return "There is already a different “kriya” in \(folder.path)." }
                try FileManager.default.removeItem(at: target)
            } else if FileManager.default.fileExists(atPath: target.path) {
                return "There is already a different “kriya” in \(folder.path)."
            }
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
            return nil
        } catch {
            return "It could not be installed: \(error.localizedDescription)"
        }
    }

    static func uninstall(from folder: URL = installFolder) {
        let target = folder.appendingPathComponent("kriya")
        if let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path), existing.hasSuffix("/CLI/kriya") {
            try? FileManager.default.removeItem(at: target)
        }
    }

    static func isInstalled(in folder: URL = installFolder) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("kriya").path))?.hasSuffix("/CLI/kriya") == true
    }
}
