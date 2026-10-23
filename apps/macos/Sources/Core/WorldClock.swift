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

/// Working hours, as whole hours on a 24-hour clock in a place's own time.
struct BusinessHours: Codable, Equatable {
    var start = 9
    var end = 18
}

enum MeetingOverlap {
    struct Slot: Equatable {
        /// The start of the hour, in the first place's time zone terms (a real moment).
        let start: Date
        let end: Date
    }

    /// The whole hours, starting at `day`, in which every place is inside its working hours. Looks at 48 hours so a day that
    /// differs between places is covered, and returns them in order. Zones with half-hour offsets are checked by the hour of
    /// the hour start in each zone.
    static func slots(places: [ClockPlace], hours: BusinessHours, from day: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> [Slot] {
        let zones = places.compactMap(\.zone)
        guard zones.count == places.count, zones.count >= 2, hours.start < hours.end else { return [] }
        var start = day
        let seconds = Int(start.timeIntervalSince1970)
        start = Date(timeIntervalSince1970: TimeInterval(seconds - seconds % 3600))
        var result: [Slot] = []
        for offset in 0..<48 {
            let slotStart = start.addingTimeInterval(TimeInterval(offset * 3600))
            let slotEnd = slotStart.addingTimeInterval(3600)
            let inside = zones.allSatisfy { zone in
                var c = calendar; c.timeZone = zone
                let a = c.dateComponents([.hour, .minute], from: slotStart), b = c.dateComponents([.hour, .minute], from: slotEnd.addingTimeInterval(-1))
                guard let ha = a.hour, let hb = b.hour, let ma = a.minute else { return false }
                let begin = Double(ha) + Double(ma) / 60
                let finish = Double(hb) + 1
                return begin >= Double(hours.start) && finish <= Double(hours.end) + 0.0001 && ha <= hb
            }
            if inside { result.append(Slot(start: slotStart, end: slotEnd)) }
        }
        return result
    }

    /// Adjoining slots joined: 10:00–11:00 and 11:00–12:00 become 10:00–12:00.
    static func merged(_ slots: [Slot]) -> [Slot] {
        var out: [Slot] = []
        for slot in slots.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, last.end == slot.start { out[out.count - 1] = Slot(start: last.start, end: slot.end) } else { out.append(slot) }
        }
        return out
    }
}

enum DaylightWarnings {
    struct Change: Equatable {
        let place: String
        let date: Date
        let shift: Int
    }

    /// Places whose clocks change within `days` days, so a meeting set across the change is not an hour off.
    static func upcoming(places: [ClockPlace], from now: Date, days: Int = 14) -> [Change] {
        let limit = now.addingTimeInterval(TimeInterval(days * 86_400))
        return places.compactMap { place -> Change? in
            guard let zone = place.zone, let next = zone.nextDaylightSavingTimeTransition(after: now), next <= limit else { return nil }
            let shift = zone.secondsFromGMT(for: next.addingTimeInterval(60)) - zone.secondsFromGMT(for: next.addingTimeInterval(-60))
            guard shift != 0 else { return nil }
            return Change(place: place.label, date: next, shift: shift / 60)
        }.sorted { $0.date < $1.date }
    }

    static func sentence(_ change: Change) -> String {
        let hours = abs(change.shift) / 60
        let amount = hours > 0 && abs(change.shift) % 60 == 0 ? "\(hours) hour\(hours == 1 ? "" : "s")" : "\(abs(change.shift)) minutes"
        let day = DateFormatter()
        day.dateStyle = .medium; day.timeStyle = .none
        return "\(change.place) clocks go \(change.shift > 0 ? "forward" : "back") \(amount) on \(day.string(from: change.date))."
    }
}

enum TimeConversion {
    /// "3pm", "15:30", "9:05 am" as minutes after midnight. Nil when it is not a time.
    static func minutes(from text: String) -> Int? {
        var t = text.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        var pm: Bool?
        if t.hasSuffix("am") { pm = false; t.removeLast(2) } else if t.hasSuffix("pm") { pm = true; t.removeLast(2) }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2, let h = Int(parts[0]), h >= 0, h <= 23 else { return nil }
        let m = parts.count == 2 ? Int(parts[1]) : 0
        guard let minute = m, minute >= 0, minute < 60 else { return nil }
        var hour = h
        if let pm {
            guard h >= 1, h <= 12 else { return nil }
            hour = h % 12 + (pm ? 12 : 0)
        }
        return hour * 60 + minute
    }

    /// The moment a time on `day` (a date in `zone`) falls at.
    static func moment(minutes: Int, on day: Date, in zone: TimeZone) -> Date? {
        var c = Calendar(identifier: .gregorian); c.timeZone = zone
        var parts = c.dateComponents([.year, .month, .day], from: day)
        parts.hour = minutes / 60; parts.minute = minutes % 60
        return c.date(from: parts)
    }

    /// "3 PM in New York is 12:30 AM (tomorrow) in Kolkata" for every place on the clock.
    static func lines(time text: String, from source: ClockPlace, to places: [ClockPlace], on day: Date, twentyFourHour: Bool) -> [String] {
        guard let zone = source.zone, let mins = minutes(from: text), let moment = moment(minutes: mins, on: day, in: zone) else { return [] }
        return places.compactMap { place in
            guard let target = place.zone else { return nil }
            let delta = WorldClockFormat.dayDelta(moment, in: target, from: zone)
            let word = WorldClockFormat.dayWord(delta)
            return "\(place.label) \(WorldClockFormat.time(moment, in: target, twentyFourHour: twentyFourHour))" + (word.isEmpty ? "" : " (\(word.lowercased()))")
        }
    }
}
