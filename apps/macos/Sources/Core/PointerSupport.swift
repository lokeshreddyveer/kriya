import CoreGraphics
import Foundation

/// Why the pointer is hidden. It comes back only when none of the reasons is left.
enum PointerHideReason: Hashable {
    /// It has been still for a while.
    case idle
    /// The person is typing.
    case typing
    /// The person asked for it with the "Hide the pointer" command.
    case manual
}

/// Which reasons are hiding the pointer. The window server counts every hide, so each hide is matched with one show: this says when.
struct PointerHideState: Equatable {
    private(set) var reasons: Set<PointerHideReason> = []

    var isHidden: Bool { !reasons.isEmpty }

    /// Adds a reason. True when this is the first one, so the pointer must be hidden now.
    mutating func add(_ reason: PointerHideReason) -> Bool {
        let wasHidden = isHidden
        reasons.insert(reason)
        return !wasHidden
    }

    /// Takes a reason away. True when it was the last one, so the pointer must be shown now.
    mutating func remove(_ reason: PointerHideReason) -> Bool {
        let wasHidden = isHidden
        reasons.remove(reason)
        return wasHidden && !isHidden
    }

    /// Takes every reason away (the mouse moved). True if the pointer was hidden and must be shown.
    mutating func removeAll() -> Bool {
        let wasHidden = isHidden
        reasons.removeAll()
        return wasHidden
    }
}

/// A saved position's display, remembered by the display's own identity as well as its place in the row, because the place changes when
/// a monitor is unplugged or rearranged and the identity does not.
struct RememberedDisplay: Codable, Equatable {
    var id: String
    var name: String
}

enum PointerPositionResolver {
    enum Choice: Equatable {
        /// The display at this place in the left-to-right order.
        case display(Int)
        /// The display the pointer is on now.
        case pointerDisplay
        /// The position was saved for a display that is not connected: the display the pointer is on is used instead.
        case missing
    }

    /// Which display a saved position lands on. `index` is where it was in the left-to-right order when saved; `remembered` is the
    /// display it was saved for; `connected` is the unique names of the displays now, left to right.
    static func resolve(index: UInt32?, remembered: RememberedDisplay?, connected: [String]) -> Choice {
        guard let index else { return .pointerDisplay }
        if let remembered {
            // Found by identity wherever it is now, never by a place that may belong to a different monitor.
            if let found = connected.firstIndex(of: remembered.id) { return .display(found) }
            return .missing
        }
        // Saved before displays were remembered: the place is all there is.
        return Int(index) < connected.count ? .display(Int(index)) : .missing
    }

    /// What to say under a saved position.
    static func describe(index: UInt32?, remembered: RememberedDisplay?, connected: [String]) -> String {
        switch resolve(index: index, remembered: remembered, connected: connected) {
        case .pointerDisplay: return "The display the pointer is on"
        case .display(let place):
            if let remembered { return "\(remembered.name) (display \(place + 1))" }
            return "Display \(place + 1)"
        case .missing:
            if let remembered { return "\(remembered.name) is not connected: the display the pointer is on is used" }
            return "Display \((index ?? 0) + 1) is not connected: the display the pointer is on is used"
        }
    }
}

enum MagnifierGeometry {
    /// The size of the captured picture in pixels, for a window `points` wide on a display with this scale.
    static func pixels(points: Double, scale: Double) -> Int {
        max(Int((points * max(scale, 1)).rounded()), 1)
    }
}

/// What to tell the person about a shortcut the pane records.
enum PointerShortcutNote {
    /// Nil when the shortcut is fine (or there is none). Otherwise a sentence saying it is off and who else uses the keys.
    static func message(entry: ShortcutEntry?, others: [ShortcutEntry]) -> String? {
        guard let entry, entry.status == .refused else { return nil }
        let owners = others.filter { $0.id != entry.id }.map { "\($0.owner): \($0.title)" }
        if owners.isEmpty { return "These keys are not working: macOS or another app already uses them." }
        return "These keys are not working: they are also used by " + owners.joined(separator: ", ") + "."
    }
}
