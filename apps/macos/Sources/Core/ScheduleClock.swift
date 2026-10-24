import Foundation

/// When a workflow that runs on a schedule is due. Pure functions of the time, the calendar and when it last ran, so they can be
/// tested at any hour without waiting for one.
enum ScheduleClock {
    /// A time that passes while the Mac is asleep is still run, once, if the Mac wakes within this long afterwards.
    static let catchUp: TimeInterval = 15 * 60

    /// Monday is 1 and Sunday is 7, whatever the calendar's first weekday is.
    static func weekday(_ date: Date, calendar: Calendar) -> Int {
        let sundayFirst = calendar.component(.weekday, from: date)   // 1 = Sunday … 7 = Saturday
        return sundayFirst == 1 ? 7 : sundayFirst - 1
    }

    /// Whether “every `minutes` minutes” is due: that long has passed since it last ran (or was turned on).
    static func intervalDue(minutes: UInt32, now: Date, lastRun: Date) -> Bool {
        minutes >= 1 && now.timeIntervalSince(lastRun) >= TimeInterval(minutes) * 60
    }

    /// Whether “at hh:mm on these days” is due now: today is one of the days, the time has come, it was not longer ago than the
    /// catch-up window, and it has not already run for this time today.
    static func dailyDue(hour: UInt8, minute: UInt8, weekdays: [UInt8], now: Date, lastRun: Date?, calendar: Calendar) -> Bool {
        guard hour < 24, minute < 60 else { return false }
        if !weekdays.isEmpty, !weekdays.contains(UInt8(weekday(now, calendar: calendar))) { return false }
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = Int(hour); parts.minute = Int(minute); parts.second = 0
        guard let scheduled = calendar.date(from: parts), scheduled <= now, now.timeIntervalSince(scheduled) <= catchUp else { return false }
        if let lastRun, lastRun >= scheduled { return false }
        return true
    }
}

/// What to do about a folder that changed: which of its items are new, and which are still being written.
enum FolderChange {
    /// Names a browser or another program gives a file while it is still being written. They count when the final name appears.
    static let unfinishedSuffixes = [".crdownload", ".download", ".part", ".partial", ".tmp", ".opdownload", ".filepart", ".!qB", ".aria2"]

    static func isUnfinished(_ name: String) -> Bool {
        name.hasPrefix(".") || name.hasPrefix("~$") || unfinishedSuffixes.contains { name.lowercased().hasSuffix($0.lowercased()) }
    }

    /// The names in `after` that were not in `before`, leaving out hidden and unfinished ones, sorted so the order is the same each time.
    static func newItems(before: Set<String>, after: Set<String>) -> [String] {
        after.subtracting(before).filter { !isUnfinished($0) }.sorted()
    }

    /// The names that count at all (to remember as “already seen”): everything except hidden and unfinished items.
    static func counted(_ names: [String]) -> Set<String> { Set(names.filter { !isUnfinished($0) }) }

    /// A folder path as the person wrote it, made absolute. Nil if it is not an absolute path, goes up with “..”, or is outside the home
    /// folder and the mounted drives (a workflow is not pointed at system folders).
    static func resolve(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }
        let absolute: String
        if trimmed.hasPrefix("~/") { absolute = home.path + String(trimmed.dropFirst(1)) }
        else if trimmed == "~" { absolute = home.path }
        else if trimmed.hasPrefix("/") { absolute = trimmed }
        else { return nil }
        let url = URL(fileURLWithPath: absolute)
        guard !url.pathComponents.contains("..") else { return nil }
        let standard = url.standardizedFileURL.path
        let roots = [home.standardizedFileURL.path, "/Volumes"]
        return roots.contains(where: { standard == $0 || standard.hasPrefix($0 + "/") }) ? url.standardizedFileURL : nil
    }
}
