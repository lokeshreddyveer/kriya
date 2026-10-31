import CoreGraphics
import Foundation

// MARK: - What a button becomes

/// What a physical left or right button does instead of its own job.
enum ReplacementTarget: Codable, Equatable, Hashable {
    /// Another mouse button's press: 0 left, 1 right, 2 middle, 3 and up the side buttons.
    case button(UInt32)
    /// A saved action, run when the button goes down.
    case action(String)
}

struct PrimaryButtonReplacementConfig: Codable, Equatable {
    /// What the physical left button becomes. Nil leaves it alone.
    var left: ReplacementTarget?
    var right: ReplacementTarget?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        left = try? c.decodeIfPresent(ReplacementTarget.self, forKey: .left)
        right = try? c.decodeIfPresent(ReplacementTarget.self, forKey: .right)
    }

    private enum CodingKeys: String, CodingKey { case left, right }

    /// What a physical button becomes. Only the left and right buttons can be replaced; a replacement that does nothing new (left to
    /// left) is no replacement.
    func target(for physical: UInt32) -> ReplacementTarget? {
        let t: ReplacementTarget?
        switch physical {
        case 0: t = left
        case 1: t = right
        default: t = nil
        }
        if case .button(let b)? = t, b == physical { return nil }
        if case .action(let id)? = t, id.isEmpty { return nil }
        return t
    }

    var replacesAnything: Bool { target(for: 0) != nil || target(for: 1) != nil }

    /// Whether the mouse can still do an ordinary click afterwards: some physical button still gives the left button.
    var keepsPrimaryClick: Bool {
        let leftStays = target(for: 0) == nil
        let rightGivesLeft = target(for: 1) == .button(0)
        let leftGivesLeft = target(for: 0) == .button(0)
        return leftStays || rightGivesLeft || leftGivesLeft
    }

    /// Whether anything can still be pressed to open a menu: some physical button still gives the right button.
    var keepsSecondaryClick: Bool {
        target(for: 1) == nil || target(for: 0) == .button(1) || target(for: 1) == .button(1)
    }

    enum Issue: Equatable {
        case nothingToReplace
        /// No button would be left that clicks: every click is replaced by something else. The mouse could not click at all.
        case losesPrimaryClick
        /// No button would be left that right-clicks.
        case losesSecondaryClick
    }

    var issues: [Issue] {
        guard replacesAnything else { return [.nothingToReplace] }
        var out: [Issue] = []
        if !keepsPrimaryClick { out.append(.losesPrimaryClick) }
        if !keepsSecondaryClick { out.append(.losesSecondaryClick) }
        return out
    }

    /// Whether it may be armed: a click is kept. Losing right-click is a warning, not a block (a menu can still be opened by keyboard).
    var canArm: Bool { replacesAnything && keepsPrimaryClick }
}

struct PrimaryButtonReplacementSettings: Codable, Equatable {
    /// Off unless switched on. Even then it does nothing until it is armed with a confirmation, every time Kriya starts.
    var enabled = false
    var config = PrimaryButtonReplacementConfig()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, false)
        config = c.value(.config, PrimaryButtonReplacementConfig())
    }

    private enum CodingKeys: String, CodingKey { case enabled, config }
}

struct PrimaryButtonReplacementStore {
    static let key = "mouse.primaryReplacement.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var settings: PrimaryButtonReplacementSettings {
        get { defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(PrimaryButtonReplacementSettings.self, from: $0) } ?? PrimaryButtonReplacementSettings() }
        nonmutating set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.key) } }
    }
}

// MARK: - Arming

enum ReplacementStop: Equatable {
    case confirmTimeout
    case escapeThreeTimes
    case rageClicking
    case safeMode
    case permissionLost
    case sleep
    case displaysChanged
    case eventTapFailed
    case switchedOff
    case quit

    var message: String {
        switch self {
        case .confirmTimeout: return "Not confirmed in time, so button replacement stayed off."
        case .escapeThreeTimes: return "Escape was pressed three times, so button replacement was turned off."
        case .rageClicking: return "A button was pressed many times quickly, so button replacement was turned off in case the mouse was not working."
        case .safeMode: return "Safe Mode is on, so button replacement is off."
        case .permissionLost: return "Input Monitoring was turned off, so button replacement is off."
        case .sleep: return "The Mac slept or the screen locked, so button replacement was turned off."
        case .displaysChanged: return "The displays changed, so button replacement was turned off."
        case .eventTapFailed: return "Kriya lost its hold on the mouse, so button replacement was turned off."
        case .switchedOff: return "Button replacement was turned off."
        case .quit: return "Kriya quit."
        }
    }
}

/// Armed only by a confirmation: five seconds to press the physical button named. Nothing is remembered between runs, so it is off every
/// time Kriya starts, and anything unusual turns it off again.
struct ReplacementArming: Equatable {
    enum State: Equatable {
        case off
        case countdown(deadline: Double, confirm: UInt32)
        case armed
        case paused
        case stopped(ReplacementStop)
    }

    static let countdownSeconds = 5.0

    private(set) var state = State.off

    var isArmed: Bool { state == .armed }
    var isCountingDown: Bool { if case .countdown = state { return true }; return false }

    /// The button to press to confirm, while counting down.
    var confirmButton: UInt32? { if case .countdown(_, let b) = state { return b }; return nil }

    func remaining(now: Double) -> Double {
        if case .countdown(let deadline, _) = state { return max(0, deadline - now) }
        return 0
    }

    /// Starts the five seconds. The button to press is the first one replaced, so confirming proves the person can press it. Only from
    /// off, paused or stopped, and only for a configuration that may be armed.
    @discardableResult
    mutating func begin(config: PrimaryButtonReplacementConfig, now: Double) -> Bool {
        guard config.canArm else { return false }
        switch state {
        case .armed, .countdown: return false
        default: break
        }
        let confirm: UInt32 = config.target(for: 0) != nil ? 0 : 1
        state = .countdown(deadline: now + Self.countdownSeconds, confirm: confirm)
        return true
    }

    /// Time passing. Unconfirmed in five seconds, it is stopped.
    mutating func tick(now: Double) {
        if case .countdown(let deadline, _) = state, now >= deadline { state = .stopped(.confirmTimeout) }
    }

    /// A physical press, before any replacement. True when it was the confirmation, which arms it (and is not passed on).
    mutating func physicalPress(_ button: UInt32, now: Double) -> Bool {
        guard case .countdown(let deadline, let confirm) = state, button == confirm, now < deadline else { return false }
        state = .armed
        return true
    }

    mutating func pause() { if state == .armed || isCountingDown { state = .paused } }

    /// Anything that must turn it off at once. Always works, in every state.
    mutating func stop(_ reason: ReplacementStop) {
        state = reason == .switchedOff ? .off : .stopped(reason)
    }
}

// MARK: - Panic detectors

/// Escape pressed three times in a row, quickly: the way out that needs no mouse at all.
struct EscapeTriplePress: Equatable {
    var window = 1.5
    private var times: [Double] = []

    /// True when this press is the third within the window.
    mutating func press(at now: Double) -> Bool {
        times.append(now)
        times.removeAll { now - $0 > window }
        if times.count >= 3 { times = []; return true }
        return false
    }

    mutating func reset() { times = [] }
}

/// A button hammered many times in a short while: somebody whose mouse is not doing what they expect. Turns it off.
struct RageClickDetector: Equatable {
    var presses = 8
    var window = 2.0
    private var times: [Double] = []

    mutating func press(at now: Double) -> Bool {
        times.append(now)
        times.removeAll { now - $0 > window }
        if times.count >= presses { times = []; return true }
        return false
    }

    mutating func reset() { times = [] }
}

// MARK: - Turning one button into another

enum ReplacementEvents {
    private enum Kind { case down, up, dragged }

    /// The same press, release or drag as it would be for another button. Nil for an event that is not a button event.
    static func converted(_ type: CGEventType, toButton button: UInt32) -> CGEventType? {
        let kind: Kind
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .down
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = .up
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: kind = .dragged
        default: return nil
        }
        switch (button, kind) {
        case (0, .down): return .leftMouseDown
        case (0, .up): return .leftMouseUp
        case (0, .dragged): return .leftMouseDragged
        case (1, .down): return .rightMouseDown
        case (1, .up): return .rightMouseUp
        case (1, .dragged): return .rightMouseDragged
        case (_, .down): return .otherMouseDown
        case (_, .up): return .otherMouseUp
        case (_, .dragged): return .otherMouseDragged
        }
    }
}
