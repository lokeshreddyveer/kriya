import CoreGraphics
import Foundation

/// One word the text reader found, with where it sits in the picture (0 to 1, from the top left).
struct RecognizedWord: Equatable {
    let text: String
    let box: CGRect
}

struct RecognizedLine: Equatable {
    let words: [RecognizedWord]
    var text: String { words.map(\.text).joined(separator: " ") }
}

/// Finding text in a picture that should not be shared, and where it is. Nothing here sees the picture: it works from the
/// words the text reader found.
enum Redaction {
    struct Options: Equatable {
        var emails = true
        var phones = true
        var addresses = true
        var cards = true
        var tokens = true
        /// Words or names the person wants hidden wherever they appear.
        var extraWords: [String] = []
    }

    /// The parts of `text` that look private, as ranges.
    static func sensitiveRanges(in text: String, options: Options = Options()) -> [NSRange] {
        var found: [NSRange] = []
        let whole = NSRange(text.startIndex..., in: text)

        func collect(_ pattern: String, options regexOptions: NSRegularExpression.Options = [], check: ((String) -> Bool)? = nil) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else { return }
            regex.enumerateMatches(in: text, range: whole) { match, _, _ in
                guard let match, let range = Range(match.range, in: text) else { return }
                if check?(String(text[range])) ?? true { found.append(match.range) }
            }
        }

        if options.emails { collect(#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: .caseInsensitive) }
        if options.addresses { collect(#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#) { ipv4($0) } }
        if options.cards { collect(#"\b\d(?:[ \-]?\d){12,18}\b"#) { luhn(digits(of: $0)) } }
        if options.phones {
            collect(#"(?<![\w])\+?\d[\d\s().\-]{6,}\d(?![\w])"#) { candidate in
                let count = digits(of: candidate).count
                return (8...15).contains(count) && !luhn(digits(of: candidate)) && !isDate(candidate) && !isDottedNumber(candidate)
            }
        }
        if options.tokens {
            // A word that looks like a key or token: judged by the same rules as the clipboard's secret detection.
            var searchStart = text.startIndex
            for word in text.split(whereSeparator: \.isWhitespace) {
                guard let range = text.range(of: word, range: searchStart..<text.endIndex) else { continue }
                searchStart = range.upperBound
                // Judged by the clipboard's rules, and by the shapes of known keys (AWS, GitHub, Slack, Stripe, JWT, card numbers).
                if (word.count >= 16 && clipLooksSensitive(text: String(word))) || (word.count >= 8 && ClipSecrets.classify(String(word)) != nil) { found.append(NSRange(range, in: text)) }
            }
        }
        for extra in options.extraWords.map({ $0.trimmingCharacters(in: .whitespaces) }) where extra.count >= 2 {
            collect(NSRegularExpression.escapedPattern(for: extra), options: .caseInsensitive)
        }
        return merged(found)
    }

    /// The same place found by two rules is one place, and a place inside a bigger one is part of it.
    static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var kept: [NSRange] = []
        for range in ranges.sorted(by: { $0.location != $1.location ? $0.location < $1.location : $0.length > $1.length }) {
            if let last = kept.last, NSIntersectionRange(last, range).length == range.length { continue }
            kept.append(range)
        }
        return kept
    }

    /// The boxes to cover, from the words found in a picture. Several matches on one line are covered separately.
    static func plan(_ lines: [RecognizedLine], options: Options = Options(), padding: CGFloat = 0.004) -> [CGRect] {
        var boxes: [CGRect] = []
        for line in lines where !line.words.isEmpty {
            // The line is rebuilt from its words, so a match's place in the text maps back to the words that make it up.
            var text = ""
            var spans: [(NSRange, CGRect)] = []
            for word in line.words {
                if !text.isEmpty { text += " " }
                let start = (text as NSString).length
                text += word.text
                spans.append((NSRange(location: start, length: (word.text as NSString).length), word.box))
            }
            for range in sensitiveRanges(in: text, options: options) {
                let covered = spans.filter { NSIntersectionRange($0.0, range).length > 0 }.map(\.1)
                guard var box = covered.first else { continue }
                for other in covered.dropFirst() { box = box.union(other) }
                boxes.append(box.insetBy(dx: -padding, dy: -padding).intersection(CGRect(x: 0, y: 0, width: 1, height: 1)))
            }
        }
        return boxes
    }

    // MARK: Checks

    static func digits(of text: String) -> [Int] { text.compactMap { $0.wholeNumberValue } }

    /// Whether a run of digits passes the check card numbers pass.
    static func luhn(_ digits: [Int]) -> Bool {
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    /// A date such as 2026-10-22 has digits and dashes but is not a phone number.
    static func isDate(_ text: String) -> Bool {
        text.range(of: #"^\d{4}[-./]\d{1,2}[-./]\d{1,2}$|^\d{1,2}[-./]\d{1,2}[-./]\d{2,4}$"#, options: .regularExpression) != nil
    }

    /// Numbers joined by dots, like a version or an address, are not phone numbers.
    static func isDottedNumber(_ text: String) -> Bool {
        text.range(of: #"^\d+(\.\d+){2,}$"#, options: .regularExpression) != nil
    }

    static func ipv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } == true }
    }
}
