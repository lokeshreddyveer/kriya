import Foundation

/// What macOS wrote in a file's `com.apple.quarantine` mark when it was downloaded: `0083;5f3a1c2b;Safari;UUID`.
struct QuarantineInfo: Equatable {
    var flags: String
    var date: Date?
    var app: String

    static func parse(_ value: String) -> QuarantineInfo? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, !parts[0].isEmpty else { return nil }
        let date = UInt64(parts[1], radix: 16).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return QuarantineInfo(flags: parts[0], date: date, app: parts[2])
    }

    /// True when macOS has already let the person approve this file once (the "user approved" bit).
    var wasApproved: Bool { UInt16(flags, radix: 16).map { $0 & 0x0040 != 0 } ?? false }
}

enum FinderInspectText {
    /// `rwxr-xr-x` for a mode like 0o755.
    static func permissionString(_ mode: Int) -> String {
        let letters = ["r", "w", "x"]
        return (0..<9).map { i in mode & (1 << (8 - i)) != 0 ? letters[i % 3] : "-" }.joined()
    }

    /// "1 h 02 min 03 s" or "45 s" from seconds.
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "unknown" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d h %02d min %02d s", h, m, s) }
        if m > 0 { return String(format: "%d min %02d s", m, s) }
        return "\(s) s"
    }
}
