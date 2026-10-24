import Foundation

/// The web addresses a workspace opens. Only web pages: a workspace can come from a file someone else made, and an address like
/// `file:` or an app's own link scheme would run something instead of showing a page.
enum WorkspaceAddress {
    /// The address as a web link. A bare "example.com/page" gets https. Anything that is not a web page gives nil.
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// The lines of the editor split into addresses that will open and lines that will not.
    static func parse(_ lines: String) -> (valid: [String], rejected: [String]) {
        var valid: [String] = [], rejected: [String] = []
        for line in lines.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if let url = url(from: line) { valid.append(url.absoluteString) } else { rejected.append(line) }
        }
        return (valid, rejected)
    }
}
