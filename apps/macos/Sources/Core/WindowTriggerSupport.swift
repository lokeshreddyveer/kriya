import Foundation

/// A key pressed twice quickly on its own, such as Option Option, that runs a command.
struct ModifierTap: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    /// shift, control, option, command or fn.
    var modifier: String
    var command: String

    static let modifiers: [(id: String, title: String)] = [("shift", "Shift"), ("control", "Control"), ("option", "Option"), ("command", "Command"), ("fn", "Fn")]
    static let maxCount = 10
}

/// Finds a double-tap of one modifier key in the stream of "these modifiers are down now" and "a key was pressed" events. A tap
/// is the modifier going down and up again, alone, within a short time with no other key between; two taps close together fire.
struct ModifierTapDetector {
    var tapLimit: TimeInterval = 0.30
    var gapLimit: TimeInterval = 0.45
    private var downAt: [String: TimeInterval] = [:]
    private var lastTap: (modifier: String, at: TimeInterval)?
    private var previous: Set<String> = []
    private var dirty = false

    /// The modifiers held now. Returns the modifier that was just double-tapped, if any.
    mutating func flagsChanged(_ held: Set<String>, at time: TimeInterval) -> String? {
        defer { previous = held }
        let added = held.subtracting(previous), removed = previous.subtracting(held)
        if held.count > 1 || (!added.isEmpty && !previous.isEmpty) { dirty = true; lastTap = nil }
        if let down = added.first, held.count == 1 { downAt[down] = time; dirty = false }
        guard let up = removed.first, held.isEmpty, let start = downAt[up] else { return nil }
        downAt[up] = nil
        guard !dirty, time - start <= tapLimit else { lastTap = nil; return nil }
        if let last = lastTap, last.modifier == up, time - last.at <= gapLimit {
            lastTap = nil
            return up
        }
        lastTap = (up, time)
        return nil
    }

    /// Any other key in between means it was a shortcut, not a tap.
    mutating func keyPressed() { dirty = true; lastTap = nil }
}

/// Run a command when an app opens or comes to the front: put its window where it belongs.
struct AppLayoutTrigger: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var appID: String
    /// A window command such as window.left_half, window.size.<id> or window.layout.<id>.
    var command: String
    var when: When

    enum When: String, Codable, CaseIterable, Identifiable {
        case launch, firstActivation, everyActivation
        var id: String { rawValue }
        var title: String {
            switch self {
            case .launch: return "When it opens"
            case .firstActivation: return "The first time it comes forward after opening"
            case .everyActivation: return "Every time it comes forward"
            }
        }
    }

    static let maxCount = 40

    /// Which triggers fire for this event. `isFirstActivation` is true the first time an app comes forward after it launched.
    static func firing(_ triggers: [AppLayoutTrigger], appID: String, launched: Bool, isFirstActivation: Bool) -> [AppLayoutTrigger] {
        triggers.filter { trigger in
            guard trigger.appID == appID else { return false }
            switch trigger.when {
            case .launch: return launched
            case .firstActivation: return !launched && isFirstActivation
            case .everyActivation: return !launched
            }
        }
    }
}

/// How the pointer wraps around the edges of the screens.
enum PointerWrapMode: String, CaseIterable, Identifiable {
    case off, horizontal, both
    var id: String { rawValue }
    var title: String {
        switch self { case .off: return "Off"; case .horizontal: return "Left and right"; case .both: return "All four edges" }
    }

    /// Where the pointer should jump to, if it has run into an edge of the area all displays cover; nil if it should stay.
    static func wrapped(_ point: (x: Double, y: Double), moving delta: (dx: Double, dy: Double), area: (minX: Double, minY: Double, maxX: Double, maxY: Double), mode: PointerWrapMode) -> (x: Double, y: Double)? {
        guard mode != .off else { return nil }
        let edge = 1.0, inset = 3.0
        if delta.dx < 0, point.x <= area.minX + edge { return (area.maxX - inset, point.y) }
        if delta.dx > 0, point.x >= area.maxX - edge { return (area.minX + inset, point.y) }
        guard mode == .both else { return nil }
        if delta.dy < 0, point.y <= area.minY + edge { return (point.x, area.maxY - inset) }
        if delta.dy > 0, point.y >= area.maxY - edge { return (point.x, area.minY + inset) }
        return nil
    }
}


enum WindowThrow {
    /// The window slid to an edge or corner of the area, keeping its size, `gap` in from the edge. -1 is left or up, 1 right or down.
    static func frame(current: Rect, area: Rect, gap: Double, dx: Int, dy: Int) -> Rect {
        var frame = current
        if dx < 0 { frame.x = area.x + gap } else if dx > 0 { frame.x = area.x + area.width - current.width - gap }
        if dy < 0 { frame.y = area.y + gap } else if dy > 0 { frame.y = area.y + area.height - current.height - gap }
        frame.x = max(frame.x, area.x)
        frame.y = max(frame.y, area.y)
        return frame
    }
}


enum WindowReflow {
    /// The part of the area that is left beside a window snapped to one side or to the top or bottom, or nil if the window is not
    /// snapped to a side (so there is no clear space to fill).
    static func remaining(anchor: Rect, area: Rect, gap: Double) -> Rect? {
        let tolerance = 6.0, minimum = 80.0
        let fullHeight = anchor.height >= area.height * 0.85, fullWidth = anchor.width >= area.width * 0.85
        let left = anchor.x <= area.x + tolerance, right = anchor.x + anchor.width >= area.x + area.width - tolerance
        let top = anchor.y <= area.y + tolerance, bottom = anchor.y + anchor.height >= area.y + area.height - tolerance
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Rect? { w >= minimum && h >= minimum ? Rect(x: x, y: y, width: w, height: h) : nil }
        if fullHeight, left, !right { return rect(anchor.x + anchor.width + gap, area.y, area.x + area.width - (anchor.x + anchor.width + gap), area.height) }
        if fullHeight, right, !left { return rect(area.x, area.y, anchor.x - gap - area.x, area.height) }
        if fullWidth, top, !bottom { return rect(area.x, anchor.y + anchor.height + gap, area.width, area.y + area.height - (anchor.y + anchor.height + gap)) }
        if fullWidth, bottom, !top { return rect(area.x, area.y, area.width, anchor.y - gap - area.y) }
        return nil
    }
}


/// A menu item of an app, kept so it can be run from the pointer menu without opening the app's own menus.
struct AppMenuFavorite: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var appID: String
    /// The titles from the menu bar down: ["Edit", "Find", "Find Next"].
    var path: [String]

    var title: String { path.last ?? "" }
    var detail: String { path.dropLast().joined(separator: " › ") }

    static let maxCount = 60

    /// Adds the item, or takes it off if it is already there.
    static func toggled(appID: String, path: [String], in list: [AppMenuFavorite]) -> [AppMenuFavorite] {
        if list.contains(where: { $0.appID == appID && $0.path == path }) { return list.filter { !($0.appID == appID && $0.path == path) } }
        guard !path.isEmpty, list.count < maxCount else { return list }
        return list + [AppMenuFavorite(appID: appID, path: path)]
    }
}
