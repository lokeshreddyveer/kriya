import Foundation

/// What Kriya is built from, and under which licence each part comes. Kept next to the dependency lists in `Cargo.toml` and
/// `project.yml`. Keep them in step when a dependency is added.
enum Licenses {
    struct Item: Identifiable, Equatable {
        let name: String
        let license: String
        let purpose: String
        var id: String { name }
    }

    static let all: [Item] = [
        Item(name: "Sparkle", license: "MIT", purpose: "Updates"),
        Item(name: "rusqlite (with SQLite)", license: "MIT (SQLite is public domain)", purpose: "Storage"),
        Item(name: "UniFFI", license: "MPL-2.0", purpose: "Rust to Swift"),
        Item(name: "serde and serde_json", license: "MIT or Apache-2.0", purpose: "Reading and writing settings"),
        Item(name: "regex", license: "MIT or Apache-2.0", purpose: "Patterns"),
        Item(name: "url", license: "MIT or Apache-2.0", purpose: "Web addresses"),
        Item(name: "thiserror", license: "MIT or Apache-2.0", purpose: "Error messages"),
        Item(name: "sha2", license: "MIT or Apache-2.0", purpose: "Fingerprints"),
        Item(name: "aes-gcm", license: "MIT or Apache-2.0", purpose: "Encryption"),
        Item(name: "hmac", license: "MIT or Apache-2.0", purpose: "Message authentication"),
    ]

    /// The Rust crates the list covers, by crate name.
    static let rustCrates: Set<String> = ["rusqlite", "uniffi", "serde", "serde_json", "regex", "url", "thiserror", "sha2", "aes-gcm", "hmac"]

    /// Crate names that appear under `[dependencies]` in a Cargo.toml.
    static func dependencyNames(inCargo text: String) -> Set<String> {
        var inSection = false
        var names = Set<String>()
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSection = line == "[dependencies]"; continue }
            guard inSection, let eq = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            names.insert(line[..<eq].trimmingCharacters(in: .whitespaces))
        }
        return names
    }
}
