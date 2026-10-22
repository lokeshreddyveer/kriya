import AppKit

/// Hold a mouse button and drag to scroll the page under the pointer like grabbing it, let it glide on after letting go,
/// and hold keys so the window under the pointer follows the pointer with no click.
///
/// The button that scrolls is taken by Kriya when pressed. If it is let go without the pointer moving, Kriya sends the
/// click on to the app, so a plain middle click still opens a link in a new tab. Needs Input Monitoring.
final class DragTools {
    private let events: EventMonitor
    private let store: DragToolsStore
    private let windowStore: WindowStore
    private let run: (String) -> Void
    private var token: EventMonitor.Token?

    private enum Phase { case idle, pending, scrolling }

    // Read and written on the event tap's thread (one thread), under the lock because `stop` runs elsewhere.
    private let lock = NSLock()
    private var phase = Phase.idle
    private var button: UInt32 = 0
    private var downLocation = CGPoint.zero
    private var lastLocation = CGPoint.zero
    private var following = false
    private var gliding = false
    // Double clicks and a held button turning the wheel.
    private var lastDown: [UInt32: UInt64] = [:]
    private var swallowUp: Set<UInt32> = []
    private var wheelButton: UInt32?
    private var wheelScrolled = false
    private var wheelDown = CGPoint.zero
    private var wheelAccumulated = 0.0

    // Used only on `work`.
    private let work = DispatchQueue(label: "app.kriya.dragtools", qos: .userInteractive)
    private var moves: [DragMove] = []
    private var carryX = 0.0
    private var carryY = 0.0
    private var velocity = Velocity(x: 0, y: 0)
    private var glideTimer: DispatchSourceTimer?
    private var lastTick: UInt64 = 0
    private var window: AXWindow?
    private var startFrame = Rect(x: 0, y: 0, width: 0, height: 0)
    private var startMouse = CGPoint.zero
    private var latest = CGPoint.zero
    private var updateQueued = false

    private static let types: [CGEventType] = [
        .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        .mouseMoved, .flagsChanged, .scrollWheel,
    ]

    init(events: EventMonitor, store: DragToolsStore, windowStore: WindowStore, run: @escaping (String) -> Void) {
        self.events = events
        self.store = store
        self.windowStore = windowStore
        self.run = run
    }

    func start() {
        guard token == nil else { return }
        token = events.subscribe(owner: "drag.tools", events: Self.types, mode: .active) { [weak self] type, event in
            self?.handle(type, event) ?? .passThrough
        }
    }

    func stop() {
        if let token { events.unsubscribe(token) }
        token = nil
        lock.lock()
        phase = .idle
        following = false
        gliding = false
        lock.unlock()
        work.async { [self] in
            stopGlide()
            window = nil
        }
    }

    // MARK: Events (on the tap's thread)

    private func handle(_ type: CGEventType, _ event: CGEvent) -> EventDisposition {
        let config = store.current
        switch type {
        case .flagsChanged:
            handleFlags(event, config)
            return .passThrough
        case .mouseMoved:
            lock.lock()
            let active = following
            lock.unlock()
            if active { track(event.location) }
            return .passThrough
        case .scrollWheel:
            return wheel(event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return buttonDown(type, event, config)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return buttonDragged(event, config)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return buttonUp(event, config)
        default:
            return .passThrough
        }
    }

    private func buttonNumber(_ event: CGEvent) -> UInt32 {
        UInt32(max(0, event.getIntegerValueField(.mouseEventButtonNumber)))
    }

    private func buttonDown(_ type: CGEventType, _ event: CGEvent, _ config: DragToolsConfig) -> EventDisposition {
        lock.lock()
        let wasGliding = gliding
        lock.unlock()
        if wasGliding { work.async { [self] in stopGlide() } }
        let number = buttonNumber(event)
        let held = KeyModifiers.bits(from: event.flags)
        let dragScrollsThis = config.scrollEnabled && number == config.scrollButton && held == config.scrollModifier

        // A button that turns the wheel into actions: the press is held back, and a press with no wheel turn still clicks.
        if !dragScrollsThis, config.buttonScrolls.contains(where: { $0.button == number }) {
            let location = event.location
            lock.lock()
            wheelButton = number
            wheelScrolled = false
            wheelDown = location
            wheelAccumulated = 0
            lock.unlock()
            return .drop
        }

        // A second quick click of a button runs an action. The first click was an ordinary click.
        if let binding = config.doubleClicks.first(where: { $0.button == number && $0.modifiers == held }) {
            let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
            lock.lock()
            let previous = lastDown[number]
            let isSecond = previous.map { now &- $0 <= UInt64(config.doubleClickMs) } ?? false
            lastDown[number] = isSecond ? nil : now
            if isSecond { swallowUp.insert(number) }
            lock.unlock()
            if isSecond {
                let id = binding.actionId
                DispatchQueue.main.async { [run] in run(id) }
                return .drop
            }
        }
        guard dragScrollsThis else { return .passThrough }
        // Not in a window that gives its own meaning to dragging, such as an excluded app.
        let location = event.location
        lock.lock()
        phase = .pending
        button = config.scrollButton
        downLocation = location
        lastLocation = location
        lock.unlock()
        work.async { [self] in
            stopGlide()
            moves.removeAll()
            carryX = 0
            carryY = 0
        }
        return .drop
    }

    private func buttonDragged(_ event: CGEvent, _ config: DragToolsConfig) -> EventDisposition {
        lock.lock()
        let current = phase
        let from = lastLocation
        let origin = downLocation
        lock.unlock()
        // The window following the pointer is moved by the plain pointer; dragging has nothing to do with it.
        guard current != .idle else { return .passThrough }
        // Only a drag with the button that started this is taken. If its release was lost, the state clears here rather
        // than swallowing every later drag.
        let dragButton = buttonNumber(event)
        lock.lock()
        let started = button
        lock.unlock()
        if dragButton != started {
            lock.lock()
            phase = .idle
            lock.unlock()
            return .passThrough
        }
        let location = event.location
        if current == .pending, hypot(location.x - origin.x, location.y - origin.y) < 4 { return .drop }
        lock.lock()
        phase = .scrolling
        lastLocation = location
        lock.unlock()
        let dx = location.x - from.x
        let dy = location.y - from.y
        let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
        work.async { [self] in
            moves.append(DragMove(dx: dx, dy: dy, atMs: now))
            if moves.count > 12 { moves.removeFirst(moves.count - 12) }
            post(dx: dx, dy: dy, config: config)
        }
        return .drop
    }

    private func buttonUp(_ event: CGEvent, _ config: DragToolsConfig) -> EventDisposition {
        let number = buttonNumber(event)
        lock.lock()
        if swallowUp.remove(number) != nil {
            lock.unlock()
            return .drop
        }
        if wheelButton == number {
            let scrolled = wheelScrolled
            let origin = wheelDown
            wheelButton = nil
            lock.unlock()
            if !scrolled { work.async { Self.repost(button: number, at: origin, flags: event.flags) } }
            return .drop
        }
        lock.unlock()
        lock.lock()
        let current = phase
        let which = button
        let origin = downLocation
        if buttonNumber(event) == which { phase = .idle }
        lock.unlock()
        guard current != .idle, buttonNumber(event) == which else { return .passThrough }
        if current == .pending {
            // It was a click, not a drag: the app gets it after all.
            work.async { [self] in Self.repost(button: which, at: origin, flags: event.flags) }
        } else if config.momentum {
            let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
            work.async { [self] in
                velocity = dragReleaseVelocity(moves: moves, releasedAtMs: now)
                if velocity.x != 0 || velocity.y != 0 { startGlide(config: config) }
            }
        }
        return .drop
    }

    /// The wheel turned while a held-back button is down: each notch runs the action for that direction.
    private func wheel(_ event: CGEvent) -> EventDisposition {
        lock.lock()
        let button = wheelButton
        lock.unlock()
        guard let button, let binding = store.current.buttonScrolls.first(where: { $0.button == button }) else { return .passThrough }
        let delta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) / (event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 ? 20 : 8)
        lock.lock()
        wheelScrolled = true
        wheelAccumulated += delta
        var fire: String?
        if wheelAccumulated >= 1 { fire = binding.upActionId; wheelAccumulated = 0 }
        if wheelAccumulated <= -1 { fire = binding.downActionId; wheelAccumulated = 0 }
        lock.unlock()
        if let fire { DispatchQueue.main.async { [run] in run(fire) } }
        return .drop
    }

    // MARK: Scrolling and gliding (on `work`)

    private func post(dx: Double, dy: Double, config: DragToolsConfig) {
        let sign = config.scrollInvert ? -1.0 : 1.0
        carryX += dx * config.scrollSpeed * sign
        carryY += dy * config.scrollSpeed * sign
        let ix = Int32(carryX.rounded(.towardZero))
        let iy = Int32(carryY.rounded(.towardZero))
        carryX -= Double(ix)
        carryY -= Double(iy)
        guard ix != 0 || iy != 0 else { return }
        SmoothScrollDriver.postScroll(dx: ix, dy: iy, flags: [], location: CGEvent(source: nil)?.location ?? .zero)
    }

    private func startGlide(config: DragToolsConfig) {
        stopGlide()
        lock.lock()
        gliding = true
        lock.unlock()
        lastTick = DispatchTime.now().uptimeNanoseconds
        let source = DispatchSource.makeTimerSource(queue: work)
        source.schedule(deadline: .now() + .milliseconds(8), repeating: .milliseconds(8), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let dt = Double(now &- self.lastTick) / 1_000_000
            self.lastTick = now
            let step = dragGlideStep(velocity: self.velocity, dtMs: dt, keepPerFrame: config.momentumKeep)
            self.velocity = step.rest
            self.post(dx: step.dx, dy: step.dy, config: config)
            if step.rest.x == 0 && step.rest.y == 0 { self.stopGlide() }
        }
        glideTimer = source
        source.resume()
    }

    private func stopGlide() {
        glideTimer?.cancel()
        glideTimer = nil
        velocity = Velocity(x: 0, y: 0)
        lock.lock()
        gliding = false
        lock.unlock()
    }

    /// Sends a click on to the app after it was held back. Kriya's own events carry a marker so they are not caught again.
    private static func repost(button: UInt32, at point: CGPoint, flags: CGEventFlags) {
        let (down, up): (CGEventType, CGEventType) = {
            switch button {
            case 0: return (.leftMouseDown, .leftMouseUp)
            case 1: return (.rightMouseDown, .rightMouseUp)
            default: return (.otherMouseDown, .otherMouseUp)
            }
        }()
        let mouseButton = CGMouseButton(rawValue: button) ?? .center
        for (index, type) in [down, up].enumerated() {
            guard let click = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: mouseButton) else { continue }
            click.flags = flags
            click.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            click.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
            if index == 0 {
                click.post(tap: .cghidEventTap)
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { click.post(tap: .cghidEventTap) }
            }
        }
    }

    // MARK: A window that follows the pointer

    private func handleFlags(_ event: CGEvent, _ config: DragToolsConfig) {
        let held = KeyModifiers.bits(from: event.flags)
        lock.lock()
        let active = following
        lock.unlock()
        if config.followModifier != 0, held == config.followModifier, !active {
            let point = event.location
            lock.lock()
            following = true
            lock.unlock()
            work.async { [self] in begin(at: point) }
        } else if active, held != config.followModifier {
            lock.lock()
            following = false
            lock.unlock()
            work.async { [self] in window = nil }
        }
    }

    private func begin(at point: CGPoint) {
        window = nil
        let config = windowStore.currentConfig
        guard AXIsProcessTrusted(), let found = AXWindow.at(point), !config.isExcluded(appId: found.appID), !found.isFullScreen,
              let frame = found.frame else { return }
        window = found
        startFrame = frame
        startMouse = point
        latest = point
        found.raise()
    }

    private func track(_ point: CGPoint) {
        work.async { [self] in
            latest = point
            guard window != nil, !updateQueued else { return }
            updateQueued = true
            work.asyncAfter(deadline: .now() + .milliseconds(8)) { [self] in
                updateQueued = false
                guard let window else { return }
                window.setPosition(startFrame.x + latest.x - startMouse.x, startFrame.y + latest.y - startMouse.y)
            }
        }
    }
}
