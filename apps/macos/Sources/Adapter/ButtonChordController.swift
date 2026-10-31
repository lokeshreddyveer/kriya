import AppKit
import Combine

/// Mouse button chords: two or more buttons held together, with keys, running an action when the chord is pressed, released, clicked,
/// double-clicked, held or dragged. A button that could still become part of a chord is held back for a moment; if no chord forms, it
/// is sent on as the ordinary press it was, so the button's own rule, gesture or click still happens. Off unless switched on.
final class ButtonChordController {
    /// Presses sent on again carry this, not the marker Kriya's other synthetic events do, so the mouse rules still see them as real.
    static let replayMarker: Int64 = 0x4B52_4A43
    /// Before the navigation drag (25) and the drag tools (20), which it gives way to by asking the claims.
    static let priority = 30

    private let events: EventMonitor
    private let defaults: UserDefaults
    private let run: (String) -> Void
    private let mouseClaims: (UInt32, UInt64) -> ButtonClaims
    private let now: () -> UInt64
    private var token: EventMonitor.Token?
    private var cancellables = Set<AnyCancellable>()

    private struct Pending {
        var location: CGPoint
        var flags: CGEventFlags
    }

    private let lock = NSLock()
    private var matcher = ButtonChordMatcher(settings: ButtonChordSettings())
    private var settings = ButtonChordSettings()
    private var allowed = false
    /// Presses held back, waiting to see if a chord forms.
    private var pending: [UInt32: Pending] = [:]
    /// Buttons whose press was sent on: their release goes on too.
    private var replayed: Set<UInt32> = []
    /// Buttons that were part of a chord that ran: their release, and any drag, is not for the app.
    private var consumed: Set<UInt32> = []
    private var settleTimer: DispatchSourceTimer?
    private var holdTimer: DispatchSourceTimer?
    private var lastModifiers: UInt64 = 0

    private static let types: [CGEventType] = [
        .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged,
    ]

    init(events: EventMonitor, defaults: UserDefaults = .standard, run: @escaping (String) -> Void,
         mouseClaims: @escaping (UInt32, UInt64) -> ButtonClaims = { _, _ in ButtonClaims() },
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds / 1_000_000 }) {
        self.events = events
        self.defaults = defaults
        self.run = run
        self.mouseClaims = mouseClaims
        self.now = now
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        // Sleep and a locked screen can swallow a release: nothing is left held back.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            ws.publisher(for: name).sink { [weak self] _ in self?.letGo() }.store(in: &cancellables)
        }
    }

    /// Starts or stops listening: only while chords are switched on, there is a chord to match, and the system lets Kriya (Input
    /// Monitoring on, safe mode off, Mouse & Trackpad on).
    func refresh(allowed newAllowed: Bool? = nil) {
        let loaded = ButtonChordStore(defaults: defaults).settings
        lock.lock()
        if let newAllowed { allowed = newAllowed }
        let changed = loaded != settings
        settings = loaded
        let listen = allowed && loaded.enabled && !loaded.rules.filter(\.isSafe).isEmpty
        lock.unlock()
        if listen {
            if changed { letGo(); lock.lock(); matcher = ButtonChordMatcher(settings: loaded); lock.unlock() }
            if token == nil {
                token = events.subscribe(owner: "button.chords", events: Self.types, mode: .active, priority: Self.priority) { [weak self] type, event in
                    self?.handle(type, event) ?? .passThrough
                }
            }
        } else if token != nil {
            stop()
        }
    }

    func stop(replayPending: Bool = true) {
        if let token { events.unsubscribe(token) }
        token = nil
        letGo(replayPending: replayPending)
    }

    /// Nothing is left held back: presses waiting are sent on (unless `replayPending` is off, as when mouse rules are paused: then they are
    /// only forgotten, and no event is posted), and every button is forgotten.
    func letGo(replayPending: Bool = true) {
        lock.lock()
        let waiting = pending
        pending = [:]
        settleTimer?.cancel(); settleTimer = nil
        holdTimer?.cancel(); holdTimer = nil
        replayed = []
        consumed = []
        matcher.reset()
        lock.unlock()
        if replayPending { for (button, press) in waiting.sorted(by: { $0.key < $1.key }) { post(down: true, button: button, press) } }
    }

    // MARK: Events (on the tap's thread)

    private static func isDown(_ t: CGEventType) -> Bool { t == .leftMouseDown || t == .rightMouseDown || t == .otherMouseDown }
    private static func isUp(_ t: CGEventType) -> Bool { t == .leftMouseUp || t == .rightMouseUp || t == .otherMouseUp }

    func handle(_ type: CGEventType, _ event: CGEvent) -> EventDisposition {
        // Presses this sent on, and Kriya's other synthetic events, are never held back again.
        let marker = event.getIntegerValueField(.eventSourceUserData)
        if marker == Self.replayMarker || marker == EventMonitor.syntheticMarker { return .passThrough }
        let button = UInt32(max(0, event.getIntegerValueField(.mouseEventButtonNumber)))
        let modifiers = KeyModifiers.bits(from: event.flags)
        let ms = now()

        if Self.isDown(type) { return down(button, modifiers, event, ms) }
        if Self.isUp(type) { return up(button, modifiers, ms) }
        return dragged(button, modifiers)
    }

    private func down(_ button: UInt32, _ modifiers: UInt64, _ event: CGEvent, _ ms: UInt64) -> EventDisposition {
        lock.lock()
        guard allowed, settings.enabled else { lock.unlock(); return .passThrough }
        lastModifiers = modifiers
        guard matcher.mayBecomeChord(button: button, modifiers: modifiers) else {
            // Not part of any chord: it goes through, and is noted if other buttons are held so a chord is not wrongly completed by it.
            lock.unlock()
            return .passThrough
        }
        lock.unlock()
        // Another part of Kriya or an app left alone has this button: it is theirs.
        let claims = mouseClaims(button, modifiers)
        if claims.excluded || claims.dragCapture { return .passThrough }

        lock.lock()
        pending[button] = Pending(location: event.location, flags: event.flags)
        let match = matcher.press(button, modifiers: modifiers, at: ms)
        if let match {
            // The chord formed: the presses held back are its, and are not for the app.
            consumed.formUnion(matcher.heldButtons)
            pending = [:]
            settleTimer?.cancel(); settleTimer = nil
            lock.unlock()
            fire(match)
            return .drop
        }
        if settleTimer == nil { startSettleTimer(after: settings.settleMs) }
        startHoldTimerIfNeeded()
        lock.unlock()
        return .drop
    }

    private func up(_ button: UInt32, _ modifiers: UInt64, _ ms: UInt64) -> EventDisposition {
        lock.lock()
        guard allowed, settings.enabled else { lock.unlock(); return .passThrough }
        let wasConsumed = consumed.contains(button)
        let wasReplayed = replayed.contains(button)
        let wasPending = pending[button] != nil
        guard wasConsumed || wasReplayed || wasPending else { lock.unlock(); return .passThrough }
        let rules = matcher.release(button, modifiers: modifiers, at: ms)
        if matcher.heldButtons.isEmpty { holdTimer?.cancel(); holdTimer = nil }
        if !rules.isEmpty { consumed.formUnion(matcher.heldButtons); consumed.insert(button) }
        let nowConsumed = consumed.contains(button)

        if wasPending && !nowConsumed {
            // Let go before a chord formed: the presses held back were ordinary clicks after all.
            let waiting = pending
            pending = [:]
            settleTimer?.cancel(); settleTimer = nil
            for key in waiting.keys where key != button { replayed.insert(key) }
            lock.unlock()
            for (key, press) in waiting.sorted(by: { $0.key < $1.key }) { post(down: true, button: key, press) }
            if let press = waiting[button] { post(down: false, button: button, press) }
            rules.forEach(fire)
            return .drop
        }
        if wasPending { pending[button] = nil }
        consumed.remove(button)
        replayed.remove(button)
        if matcher.heldButtons.isEmpty { consumed = []; replayed = [] }
        lock.unlock()
        rules.forEach(fire)
        return nowConsumed ? .drop : .passThrough
    }

    private func dragged(_ button: UInt32, _ modifiers: UInt64) -> EventDisposition {
        lock.lock()
        guard allowed, settings.enabled else { lock.unlock(); return .passThrough }
        let held = consumed.contains(button) || pending[button] != nil
        var match: ButtonChordRule?
        if matcher.heldButtons.count >= 2 {
            match = matcher.dragged(modifiers: modifiers)
            if match != nil { consumed.formUnion(matcher.heldButtons); pending = [:]; settleTimer?.cancel(); settleTimer = nil }
        }
        lock.unlock()
        if let match { fire(match) }
        return held || match != nil ? .drop : .passThrough
    }

    // MARK: Timers

    /// Called with the lock held.
    private func startSettleTimer(after ms: Double) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(Int(ms)))
        timer.setEventHandler { [weak self] in self?.settled() }
        timer.resume()
        settleTimer = timer
    }

    /// No chord formed in time: what was held back is sent on as ordinary presses.
    private func settled() {
        lock.lock()
        let waiting = pending
        pending = [:]
        settleTimer = nil
        replayed.formUnion(waiting.keys)
        lock.unlock()
        for (button, press) in waiting.sorted(by: { $0.key < $1.key }) { post(down: true, button: button, press) }
    }

    /// Called with the lock held. Only chords set to hold need it.
    private func startHoldTimerIfNeeded() {
        guard holdTimer == nil, settings.rules.contains(where: { $0.chord.phase == .hold }) else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.holdTick() }
        timer.resume()
        holdTimer = timer
    }

    private func holdTick() {
        lock.lock()
        let match = matcher.holdDue(modifiers: lastModifiers, at: now())
        if match != nil { consumed.formUnion(matcher.heldButtons); pending = [:]; settleTimer?.cancel(); settleTimer = nil }
        if matcher.heldButtons.isEmpty { holdTimer?.cancel(); holdTimer = nil }
        lock.unlock()
        if let match { fire(match) }
    }

    // MARK: Doing things

    private func fire(_ rule: ButtonChordRule) {
        InteractionTrace.shared.note("Mouse", "A button chord ran a rule")
        let id = rule.actionId
        DispatchQueue.main.async { self.run(id) }
    }

    private func post(down: Bool, button: UInt32, _ press: Pending) {
        let type: CGEventType
        switch button {
        case 0: type = down ? .leftMouseDown : .leftMouseUp
        case 1: type = down ? .rightMouseDown : .rightMouseUp
        default: type = down ? .otherMouseDown : .otherMouseUp
        }
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: press.location, mouseButton: CGMouseButton(rawValue: button) ?? .center) else { return }
        e.flags = press.flags
        e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        e.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
        e.post(tap: .cghidEventTap)
    }
}
