import Foundation

/// Matching what a person typed against a name, loosely: letters in order (not all together), the start of each word, and a
/// short form such as "vsc" for "Visual Studio Code". Higher is better; nil means no match.
enum FuzzyMatcher {
    static func score(_ query: String, in text: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let t = Array(text.lowercased())
        // Lower-casing can change the length for a few letters; then capitals simply are not used as hints.
        let original = Array(text).count == t.count ? Array(text) : t
        guard q.count <= t.count else { return nil }

        // The whole text, or the start of it, or of a word, is the best kind of match.
        let lowered = String(t)
        let phrase = String(q)
        if lowered == phrase { return 1000 }
        if lowered.hasPrefix(phrase) { return 900 - min(t.count - q.count, 100) }
        if let range = lowered.range(of: phrase) {
            let offset = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
            let atWordStart = offset == 0 || !t[offset - 1].isLetter && !t[offset - 1].isNumber
            return (atWordStart ? 800 : 600) - min(offset, 100)
        }

        // Letters in order, rewarding runs, word starts and capital letters, and charging for gaps.
        var score = 0
        var position = 0
        var previous = -2
        var firstMatch = -1
        var wordStarts = 0
        for char in q {
            var found = -1
            var i = position
            while i < t.count {
                if t[i] == char { found = i; break }
                i += 1
            }
            guard found >= 0 else { return nil }
            if firstMatch < 0 { firstMatch = found }
            var gain = 10
            if found == previous + 1 { gain += 15 }
            let startsWord = found == 0 || !t[found - 1].isLetter && !t[found - 1].isNumber
            if startsWord { gain += 20; wordStarts += 1 }
            else if original[found].isUppercase, found > 0, original[found - 1].isLowercase { gain += 12 }
            gain -= min(found - position, 6)
            score += gain
            previous = found
            position = found + 1
        }
        // Letters spread across the whole name are no match, unless most of them start words ("vsc" for Visual Studio Code).
        let span = previous - firstMatch + 1
        let tightness = q.count * 100 / max(span, 1)
        let acronym = wordStarts * 100 >= q.count * 60
        guard score > 0, tightness >= 40 || acronym else { return nil }
        return min(500, score + tightness / 4 - firstMatch)
    }

    /// The best score of the query against any of the texts, with the first text counting for a little more.
    static func best(_ query: String, in texts: [String]) -> Int? {
        var best: Int?
        for (index, text) in texts.enumerated() {
            guard let score = score(query, in: text) else { continue }
            let adjusted = index == 0 ? score + 5 : score
            if adjusted > (best ?? Int.min) { best = adjusted }
        }
        return best
    }
}
