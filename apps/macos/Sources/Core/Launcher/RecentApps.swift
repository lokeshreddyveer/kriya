import Foundation

/// The apps used lately, most recent first, kept so the launcher can offer them when the box is empty.
struct RecentApps: Codable, Equatable {
    static let capacity = 15

    private(set) var ids: [String] = []

    /// Notes that an app came to the front. Kriya itself and Finder's desktop-only helpers are not kept.
    mutating func record(_ bundleID: String?, ignoring ignored: Set<String> = []) {
        guard let bundleID, !bundleID.isEmpty, !ignored.contains(bundleID) else { return }
        ids.removeAll { $0 == bundleID }
        ids.insert(bundleID, at: 0)
        if ids.count > Self.capacity { ids.removeLast(ids.count - Self.capacity) }
    }

    mutating func remove(_ bundleID: String) { ids.removeAll { $0 == bundleID } }

    /// The most recent few, leaving out the app in front (it is already there) when asked.
    func recent(_ limit: Int, excluding front: String? = nil) -> [String] {
        Array(ids.filter { $0 != front }.prefix(limit))
    }
}
