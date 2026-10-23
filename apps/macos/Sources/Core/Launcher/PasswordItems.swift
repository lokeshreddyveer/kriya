import Foundation

/// An entry in the password manager, as much as the launcher needs to find it: never the password itself.
struct PasswordItem: Equatable, Identifiable {
    let id: String
    let title: String
    let vault: String
    let username: String
    let urls: [String]
}

enum PasswordItems {
    /// 1Password item identifiers are short runs of letters and digits; anything else is not passed to the command line.
    static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9]{12,40}$"#, options: .regularExpression) != nil
    }

    /// The items in `op item list --format json`. Entries without a usable identifier are dropped.
    static func parse(_ data: Data) -> [PasswordItem] {
        guard data.count < 8_000_000, let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = item["id"] as? String, isValidID(id), let title = item["title"] as? String, !title.isEmpty else { return nil }
            let vault = ((item["vault"] as? [String: Any])?["name"] as? String) ?? ""
            let urls = (item["urls"] as? [[String: Any]])?.compactMap { $0["href"] as? String }.filter { $0.hasPrefix("https://") || $0.hasPrefix("http://") } ?? []
            return PasswordItem(id: id, title: String(title.prefix(120)), vault: vault, username: (item["additional_information"] as? String) ?? "", urls: urls)
        }
    }

    /// Items whose title, user name or address contain every word typed, best matches (title starts with the word) first.
    static func search(_ query: String, in items: [PasswordItem], limit: Int = 6) -> [PasswordItem] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let found = items.filter { item in
            let haystack = ([item.title, item.username] + item.urls).joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        return Array(found.sorted { a, b in
            let aStarts = a.title.lowercased().hasPrefix(words[0]), bStarts = b.title.lowercased().hasPrefix(words[0])
            return aStarts != bStarts ? aStarts : a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }.prefix(limit))
    }

    /// The arguments that read one field of an item. `field` is one of the fixed names, never text from outside.
    enum Field: String {
        case password, username
        case otp
    }

    static func arguments(for field: Field, id: String) -> [String]? {
        guard isValidID(id) else { return nil }
        switch field {
        case .password: return ["item", "get", id, "--fields", "label=password", "--reveal"]
        case .username: return ["item", "get", id, "--fields", "label=username"]
        case .otp: return ["item", "get", id, "--otp"]
        }
    }
}

/// When a copied secret should be taken off the clipboard again: only if nothing else has been copied since.
enum SecretClipboard {
    static let seconds: TimeInterval = 30

    static func shouldClear(changeCountAtCopy: Int, now changeCount: Int) -> Bool { changeCount == changeCountAtCopy }
}
