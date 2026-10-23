import Foundation

/// The rules for passing a piece of clipboard text between Macs through iCloud Drive. Each Mac drops an encrypted file in a
/// shared folder, other Macs read the newest one meant for them, and files are removed after a few minutes.
enum SharedClipboard {
    static let maxAge: TimeInterval = 600
    static let maxBytes = 100_000
    static let fileExtension = "kriyaclip"

    struct Payload: Codable, Equatable {
        var from: String
        var text: String
    }

    /// "1700000000000-DEVICEID.kriyaclip".
    static func fileName(deviceID: String, at date: Date) -> String {
        "\(Int64(date.timeIntervalSince1970 * 1000))-\(deviceID).\(fileExtension)"
    }

    static func parse(_ name: String) -> (deviceID: String, date: Date)? {
        guard name.hasSuffix("." + fileExtension) else { return nil }
        let stem = String(name.dropLast(fileExtension.count + 1))
        guard let dash = stem.firstIndex(of: "-"), let ms = Int64(stem[..<dash]) else { return nil }
        let device = String(stem[stem.index(after: dash)...])
        guard !device.isEmpty else { return nil }
        return (device, Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// Files old enough to remove.
    static func expired(_ names: [String], now: Date) -> [String] {
        names.filter { name in parse(name).map { now.timeIntervalSince($0.date) > maxAge } ?? false }
    }

    /// The newest file from another Mac that this Mac has not already taken, if it is still fresh.
    static func newestForMe(_ names: [String], myID: String, after seen: Date, now: Date) -> String? {
        names.compactMap { name -> (String, Date)? in
            guard let p = parse(name), p.deviceID != myID, p.date > seen, now.timeIntervalSince(p.date) <= maxAge else { return nil }
            return (name, p.date)
        }.max { $0.1 < $1.1 }?.0
    }

    /// Whether text is fine to send: not empty, not huge.
    static func isSendable(_ text: String?) -> Bool {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return text.utf8.count <= maxBytes
    }

    static func preview(_ text: String) -> String {
        let one = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return one.count > 50 ? String(one.prefix(50)) + "…" : one
    }
}
