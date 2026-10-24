import Foundation

/// Which sound output (or input) to use as devices come and go. The person puts devices in order of preference; when the one in use
/// goes away, the best one that is still connected takes over, and when a better one comes back, it can take over again. It acts only
/// when the set of connected devices changes, never in between, so a device the person chose by hand is left alone.
enum DevicePolicy {
    struct Reaction: Equatable {
        var switchTo: String
        var why: Why
        enum Why: Equatable { case inUseWentAway, preferredReturned }
    }

    /// What to do after the connected devices changed from `previous` to `now`. `current` is the device that was in use before the change.
    static func reaction(previous: Set<String>, now: Set<String>, current: String?, priority: [String], switchBack: Bool) -> Reaction? {
        if let current, previous.contains(current), !now.contains(current) {
            // The device in use is gone: the best one left, if the person ranked any of them. Otherwise macOS has chosen and that stands.
            return best(among: now, priority: priority).map { Reaction(switchTo: $0, why: .inUseWentAway) }
        }
        guard switchBack else { return nil }
        let arrived = now.subtracting(previous)
        guard !arrived.isEmpty else { return nil }
        let currentRank = current.flatMap { priority.firstIndex(of: $0) } ?? Int.max
        let better = arrived.compactMap { uid in priority.firstIndex(of: uid).map { (uid: uid, rank: $0) } }.filter { $0.rank < currentRank }
        return better.min { $0.rank < $1.rank }.map { Reaction(switchTo: $0.uid, why: .preferredReturned) }
    }

    /// The first device in the order of preference that is connected.
    static func best(among connected: Set<String>, priority: [String]) -> String? { priority.first { connected.contains($0) } }

    // MARK: Devices that come back under another unique name

    /// Some devices (Bluetooth, HDMI and aggregates especially) come back with a new unique name. A ranked device that is not
    /// connected, whose saved device name matches exactly one connected device that is not in the list, is taken to be that device:
    /// it keeps its place. Two candidates, or none, change nothing, so a guess is never made between two similar devices.
    /// `savedNames` and `connectedNames` map unique names to the device's own name.
    static func migrate(_ list: [String], savedNames: [String: String], connectedNames: [String: String]) -> [String] {
        var result = list
        for (index, uid) in list.enumerated() where connectedNames[uid] == nil {
            guard let name = savedNames[uid], !name.isEmpty else { continue }
            let candidates = connectedNames.filter { $0.value == name && !result.contains($0.key) }.map(\.key)
            if candidates.count == 1 { result[index] = candidates[0] }
        }
        return result
    }

    // MARK: Keeping the list

    /// The list with `uid` added at the end (once).
    static func adding(_ uid: String, to list: [String]) -> [String] { list.contains(uid) ? list : list + [uid] }

    static func removing(_ uid: String, from list: [String]) -> [String] { list.filter { $0 != uid } }

    /// The list with `uid` moved up (negative) or down (positive) by `offset` places, staying inside the list.
    static func moving(_ uid: String, by offset: Int, in list: [String]) -> [String] {
        guard let from = list.firstIndex(of: uid) else { return list }
        let to = min(max(from + offset, 0), list.count - 1)
        guard to != from else { return list }
        var next = list
        next.remove(at: from)
        next.insert(uid, at: to)
        return next
    }

    /// Where a device ranks (1 is best), or nil if it is not in the list.
    static func rank(of uid: String, in list: [String]) -> Int? { list.firstIndex(of: uid).map { $0 + 1 } }
}
