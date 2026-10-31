import CoreGraphics
import Foundation

// MARK: - Intent

/// A gesture a trackpad would make, as a mouse can ask for it.
enum GestureKind: Equatable {
    case twoFingerSwipe(NavigateDirection)
    case threeFingerSwipe(NavigateDirection)
    case fourFingerPinch(zoomIn: Bool)
    case rotate
    case commandTab
    case missionControl
    case appExpose

    /// Carries on while the button is held (began, changed…, ended) instead of happening once.
    var isContinuous: Bool {
        switch self {
        case .twoFingerSwipe, .fourFingerPinch, .rotate: return true
        default: return false
        }
    }

    /// Whether macOS lets Kriya do it. Rotation has no public way to be sent.
    var isAvailable: Bool { self != .rotate }

    var title: String {
        switch self {
        case .twoFingerSwipe: return "Two-finger swipe"
        case .threeFingerSwipe: return "Three-finger swipe"
        case .fourFingerPinch: return "Four-finger pinch"
        case .rotate: return "Rotate"
        case .commandTab: return "Command-Tab"
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        }
    }
}

enum GesturePhase: Equatable { case began, changed, ended, cancelled }

/// What is asked for: a kind, where it is in its life, and how far it has gone (points, for swipes and pinches).
struct GestureIntent: Equatable {
    var kind: GestureKind
    var phase: GesturePhase
    var dx = 0.0
    var dy = 0.0
}

// MARK: - Recognizer

/// Turns a stream of pointer movement into gesture intents for one chosen kind per direction. It holds no timers and posts nothing, so it
/// can be fed by a drag, a button hold or a test alike.
struct GestureRecognizer: Equatable {
    /// What a movement does, by the way it first goes. Nil leaves that direction doing nothing.
    var mapping: [NavigateDirection: GestureKind]
    var threshold = 14.0
    var dominance = 1.3

    private var travel = CGPoint.zero
    private(set) var current: GestureKind?
    private(set) var decided = false

    init(mapping: [NavigateDirection: GestureKind], threshold: Double = 14, dominance: Double = 1.3) {
        self.mapping = mapping
        self.threshold = threshold
        self.dominance = dominance
    }

    var isRecognizing: Bool { current != nil }

    mutating func move(dx: Double, dy: Double) -> [GestureIntent] {
        guard dx.isFinite, dy.isFinite else { return [] }
        travel.x += dx; travel.y += dy
        if !decided {
            guard let way = NavigateDragSession.direction(travel: travel, threshold: threshold, dominance: dominance) else { return [] }
            decided = true
            guard let kind = mapping[way] else { return [] }
            current = kind
            if kind.isContinuous {
                return [GestureIntent(kind: kind, phase: .began), GestureIntent(kind: kind, phase: .changed, dx: travel.x, dy: travel.y)]
            }
            return [GestureIntent(kind: kind, phase: .began), GestureIntent(kind: kind, phase: .ended)]
        }
        guard let kind = current, kind.isContinuous else { return [] }
        return [GestureIntent(kind: kind, phase: .changed, dx: dx, dy: dy)]
    }

    /// The input was let go normally.
    mutating func end() -> [GestureIntent] {
        defer { reset() }
        guard let kind = current, kind.isContinuous else { return [] }
        return [GestureIntent(kind: kind, phase: .ended)]
    }

    /// The input was taken away (Escape, timeout, sleep).
    mutating func cancel() -> [GestureIntent] {
        defer { reset() }
        guard let kind = current, kind.isContinuous else { return [] }
        return [GestureIntent(kind: kind, phase: .cancelled)]
    }

    private mutating func reset() { travel = .zero; current = nil; decided = false }
}

// MARK: - Safety

enum GestureRefusal: Equatable {
    case off, unavailable, anotherGestureRunning, tooSoon, tooLong, notBegun
}

/// The rules a gesture must pass before it is sent, and the one thing that always gets through: a cancel. At most one gesture is alive at
/// a time, a continuous one has a time limit, one-shot actions are spaced out, and nothing is sent when it is switched off.
struct GestureSafetyPolicy: Equatable {
    var allowed = true
    var maxSeconds = 30.0
    var minOneShotInterval = 0.4

    private(set) var active: GestureKind?
    private var startedAt: TimeInterval = 0
    private var lastOneShot: TimeInterval = -.infinity

    init(allowed: Bool = true, maxSeconds: Double = 30, minOneShotInterval: Double = 0.4) {
        self.allowed = allowed
        self.maxSeconds = min(max(maxSeconds, 1), 300)
        self.minOneShotInterval = max(minOneShotInterval, 0)
    }

    /// Decides one intent at `now` (seconds). Cancels and ends of the running gesture are always admitted so it can never be left half done.
    mutating func admit(_ intent: GestureIntent, now: TimeInterval) -> GestureRefusal? {
        if intent.phase == .cancelled || intent.phase == .ended {
            if intent.kind == active { active = nil; return nil }
            // A one-shot's own end carries no state.
            return intent.kind.isContinuous ? .notBegun : nil
        }
        guard allowed else { return .off }
        guard intent.kind.isAvailable else { return .unavailable }
        switch intent.phase {
        case .began:
            if active != nil { return .anotherGestureRunning }
            if intent.kind.isContinuous {
                active = intent.kind; startedAt = now
            } else {
                if now - lastOneShot < minOneShotInterval { return .tooSoon }
                lastOneShot = now
            }
            return nil
        case .changed:
            guard intent.kind == active else { return .notBegun }
            if now - startedAt > maxSeconds { return .tooLong }
            return nil
        default:
            return nil
        }
    }

    /// True when a running gesture has outlived its limit and must be cancelled by whoever owns it.
    func isExpired(now: TimeInterval) -> Bool { active != nil && now - startedAt > maxSeconds }

    mutating func reset() { active = nil }
}

// MARK: - Emitter and service

/// Sends a gesture to the system. The real one uses only public ways in; a check collects what it was asked.
protocol TrackpadEventEmitter: AnyObject {
    func emit(_ intent: GestureIntent, at point: CGPoint)
}

/// Owns the lifecycle: recognizes, asks the policy, emits, and cancels everything on request.
final class TrackpadGestureService {
    private let emitter: TrackpadEventEmitter
    private let now: () -> TimeInterval
    private let lock = NSLock()
    private var policy: GestureSafetyPolicy
    private var recognizer: GestureRecognizer
    private var point = CGPoint.zero
    private(set) var refusals: [GestureRefusal] = []

    init(emitter: TrackpadEventEmitter, recognizer: GestureRecognizer, policy: GestureSafetyPolicy = GestureSafetyPolicy(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.emitter = emitter
        self.recognizer = recognizer
        self.policy = policy
        self.now = now
    }

    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return policy.active != nil }

    func setAllowed(_ allowed: Bool) {
        lock.lock(); policy.allowed = allowed; lock.unlock()
        if !allowed { cancel() }
    }

    func move(dx: Double, dy: Double, at location: CGPoint) {
        lock.lock()
        point = location
        // A gesture past its time limit is cancelled rather than carried on.
        let expired = policy.isExpired(now: now())
        lock.unlock()
        if expired { cancel(); return }
        lock.lock(); let intents = recognizer.move(dx: dx, dy: dy); lock.unlock()
        send(intents, at: location)
    }

    func end() { lock.lock(); let intents = recognizer.end(); let p = point; lock.unlock(); send(intents, at: p) }

    /// Stops whatever is running, whatever state it is in. Safe to call at any time, any number of times.
    func cancel() {
        lock.lock()
        let intents = recognizer.cancel()
        let running = policy.active
        let p = point
        lock.unlock()
        send(intents, at: p)
        // Anything the recognizer no longer knew about but the policy still holds is cancelled too.
        if let running { send([GestureIntent(kind: running, phase: .cancelled)], at: p) }
        lock.lock(); policy.reset(); lock.unlock()
    }

    /// An action asked for directly (a shortcut or button rule): a one-shot, or a whole continuous gesture of fixed size.
    func perform(_ kind: GestureKind, at location: CGPoint) {
        send([GestureIntent(kind: kind, phase: .began), GestureIntent(kind: kind, phase: .ended)], at: location)
    }

    func sendSequence(_ intents: [GestureIntent], at location: CGPoint) { send(intents, at: location) }

    private func send(_ intents: [GestureIntent], at location: CGPoint) {
        for intent in intents {
            lock.lock(); let refusal = policy.admit(intent, now: now()); if let refusal { refusals.append(refusal) }; lock.unlock()
            if refusal == nil { emitter.emit(intent, at: location) }
        }
    }
}

// MARK: - Commands

/// The gestures that can be run by name from a shortcut, a button rule, a chord or a hold, like any other command.
enum TrackpadGestureCommands {
    struct Entry { let command: String; let title: String; let kind: GestureKind }

    /// How far a swipe or pinch goes when it is run by name, in points.
    static let swipeDistance = 400.0
    static let pinchDistance = 150.0

    static let all: [Entry] = {
        var list: [Entry] = [
            Entry(command: "gesture.mission_control", title: "Trackpad gesture: Mission Control", kind: .missionControl),
            Entry(command: "gesture.app_expose", title: "Trackpad gesture: App Exposé", kind: .appExpose),
            Entry(command: "gesture.command_tab", title: "Trackpad gesture: Command-Tab", kind: .commandTab),
            Entry(command: "gesture.pinch.in", title: "Trackpad gesture: pinch in (zoom in)", kind: .fourFingerPinch(zoomIn: true)),
            Entry(command: "gesture.pinch.out", title: "Trackpad gesture: pinch out (zoom out)", kind: .fourFingerPinch(zoomIn: false)),
        ]
        for direction in NavigateDirection.allCases {
            list.append(Entry(command: "gesture.swipe3.\(direction.rawValue)", title: "Trackpad gesture: three-finger swipe \(direction.rawValue)", kind: .threeFingerSwipe(direction)))
            list.append(Entry(command: "gesture.swipe2.\(direction.rawValue)", title: "Trackpad gesture: two-finger swipe \(direction.rawValue)", kind: .twoFingerSwipe(direction)))
        }
        return list
    }()
}

extension TrackpadGestureService {
    /// Runs one named gesture from start to finish: a swipe or pinch moves a fixed distance, a one-shot happens once.
    func run(_ kind: GestureKind, at location: CGPoint) {
        guard kind.isContinuous else { return perform(kind, at: location) }
        let distance = TrackpadGestureCommands.swipeDistance
        var dx = 0.0, dy = 0.0
        switch kind {
        case .twoFingerSwipe(let direction):
            // The page follows the fingers: a swipe up moves it up.
            switch direction {
            case .up: dy = -distance
            case .down: dy = distance
            case .left: dx = -distance
            case .right: dx = distance
            }
        case .fourFingerPinch: dx = TrackpadGestureCommands.pinchDistance
        default: break
        }
        sendSequence([GestureIntent(kind: kind, phase: .began), GestureIntent(kind: kind, phase: .changed, dx: dx, dy: dy), GestureIntent(kind: kind, phase: .ended)], at: location)
    }
}
