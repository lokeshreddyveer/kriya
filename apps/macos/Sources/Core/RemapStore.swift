import Combine
import Foundation

/// Settings for key remapping: tap or hold keys, a Hyper key, double taps and keys pressed together.
final class RemapStore: ObservableObject {
    @Published private(set) var config = RemapConfig(enabled: false, rules: [], holdMs: 200, doubleTapMs: 250, chordMs: 50)
    @Published var lastError: String?

    private let core: KriyaCore
    private let lock = NSLock()
    private var snapshot: RemapConfig?      // guarded by lock

    init(core: KriyaCore) {
        self.core = core
        reload()
    }

    func reload() {
        do {
            config = try core.remapConfig()
        } catch {
            Log.error("Remap", "Could not load key remapping: \(error.userMessage)")
        }
        lock.lock()
        snapshot = config
        lock.unlock()
    }

    var current: RemapConfig {
        lock.lock()
        defer { lock.unlock() }
        return snapshot ?? config
    }

    func update(_ change: (inout RemapConfig) -> Void) {
        var next = config
        change(&next)
        do {
            try core.saveRemapConfig(config: next)
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
        reload()
    }

    func upsert(_ rule: RemapRule) {
        update { config in
            if let index = config.rules.firstIndex(where: { $0.id == rule.id }) { config.rules[index] = rule } else { config.rules.append(rule) }
        }
    }

    func delete(_ id: String) { update { $0.rules.removeAll { $0.id == id } } }

    /// Caps Lock is turned into an ordinary key (F18) by the system helper while a rule uses it.
    var usesCapsLock: Bool {
        let config = current
        return config.enabled && config.rules.contains { $0.enabled && ($0.keyCode == RemapKeys.capsLock || $0.chordWith.contains(RemapKeys.capsLock)) }
    }
}

enum RemapKeys {
    /// Caps Lock arrives as F18 once the system helper has swapped them.
    static let capsLock: UInt16 = 79
    static let escape: UInt16 = 53
    static let hyper: UInt64 = KeyModifiers.control | KeyModifiers.option | KeyModifiers.shift | KeyModifiers.command

    /// The keys that can be remapped without recording them.
    static let common: [(title: String, code: UInt16)] = [
        ("Caps Lock", 79), ("Right ⌘", 54), ("Right ⌥", 61), ("Right ⌃", 62), ("Right ⇧", 60), ("Fn", 63),
        ("Left ⌘", 55), ("Left ⌥", 58), ("Left ⌃", 59), ("Esc", 53), ("Tab", 48), ("Return", 36), ("Space", 49),
    ] + media

    /// Media keys have no key code of their own; they are 1000 plus the number the system gives them.
    static let media: [(title: String, code: UInt16)] = [
        ("Play / Pause", 1016), ("Next track", 1017), ("Previous track", 1018), ("Volume up", 1000), ("Volume down", 1001),
        ("Mute", 1007), ("Brightness up", 1002), ("Brightness down", 1003),
    ]

    static func name(_ code: UInt16) -> String {
        if let match = common.first(where: { $0.code == code }) { return match.title }
        return KeyNames.describe(keyCode: code, modifiers: 0)
    }

    static func describe(_ output: RemapOutput?) -> String {
        switch output {
        case .none: return "Nothing"
        case .some(.key(let code, let mods)): return KeyNames.describe(keyCode: code, modifiers: mods)
        case .some(.modifiers(let mods)):
            if mods == hyper { return "Hyper (⌃⌥⇧⌘)" }
            var text = ""
            if mods & KeyModifiers.control != 0 { text += "⌃" }
            if mods & KeyModifiers.option != 0 { text += "⌥" }
            if mods & KeyModifiers.shift != 0 { text += "⇧" }
            if mods & KeyModifiers.command != 0 { text += "⌘" }
            return text.isEmpty ? "Nothing" : text + " held"
        case .some(.action): return "A saved action"
        case .some(.nothing): return "Nothing (key disabled)"
        }
    }

    static func summary(_ rule: RemapRule) -> String {
        var parts: [String] = []
        if !rule.chordWith.isEmpty {
            parts.append(([rule.keyCode] + rule.chordWith).map(name).joined(separator: " + ") + " together → " + describe(rule.tap))
            return parts.joined()
        }
        if let tap = rule.tap { parts.append((rule.hold == nil && rule.doubleTap == nil ? "" : "tap ") + "→ " + describe(tap)) }
        if let hold = rule.hold { parts.append("hold → " + describe(hold)) }
        if let double = rule.doubleTap { parts.append("double-tap → " + describe(double)) }
        return name(rule.keyCode) + " " + parts.joined(separator: ", ")
    }
}
