import Foundation

/// File names for captures and recordings from a pattern such as "{app} {date} {time}".
enum CaptureNaming {
    static let defaultPattern = "Kriya Capture {date} {time}"
    static let tokens = ["{date}", "{time}", "{app}", "{mode}", "{n}"]

    /// What is wrong with a pattern, or nil. It must say something that differs between captures.
    static func problem(_ pattern: String) -> String? {
        let text = pattern.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return "Type a name pattern, or reset to the default." }
        if text.count > 100 { return "That name is too long." }
        if text.contains("/") || text.contains(":") { return "A file name cannot contain / or :." }
        if !text.contains("{time}") && !text.contains("{n}") && !text.contains("{date}") {
            return "Add {time}, {date} or {n}, or every capture would get the same name."
        }
        return nil
    }

    /// The name, with the extension, that does not clash with `existing`. A bad pattern falls back to the default one.
    static func fileName(pattern: String?, date: Date, app: String?, mode: String, ext: String, existing: (String) -> Bool = { _ in false }) -> String {
        let chosen = (pattern.flatMap { problem($0) == nil ? $0 : nil }) ?? defaultPattern
        let dateFormat = DateFormatter()
        dateFormat.locale = Locale(identifier: "en_US_POSIX")
        dateFormat.dateFormat = "yyyy-MM-dd"
        let timeFormat = DateFormatter()
        timeFormat.locale = Locale(identifier: "en_US_POSIX")
        timeFormat.dateFormat = "HH.mm.ss"
        let appName = clean(app ?? "") 
        func build(_ number: Int) -> String {
            var stem = chosen
                .replacingOccurrences(of: "{date}", with: dateFormat.string(from: date))
                .replacingOccurrences(of: "{time}", with: timeFormat.string(from: date))
                .replacingOccurrences(of: "{app}", with: appName.isEmpty ? "Screen" : appName)
                .replacingOccurrences(of: "{mode}", with: mode)
                .replacingOccurrences(of: "{n}", with: String(number))
            stem = stem.trimmingCharacters(in: .whitespaces)
            return stem.isEmpty ? "Kriya Capture" : stem
        }
        var number = 1
        var name = build(number) + "." + ext
        // A second capture in the same second gets a counter on the end instead of replacing the first.
        while existing(name) {
            number += 1
            name = chosen.contains("{n}") ? build(number) + "." + ext : build(1) + " \(number)." + ext
        }
        return name
    }

    /// App names go into file names, so characters that cannot be there are dropped.
    static func clean(_ text: String) -> String {
        String(text.filter { !"/:\\\0".contains($0) && !$0.isNewline }.prefix(40)).trimmingCharacters(in: .whitespaces)
    }
}
