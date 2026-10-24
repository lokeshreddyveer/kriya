import Foundation

/// Files that hold a secret (the MCP server's key, the browser extensions' key): written readable by this user only from the first
/// byte, checked after every write, and put right if something loosened them since.
enum PrivateFile {
    /// Writes `data` so that the file never exists with looser permissions than 0600. False if it could not be written or the
    /// permissions could not be made private.
    @discardableResult
    static func write(_ data: Data, to url: URL, fileManager: FileManager = .default) -> Bool {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            Log.info("Files", "Could not make the folder for a private file: \(error.localizedDescription)")
            return false
        }
        // A new file is created with 0600 already; an existing one is replaced, so it is removed first rather than kept with old modes.
        try? fileManager.removeItem(at: url)
        guard fileManager.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            Log.info("Files", "Could not write a private file.")
            return false
        }
        return ensurePrivate(url, fileManager: fileManager)
    }

    /// Makes sure the file is 0600 and says whether it is now. A file that is missing counts as not private.
    @discardableResult
    static func ensurePrivate(_ url: URL, fileManager: FileManager = .default) -> Bool {
        if isPrivate(url, fileManager: fileManager) == true { return true }
        guard fileManager.fileExists(atPath: url.path) else { return false }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let fixed = isPrivate(url, fileManager: fileManager) == true
        Log.info("Files", fixed ? "A private file had looser permissions; they were set again." : "A private file could not be made private.")
        return fixed
    }

    /// True if only the owner can read and write it, false if others can, nil if it cannot be read.
    static func isPrivate(_ url: URL, fileManager: FileManager = .default) -> Bool? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path), let mode = attributes[.posixPermissions] as? Int else { return nil }
        return mode & 0o077 == 0
    }

    /// A key of `byteCount` random bytes as hexadecimal text, from the system's secure generator. Nil if the system cannot supply one.
    static func randomHex(byteCount: Int = 32) -> String? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
