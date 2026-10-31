import CoreGraphics
import Foundation

// MARK: - Actions

enum NavigateDirection: String, Codable, CaseIterable, Identifiable {
    case up, down, left, right
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var isHorizontal: Bool { self == .left || self == .right }
}

/// What a drag in one direction does.
enum NavigateDragAction: String, Codable, CaseIterable, Identifiable {
    case none
    /// The page follows the pointer, as if grabbed, for as long as the button is held.
    case scroll
    /// Back for a drag left, forward for a drag right.
    case backForward
    case missionControl
    case appExpose
    case showDesktop
    /// The next app, as Command-Tab does.
    case commandTab
    /// The Space to the left for a drag left, to the right for a drag right.
    case switchSpace
    /// Dragging up zooms in, down zooms out, for as long as the button is held.
    case zoom
    /// Listed because it was asked for, but macOS gives apps no way to send a rotation, so it does nothing.
    case rotate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Nothing"
        case .scroll: return "Scroll"
        case .backForward: return "Back and forward"
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .showDesktop: return "Show the desktop"
        case .commandTab: return "Switch app (Command-Tab)"
        case .switchSpace: return "Switch Space"
        case .zoom: return "Zoom"
        case .rotate: return "Rotate (not available)"
        }
    }

    /// Carries on for as long as the button is held, instead of happening once.
    var isContinuous: Bool { self == .scroll || self == .zoom || self == .rotate }

    /// Whether macOS lets Kriya do it at all.
    var isAvailable: Bool { self != .rotate }

    /// Whether it makes sense for a drag this way. Back, forward and Spaces go sideways; the rest go any way.
    func suits(_ direction: NavigateDirection) -> Bool {
        switch self {
        case .backForward, .switchSpace: return direction.isHorizontal
        default: return true
        }
    }
}

/// One thing to do once, as the keys or windows of macOS understand it.
enum NavigateDragCommand: String, Equatable {
    case back, forward, missionControl, appExpose, showDesktop, commandTab, spaceLeft, spaceRight

    /// What a one-shot action does for a drag in a direction. Nil when it does nothing there.
    static func resolve(_ action: NavigateDragAction, _ direction: NavigateDirection) -> NavigateDragCommand? {
        guard action.isAvailable, action.suits(direction) else { return nil }
        switch action {
        case .backForward: return direction == .left ? .back : .forward
        case .missionControl: return .missionControl
        case .appExpose: return .appExpose
        case .showDesktop: return .showDesktop
        case .commandTab: return .commandTab
        case .switchSpace: return direction == .left ? .spaceLeft : .spaceRight
        default: return nil
        }
    }
}

// MARK: - Settings

struct NavigateDragConfig: Codable, Equatable {
    /// The mouse button that is captured. Only the buttons beyond left and right (middle, side buttons), which no other part of the
    /// system depends on: capturing the left or right button could leave a Mac impossible to use if something went wrong.
    var button: UInt32 = 2
    /// Keys that must be held with the button, as the core counts them; 0 for none.
    var modifier: UInt64 = 0
    /// What a drag does, by the way it first goes.
    var mapping: [NavigateDirection: NavigateDragAction] = [.up: .scroll, .down: .scroll, .left: .backForward, .right: .backForward]
    /// How far the pointer must travel, in points, before the direction is decided.
    var threshold = 14.0
    /// How much further it must go in one direction than the other to count as that direction.
    var dominance = 1.3
    var speed = 1.0
    var reverseScroll = false
    /// The real pointer stays where the drag began and a virtual one is drawn. Off: nothing is drawn (the real one is still held).
    var showVirtualPointer = true
    /// Where the real pointer is when it is let go: where the drag began, or where the virtual one ended.
    var returnsToStart = true
    /// A capture is let go after this many seconds whatever happens, so the pointer can never stay held.
    var maxSeconds = 30.0

    static let thresholdRange: ClosedRange<Double> = 4...80
    static let dominanceRange: ClosedRange<Double> = 1...4
    static let speedRange: ClosedRange<Double> = 0.1...6
    static let secondsRange: ClosedRange<Double> = 3...120
    /// The lowest button number that may be captured.
    static let firstCapturableButton: UInt32 = 2
    static let lastCapturableButton: UInt32 = 31

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NavigateDragConfig()
        button = c.value(.button, d.button); modifier = c.value(.modifier, d.modifier)
        let saved: [String: NavigateDragAction] = c.value(.mapping, [:])
        var map = d.mapping
        for (key, value) in saved { if let direction = NavigateDirection(rawValue: key) { map[direction] = value } }
        mapping = map
        threshold = c.value(.threshold, d.threshold); dominance = c.value(.dominance, d.dominance); speed = c.value(.speed, d.speed)
        reverseScroll = c.value(.reverseScroll, d.reverseScroll); showVirtualPointer = c.value(.showVirtualPointer, d.showVirtualPointer)
        returnsToStart = c.value(.returnsToStart, d.returnsToStart); maxSeconds = c.value(.maxSeconds, d.maxSeconds)
    }

    /// Saved as plain text keys so a file written by one version reads in another.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(button, forKey: .button); try c.encode(modifier, forKey: .modifier)
        try c.encode(Dictionary(uniqueKeysWithValues: mapping.map { ($0.key.rawValue, $0.value) }), forKey: .mapping)
        try c.encode(threshold, forKey: .threshold); try c.encode(dominance, forKey: .dominance); try c.encode(speed, forKey: .speed)
        try c.encode(reverseScroll, forKey: .reverseScroll); try c.encode(showVirtualPointer, forKey: .showVirtualPointer)
        try c.encode(returnsToStart, forKey: .returnsToStart); try c.encode(maxSeconds, forKey: .maxSeconds)
    }

    private enum CodingKeys: String, CodingKey { case button, modifier, mapping, threshold, dominance, speed, reverseScroll, showVirtualPointer, returnsToStart, maxSeconds }

    func action(for direction: NavigateDirection) -> NavigateDragAction { mapping[direction] ?? .none }

    /// Every number brought into range, the button held to one that may be captured, and a direction given an action that cannot suit
    /// it (Back on a vertical drag) made to do nothing rather than something surprising.
    func sanitized() -> NavigateDragConfig {
        func clamp(_ v: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double { v.isNaN ? fallback : min(max(v, r.lowerBound), r.upperBound) }
        let d = NavigateDragConfig()
        var next = self
        next.button = min(max(button, Self.firstCapturableButton), Self.lastCapturableButton)
        next.threshold = clamp(threshold, Self.thresholdRange, d.threshold)
        next.dominance = clamp(dominance, Self.dominanceRange, d.dominance)
        next.speed = clamp(speed, Self.speedRange, d.speed)
        next.maxSeconds = clamp(maxSeconds, Self.secondsRange, d.maxSeconds)
        for direction in NavigateDirection.allCases where !action(for: direction).suits(direction) { next.mapping[direction] = NavigateDragAction.none }
        return next
    }

    /// Things the person should know about how this is set, one sentence each.
    var warnings: [String] {
        var out: [String] = []
        for direction in NavigateDirection.allCases {
            let a = action(for: direction)
            if !a.isAvailable { out.append("“\(a.title)” does nothing: macOS gives apps no way to send it.") }
            else if !a.suits(direction) { out.append("“\(a.title)” does nothing for a drag \(direction.rawValue); it goes sideways.") }
        }
        return out
    }
}

struct NavigateDragSettings: Codable, Equatable {
    /// Off unless switched on: capturing a mouse button and holding the pointer is not something to happen unasked.
    var enabled = false
    var config = NavigateDragConfig()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, false)
        config = c.value(.config, NavigateDragConfig()).sanitized()
    }
}

struct NavigateDragStore {
    static let key = "mouse.navigateDrag.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var settings: NavigateDragSettings {
        get { defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(NavigateDragSettings.self, from: $0) } ?? NavigateDragSettings() }
        nonmutating set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.key) } }
    }
}

// MARK: - The session

/// What a session asks to be done. The controller does it: nothing here touches the screen or the system.
enum NavigateDragEffect: Equatable {
    /// The virtual pointer is here (global points, top left origin), inside the display.
    case pointer(CGPoint)
    case scroll(dx: Double, dy: Double)
    case zoom(Double)
    case run(NavigateDragCommand)
    /// The button was let go before the pointer went anywhere: it was a click, and is sent on as one.
    case click
}

/// One press-drag-release: where it began, where the virtual pointer is, what it has become, and how far it has got.
struct NavigateDragSession: Equatable {
    enum Phase: Equatable {
        /// Pressed; the pointer has not gone far enough to say which way.
        case pending
        /// A continuous action (scroll, zoom) is following the pointer.
        case tracking
        /// A one-shot action was done, or the drag does nothing: the rest of the drag is ignored.
        case fired
        case finished
        case cancelled
    }

    var startPoint: CGPoint
    var currentPoint: CGPoint
    var displayID: CGDirectDisplayID
    var action: NavigateDragAction = .none
    var phase: Phase = .pending
    var direction: NavigateDirection?

    private let bounds: CGRect
    /// How far the pointer has travelled from where it began, before being held to the display.
    private var travel = CGPoint.zero

    init(startPoint: CGPoint, displayID: CGDirectDisplayID, bounds: CGRect) {
        self.startPoint = startPoint
        currentPoint = startPoint
        self.displayID = displayID
        self.bounds = bounds
    }

    var isActive: Bool { phase == .pending || phase == .tracking || phase == .fired }

    /// Which way the pointer has gone, once it has gone far enough and clearly more one way than the other. Nil until then.
    static func direction(travel: CGPoint, threshold: Double, dominance: Double) -> NavigateDirection? {
        let ax = abs(travel.x), ay = abs(travel.y)
        let far = max(ax, ay)
        guard far >= threshold, far >= min(ax, ay) * dominance else { return nil }
        if ax >= ay { return travel.x < 0 ? .left : .right }
        return travel.y < 0 ? .up : .down
    }

    /// The pointer moved by (dx, dy) points. Returns what to do.
    mutating func move(dx: Double, dy: Double, config: NavigateDragConfig) -> [NavigateDragEffect] {
        guard isActive, dx.isFinite, dy.isFinite else { return [] }
        var effects: [NavigateDragEffect] = []
        travel.x += dx; travel.y += dy
        let moved = CGPoint(x: min(max(currentPoint.x + dx, bounds.minX), bounds.maxX - 1), y: min(max(currentPoint.y + dy, bounds.minY), bounds.maxY - 1))
        if moved != currentPoint { currentPoint = moved; effects.append(.pointer(moved)) }

        if phase == .pending {
            guard let way = Self.direction(travel: travel, threshold: config.threshold, dominance: config.dominance) else { return effects }
            direction = way
            action = config.action(for: way)
            if action.isContinuous && action.isAvailable && action.suits(way) {
                phase = .tracking
                // What has been travelled so far counts, so the page does not wait for the direction to be decided.
                effects += continuous(dx: travel.x, dy: travel.y, config: config)
            } else {
                phase = .fired
                if let command = NavigateDragCommand.resolve(action, way) { effects.append(.run(command)) }
            }
            return effects
        }
        if phase == .tracking { effects += continuous(dx: dx, dy: dy, config: config) }
        return effects
    }

    private func continuous(dx: Double, dy: Double, config: NavigateDragConfig) -> [NavigateDragEffect] {
        switch action {
        case .scroll:
            // The page follows the pointer as if grabbed: pointer down, page down, which a scroll event spells as positive.
            let sign = config.reverseScroll ? -1.0 : 1.0
            return [.scroll(dx: dx * config.speed * sign, dy: dy * config.speed * sign)]
        case .zoom:
            // Up zooms in, down zooms out.
            return dy == 0 ? [] : [.zoom(-dy * config.speed * 0.2)]
        default:
            return []
        }
    }

    /// The button was let go. Without ever deciding a direction, that was a click.
    mutating func end() -> [NavigateDragEffect] {
        guard isActive else { return [] }
        let wasPending = phase == .pending
        phase = .finished
        return wasPending ? [.click] : []
    }

    /// Stopped from outside: Escape, a timeout, sleep, the feature being switched off. Nothing more happens, and a click is not sent.
    mutating func cancel() {
        guard isActive else { return }
        phase = .cancelled
    }

    /// Where the real pointer goes when it is let go.
    func restorePoint(returnsToStart: Bool) -> CGPoint { returnsToStart ? startPoint : currentPoint }
}
