import Foundation

/// When the drag tools' own handler has to be on the event tap.
enum DragToolsActivation {
    /// Whether any drag tool is switched on, auto-scroll included.
    static func needsEvents(_ c: DragToolsConfig) -> Bool {
        c.scrollEnabled || c.autoScrollEnabled || c.followModifier != 0 || !c.doubleClicks.isEmpty || !c.buttonScrolls.isEmpty
    }

    /// The handler runs only when a tool needs it, Input Monitoring is allowed, safe mode is off and Mouse & Trackpad itself is on.
    static func shouldRun(_ c: DragToolsConfig, inputMonitoring: Bool, safeMode: Bool, mouseOn: Bool) -> Bool {
        needsEvents(c) && inputMonitoring && !safeMode && mouseOn
    }
}

/// The layers a mouse button can be claimed by, in the order they win.
enum InputLayer: Int, CaseIterable, Comparable {
    case excluded, dragCapture, gesture, hold, doubleClick, buttonRule, native

    static func < (a: InputLayer, b: InputLayer) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .excluded: return "An app left alone"
        case .dragCapture: return "Drag to scroll, auto-scroll, or a held button with the wheel"
        case .gesture: return "A button gesture"
        case .hold: return "A hold rule"
        case .doubleClick: return "A double-click rule"
        case .buttonRule: return "A button rule"
        case .native: return "What macOS does"
        }
    }
}

/// Which layers want a given button press (with the keys held).
struct ButtonClaims: Equatable {
    var excluded = false
    var dragCapture = false
    var gesture = false
    var hold = false
    var doubleClick = false
    var click = false
}

enum InputPrecedence {
    /// The one that wins: the first layer, in order, that wants the press. Nothing wanting it leaves it to macOS.
    static func winner(_ c: ButtonClaims) -> InputLayer {
        if c.excluded { return .excluded }
        if c.dragCapture { return .dragCapture }
        if c.gesture { return .gesture }
        if c.hold { return .hold }
        if c.doubleClick { return .doubleClick }
        if c.click { return .buttonRule }
        return .native
    }

    /// Whether a double-click rule may act: nothing earlier in the order wants the same button and keys.
    static func doubleClickMayAct(_ c: ButtonClaims) -> Bool {
        var claims = c
        claims.doubleClick = true
        return winner(claims) == .doubleClick
    }
}

/// Button rules that repeat an earlier one.
enum ButtonRuleCheck {
    /// The positions of rules that use the same button, keys and trigger as an earlier rule. The earlier rule is the one that runs.
    static func shadowed(_ rules: [ButtonRule]) -> Set<Int> {
        var seen = Set<String>()
        var result = Set<Int>()
        for (index, rule) in rules.enumerated() {
            let key = "\(rule.button)/\(rule.modifiers)/\(rule.trigger == .hold ? "hold" : "click")"
            if !seen.insert(key).inserted { result.insert(index) }
        }
        return result
    }
}

/// Deciding which device an event came from, from when each device was last active.
enum DeviceAttribution {
    enum Result: Equatable {
        case device(String)
        /// Two devices were active within the window: which one this event is from cannot be told.
        case ambiguous
        case none
    }

    /// `ages` is how long ago, in nanoseconds, each device was last active. Devices older than `maxAge` do not count.
    static func resolve(ages: [String: UInt64], maxAge: UInt64) -> Result {
        let recent = ages.filter { $0.value <= maxAge }
        switch recent.count {
        case 0: return .none
        case 1: return .device(recent.keys.first!)
        default: return .ambiguous
        }
    }
}

/// Whether the drag tools use a given button (with the keys held), so a button rule on the same button can say it will be taken first.
extension DragToolsActivation {
    static func uses(_ c: DragToolsConfig, button: UInt32, modifiers: UInt64) -> Bool {
        (c.scrollEnabled && c.scrollButton == button && c.scrollModifier == modifiers)
            || (c.autoScrollEnabled && c.autoScrollButton == button && c.autoScrollModifier == modifiers)
            || c.buttonScrolls.contains { $0.button == button }
    }
}

/// A button held on one device. Two devices can hold the same button at once, so the button alone is not enough to tell them apart.
struct HeldKey: Hashable {
    var device: String
    var button: UInt32
}

/// The buttons being held, by device. A release is matched to its own device's press; if the device was named differently on the way
/// up (the guess about which device an event came from can change between a press and its release), it is matched to any press of that
/// button, so a press is never left waiting for a release that already happened.
struct DeviceButtonSet {
    private var held: [HeldKey: Int] = [:]
    private var counter = 0

    var isEmpty: Bool { held.isEmpty }

    mutating func insert(button: UInt32, device: String) {
        counter += 1
        held[HeldKey(device: device, button: button)] = counter
    }

    /// Takes away the release's press. True if there was one.
    mutating func remove(button: UInt32, device: String) -> Bool {
        if held.removeValue(forKey: HeldKey(device: device, button: button)) != nil { return true }
        // The oldest press of this button on any device.
        guard let match = held.filter({ $0.key.button == button }).min(by: { $0.value < $1.value })?.key else { return false }
        held.removeValue(forKey: match)
        return true
    }

    mutating func removeAll() { held.removeAll() }
}

/// What each missing permission is needed for, in Mouse & Trackpad's own words.
enum MousePermissionNote {
    static func purpose(_ permission: Permission) -> String? {
        switch permission {
        case .inputMonitoring: return "to see button presses, scrolling and movement (scroll and button settings, gestures, drag tools)"
        case .accessibility: return "to move windows with the pointer and to act on other apps' windows"
        default: return nil
        }
    }

    /// One line for the banner: every permission that is missing and what it is for.
    static func message(missing: [Permission]) -> String {
        let parts = missing.compactMap { permission in purpose(permission).map { "\(permission.title) \($0)" } }
        guard !parts.isEmpty else { return "Your changes are saved, but they only take effect while the feature is on and allowed." }
        return "Your changes are saved. Still needed: " + parts.joined(separator: "; ") + "."
    }
}
