import Foundation

/// A small calculator for the launcher. It reads numbers, + - * / ^ %, brackets, a few functions and "x% of y". It does not
/// use NSExpression, so nothing a person types can run code or crash the app.
enum LauncherCalculator {
    /// The answer as text, or nil when the text is not a sum.
    static func evaluate(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard text.count <= 200, text.contains(where: { $0.isNumber }) else { return nil }
        // A plain number is not a question.
        guard text.contains(where: { "+-*/^%()×÷".contains($0) }) || text.lowercased().contains("of ")
                || text.lowercased().range(of: #"[a-z]{2,}\("#, options: .regularExpression) != nil else { return nil }
        var parser = Parser(text: text)
        guard let value = parser.parse(), value.isFinite else { return nil }
        return format(value)
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 10
        formatter.usesGroupingSeparator = false
        formatter.decimalSeparator = "."
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private struct Parser {
        let characters: [Character]
        var index = 0
        var depth = 0

        init(text: String) {
            // "20% of 150" becomes (20/100)*(150), so it goes through the same rules as everything else.
            var cleaned = text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
                .replacingOccurrences(of: ",", with: "")
            if let range = cleaned.range(of: #"(?i)([0-9.]+)\s*%\s*of\s+"#, options: .regularExpression) {
                let head = String(cleaned[range]).lowercased()
                let number = head.split(separator: "%")[0].trimmingCharacters(in: .whitespaces)
                cleaned = cleaned.replacingCharacters(in: range, with: "(\(number)/100)*")
            }
            characters = Array(cleaned.lowercased())
        }

        mutating func parse() -> Double? {
            guard let value = expression() else { return nil }
            skipSpaces()
            return index == characters.count ? value : nil
        }

        private mutating func skipSpaces() { while index < characters.count, characters[index] == " " { index += 1 } }

        private mutating func peek() -> Character? { skipSpaces(); return index < characters.count ? characters[index] : nil }

        private mutating func expression() -> Double? {
            guard var left = term() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                index += 1
                guard let right = term() else { return nil }
                left = op == "+" ? left + right : left - right
            }
            return left
        }

        private mutating func term() -> Double? {
            guard var left = power() else { return nil }
            while let op = peek(), op == "*" || op == "/" || op == "%" {
                index += 1
                guard let right = power() else { return nil }
                switch op {
                case "*": left *= right
                case "/": guard right != 0 else { return nil }; left /= right
                default: guard right != 0 else { return nil }; left = left.truncatingRemainder(dividingBy: right)
                }
            }
            return left
        }

        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek() == "^" {
                index += 1
                guard let exponent = power() else { return nil }
                let result = pow(base, exponent)
                return result.isFinite ? result : nil
            }
            return base
        }

        private mutating func unary() -> Double? {
            if peek() == "-" { index += 1; return unary().map { -$0 } }
            if peek() == "+" { index += 1; return unary() }
            return primary()
        }

        private mutating func primary() -> Double? {
            guard let c = peek() else { return nil }
            if c == "(" {
                index += 1
                depth += 1
                guard depth < 40, let inner = expression(), peek() == ")" else { return nil }
                index += 1
                depth -= 1
                return inner
            }
            if c.isNumber || c == "." { return number() }
            if c.isLetter { return named() }
            return nil
        }

        private mutating func number() -> Double? {
            let start = index
            while index < characters.count, characters[index].isNumber || characters[index] == "." { index += 1 }
            return Double(String(characters[start..<index]))
        }

        private mutating func named() -> Double? {
            let start = index
            while index < characters.count, characters[index].isLetter { index += 1 }
            let name = String(characters[start..<index])
            switch name {
            case "pi": return Double.pi
            case "e": return M_E
            default: break
            }
            guard peek() == "(" else { return nil }
            index += 1
            depth += 1
            guard depth < 40, let argument = expression(), peek() == ")" else { return nil }
            index += 1
            depth -= 1
            switch name {
            case "sqrt": return argument >= 0 ? argument.squareRoot() : nil
            case "abs": return abs(argument)
            case "round": return argument.rounded()
            case "floor": return argument.rounded(.down)
            case "ceil": return argument.rounded(.up)
            case "sin": return sin(argument)
            case "cos": return cos(argument)
            case "tan": return tan(argument)
            case "ln": return argument > 0 ? log(argument) : nil
            case "log": return argument > 0 ? log10(argument) : nil
            default: return nil
            }
        }
    }
}

/// Timers typed into the launcher: "timer 5m", "timer 90 seconds", "timer 1h30m".
enum LauncherTimerParser {
    /// The seconds asked for, or nil when the text is not a timer. A day is the most.
    static func seconds(from input: String) -> TimeInterval? {
        let text = input.lowercased().trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("timer") || text.hasSuffix("timer") else { return nil }
        let body = text.replacingOccurrences(of: "timer", with: "").trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        var total: TimeInterval = 0
        var matched = false
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let whole = NSRange(body.startIndex..., in: body)
        regex.enumerateMatches(in: body, range: whole) { match, _, _ in
            guard let match, let numberRange = Range(match.range(at: 1), in: body), let unitRange = Range(match.range(at: 2), in: body),
                  let value = Double(body[numberRange]) else { return }
            let unit = body[unitRange]
            total += value * (unit.hasPrefix("h") ? 3600 : unit.hasPrefix("m") ? 60 : 1)
            matched = true
        }
        // A bare number means minutes.
        if !matched, let minutes = Double(body) { total = minutes * 60; matched = true }
        // Anything left over that is not a time means it was not a timer after all.
        let rest = regex.stringByReplacingMatches(in: body, range: whole, withTemplate: "").trimmingCharacters(in: .whitespaces)
        if matched, !rest.isEmpty, Double(body) == nil { return nil }
        guard matched, total >= 1, total <= 86_400 else { return nil }
        return total
    }

    static func describe(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) hour\(h == 1 ? "" : "s")") }
        if m > 0 { parts.append("\(m) minute\(m == 1 ? "" : "s")") }
        if s > 0 || parts.isEmpty { parts.append("\(s) second\(s == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }
}
