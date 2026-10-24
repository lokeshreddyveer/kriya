import Foundation

/// A keyboard that is connected, by something that stays the same when its name does not.
struct KeyboardDevice: Equatable, Hashable, Identifiable {
    var id: String
    var name: String

    /// Made from what the keyboard reports: who made it, which model, and its serial number when it has one. Two keyboards of one model
    /// without serial numbers look alike; a rule for that model then covers both, and the pane says so.
    static func identity(vendor: Int, product: Int, serial: String?) -> String {
        let trimmed = serial?.trimmingCharacters(in: .whitespaces) ?? ""
        return "kb:\(String(vendor, radix: 16)):\(String(product, radix: 16))" + (trimmed.isEmpty ? "" : ":\(trimmed)")
    }
}

enum KeyboardRuleMatch {
    /// Whether a rule limited to one keyboard is in force. A rule saved with the keyboard's name (before keyboards had their own
    /// identity) still works while a keyboard of that name is connected. A rule for no keyboard is always in force.
    static func applies(rule keyboard: String?, connected: [KeyboardDevice]) -> Bool {
        guard let keyboard, !keyboard.isEmpty else { return true }
        return connected.contains { $0.id == keyboard || $0.name == keyboard }
    }

    /// What to call the keyboard a rule is limited to: its current name, the name remembered for it, or the saved text.
    static func title(for keyboard: String, connected: [KeyboardDevice], remembered: [String: String]) -> String {
        if let live = connected.first(where: { $0.id == keyboard }) { return live.name }
        if let name = remembered[keyboard] { return name }
        return keyboard.hasPrefix("kb:") ? "A keyboard that is not connected" : keyboard
    }

    /// Several connected keyboards that cannot be told apart (same model, no serial number).
    static func lookAlikes(_ connected: [KeyboardDevice]) -> Set<String> {
        let counts = Dictionary(grouping: connected, by: \.id).mapValues(\.count)
        return Set(counts.filter { $0.value > 1 }.keys)
    }
}

/// What looking at the focused field showed.
enum FieldCheck: Equatable {
    /// The system would not say what has the focus: no Accessibility permission, an app that refuses, a field that hides its kind.
    case unavailable
    case secureField
    case describedAsPassword
    case ordinary
}

enum ExpansionSafety {
    enum Verdict: Equatable {
        case allow
        case deny(Reason)
    }

    enum Reason: Equatable {
        case secureInput, excludedApp, passwordField
        /// Kriya could not tell what kind of field this is, and the app is not one the person said to trust.
        case cannotInspect
    }

    /// Whether text may be replaced here. When the field cannot be inspected the answer is no, unless the person trusted this app
    /// for exactly that case: a password box that cannot be recognised must never be typed into by a guess.
    static func verdict(secureInput: Bool, appExcluded: Bool, field: FieldCheck, appTrusted: Bool) -> Verdict {
        if secureInput { return .deny(.secureInput) }
        if appExcluded { return .deny(.excludedApp) }
        switch field {
        case .secureField, .describedAsPassword: return .deny(.passwordField)
        case .unavailable: return appTrusted ? .allow : .deny(.cannotInspect)
        case .ordinary: return .allow
        }
    }

    static func message(for reason: Reason, app: String) -> String {
        switch reason {
        case .secureInput: return "macOS is protecting keyboard input, so Kriya cannot expand text."
        case .excludedApp: return "\(app) is on the list of apps where text is never expanded."
        case .passwordField: return "This looks like a password field, so nothing was expanded."
        case .cannotInspect: return "Text was not expanded in \(app): Kriya cannot tell what kind of field this is. If you type ordinary text there, allow it in Expansion."
        }
    }
}

/// Which keyboard behaviours are paused. A pause is for the moment and is gone when Kriya restarts.
struct KeyboardPauseState: Equatable {
    var remaps = false
    var expansion = false
    var shortcuts = false

    var isAnyPaused: Bool { remaps || expansion || shortcuts }
    var isAllPaused: Bool { remaps && expansion && shortcuts }

    /// All paused, or, if they all were, all running again.
    mutating func toggleAll() {
        let target = !isAllPaused
        remaps = target; expansion = target; shortcuts = target
    }

    var summary: String {
        let parts = [remaps ? "remapping" : nil, expansion ? "text expansion" : nil, shortcuts ? "shortcuts" : nil].compactMap { $0 }
        return parts.isEmpty ? "Nothing is paused" : "Paused: " + parts.joined(separator: ", ")
    }
}
