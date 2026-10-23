import CryptoKit
import Foundation

/// One answer from a converter or generator: the value shown big, what it is, and what choosing it copies.
struct ToolResult: Equatable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let copy: String
    let symbol: String
    /// Not remembered, and never written anywhere (a generated password).
    var sensitive = false
    /// A colour to show in place of the icon, as `#RRGGBB`.
    var swatchHex: String?
}

// MARK: - Units

enum UnitConverter {
    enum Dimension: String { case length, mass, volume, speed, area, data, time, temperature }

    /// name → (dimension, how many base units one of it is). Temperature is handled apart.
    private static let table: [String: (Dimension, Double)] = {
        var t: [String: (Dimension, Double)] = [:]
        func add(_ names: [String], _ d: Dimension, _ factor: Double) { for n in names { t[n] = (d, factor) } }
        add(["mm", "millimeter", "millimeters", "millimetre", "millimetres"], .length, 0.001)
        add(["cm", "centimeter", "centimeters", "centimetre", "centimetres"], .length, 0.01)
        add(["m", "meter", "meters", "metre", "metres"], .length, 1)
        add(["km", "kilometer", "kilometers", "kilometre", "kilometres"], .length, 1000)
        add(["in", "inch", "inches"], .length, 0.0254)
        add(["ft", "foot", "feet"], .length, 0.3048)
        add(["yd", "yard", "yards"], .length, 0.9144)
        add(["mi", "mile", "miles"], .length, 1609.344)
        add(["nmi", "nautical mile", "nautical miles"], .length, 1852)
        add(["mg", "milligram", "milligrams"], .mass, 0.001)
        add(["g", "gram", "grams"], .mass, 1)
        add(["kg", "kilogram", "kilograms", "kilo", "kilos"], .mass, 1000)
        add(["t", "tonne", "tonnes"], .mass, 1_000_000)
        add(["oz", "ounce", "ounces"], .mass, 28.349523125)
        add(["lb", "lbs", "pound", "pounds"], .mass, 453.59237)
        add(["st", "stone", "stones"], .mass, 6350.29318)
        add(["ml", "milliliter", "milliliters", "millilitre", "millilitres"], .volume, 0.001)
        add(["l", "liter", "liters", "litre", "litres"], .volume, 1)
        add(["tsp", "teaspoon", "teaspoons"], .volume, 0.00492892159375)
        add(["tbsp", "tablespoon", "tablespoons"], .volume, 0.01478676478125)
        add(["floz", "fl oz", "fluid ounce", "fluid ounces"], .volume, 0.0295735295625)
        add(["cup", "cups"], .volume, 0.2365882365)
        add(["pt", "pint", "pints"], .volume, 0.473176473)
        add(["qt", "quart", "quarts"], .volume, 0.946352946)
        add(["gal", "gallon", "gallons"], .volume, 3.785411784)
        add(["m/s", "mps"], .speed, 1)
        add(["km/h", "kph", "kmh", "kmph"], .speed, 1000.0 / 3600)
        add(["mph", "mi/h"], .speed, 0.44704)
        add(["kn", "kt", "knot", "knots"], .speed, 1852.0 / 3600)
        add(["sqm", "m2", "m²", "square meter", "square meters"], .area, 1)
        add(["sqkm", "km2", "km²"], .area, 1_000_000)
        add(["sqft", "ft2", "ft²", "square foot", "square feet"], .area, 0.09290304)
        add(["sqmi", "mi2", "mi²"], .area, 2_589_988.110336)
        add(["acre", "acres"], .area, 4046.8564224)
        add(["ha", "hectare", "hectares"], .area, 10_000)
        add(["b", "byte", "bytes"], .data, 1)
        add(["kb", "kilobyte", "kilobytes"], .data, 1000)
        add(["mb", "megabyte", "megabytes"], .data, 1_000_000)
        add(["gb", "gigabyte", "gigabytes"], .data, 1_000_000_000)
        add(["tb", "terabyte", "terabytes"], .data, 1_000_000_000_000)
        add(["kib"], .data, 1024)
        add(["mib"], .data, 1_048_576)
        add(["gib"], .data, 1_073_741_824)
        add(["ms", "millisecond", "milliseconds"], .time, 0.001)
        add(["s", "sec", "secs", "second", "seconds"], .time, 1)
        add(["min", "mins", "minute", "minutes"], .time, 60)
        add(["h", "hr", "hrs", "hour", "hours"], .time, 3600)
        add(["d", "day", "days"], .time, 86_400)
        add(["wk", "week", "weeks"], .time, 604_800)
        return t
    }()

    private static let temperatures: [String: String] = [
        "c": "c", "°c": "c", "celsius": "c", "centigrade": "c",
        "f": "f", "°f": "f", "fahrenheit": "f",
        "k": "k", "kelvin": "k",
    ]

    /// "5 km to mi", "100 f in c", "2.5 kg as lb": the answer as text, or nil when it is not a conversion we know.
    static func convert(_ input: String) -> ToolResult? {
        let pattern = #"^\s*([-+]?\d+(?:[.,]\d+)?)\s*([A-Za-z°/²0-9 ]+?)\s+(?:to|in|as|into|->)\s+([A-Za-z°/²0-9 ]+?)\s*$"#
        guard input.count <= 80,
              let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)), match.numberOfRanges == 4,
              let r1 = Range(match.range(at: 1), in: input), let r2 = Range(match.range(at: 2), in: input), let r3 = Range(match.range(at: 3), in: input),
              let amount = Double(input[r1].replacingOccurrences(of: ",", with: ".")) else { return nil }
        let from = input[r2].lowercased().trimmingCharacters(in: .whitespaces)
        let to = input[r3].lowercased().trimmingCharacters(in: .whitespaces)

        if let a = temperatures[from], let b = temperatures[to] {
            let celsius: Double
            switch a { case "f": celsius = (amount - 32) * 5 / 9; case "k": celsius = amount - 273.15; default: celsius = amount }
            let value: Double
            switch b { case "f": value = celsius * 9 / 5 + 32; case "k": value = celsius + 273.15; default: value = celsius }
            return make(amount, from, value, to)
        }
        guard let source = table[from], let target = table[to], source.0 == target.0 else { return nil }
        return make(amount, from, amount * source.1 / target.1, to)
    }

    private static func make(_ amount: Double, _ from: String, _ value: Double, _ to: String) -> ToolResult? {
        guard value.isFinite else { return nil }
        let shown = format(value)
        return ToolResult(id: "unit:\(amount)\(from)\(to)", title: "\(shown) \(to)", subtitle: "\(format(amount)) \(from) =", copy: shown, symbol: "ruler")
    }

    static func format(_ value: Double) -> String {
        if value == 0 { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1e12 || magnitude < 1e-6 { return String(format: "%.4g", value) }
        let digits = magnitude >= 1000 ? 2 : magnitude >= 1 ? 4 : 6
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = digits
        formatter.usesGroupingSeparator = false
        formatter.decimalSeparator = "."
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

// MARK: - Currency

enum CurrencyConverter {
    /// "100 usd to eur": the amount and the two codes, or nil.
    static func parse(_ input: String) -> (amount: Double, from: String, to: String)? {
        let pattern = #"^\s*([-+]?\d+(?:[.,]\d+)?)\s*([A-Za-z]{3})\s+(?:to|in|as|into|->)\s+([A-Za-z]{3})\s*$"#
        guard input.count <= 40, let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)), match.numberOfRanges == 4,
              let r1 = Range(match.range(at: 1), in: input), let r2 = Range(match.range(at: 2), in: input), let r3 = Range(match.range(at: 3), in: input),
              let amount = Double(input[r1].replacingOccurrences(of: ",", with: ".")) else { return nil }
        let from = input[r2].uppercased(), to = input[r3].uppercased()
        guard knownCodes.contains(from), knownCodes.contains(to), from != to else { return nil }
        return (amount, from, to)
    }

    /// Currencies the daily reference rates cover.
    static let knownCodes: Set<String> = [
        "EUR", "USD", "JPY", "GBP", "CHF", "CAD", "AUD", "NZD", "CNY", "INR", "SEK", "NOK", "DKK", "PLN", "CZK", "HUF", "RON", "BGN",
        "TRY", "BRL", "MXN", "ZAR", "KRW", "SGD", "HKD", "IDR", "ILS", "MYR", "PHP", "THB", "ISK",
    ]

    /// `rates` are units of each currency per one euro (EUR itself is 1).
    static func convert(amount: Double, from: String, to: String, rates: [String: Double]) -> Double? {
        guard let a = from == "EUR" ? 1 : rates[from], let b = to == "EUR" ? 1 : rates[to], a > 0, b > 0 else { return nil }
        let value = amount / a * b
        return value.isFinite ? value : nil
    }

    static func result(amount: Double, from: String, to: String, rates: [String: Double], date: String?) -> ToolResult? {
        guard let value = convert(amount: amount, from: from, to: to, rates: rates) else { return nil }
        let shown = String(format: abs(value) >= 100 ? "%.2f" : "%.4f", value)
        let trimmed = shown.contains(".") ? shown.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) : shown
        return ToolResult(id: "fx:\(from)\(to)\(amount)", title: "\(trimmed) \(to)", subtitle: "\(UnitConverter.format(amount)) \(from) at the rate of \(date ?? "the last update")", copy: trimmed, symbol: "dollarsign.circle")
    }

    /// The address that returns the latest reference rates against the euro. Only currency codes are sent.
    static var ratesURL: URL { URL(string: "https://api.frankfurter.app/latest")! }

    /// The rates in the service's answer, and the date it carries.
    static func parseRates(_ data: Data) -> (rates: [String: Double], date: String?)? {
        guard data.count < 200_000, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = root["rates"] as? [String: Any] else { return nil }
        var rates: [String: Double] = [:]
        for (code, value) in raw {
            if let number = value as? Double, number > 0, number.isFinite, code.count == 3 { rates[code.uppercased()] = number }
        }
        return rates.isEmpty ? nil : (rates, root["date"] as? String)
    }
}

// MARK: - Time zones

enum TimeZoneTool {
    private static let aliases: [String: String] = [
        "nyc": "America/New_York", "new york": "America/New_York", "ny": "America/New_York", "boston": "America/New_York", "miami": "America/New_York", "toronto": "America/Toronto",
        "la": "America/Los_Angeles", "los angeles": "America/Los_Angeles", "sf": "America/Los_Angeles", "san francisco": "America/Los_Angeles", "seattle": "America/Los_Angeles", "vancouver": "America/Vancouver",
        "chicago": "America/Chicago", "dallas": "America/Chicago", "houston": "America/Chicago", "austin": "America/Chicago", "denver": "America/Denver", "phoenix": "America/Phoenix",
        "mexico city": "America/Mexico_City", "sao paulo": "America/Sao_Paulo", "buenos aires": "America/Argentina/Buenos_Aires", "bogota": "America/Bogota", "lima": "America/Lima",
        "london": "Europe/London", "uk": "Europe/London", "dublin": "Europe/Dublin", "lisbon": "Europe/Lisbon", "paris": "Europe/Paris", "berlin": "Europe/Berlin", "madrid": "Europe/Madrid",
        "rome": "Europe/Rome", "amsterdam": "Europe/Amsterdam", "zurich": "Europe/Zurich", "stockholm": "Europe/Stockholm", "oslo": "Europe/Oslo", "athens": "Europe/Athens",
        "istanbul": "Europe/Istanbul", "moscow": "Europe/Moscow", "kyiv": "Europe/Kyiv", "cairo": "Africa/Cairo", "lagos": "Africa/Lagos", "nairobi": "Africa/Nairobi", "johannesburg": "Africa/Johannesburg",
        "dubai": "Asia/Dubai", "riyadh": "Asia/Riyadh", "tehran": "Asia/Tehran", "karachi": "Asia/Karachi", "delhi": "Asia/Kolkata", "mumbai": "Asia/Kolkata", "india": "Asia/Kolkata", "ist": "Asia/Kolkata",
        "bangalore": "Asia/Kolkata", "hyderabad": "Asia/Kolkata", "chennai": "Asia/Kolkata", "kolkata": "Asia/Kolkata", "dhaka": "Asia/Dhaka", "bangkok": "Asia/Bangkok", "jakarta": "Asia/Jakarta",
        "singapore": "Asia/Singapore", "kuala lumpur": "Asia/Kuala_Lumpur", "hong kong": "Asia/Hong_Kong", "shanghai": "Asia/Shanghai", "beijing": "Asia/Shanghai", "taipei": "Asia/Taipei",
        "manila": "Asia/Manila", "seoul": "Asia/Seoul", "tokyo": "Asia/Tokyo", "japan": "Asia/Tokyo", "sydney": "Australia/Sydney", "melbourne": "Australia/Melbourne", "perth": "Australia/Perth",
        "auckland": "Pacific/Auckland", "honolulu": "Pacific/Honolulu", "anchorage": "America/Anchorage", "utc": "UTC", "gmt": "GMT", "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles",
        "est": "America/New_York", "edt": "America/New_York", "cst": "America/Chicago", "mst": "America/Denver", "cet": "Europe/Paris", "bst": "Europe/London", "jst": "Asia/Tokyo",
    ]

    /// A place name or abbreviation as a time zone: a known alias first, then the last part of a zone's own name ("Kolkata").
    static func zone(named raw: String) -> TimeZone? {
        let name = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 40 else { return nil }
        if let id = aliases[name], let zone = TimeZone(identifier: id) { return zone }
        let want = name.replacingOccurrences(of: " ", with: "_")
        if let id = TimeZone.knownTimeZoneIdentifiers.first(where: { $0.lowercased().split(separator: "/").last.map(String.init) == want }) { return TimeZone(identifier: id) }
        return nil
    }

    private static func clock(_ date: Date, in zone: TimeZone, withDay: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = zone
        formatter.dateFormat = withDay ? "EEE h:mm a" : "h:mm a"
        return formatter.string(from: date)
    }

    private static func offset(_ zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let h = abs(seconds) / 3600, m = abs(seconds) % 3600 / 60
        return m == 0 ? "GMT\(sign)\(h)" : String(format: "GMT%@%d:%02d", sign, h, m)
    }

    /// "time in tokyo", "tokyo time", "3pm nyc in london", "15:30 london to tokyo".
    static func answer(_ input: String, now: Date = Date()) -> ToolResult? {
        let text = input.lowercased().trimmingCharacters(in: .whitespaces)
        guard text.count <= 60 else { return nil }
        if let found = firstMatch(#"^(?:what(?:'s| is) the )?time (?:in|at) (.+?)\??$"#, text) ?? firstMatch(#"^(.+?) time$"#, text), let zone = zone(named: found[0]) {
            return ToolResult(id: "time:\(zone.identifier)", title: clock(now, in: zone), subtitle: "\(zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone.identifier) (\(offset(zone, at: now)))", copy: clock(now, in: zone), symbol: "clock")
        }
        if let parts = firstMatch(#"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s+(.+?)\s+(?:in|to)\s+(.+)$"#, text), parts.count == 5,
           let from = zone(named: parts[3]), let to = zone(named: parts[4]), var hour = Int(parts[0]) {
            let minute = Int(parts[1]) ?? 0
            if parts[2] == "pm", hour < 12 { hour += 12 }
            if parts[2] == "am", hour == 12 { hour = 0 }
            guard hour < 24, minute < 60 else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = from
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            guard let date = calendar.date(from: components) else { return nil }
            let place = parts[4].capitalized
            return ToolResult(id: "time:\(text)", title: clock(date, in: to), subtitle: "\(String(format: "%d:%02d", hour, minute)) in \(parts[3].capitalized) is this in \(place) (\(offset(to, at: date)))", copy: clock(date, in: to), symbol: "clock.arrow.2.circlepath")
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
}

// MARK: - Colours

enum ColorTool {
    /// "#ff8800", "ff8800", "#f80" or "rgb(255, 136, 0)" as red, green and blue from 0 to 255.
    static func parse(_ input: String) -> (r: Int, g: Int, b: Int)? {
        let text = input.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("rgb") {
            let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard numbers.count == 3, numbers.allSatisfy({ (0...255).contains($0) }) else { return nil }
            return (numbers[0], numbers[1], numbers[2])
        }
        var hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard hex.count == 3 || hex.count == 6, hex.allSatisfy(\.isHexDigit), text.hasPrefix("#") || hex.count == 6 else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let value = Int(hex, radix: 16) else { return nil }
        return ((value >> 16) & 255, (value >> 8) & 255, value & 255)
    }

    static func hex(_ c: (r: Int, g: Int, b: Int)) -> String { String(format: "#%02X%02X%02X", c.r, c.g, c.b) }

    static func hsl(_ c: (r: Int, g: Int, b: Int)) -> String {
        let r = Double(c.r) / 255, g = Double(c.g) / 255, b = Double(c.b) / 255
        let high = max(r, g, b), low = min(r, g, b)
        let l = (high + low) / 2
        guard high != low else { return "hsl(0, 0%, \(Int((l * 100).rounded()))%)" }
        let d = high - low
        let s = l > 0.5 ? d / (2 - high - low) : d / (high + low)
        var h: Double
        switch high {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h *= 60
        return "hsl(\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
    }

    static func results(for input: String) -> [ToolResult] {
        guard let c = parse(input) else { return [] }
        let hexText = hex(c)
        return [
            ToolResult(id: "color:hex", title: hexText, subtitle: "Hex colour", copy: hexText, symbol: "paintpalette", swatchHex: hexText),
            ToolResult(id: "color:rgb", title: "rgb(\(c.r), \(c.g), \(c.b))", subtitle: "Copy as RGB", copy: "rgb(\(c.r), \(c.g), \(c.b))", symbol: "paintpalette", swatchHex: hexText),
            ToolResult(id: "color:hsl", title: hsl(c), subtitle: "Copy as HSL", copy: hsl(c), symbol: "paintpalette", swatchHex: hexText),
        ]
    }
}

// MARK: - Text helpers and generators

enum TextTool {
    /// "base64 hello", "base64 decode aGVsbG8=", "urlencode a b", "sha256 text", "upper text", "slug Hello World", "count text".
    static func answer(_ input: String) -> [ToolResult] {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { return [] }
        let word = trimmed[..<space].lowercased()
        let rest = String(trimmed[trimmed.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, rest.count <= 5000 else { return [] }

        func one(_ id: String, _ title: String, _ subtitle: String, _ symbol: String = "textformat") -> [ToolResult] {
            [ToolResult(id: "text:\(id):\(rest.prefix(40))", title: title, subtitle: subtitle, copy: title, symbol: symbol)]
        }
        switch word {
        case "base64", "b64":
            let (action, body) = splitAction(rest)
            if action == "decode" || action == "d" {
                guard let data = Data(base64Encoded: padded(body)), let text = String(data: data, encoding: .utf8) else { return [] }
                return one("b64d", text, "Base64 decoded")
            }
            return one("b64", Data(body.utf8).base64EncodedString(), "Base64 encoded")
        case "base64d", "b64d":
            guard let data = Data(base64Encoded: padded(rest)), let text = String(data: data, encoding: .utf8) else { return [] }
            return one("b64d", text, "Base64 decoded")
        case "urlencode":
            return rest.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))).map { one("urle", $0, "URL encoded") } ?? []
        case "urldecode":
            return rest.removingPercentEncoding.map { one("urld", $0, "URL decoded") } ?? []
        case "sha256", "sha":
            return one("sha", SHA256.hash(data: Data(rest.utf8)).map { String(format: "%02x", $0) }.joined(), "SHA-256 of the text", "number")
        case "md5":
            return one("md5", Insecure.MD5.hash(data: Data(rest.utf8)).map { String(format: "%02x", $0) }.joined(), "MD5 of the text", "number")
        case "upper", "uppercase":
            return one("up", rest.uppercased(), "Upper case")
        case "lower", "lowercase":
            return one("low", rest.lowercased(), "Lower case")
        case "title", "titlecase":
            return one("title", rest.capitalized, "Title case")
        case "slug":
            let slug = rest.folding(options: .diacriticInsensitive, locale: .current).lowercased()
                .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return slug.isEmpty ? [] : one("slug", slug, "As a URL slug")
        case "count", "length":
            let words = rest.split { $0.isWhitespace }.count
            let summary = "\(rest.count) characters, \(words) word\(words == 1 ? "" : "s")"
            return [ToolResult(id: "text:count", title: summary, subtitle: "Count", copy: summary, symbol: "number")]
        case "reverse":
            return one("rev", String(rest.reversed()), "Reversed")
        case "json":
            guard let data = rest.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), let text = String(data: pretty, encoding: .utf8) else { return [] }
            return one("json", text, "JSON, tidied", "curlybraces")
        case "timestamp", "epoch":
            guard let seconds = Double(rest) else { return [] }
            let value = seconds > 1e11 ? seconds / 1000 : seconds
            let formatter = ISO8601DateFormatter()
            return one("ts", formatter.string(from: Date(timeIntervalSince1970: value)), "Date for that timestamp", "calendar")
        default:
            return []
        }
    }

    private static func splitAction(_ text: String) -> (String, String) {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, ["encode", "decode", "e", "d"].contains(parts[0].lowercased()) { return (parts[0].lowercased(), parts[1]) }
        return ("encode", text)
    }

    private static func padded(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").trimmingCharacters(in: .whitespaces)
        return clean + String(repeating: "=", count: (4 - clean.count % 4) % 4)
    }
}

enum GeneratorTool {
    private static let lowercase = Array("abcdefghijkmnopqrstuvwxyz")
    private static let uppercase = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    private static let digits = Array("23456789")
    private static let symbols = Array("!@#$%^&*-_=+?")

    /// A password with at least one of each kind, drawn from a secure random source. `random` is replaceable for tests.
    static func password(length: Int, random: () -> UInt32 = { UInt32.random(in: .min ... .max) }) -> String {
        let n = min(max(length, 8), 64)
        let pools = [lowercase, uppercase, digits, symbols]
        let all = pools.flatMap { $0 }
        func pick(_ pool: [Character]) -> Character { pool[Int(random()) % pool.count] }
        var characters = pools.map(pick)
        while characters.count < n { characters.append(pick(all)) }
        // Shuffled so the required kinds are not always first.
        for i in stride(from: characters.count - 1, to: 0, by: -1) { characters.swapAt(i, Int(random()) % (i + 1)) }
        return String(characters)
    }

    private static let words = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo consequat duis aute irure in reprehenderit voluptate velit esse cillum fugiat nulla pariatur excepteur sint occaecat cupidatat non proident sunt culpa qui officia deserunt mollit anim id est laborum".split(separator: " ").map(String.init)

    static func lorem(paragraphs: Int) -> String {
        let count = min(max(paragraphs, 1), 10)
        return (0..<count).map { p in
            let sentences = (0..<4).map { s -> String in
                let length = 8 + (p * 3 + s * 5) % 7
                let start = (p * 11 + s * 17) % words.count
                let line = (0..<length).map { words[(start + $0 * 3) % words.count] }.joined(separator: " ")
                return line.prefix(1).uppercased() + line.dropFirst() + "."
            }
            return sentences.joined(separator: " ")
        }.joined(separator: "\n\n")
    }

    /// "uuid", "password", "password 24", "lorem 2".
    static func answer(_ input: String, random: () -> UInt32 = { UInt32.random(in: .min ... .max) }) -> [ToolResult] {
        let parts = input.trimmingCharacters(in: .whitespaces).lowercased().split(separator: " ").map(String.init)
        guard let word = parts.first, parts.count <= 2 else { return [] }
        let number = parts.count == 2 ? Int(parts[1]) : nil
        if parts.count == 2 && number == nil { return [] }
        switch word {
        case "uuid", "guid":
            guard parts.count == 1 else { return [] }
            let value = UUID().uuidString.lowercased()
            return [ToolResult(id: "gen:uuid:\(value)", title: value, subtitle: "New UUID", copy: value, symbol: "number.square")]
        case "password", "pass", "pw":
            let value = password(length: number ?? 20, random: random)
            return [ToolResult(id: "gen:pw:\(value)", title: value, subtitle: "New password, \(value.count) characters", copy: value, symbol: "key", sensitive: true)]
        case "lorem":
            let text = lorem(paragraphs: number ?? 1)
            let count = min(max(number ?? 1, 1), 10)
            return [ToolResult(id: "gen:lorem:\(count)", title: String(text.prefix(70)) + "…", subtitle: "\(count) paragraph\(count == 1 ? "" : "s") of filler text", copy: text, symbol: "text.alignleft")]
        default:
            return []
        }
    }
}

// MARK: - Meetings

enum MeetingLink {
    private static let patterns = [
        #"https://[\w.-]*zoom\.us/[^\s<>"')]+"#,
        #"https://meet\.google\.com/[a-z0-9-]+(?:\?[^\s<>"')]*)?"#,
        #"https://teams\.microsoft\.com/l/meetup-join/[^\s<>"')]+"#,
        #"https://teams\.live\.com/meet/[^\s<>"')]+"#,
        #"https://[\w.-]*webex\.com/[^\s<>"')]+"#,
        #"https://[\w.-]*whereby\.com/[^\s<>"')]+"#,
        #"https://[\w.-]*gotomeeting\.com/[^\s<>"')]+"#,
    ]

    /// The first video-call link in the text of an event (its location, notes or address), or nil.
    static func extract(from texts: [String?]) -> URL? {
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            var best: (range: Range<String.Index>, url: URL)?
            for pattern in patterns {
                guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]), let url = URL(string: String(text[range])) else { continue }
                if best == nil || range.lowerBound < best!.range.lowerBound { best = (range, url) }
            }
            if let best { return best.url }
        }
        return nil
    }

    /// "in 12 minutes", "now", "5 minutes ago" for how far an event is from `now`.
    static func relative(_ start: Date, now: Date = Date()) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded())
        switch minutes {
        case ..<(-1): return "started \(-minutes) min ago"
        case -1...1: return "now"
        case 2..<60: return "in \(minutes) min"
        default:
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "in \(h) h" : "in \(h) h \(m) min"
        }
    }
}
