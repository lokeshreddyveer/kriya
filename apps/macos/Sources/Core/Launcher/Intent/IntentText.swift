import Foundation

/// Plain-word helpers for reading a request: tidying the text, numbers said as words, durations, times of day and percentages.
/// Pure functions, no clock of their own (`now` and the calendar are passed in), so they can be tested exactly.
enum IntentText {
    // MARK: Tidying

    private static let leadingFillers = [
        "hey kriya ", "ok kriya ", "kriya ", "hey ", "please ", "can you ", "could you ", "would you ", "will you ", "can i ", "i want to ",
        "i'd like to ", "i would like to ", "i need to ", "i wanna ", "go ahead and ", "just ", "let's ", "lets ", "now ",
    ]
    private static let trailingFillers = [" please", " for me", " right now", " now", " thanks", " thank you", " pls"]

    /// Lower-case, single spaces, no polite padding ("could you please mute Spotify for me" → "mute spotify"), numbers as digits
    /// ("an hour" → "1 hour", "volume forty" → "volume 40"). The original text is kept by the caller for anything that is searched for.
    static func normalize(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        text = text.lowercased().replacingOccurrences(of: ",", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        while let last = text.last, ".!?,;".contains(last) { text.removeLast() }
        var changed = true
        while changed {
            changed = false
            for filler in leadingFillers where text.hasPrefix(filler) { text = String(text.dropFirst(filler.count)); changed = true }
            for filler in trailingFillers where text.hasSuffix(filler) { text = String(text.dropLast(filler.count)); changed = true }
        }
        return numbersAsDigits(text)
    }

    // MARK: Numbers said as words

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]

    /// "forty five" → "45", "twenty-five" → "25", "a hundred" → "100"; "an hour" → "1 hour", "half an hour" → "30 minutes".
    static func numbersAsDigits(_ text: String) -> String {
        var t = " " + text + " "
        let phrases: [(String, String)] = [
            (" an hour and a half ", " 90 minutes "), (" half an hour ", " 30 minutes "), (" half hour ", " 30 minutes "), (" half a minute ", " 30 seconds "),
            (" a quarter of an hour ", " 15 minutes "), (" quarter of an hour ", " 15 minutes "),
            (" an hour ", " 1 hour "), (" a hour ", " 1 hour "), (" a minute ", " 1 minute "), (" a second ", " 1 second "),
            (" a hundred ", " 100 "), (" one hundred ", " 100 "), (" hundred ", " 100 "),
        ]
        for (word, digits) in phrases { t = t.replacingOccurrences(of: word, with: digits) }
        t = t.replacingOccurrences(of: "-", with: " ")
        var tokens = t.split(separator: " ").map(String.init)
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if let ten = tens[token] {
                if i + 1 < tokens.count, let unit = units[tokens[i + 1]], unit >= 1, unit <= 9 { out.append(String(ten + unit)); i += 2; continue }
                out.append(String(ten)); i += 1; continue
            }
            if let unit = units[token], !isArticleUse(token, tokens, i) { out.append(String(unit)); i += 1; continue }
            out.append(token); i += 1
        }
        tokens = out
        return tokens.joined(separator: " ")
    }

    /// "one" in "play the one with" is not a number; only a "one" followed by a unit or a percent sign is read as 1.
    private static func isArticleUse(_ token: String, _ tokens: [String], _ index: Int) -> Bool {
        guard token == "one" else { return false }
        guard index + 1 < tokens.count else { return true }
        let next = tokens[index + 1]
        return !["hour", "hours", "minute", "minutes", "second", "seconds", "percent", "%", "min", "mins", "sec", "secs"].contains(next)
    }

    // MARK: Durations and times

    static let shortest: TimeInterval = 1
    static let longest: TimeInterval = 86_400

    struct Extracted<T: Equatable>: Equatable {
        var value: T
        /// The text with the part that was read taken out ("mute spotify for 1 hour" → "mute spotify").
        var remainder: String
    }

    // No word boundary after the unit: “2h30m” has none between h and 3. A unit must only not be followed by another letter (“5 mins” yes, “5 minuteman” no).
    private static let durationPart = #"(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)(?![a-z])"#

    /// A length of time said in words, or a time of day to wait for ("until 3pm"), in seconds. Nil if there is none.
    static func extractDuration(from text: String, now: Date, calendar: Calendar = .current) -> Extracted<TimeInterval>? {
        if let (seconds, remainder) = untilTime(in: text, now: now, calendar: calendar) { return Extracted(value: seconds, remainder: remainder) }
        guard let regex = try? NSRegularExpression(pattern: durationPart) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var total: TimeInterval = 0
        for match in matches {
            guard let value = Double(ns.substring(with: match.range(at: 1))) else { continue }
            let unit = ns.substring(with: match.range(at: 2))
            total += value * (unit.hasPrefix("h") ? 3600 : unit.hasPrefix("m") ? 60 : 1)
        }
        var remainder = text
        for match in matches.reversed() { remainder = (remainder as NSString).replacingCharacters(in: match.range, with: " ") }
        return Extracted(value: total, remainder: tidyRemainder(remainder, dropping: ["for", "in", "after", "and", "of", "about"]))
    }

    /// "until 3pm", "till 15:30", "until noon": seconds to the next time the clock shows that.
    private static func untilTime(in text: String, now: Date, calendar: Calendar) -> (TimeInterval, String)? {
        guard let regex = try? NSRegularExpression(pattern: #"\b(?:until|till|til)\s+(noon|midnight|(\d{1,2})(?::(\d{2}))?\s*(am|pm)?)\b"#) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var hour: Int, minute = 0
        let word = ns.substring(with: match.range(at: 1))
        if word == "noon" { hour = 12 } else if word == "midnight" { hour = 0 } else {
            guard match.range(at: 2).location != NSNotFound, var h = Int(ns.substring(with: match.range(at: 2))) else { return nil }
            if match.range(at: 3).location != NSNotFound { minute = Int(ns.substring(with: match.range(at: 3))) ?? 0 }
            let hasSuffix = match.range(at: 4).location != NSNotFound
            let hasMinutes = match.range(at: 3).location != NSNotFound
            // A bare number ("until 5") is not a time of day; it needs am/pm or a colon.
            guard hasSuffix || hasMinutes else { return nil }
            if hasSuffix {
                let suffix = ns.substring(with: match.range(at: 4))
                guard (1...12).contains(h) else { return nil }
                if suffix == "pm", h < 12 { h += 12 }
                if suffix == "am", h == 12 { h = 0 }
            }
            hour = h
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = hour; parts.minute = minute; parts.second = 0
        guard var target = calendar.date(from: parts) else { return nil }
        if target <= now { target = calendar.date(byAdding: .day, value: 1, to: target) ?? target }
        let remainder = (text as NSString).replacingCharacters(in: match.range, with: " ")
        return (target.timeIntervalSince(now), tidyRemainder(remainder, dropping: ["for", "in", "after", "and"]))
    }

    /// Removes a stray joining word left at an end after a part was taken out ("mute spotify for" → "mute spotify").
    static func tidyRemainder(_ text: String, dropping words: [String]) -> String {
        var parts = text.split(separator: " ").map(String.init)
        while let last = parts.last, words.contains(last) { parts.removeLast() }
        while let first = parts.first, words.contains(first) { parts.removeFirst() }
        return parts.joined(separator: " ")
    }

    // MARK: Percentages

    /// "40%", "40 percent", "to 40", or "volume 40" read as a level from 0 to 100 (more is returned as said; the caller checks the limit).
    static func extractPercent(from text: String) -> Extracted<Double>? {
        let patterns = [#"(\d+(?:\.\d+)?)\s*(?:%|percent)"#, #"\bto\s+(\d+(?:\.\d+)?)\b(?!\s*(?:hours?|minutes?|mins?|seconds?|secs?))"#, #"\bvolume\s+(?:at\s+|of\s+)?(\d+(?:\.\d+)?)\b"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                  let value = Double(ns.substring(with: match.range(at: 1))) else { continue }
            var remainder = text
            // For "volume 40" only the number goes; the word "volume" stays so the sentence still reads as a volume request.
            let range = pattern.contains("volume") ? match.range(at: 1) : match.range
            remainder = (remainder as NSString).replacingCharacters(in: range, with: " ")
            return Extracted(value: value, remainder: tidyRemainder(remainder.components(separatedBy: " ").filter { !$0.isEmpty }.joined(separator: " "), dropping: ["to", "at", "of"]))
        }
        return nil
    }

    // MARK: Looking for shell text

    /// Whether text looks like something to type into a shell or a script, which is never run from a request.
    static func looksLikeShell(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("$(") || lower.contains("`") || lower.contains("&&") || lower.contains("||") || lower.contains(">>") || lower.contains("2>&1") { return true }
        if lower.contains(";") && lower.contains(" ") { return true }
        if lower.range(of: #"(^|\s)\|(\s|$)"#, options: .regularExpression) != nil { return true }
        // Whole words only: "perform a search" contains "rm " but is not a command.
        let commands = ["sudo", "rm", "chmod", "chown", "curl", "wget", "osascript", "bash", "zsh", "eval", "exec", "launchctl", "killall", "mkfs", "nc", "ssh", "scp"]
        let pattern = #"(^|\s)("# + commands.joined(separator: "|") + #")(\s|$)"#
        if lower.range(of: pattern, options: .regularExpression) != nil { return true }
        let fragments = ["sh -c", "python -c", "perl -e", "defaults write", "dd if=", "diskutil erase", "> /dev/", "/bin/", "/usr/bin/", "rm -"]
        return fragments.contains { lower.contains($0) }
    }
}
