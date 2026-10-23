import Foundation

/// What the window-button rules change compared with what macOS does, in plain words.
enum TrafficInsight {
    struct Note: Equatable, Identifiable {
        let id: String
        let text: String
        /// True when a click that normally works is now taken over or disabled.
        let replacesNative: Bool
    }

    static func buttonName(_ b: TrafficButton) -> String {
        switch b { case .close: return "red"; case .minimize: return "yellow"; case .zoom: return "green" }
    }

    /// What macOS does with the button when it is clicked with these keys.
    static func nativeBehavior(_ button: TrafficButton, modifiers: UInt64) -> String {
        switch (button, modifiers) {
        case (.close, 0): return "closes the window"
        case (.close, KeyModifiers.option): return "closes all of the app's windows"
        case (.minimize, 0): return "minimizes the window"
        case (.minimize, KeyModifiers.option): return "minimizes all of the app's windows"
        case (.zoom, 0): return "enters full screen"
        case (.zoom, KeyModifiers.option): return "zooms the window (not full screen)"
        default: return "does the normal thing"
        }
    }

    static func notes(for bindings: [TrafficBinding]) -> [Note] {
        bindings.compactMap { binding in
            guard binding.action != .native else { return nil }
            let keys = binding.modifiers == 0 ? "A plain click" : "\(KeyModifiers.glyphs(for: binding.modifiers)) click"
            let native = nativeBehavior(binding.button, modifiers: binding.modifiers)
            let now = binding.action == .doNothing ? "does nothing" : binding.action.title.lowercased()
            return Note(id: "\(binding.button)|\(binding.modifiers)", text: "\(keys) on the \(buttonName(binding.button)) button now \(now). macOS \(native).", replacesNative: true)
        }
    }

    /// Two bindings on the same button and keys: only the first can run.
    static func duplicates(_ bindings: [TrafficBinding]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for b in bindings {
            let key = "\(b.button)|\(b.modifiers)"
            if !seen.insert(key).inserted { out.append("The \(buttonName(b.button)) button has two rules for the same keys; only the first is used.") }
        }
        return out
    }

    /// What a double-click on the title bar does now, against macOS's own.
    static func titleBarNote(_ action: TrafficAction) -> String? {
        action == .native ? nil : "Double-clicking a title bar now: \(action.title.lowercased()). macOS would zoom or minimize, as set in System Settings."
    }
}
