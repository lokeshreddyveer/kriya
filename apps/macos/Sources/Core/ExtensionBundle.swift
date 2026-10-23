import CryptoKit
import Foundation

/// What an extension may be allowed to do. These are promises the person approves; Kriya applies the ones it can (a command that
/// says it uses the network does not run in Local Only mode, and only a command that says it reads the clipboard is given it).
enum ExtensionPermission: String, Codable, CaseIterable, Identifiable {
    case clipboard, network
    var id: String { rawValue }
    var title: String { self == .clipboard ? "Read the clipboard" : "Use the network" }
    var detail: String {
        switch self {
        case .clipboard: return "Its commands are given the text on the clipboard when they run."
        case .network: return "Its commands may contact the internet. They do not run while Local Only is on."
        }
    }
}

struct ExtensionCommand: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    /// A file inside the bundle, by relative path.
    var script: String
    var arguments: [String]?
    var symbol: String?
}

/// The description of an extension bundle: a folder with this file as `manifest.json`, and the scripts it names. The file list
/// holds the SHA-256 of every file, and the whole description is signed by the publisher's key, so a bundle that was changed
/// after signing, or has a file added, is refused.
struct ExtensionManifest: Codable, Equatable {
    var id: String
    var name: String
    var version: String
    var author: String
    var summary: String?
    /// The publisher's Ed25519 public key, base64.
    var publisherKey: String
    var permissions: [ExtensionPermission]
    var commands: [ExtensionCommand]
    /// Relative path to SHA-256 (hex), for every file in the bundle except `manifest.json`.
    var files: [String: String]
    var signature: String?

    /// The bytes that are signed: the manifest without its signature, in a fixed order.
    func signingBytes() throws -> Data {
        var copy = self
        copy.signature = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(copy)
    }
}

enum ExtensionProblem: Error, Equatable, LocalizedError {
    case unreadable
    case invalid(String)
    case notSigned
    case badSignature
    case fileChanged(String)
    case fileMissing(String)
    case unlistedFile(String)
    case sameIDDifferentPublisher
    case olderVersion(installed: String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "That folder has no readable manifest.json."
        case .invalid(let why): return "The manifest is not valid: \(why)"
        case .notSigned: return "This extension is not signed."
        case .badSignature: return "The signature does not match. The extension was changed after it was signed, or the key is not the publisher's."
        case .fileChanged(let name): return "“\(name)” is not the file that was signed."
        case .fileMissing(let name): return "“\(name)” is listed but missing."
        case .unlistedFile(let name): return "“\(name)” is in the folder but not in the signed list."
        case .sameIDDifferentPublisher: return "An extension with this id is already installed from a different publisher."
        case .olderVersion(let v): return "Version \(v) is already installed, and this one is not newer."
        }
    }
}

enum ExtensionBundle {
    static let maxFiles = 200
    static let maxCommands = 30
    static let maxFileBytes = 5_000_000

    static func isValidID(_ id: String) -> Bool { id.range(of: #"^[a-z0-9][a-z0-9.-]{2,60}$"#, options: .regularExpression) != nil }
    static func isValidVersion(_ v: String) -> Bool { v.range(of: #"^\d{1,4}(\.\d{1,4}){0,2}$"#, options: .regularExpression) != nil }

    /// A path inside the bundle: relative, no `..`, no hidden parts, no odd characters.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 200, !path.hasPrefix("/"), path != "manifest.json" else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." && !$0.hasPrefix(".") && $0.range(of: #"^[A-Za-z0-9 _.\-+@()]+$"#, options: .regularExpression) != nil }
    }

    /// Whatever is wrong with the shape of a manifest, in words. Empty when it is fine.
    static func shapeProblems(_ m: ExtensionManifest) -> [String] {
        var out: [String] = []
        if !isValidID(m.id) { out.append("the id must be lower-case letters, digits, dots or dashes (3 to 61 characters)") }
        if m.name.trimmingCharacters(in: .whitespaces).isEmpty || m.name.count > 80 { out.append("the name is empty or too long") }
        if !isValidVersion(m.version) { out.append("the version must look like 1.2.3") }
        if m.commands.isEmpty || m.commands.count > maxCommands { out.append("it needs between 1 and \(maxCommands) commands") }
        if m.files.count > maxFiles { out.append("it lists too many files") }
        if Set(m.commands.map(\.id)).count != m.commands.count { out.append("two commands share an id") }
        for command in m.commands {
            if !isValidID("x." + command.id) || command.id.contains(" ") { out.append("command id “\(command.id)” is not valid") }
            if command.title.trimmingCharacters(in: .whitespaces).isEmpty { out.append("a command has no title") }
            if !isSafeRelativePath(command.script) { out.append("script path “\(command.script)” is not allowed") }
            else if m.files[command.script] == nil { out.append("script “\(command.script)” is not in the file list") }
        }
        for (path, hash) in m.files {
            if !isSafeRelativePath(path) { out.append("file path “\(path)” is not allowed") }
            if hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) == nil { out.append("the hash for “\(path)” is not a SHA-256") }
        }
        if Data(base64Encoded: m.publisherKey)?.count != 32 { out.append("the publisher key is not an Ed25519 public key") }
        return out
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// A short, readable fingerprint of a publisher's key, for the person to compare: "A1B2 C3D4 E5F6 0718".
    static func fingerprint(ofKey base64: String) -> String {
        guard let data = Data(base64Encoded: base64) else { return "?" }
        let hex = hash(data).uppercased().prefix(16)
        return stride(from: 0, to: hex.count, by: 4).map { i in String(hex.dropFirst(i).prefix(4)) }.joined(separator: " ")
    }

    /// Checks a bundle. `listing` is every file in the folder (relative paths, `manifest.json` left out) and `read` gives a file's bytes.
    static func verify(_ m: ExtensionManifest, listing: [String], read: (String) -> Data?) throws {
        if let first = shapeProblems(m).first { throw ExtensionProblem.invalid(first) }
        guard let signature = m.signature, let signatureData = Data(base64Encoded: signature) else { throw ExtensionProblem.notSigned }
        guard let keyData = Data(base64Encoded: m.publisherKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let bytes = try? m.signingBytes(), key.isValidSignature(signatureData, for: bytes) else { throw ExtensionProblem.badSignature }
        for path in listing.sorted() where m.files[path] == nil { throw ExtensionProblem.unlistedFile(path) }
        for (path, expected) in m.files.sorted(by: { $0.key < $1.key }) {
            guard let data = read(path) else { throw ExtensionProblem.fileMissing(path) }
            guard data.count <= maxFileBytes, hash(data) == expected else { throw ExtensionProblem.fileChanged(path) }
        }
    }

    /// Fills in the file list and the key, and signs. For a publisher preparing a bundle.
    static func sign(_ draft: ExtensionManifest, files: [String: Data], with key: Curve25519.Signing.PrivateKey) throws -> ExtensionManifest {
        var m = draft
        m.publisherKey = key.publicKey.rawRepresentation.base64EncodedString()
        m.files = files.mapValues(hash)
        m.signature = nil
        if let first = shapeProblems(m).first { throw ExtensionProblem.invalid(first) }
        m.signature = try key.signature(for: m.signingBytes()).base64EncodedString()
        return m
    }

    /// Positive when `a` is newer than `b`.
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q ? 1 : -1 }
        }
        return 0
    }

    /// Whether `new` may replace `installed`: the same publisher and a newer version.
    static func checkUpdate(new: ExtensionManifest, installed: ExtensionManifest?) throws {
        guard let installed else { return }
        guard installed.publisherKey == new.publisherKey else { throw ExtensionProblem.sameIDDifferentPublisher }
        guard compareVersions(new.version, installed.version) > 0 else { throw ExtensionProblem.olderVersion(installed: installed.version) }
    }

    /// The interpreter for a script, by its file name; nil means it is run directly and must be executable.
    static func interpreter(for script: String) -> (path: String, leading: [String])? {
        switch (script as NSString).pathExtension.lowercased() {
        case "sh", "bash": return ("/bin/bash", [])
        case "zsh": return ("/bin/zsh", [])
        case "py": return ("/usr/bin/python3", [])
        case "js": return ("/usr/bin/osascript", ["-l", "JavaScript"])
        case "scpt", "applescript": return ("/usr/bin/osascript", [])
        default: return nil
        }
    }
}
