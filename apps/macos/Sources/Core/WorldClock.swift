import Foundation

/// A place on the world clock: a time zone and the short name shown for it.
struct ClockPlace: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var label: String
    var zoneID: String

    var zone: TimeZone? { TimeZone(identifier: zoneID) }
}

enum WorldClockFormat {
    /// "3:05 PM", or "15:05" with a 24-hour clock.
    static func time(_ date: Date, in zone: TimeZone, twentyFourHour: Bool, seconds: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = twentyFourHour ? (seconds ? "HH:mm:ss" : "HH:mm") : (seconds ? "h:mm:ss a" : "h:mm a")
        return f.string(from: date)
    }

    /// Whether it is yesterday, today or tomorrow there compared with the viewer's own zone: -1, 0 or 1.
    static func dayDelta(_ date: Date, in zone: TimeZone, from home: TimeZone = .current) -> Int {
        var h = Calendar(identifier: .gregorian); h.timeZone = home
        var z = Calendar(identifier: .gregorian); z.timeZone = zone
        let a = h.dateComponents([.year, .month, .day], from: date), b = z.dateComponents([.year, .month, .day], from: date)
        guard let da = h.date(from: a), let db = h.date(from: b) else { return 0 }
        return Int((db.timeIntervalSince(da) / 86_400).rounded())
    }

    /// "Tomorrow", "Yesterday" or "" for the small text under a time.
    static func dayWord(_ delta: Int) -> String { delta == 0 ? "" : delta > 0 ? "Tomorrow" : "Yesterday" }

    /// "+5 h 30 m" or "−3 h" compared with the home zone.
    static func difference(_ date: Date, in zone: TimeZone, from home: TimeZone = .current) -> String {
        let seconds = zone.secondsFromGMT(for: date) - home.secondsFromGMT(for: date)
        if seconds == 0 { return "Same time" }
        let h = abs(seconds) / 3600, m = abs(seconds) % 3600 / 60
        return (seconds > 0 ? "+" : "−") + "\(h) h" + (m > 0 ? " \(m) m" : "")
    }

    /// The text in the menu bar: "NYC 9:05 AM  LON 2:05 PM".
    static func barText(_ places: [ClockPlace], date: Date, twentyFourHour: Bool) -> String {
        places.compactMap { place in place.zone.map { "\(place.label) \(time(date, in: $0, twentyFourHour: twentyFourHour))" } }.joined(separator: "   ")
    }

    /// A short label for a zone made from a name the person typed: "new york" gives "NEW".
    static func defaultLabel(for name: String) -> String {
        let letters = name.uppercased().filter { $0.isLetter }
        return String(letters.prefix(3))
    }
}
