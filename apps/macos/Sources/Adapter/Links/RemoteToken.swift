import Foundation

/// What state the access token for remote commands is in.
enum RemoteTokenState: Equatable {
    /// Never made on this Mac.
    case neverCreated
    /// Taken back on purpose. Nothing authenticates until a new one is created.
    case revoked
    case active(String)

    var token: String? { if case .active(let t) = self { return t } else { return nil } }
}

/// The secret that remote commands carry, kept in a file only this account can read. It is its own secret, not the browser
/// extensions' one, so replacing it never disconnects the extensions.
struct RemoteTokenStore {
    let support: URL

    init(support: URL) { self.support = support }

    var fileURL: URL { support.appendingPathComponent("remote-commands-token") }
    /// A note for the command-line tool, so it can say that remote commands are off instead of asking and getting nothing.
    var stateURL: URL { support.appendingPathComponent("remote-commands-state") }

    var state: RemoteTokenState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .neverCreated }
        let text = ((try? String(contentsOf: fileURL, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty file is the mark of a revoked token; one that is anything else but a whole token is treated the same, not as open.
        return text.count == 64 ? .active(text) : .revoked
    }

    /// The token requests are checked against right now, or nil if there is none.
    var current: String? { state.token }

    /// The token to use for links and the command-line tool, or nil once it was revoked. The first time on a Mac that had links before
    /// this existed, it takes over the secret they carry, so they keep working; otherwise it makes a new one.
    @discardableResult
    func tokenForUse() -> String? {
        switch state {
        case .active(let token):
            PrivateFile.ensurePrivate(fileURL)
            return token
        case .revoked:
            return nil
        case .neverCreated:
            let token = BridgeToken.read(in: support) ?? Self.newToken()
            return PrivateFile.write(Data(token.utf8), to: fileURL) ? token : nil
        }
    }

    /// A new token. Every link and script that carried the old one stops working at once.
    @discardableResult
    func rotate() -> String? {
        let token = Self.newToken()
        return PrivateFile.write(Data(token.utf8), to: fileURL) ? token : nil
    }

    /// Takes the token back without making another: every link and script stops working, and stays that way until a new one is created.
    @discardableResult
    func revoke() -> Bool { PrivateFile.write(Data(), to: fileURL) }

    /// Writes whether remote commands are on, where the command-line tool can read it.
    func writeState(enabled: Bool) {
        PrivateFile.write(Data((enabled ? "enabled\n" : "disabled\n").utf8), to: stateURL)
    }

    static func newToken() -> String {
        PrivateFile.randomHex() ?? (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }
}
