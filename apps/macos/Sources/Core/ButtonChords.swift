import Foundation

// MARK: - The chord

/// When in the life of the last button pressed a chord fires.
enum ButtonPhase: String, Codable, CaseIterable, Identifiable {
    /// As the last button of the chord goes down.
    case down
    /// As any button of the chord comes up, while the chord is still complete.
    case up
    /// Down and up again quickly, with the rest of the chord held.
    case click
    case doubleClick
    /// Held without moving for the hold time.
    case hold
    /// Moved while the chord is held.
    case drag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .down: return "Pressed"
        case .up: return "Released"
        case .click: return "Clicked"
        case .doubleClick: return "Double-clicked"
        case .hold: return "Held"
        case .drag: return "Dragged"
        }
    }
}

/// Mouse buttons held together, with keys held as well, doing something at one point of the press. Buttons are numbered as the system
/// does: 0 left, 1 right, 2 middle, 3 and up the side buttons. A chord of one button is an ordinary button rule, so it is not valid here.
struct ButtonChord: Codable, Hashable {
    var pressedButtons: Set<UInt32>
    var modifiers: UInt64
    var phase: ButtonPhase

    static let sizeRange = 2...4
    static let lastButton: UInt32 = 31

    var isValid: Bool { Self.sizeRange.contains(pressedButtons.count) && pressedButtons.allSatisfy { $0 <= Self.lastButton } }

    var title: String {
        let names = pressedButtons.sorted().map(ButtonChord.name)
        return names.joined(separator: " + ") + " " + phase.title.lowercased()
    }

    static func name(_ button: UInt32) -> String {
        switch button {
        case 0: return "Left"
        case 1: return "Right"
        case 2: return "Middle"
        default: return "Button \(button + 1)"
        }
    }
}

/// A chord and what it runs.
struct ButtonChordRule: Codable, Hashable, Identifiable {
    var id = UUID()
    var chord: ButtonChord
    var actionId: String

    /// A chord with the left or right button and no keys would hold back every ordinary click, so it is never run. (The conflict list says so.)
    var isSafe: Bool { chord.modifiers != 0 || chord.pressedButtons.allSatisfy { $0 >= 2 } }
}

struct ButtonChordSettings: Codable, Equatable {
    /// Off unless switched on: holding back a click while waiting for a second button changes how the mouse feels.
    var enabled = false
    var rules: [ButtonChordRule] = []
    /// How long a chord must be held to count as held, and how quick a click or double click must be, in milliseconds.
    var holdMs = 500.0
    var clickMs = 300.0
    var doubleClickMs = 400.0
    /// How close in time two buttons must go down to be one chord, in milliseconds.
    var settleMs = 120.0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ButtonChordSettings()
        enabled = c.value(.enabled, d.enabled); rules = c.value(.rules, d.rules)
        holdMs = c.value(.holdMs, d.holdMs); clickMs = c.value(.clickMs, d.clickMs)
        doubleClickMs = c.value(.doubleClickMs, d.doubleClickMs); settleMs = c.value(.settleMs, d.settleMs)
    }

    private enum CodingKeys: String, CodingKey { case enabled, rules, holdMs, clickMs, doubleClickMs, settleMs }

    /// Invalid chords and numbers out of range, put right.
    func sanitized() -> ButtonChordSettings {
        var next = self
        next.rules = rules.filter { $0.chord.isValid }
        func clamp(_ v: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double { v.isNaN ? fallback : min(max(v, r.lowerBound), r.upperBound) }
        next.holdMs = clamp(holdMs, 150...3000, 500); next.clickMs = clamp(clickMs, 80...1000, 300)
        next.doubleClickMs = clamp(doubleClickMs, 100...1500, 400); next.settleMs = clamp(settleMs, 30...400, 120)
        return next
    }
}

struct ButtonChordStore {
    static let key = "mouse.buttonChords.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var settings: ButtonChordSettings {
        get { (defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(ButtonChordSettings.self, from: $0) } ?? ButtonChordSettings()).sanitized() }
        nonmutating set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.key) } }
    }
}

// MARK: - Conflicts

struct ChordConflict: Equatable, Hashable {
    enum Kind: Equatable, Hashable {
        /// Another chord has the same buttons, keys and phase: only the first can run.
        case duplicate
        /// Another chord is the same buttons and one more: the shorter fires before the longer can be completed.
        case prefix
        /// The same button is in more than one chord.
        case sharedButton(UInt32)
        /// A drag tool already takes this button with these keys.
        case dragTool(UInt32)
        /// A hold rule already takes this button with these keys.
        case holdRule(UInt32)
        /// A double-click rule already takes this button with these keys.
        case doubleClick(UInt32)
        /// A button rule on a click takes this button with these keys.
        case buttonRule(UInt32)
        /// The button's ordinary click would be held back to wait for the rest of the chord.
        case nativeClick(UInt32)
    }

    enum Severity: Int, Comparable, Hashable {
        case info, warning, error
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    /// Positions in the list of chords; the second is nil when only one chord is involved.
    var index: Int
    var other: Int?
    var kind: Kind

    var severity: Severity {
        switch kind {
        case .duplicate, .dragTool, .holdRule, .doubleClick: return .error
        case .prefix, .buttonRule: return .warning
        case .nativeClick(let button): return button <= 1 ? .error : .warning
        case .sharedButton: return .info
        }
    }

    var message: String {
        switch kind {
        case .duplicate: return "Another chord has the same buttons, keys and moment, so this one never runs."
        case .prefix: return "A shorter chord on the same buttons fires first, so the longer one is never reached."
        case .sharedButton(let b): return "\(ButtonChord.name(b)) is used in more than one chord; the buttons and keys held decide which runs."
        case .dragTool(let b): return "A drag tool already uses \(ButtonChord.name(b)) with these keys and takes it first."
        case .holdRule(let b): return "A hold rule already uses \(ButtonChord.name(b)) with these keys and takes it first."
        case .doubleClick(let b): return "A double-click rule already uses \(ButtonChord.name(b)) with these keys and takes it first."
        case .buttonRule(let b): return "A button rule already runs on a click of \(ButtonChord.name(b)) with these keys."
        case .nativeClick(let b): return "\(ButtonChord.name(b)) cannot click normally while a chord waits for it; its click is held back for a moment."
        }
    }
}

enum ButtonChordConflicts {
    /// Everything that stops a chord from running as it reads, or changes how a button behaves because of it.
    static func find(rules: [ButtonChordRule], buttonRules: [ButtonRule] = [], doubleClicks: [DoubleClickBinding] = [], drag: DragToolsConfig? = nil) -> [ChordConflict] {
        var out: [ChordConflict] = []
        for (i, rule) in rules.enumerated() {
            let c = rule.chord
            for (j, other) in rules.enumerated() where j != i {
                let o = other.chord
                guard o.modifiers == c.modifiers else { continue }
                if j < i, o.pressedButtons == c.pressedButtons, o.phase == c.phase { out.append(ChordConflict(index: i, other: j, kind: .duplicate)) }
                if o.pressedButtons.isStrictSubset(of: c.pressedButtons), o.phase == .down, c.phase == .down { out.append(ChordConflict(index: i, other: j, kind: .prefix)) }
            }
            for button in c.pressedButtons.sorted() {
                // The same button elsewhere, reported once for the pair that comes later.
                if let j = rules.indices.first(where: { $0 < i && rules[$0].chord.pressedButtons.contains(button) && rules[$0].chord.pressedButtons != c.pressedButtons }) {
                    out.append(ChordConflict(index: i, other: j, kind: .sharedButton(button)))
                }
                if let drag, DragToolsActivation.uses(drag, button: button, modifiers: c.modifiers) { out.append(ChordConflict(index: i, other: nil, kind: .dragTool(button))) }
                for existing in buttonRules where existing.button == button && existing.modifiers == c.modifiers {
                    if case .hold = existing.trigger { out.append(ChordConflict(index: i, other: nil, kind: .holdRule(button))) }
                    else { out.append(ChordConflict(index: i, other: nil, kind: .buttonRule(button))) }
                }
                if doubleClicks.contains(where: { $0.button == button && $0.modifiers == c.modifiers }) { out.append(ChordConflict(index: i, other: nil, kind: .doubleClick(button))) }
                // Left and right with no keys are the clicks everything depends on; with keys, or any other button, it is a smaller change.
                if button <= 1 || c.modifiers == 0 { out.append(ChordConflict(index: i, other: nil, kind: .nativeClick(button))) }
            }
        }
        return out
    }

    /// The worst thing wrong with each chord, by position.
    static func worst(_ conflicts: [ChordConflict]) -> [Int: ChordConflict.Severity] {
        var result: [Int: ChordConflict.Severity] = [:]
        for c in conflicts { result[c.index] = max(result[c.index] ?? .info, c.severity) }
        return result
    }
}

// MARK: - Matching

/// Follows the buttons held and says which chord has just been completed. Pure: times are given to it, and it posts nothing.
struct ButtonChordMatcher {
    var settings: ButtonChordSettings

    private(set) var held: [UInt32: UInt64] = [:]     // button → time it went down (ms)
    private var firedDown = false
    private var lastCompletedUp: UInt64?

    init(settings: ButtonChordSettings) {
        var clean = settings.sanitized()
        clean.rules = clean.rules.filter(\.isSafe)
        self.settings = clean
    }

    /// The first rule for exactly the buttons held and the keys held, at this phase.
    private func rule(_ phase: ButtonPhase, buttons: Set<UInt32>, modifiers: UInt64) -> ButtonChordRule? {
        settings.rules.first { $0.chord.phase == phase && $0.chord.pressedButtons == buttons && $0.chord.modifiers == modifiers }
    }

    var heldButtons: Set<UInt32> { Set(held.keys) }

    /// Whether a button should be held back from the app: it could still become part of a chord.
    func mayBecomeChord(button: UInt32, modifiers: UInt64) -> Bool {
        guard settings.enabled else { return false }
        let would = heldButtons.union([button])
        return settings.rules.contains { $0.chord.modifiers == modifiers && would.isSubset(of: $0.chord.pressedButtons) }
    }

    mutating func press(_ button: UInt32, modifiers: UInt64, at ms: UInt64) -> ButtonChordRule? {
        guard settings.enabled else { return nil }
        held[button] = ms
        firedDown = false
        // The buttons must have gone down close together: a button held for a long time and then joined is a hold, not a chord.
        guard held.count >= 2, let oldest = held.values.min(), ms &- oldest <= UInt64(settings.settleMs) || settings.rules.contains(where: { $0.chord.phase == .hold || $0.chord.phase == .drag }) else { return nil }
        let match = rule(.down, buttons: heldButtons, modifiers: modifiers)
        firedDown = match != nil
        return match
    }

    /// A button came up. Returns what the release completed: an up, a click or a double click.
    mutating func release(_ button: UInt32, modifiers: UInt64, at ms: UInt64) -> [ButtonChordRule] {
        guard settings.enabled, let downAt = held[button] else { held[button] = nil; return [] }
        let buttons = heldButtons
        var out: [ButtonChordRule] = []
        if buttons.count >= 2 {
            if let up = rule(.up, buttons: buttons, modifiers: modifiers) { out.append(up) }
            if ms &- downAt <= UInt64(settings.clickMs) {
                let dbl = rule(.doubleClick, buttons: buttons, modifiers: modifiers)
                let click = rule(.click, buttons: buttons, modifiers: modifiers)
                if let dbl, let last = lastCompletedUp, ms &- last <= UInt64(settings.doubleClickMs) {
                    out.append(dbl); lastCompletedUp = nil
                } else {
                    if let click { out.append(click) }
                    // A second quick click may follow; remember this one.
                    if dbl != nil { lastCompletedUp = ms }
                }
            }
        }
        held[button] = nil
        if held.isEmpty { firedDown = false }
        return out
    }

    /// The pointer moved while buttons are held: a chord set to drag fires once.
    mutating func dragged(modifiers: UInt64) -> ButtonChordRule? {
        guard settings.enabled, held.count >= 2, !firedDown else { return nil }
        let match = rule(.drag, buttons: heldButtons, modifiers: modifiers)
        if match != nil { firedDown = true }
        return match
    }

    /// Asked now and then while buttons are held and still: a chord set to hold fires once when held long enough.
    mutating func holdDue(modifiers: UInt64, at ms: UInt64) -> ButtonChordRule? {
        guard settings.enabled, held.count >= 2, !firedDown, let newest = held.values.max(), ms &- newest >= UInt64(settings.holdMs) else { return nil }
        let match = rule(.hold, buttons: heldButtons, modifiers: modifiers)
        if match != nil { firedDown = true }
        return match
    }

    /// Forgets every button, for when events were missed (sleep, a device change, the feature switched off).
    mutating func reset() { held = [:]; firedDown = false; lastCompletedUp = nil }
}
