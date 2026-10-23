import Foundation

/// "If I press this button, what happens?" worked out from a preset's settings alone.
enum RuleSimulator {
    struct Result: Equatable {
        enum Outcome: Equatable { case runs(actionID: String), nothing, ambiguous(actionIDs: [String]) }
        let outcome: Outcome
        /// Things worth knowing about, in words.
        let notes: [String]
    }

    static func simulate(_ settings: MouseSettings, button: UInt32, modifiers: UInt64, held: Bool, actionName: (String) -> String) -> Result {
        var notes: [String] = []
        let wanted: ButtonTrigger = held ? .hold : .click
        let exact = settings.buttons.filter { $0.button == button && $0.modifiers == modifiers && $0.trigger == wanted }
        if settings.gestures.enabled && settings.gestures.activationButton == button && modifiers == 0 {
            notes.append("This button starts a swipe gesture, so a plain press may be taken by the gesture before a click rule sees it.")
        }
        if !held, settings.buttons.contains(where: { $0.button == button && $0.modifiers == modifiers && $0.trigger == .hold }) {
            notes.append("A hold rule also uses this button: let go within \(settings.holdMs) ms and it counts as a click.")
        }
        if held, !exact.isEmpty { notes.append("It runs after the button has been held for \(settings.holdMs) ms.") }
        if exact.count > 1 {
            return Result(outcome: .ambiguous(actionIDs: exact.map(\.actionId)), notes: notes + ["Two rules use this exact button. The first in the list is used: “\(actionName(exact[0].actionId))”."])
        }
        if let rule = exact.first { return Result(outcome: .runs(actionID: rule.actionId), notes: notes) }
        let otherModifiers = settings.buttons.filter { $0.button == button && $0.modifiers != modifiers && $0.trigger == wanted }
        if !otherModifiers.isEmpty { notes.append("This button has a rule with different modifier keys held, but not with these.") }
        return Result(outcome: .nothing, notes: notes + ["No rule uses this. The button does what macOS does with it."])
    }
}

/// Settings for pointer effects chosen as a whole for a situation.
enum PointerProfile: String, CaseIterable, Identifiable {
    case presentation, teaching, recording, accessibility
    var id: String { rawValue }

    var title: String {
        switch self {
        case .presentation: return "Presentation"
        case .teaching: return "Teaching"
        case .recording: return "Recording"
        case .accessibility: return "Accessibility"
        }
    }

    var summary: String {
        switch self {
        case .presentation: return "Big halo, click rings, visible to the audience."
        case .teaching: return "Halo and click rings, shown on a shared screen."
        case .recording: return "Click rings only, kept in the recording."
        case .accessibility: return "A large, strong halo that is easy to follow."
        }
    }

    func apply(to c: inout PointerEffectsConfig) {
        c.enabled = true
        switch self {
        case .presentation:
            c.haloEnabled = true; c.haloSize = 96; c.haloOpacity = 0.4; c.haloPulse = false
            c.clickEnabled = true; c.clickSize = 72; c.clickDurationMs = 600
            c.showWhenSharing = true; c.hideWhenIdle = false
        case .teaching:
            c.haloEnabled = true; c.haloSize = 72; c.haloOpacity = 0.35; c.haloPulse = false
            c.clickEnabled = true; c.clickSize = 64; c.clickDurationMs = 500
            c.showWhenSharing = true; c.hideWhenIdle = false
        case .recording:
            c.haloEnabled = false
            c.clickEnabled = true; c.clickSize = 60; c.clickDurationMs = 450
            c.showWhenSharing = true; c.hideWhenIdle = false
        case .accessibility:
            c.haloEnabled = true; c.haloSize = 120; c.haloOpacity = 0.55; c.haloPulse = true
            c.clickEnabled = true; c.clickSize = 80; c.clickDurationMs = 700
            c.showWhenSharing = false; c.hideWhenIdle = false; c.hideWhileTyping = false
        }
    }
}

/// When devices came and went, and how steady each one is.
struct DeviceTimeline: Codable, Equatable {
    struct Event: Codable, Equatable, Identifiable {
        var id = UUID().uuidString
        let at: Date
        let device: String
        let connected: Bool
    }

    var events: [Event] = []
    static let limit = 300

    mutating func record(_ device: String, connected: Bool, at: Date) {
        events.insert(Event(at: at, device: device, connected: connected), at: 0)
        if events.count > Self.limit { events.removeLast(events.count - Self.limit) }
    }

    func events(for device: String) -> [Event] { events.filter { $0.device == device } }

    /// 100 for a device that stays put, less for each time it dropped off in the last day. Nil with no history.
    func health(of device: String, now: Date) -> Int? {
        let recent = events(for: device).filter { now.timeIntervalSince($0.at) <= 86_400 }
        guard !events(for: device).isEmpty else { return nil }
        let drops = recent.filter { !$0.connected }.count
        return max(100 - drops * 15, 0)
    }

    static func describe(health: Int) -> String {
        switch health {
        case 85...: return "Steady"
        case 55..<85: return "Dropped off a few times today"
        default: return "Keeps disconnecting"
        }
    }
}
