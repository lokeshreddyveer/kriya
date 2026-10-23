import Foundation

/// A page a browser extension read for the person: its title, address and main text as Markdown.
struct PageClip: Codable, Equatable {
    var title: String
    var url: String
    var site: String
    var byline: String
    var markdown: String
    var truncated: Bool
    /// The page was in a private or incognito window. Such a page is never given to an AI.
    var isPrivate: Bool? = nil
}

enum PageAction: String, CaseIterable {
    /// Save as a Markdown file.
    case markdown
    /// Copy the Markdown.
    case copy
    /// Save the Markdown file and put it on the shelf.
    case shelf
    /// Give the page's text to the AI provider chosen for browser pages, and show a summary. Asks permission for the site first.
    case summarize
    /// The same, with a question typed in.
    case ask
    /// Save as a PDF.
    case pdf
}

enum PageCapture {
    static let maxMarkdownBytes = 1_600_000
    /// A message with a whole page in it, as the native host may receive it.
    static let maxMessageBytes = 2_000_000

    /// Checks a "page" message from a browser and makes a clip. The title and text are cut to sensible sizes.
    static func clip(from message: [String: Any]) -> Result<(clip: PageClip, action: PageAction), BridgeError> {
        guard let raw = message["as"] as? String, let action = PageAction(rawValue: raw) else { return .failure(.invalid("Kriya does not know what to do with that page.")) }
        guard let markdown = message["markdown"] as? String, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.invalid("There was no text to save from that page."))
        }
        guard markdown.utf8.count <= maxMarkdownBytes else { return .failure(.invalid("That page is too big.")) }
        guard let url = BridgeProtocol.webURL(message["url"]) else { return .failure(.invalid("That is not a web page Kriya can save.")) }
        let title = BridgeProtocol.clipped(message["title"], BridgeProtocol.maxTitleLength) ?? url.host ?? "Page"
        let clip = PageClip(
            title: title, url: url.absoluteString, site: BridgeProtocol.clipped(message["site"], 100) ?? "", byline: BridgeProtocol.clipped(message["byline"], 100) ?? "",
            markdown: markdown, truncated: message["truncated"] as? Bool ?? false, isPrivate: message["private"] as? Bool
        )
        return .success((clip, action))
    }

    /// A name for the file a page is waiting in until the app takes it: `page-` and 32 letters and digits, `.json`.
    static func inboxName() -> String { "page-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".json" }

    static func isInboxName(_ name: String) -> Bool {
        name.range(of: #"^page-[0-9a-f]{32}\.json$"#, options: .regularExpression) != nil
    }

    /// A safe file name from a page title: no slashes or colons, no leading dot, not too long.
    static func fileStem(for title: String) -> String {
        var cleaned = title.map { "/\\:*?\"<>|\0".contains($0) || $0.isNewline ? Character("-") : $0 }.map(String.init).joined()
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        cleaned = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Page" : cleaned
    }

    /// The Markdown file's text: a title, where it came from, then the page.
    static func document(for clip: PageClip) -> String {
        var head = "# \(clip.title)\n\n"
        var source: [String] = []
        if !clip.byline.isEmpty { source.append("By \(clip.byline)") }
        if !clip.site.isEmpty { source.append(clip.site) }
        source.append("<\(clip.url)>")
        head += source.joined(separator: " · ") + "\n\n---\n\n"
        // The page's own first heading repeats the title; leave it out.
        var body = clip.markdown
        if let first = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first, first.hasPrefix("# "), first.dropFirst(2).trimmingCharacters(in: .whitespaces) == clip.title {
            body = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
        }
        return head + body.trimmingCharacters(in: .whitespacesAndNewlines) + (clip.truncated ? "\n\n*(The page was longer; this is the first part.)*" : "") + "\n"
    }
}

/// A small Markdown reader for what the extension writes: headings, paragraphs, lists (nested), quotes, code, rules, tables,
/// links, emphasis. It makes plain HTML with no scripts and nothing that loads from the web.
enum PageMarkdown {
    static func html(_ markdown: String, title: String) -> String {
        var out: [String] = []
        var paragraph: [String] = []
        var lists: [(tag: String, depth: Int)] = []
        var quote: [String] = []
        var table: [String] = []
        var code: [String]?

        func flushParagraph() { if !paragraph.isEmpty { out.append("<p>\(inline(paragraph.joined(separator: " ")))</p>"); paragraph = [] } }
        func closeLists(to depth: Int = -1) {
            while let last = lists.last, last.depth > depth { out.append("</li></\(last.tag)>"); lists.removeLast() }
        }
        func flushQuote() { if !quote.isEmpty { out.append("<blockquote>\(quote.map { "<p>\(inline($0))</p>" }.joined())</blockquote>"); quote = [] } }
        func flushTable() {
            guard !table.isEmpty else { return }
            var rows = table.map { line in line.trimmingCharacters(in: CharacterSet(charactersIn: "| ")).components(separatedBy: " | ") }
            if rows.count > 1, rows[1].allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { rows.remove(at: 1) }
            let cells = rows.enumerated().map { index, row in "<tr>" + row.map { "<\(index == 0 ? "th" : "td")>\(inline($0.replacingOccurrences(of: "\\|", with: "|")))</\(index == 0 ? "th" : "td")>" }.joined() + "</tr>" }
            out.append("<table>\(cells.joined())</table>")
            table = []
        }
        func flushAll() { flushParagraph(); closeLists(); flushQuote(); flushTable() }

        for raw in markdown.components(separatedBy: "\n") {
            if code != nil {
                if raw.hasPrefix("```") { out.append("<pre><code>\(escape(code!.joined(separator: "\n")))</code></pre>"); code = nil } else { code!.append(raw) }
                continue
            }
            if raw.hasPrefix("```") { flushAll(); code = []; continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushAll(); continue }
            if line == "---" || line == "***" { flushAll(); out.append("<hr>"); continue }
            if let level = headingLevel(line) {
                flushAll()
                out.append("<h\(level)>\(inline(String(line.dropFirst(level + 1))))</h\(level)>")
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph(); closeLists(); flushTable()
                quote.append(String(line.dropFirst().drop { $0 == " " }))
                continue
            }
            if line.hasPrefix("|") { flushParagraph(); closeLists(); flushQuote(); table.append(line); continue }
            if let item = listItem(raw) {
                flushParagraph(); flushQuote(); flushTable()
                if let last = lists.last, last.depth == item.depth, last.tag == item.tag { out.append("</li>") }
                else if let last = lists.last, last.depth > item.depth {
                    closeLists(to: item.depth)
                    if let again = lists.last, again.depth == item.depth, again.tag == item.tag { out.append("</li>") } else { out.append("<\(item.tag)>"); lists.append((item.tag, item.depth)) }
                } else if lists.last == nil || lists.last!.depth < item.depth {
                    out.append("<\(item.tag)>"); lists.append((item.tag, item.depth))
                }
                out.append("<li>\(inline(item.text))")
                continue
            }
            closeLists(); flushQuote(); flushTable()
            paragraph.append(line)
        }
        if let code { out.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>") }
        flushAll()
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        body { font-family: -apple-system, Helvetica, sans-serif; font-size: 13px; line-height: 1.5; color: #111; }
        h1 { font-size: 24px; } h2 { font-size: 19px; } h3 { font-size: 16px; } h4, h5, h6 { font-size: 14px; }
        pre { background: #f4f4f4; padding: 8px; font-family: Menlo, monospace; font-size: 11px; }
        code { font-family: Menlo, monospace; font-size: 12px; }
        blockquote { color: #555; margin-left: 16px; border-left: 3px solid #ccc; padding-left: 10px; }
        table { border-collapse: collapse; } td, th { border: 1px solid #ccc; padding: 3px 7px; }
        a { color: #0a58ca; }
        </style></head><body>\(out.joined(separator: "\n"))</body></html>
        """
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ raw: String) -> (tag: String, depth: Int, text: String)? {
        let spaces = raw.prefix { $0 == " " }.count
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return ("ul", spaces / 2, String(line.dropFirst(2))) }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3, line.dropFirst(digits.count).hasPrefix(". ") { return ("ol", spaces / 2, String(line.dropFirst(digits.count + 2))) }
        return nil
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Emphasis, code, links and images in a line. Images are not loaded: their description is shown instead.
    static func inline(_ text: String) -> String {
        var out = escape(text)
        func replace(_ pattern: String, _ template: String) {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        replace(#"`([^`]+)`"#, "<code>$1</code>")
        replace(#"!\[([^\]]*)\]\([^)]*\)"#, "<em>[image: $1]</em>")
        // Only web addresses become links.
        replace(#"\[([^\]]+)\]\((https?://[^)\s]+)\)"#, #"<a href="$2">$1</a>"#)
        replace(#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>")
        replace(#"(?<![\w*])\*([^*\n]+)\*(?![\w*])"#, "<em>$1</em>")
        return out
    }
}
