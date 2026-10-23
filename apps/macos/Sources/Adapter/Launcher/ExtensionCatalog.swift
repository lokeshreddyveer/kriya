import AppKit
import CryptoKit

/// The extensions installed on this Mac: signed bundles copied into Kriya's folder, switched off until the person turns them on.
final class ExtensionCatalog: ObservableObject {
    static let shared = ExtensionCatalog()
    private static let enabledKey = "extensions.enabled.v1"
    private static let trustedKey = "extensions.trusted.v1"
    private static let signingAccount = "extension-signing-key"

    struct Installed: Identifiable, Equatable {
        var manifest: ExtensionManifest
        var enabled: Bool
        var id: String { manifest.id }
    }

    struct Candidate {
        let manifest: ExtensionManifest
        let folder: URL
        let fingerprint: String
        let publisherTrusted: Bool
        let installedVersion: String?
    }

    @Published private(set) var installed: [Installed] = []
    /// Fingerprint to the name the publisher gave.
    @Published private(set) var trusted: [String: String]
    @Published private(set) var lastProblem: String?

    var root: URL = AppPaths.live.support.appendingPathComponent("Extensions", isDirectory: true)

    private init() {
        trusted = UserDefaults.standard.dictionary(forKey: Self.trustedKey) as? [String: String] ?? [:]
        reload()
    }

    func reload() {
        let enabled = Set(UserDefaults.standard.stringArray(forKey: Self.enabledKey) ?? [])
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        installed = folders.compactMap { folder in
            guard let m = Self.readManifest(in: folder), m.id == folder.lastPathComponent else { return nil }
            return Installed(manifest: m, enabled: enabled.contains(m.id))
        }.sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
    }

    static func readManifest(in folder: URL) -> ExtensionManifest? {
        (try? Data(contentsOf: folder.appendingPathComponent("manifest.json"))).flatMap { try? JSONDecoder().decode(ExtensionManifest.self, from: $0) }
    }

    /// Every file in a folder, as relative paths, without `manifest.json`. Links are not followed and count as unlisted.
    static func listing(of folder: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return [] }
        var out: [String] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isRegularFile == true || values?.isSymbolicLink == true {
                let relative = String(url.path.dropFirst(folder.path.count + 1))
                if relative != "manifest.json" { out.append(relative) }
            }
        }
        return out
    }

    // MARK: Installing

    func inspect(_ folder: URL) throws -> Candidate {
        guard let manifest = Self.readManifest(in: folder) else { throw ExtensionProblem.unreadable }
        try ExtensionBundle.verify(manifest, listing: Self.listing(of: folder)) { try? Data(contentsOf: folder.appendingPathComponent($0)) }
        let existing = installed.first { $0.id == manifest.id }?.manifest
        try ExtensionBundle.checkUpdate(new: manifest, installed: existing)
        let fingerprint = ExtensionBundle.fingerprint(ofKey: manifest.publisherKey)
        return Candidate(manifest: manifest, folder: folder, fingerprint: fingerprint, publisherTrusted: trusted[fingerprint] != nil, installedVersion: existing?.version)
    }

    /// Copies only the files the signed list names, then switches the extension off until the person turns it on.
    func install(_ candidate: Candidate) throws {
        let fm = FileManager.default
        let target = root.appendingPathComponent(candidate.manifest.id, isDirectory: true)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            for path in candidate.manifest.files.keys {
                let destination = staging.appendingPathComponent(path)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: candidate.folder.appendingPathComponent(path), to: destination)
            }
            try fm.copyItem(at: candidate.folder.appendingPathComponent("manifest.json"), to: staging.appendingPathComponent("manifest.json"))
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: staging, to: target)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        setEnabledStored(candidate.manifest.id, false)
        AuditLog.shared.record(.setting, "Installed extension “\(candidate.manifest.name)” \(candidate.manifest.version)")
        reload()
    }

    func trust(fingerprint: String, name: String) {
        trusted[fingerprint] = name
        UserDefaults.standard.set(trusted, forKey: Self.trustedKey)
    }

    func untrust(_ fingerprint: String) {
        trusted[fingerprint] = nil
        UserDefaults.standard.set(trusted, forKey: Self.trustedKey)
    }

    func setEnabled(_ id: String, _ on: Bool) {
        setEnabledStored(id, on)
        reload()
    }

    private func setEnabledStored(_ id: String, _ on: Bool) {
        var set = Set(UserDefaults.standard.stringArray(forKey: Self.enabledKey) ?? [])
        if on { set.insert(id) } else { set.remove(id) }
        UserDefaults.standard.set(Array(set).sorted(), forKey: Self.enabledKey)
    }

    func uninstall(_ id: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id, isDirectory: true))
        setEnabledStored(id, false)
        AuditLog.shared.record(.setting, "Removed extension \(id)")
        reload()
    }

    // MARK: Running

    /// Checks the installed files again, so one changed on disk since install is not run.
    func recheck(_ ext: Installed) throws {
        let folder = root.appendingPathComponent(ext.id, isDirectory: true)
        try ExtensionBundle.verify(ext.manifest, listing: Self.listing(of: folder)) { try? Data(contentsOf: folder.appendingPathComponent($0)) }
    }

    func run(_ command: ExtensionCommand, of ext: Installed) {
        let toast = Toast()
        guard ext.enabled else { toast.show("“\(ext.manifest.name)” is switched off.", isError: true); return }
        if ext.manifest.permissions.contains(.network), LocalOnly.isOn { toast.show(LocalOnly.blockedMessage, isError: true); return }
        do { try recheck(ext) } catch { toast.show("“\(ext.manifest.name)” was changed on disk and was not run: \(error.localizedDescription)", isError: true); return }
        let folder = root.appendingPathComponent(ext.id, isDirectory: true)
        let script = folder.appendingPathComponent(command.script)
        let content = "\(ext.id) \(ext.manifest.version) \(command.id) \(ext.manifest.files[command.script] ?? "")"
        let permissions = ext.manifest.permissions.map(\.title).joined(separator: ", ")
        guard LauncherApprovals.shared.ensureApproved(kind: "extension", label: "\(ext.manifest.name): \(command.title)", content: content,
                                                      detail: "Signed by \(ext.manifest.author) (\(ExtensionBundle.fingerprint(ofKey: ext.manifest.publisherKey))). It may: \(permissions.isEmpty ? "nothing beyond running" : permissions). It runs with your access to this Mac.") else { return }
        var environment = ["KRIYA_EXTENSION_ID": ext.id, "KRIYA_EXTENSION_DIR": folder.path]
        if ext.manifest.permissions.contains(.clipboard), let text = NSPasteboard.general.string(forType: .string) { environment["KRIYA_CLIPBOARD"] = String(text.prefix(100_000)) }
        let (exe, arguments): (String, [String]) = {
            let extra = command.arguments ?? []
            if let interpreter = ExtensionBundle.interpreter(for: command.script) { return (interpreter.path, interpreter.leading + [script.path] + extra) }
            return (script.path, extra)
        }()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let output = try ToolRunner.run(exe, arguments, in: folder, environment: environment, timeout: 60)
                DispatchQueue.main.async {
                    let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty { toast.show("\(command.title) finished") }
                    else if text.count < 120, !text.contains("\n") { toast.show(text) }
                    else { ScriptOutputWindow.show(title: command.title, text: text) }
                }
            } catch {
                DispatchQueue.main.async { toast.show("\(command.title) failed: \(error.localizedDescription)", isError: true) }
            }
        }
    }

    // MARK: Publishing

    /// The publisher's signing key, made once and kept in the Keychain.
    var hasSigningKey: Bool { KeychainSecrets.get(Self.signingAccount) != nil }

    func createSigningKey() -> Bool {
        let key = Curve25519.Signing.PrivateKey()
        return KeychainSecrets.set(key.rawRepresentation.base64EncodedString(), for: Self.signingAccount)
    }

    var signingFingerprint: String? {
        signingKey().map { ExtensionBundle.fingerprint(ofKey: $0.publicKey.rawRepresentation.base64EncodedString()) }
    }

    private func signingKey() -> Curve25519.Signing.PrivateKey? {
        KeychainSecrets.get(Self.signingAccount).flatMap { Data(base64Encoded: $0) }.flatMap { try? Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
    }

    /// Signs a folder that has a `manifest.json` with the commands filled in. The file list, the key and the signature are written.
    func sign(folder: URL) throws {
        guard let key = signingKey() else { throw ExtensionProblem.invalid("make a signing key first") }
        guard var draft = Self.readManifest(in: folder) ?? Self.readDraft(in: folder) else { throw ExtensionProblem.unreadable }
        var files: [String: Data] = [:]
        for path in Self.listing(of: folder) {
            guard ExtensionBundle.isSafeRelativePath(path), let data = try? Data(contentsOf: folder.appendingPathComponent(path)) else { throw ExtensionProblem.invalid("“\(path)” cannot be included") }
            files[path] = data
        }
        draft = try ExtensionBundle.sign(draft, files: files, with: key)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(draft).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    }

    /// A manifest being written by hand has no key, files or signature yet, so it cannot be read as a full one.
    private static func readDraft(in folder: URL) -> ExtensionManifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if object["publisherKey"] == nil { object["publisherKey"] = "" }
        if object["files"] == nil { object["files"] = [String: String]() }
        if object["permissions"] == nil { object["permissions"] = [String]() }
        object["signature"] = nil
        return (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? JSONDecoder().decode(ExtensionManifest.self, from: $0) }
    }
}
