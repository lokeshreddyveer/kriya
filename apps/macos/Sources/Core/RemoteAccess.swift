import Foundation

/// Whether other programs may ask Kriya to do things: a `kriya://` link, the command-line tool, a Shortcuts action, or the local web
/// address. One switch for all of them. It is on unless turned off, so scripts people already have keep working.
enum RemoteAccess {
    /// The preference. Kept as a grant of trust: a backup never switches it on.
    static let enabledKey = "remoteCommandsEnabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: enabledKey) as? Bool ?? true }

    static func setEnabled(_ on: Bool, defaults: UserDefaults = .standard) { defaults.set(on, forKey: enabledKey) }

    static let disabledMessage = "Remote commands are turned off in Kriya, so this was not run. Turn them on in Kriya's settings, under Control from outside."
    static let noTokenMessage = "Kriya's access token was revoked, so this was not run. Create a new one in Kriya's settings, under Control from outside."
    static let unauthorizedMessage = "The access token was not right, so this was not run. Copy the link or command again from Kriya's settings."
    static let invalidMessage = "That request was not understood, so nothing was run."
}

/// Why a request from outside was turned away.
enum RemoteRefusal: Error, Equatable {
    /// Not a `kriya://` request for commands at all; left to whoever handles it.
    case notOurs
    case disabled
    case noToken
    case unauthorized
    case invalid

    /// What to tell whoever asked (and the person at the Mac), or nil when it was never a request for Kriya.
    var message: String? {
        switch self {
        case .notOurs: return nil
        case .disabled: return RemoteAccess.disabledMessage
        case .noToken: return RemoteAccess.noTokenMessage
        case .unauthorized: return RemoteAccess.unauthorizedMessage
        case .invalid: return RemoteAccess.invalidMessage
        }
    }
}

extension RemoteCommand {
    /// Whether this address is one of the `kriya://` requests for commands (run, action, workflow, launcher).
    static func isOurs(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "kriya" && url.host.map { hosts.contains($0.lowercased()) } == true
    }

    /// Reads an address with the switch and the secret in view. A request is turned away, with the reason, when remote commands are off
    /// (whatever the secret says), when there is no token because it was revoked, or when the secret is wrong.
    static func authorize(_ url: URL, enabled: Bool, token: String?) -> Result<RemoteCommand, RemoteRefusal> {
        guard isOurs(url) else { return .failure(.notOurs) }
        guard enabled else { return .failure(.disabled) }
        guard let token, !token.isEmpty else { return .failure(.noToken) }
        switch parse(url, token: token) {
        case .success(let command): return .success(command)
        case .failure(.notOurs): return .failure(.notOurs)
        case .failure(.unauthorized): return .failure(.unauthorized)
        case .failure(.invalid): return .failure(.invalid)
        }
    }
}

/// The body sent back to a program that was turned away, as JSON.
enum RemoteRefusalBody {
    static func json(_ refusal: RemoteRefusal) -> String {
        let message = (refusal.message ?? "").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"ok\":false,\"error\":\"\(message)\"}"
    }
}
