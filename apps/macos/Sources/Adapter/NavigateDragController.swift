import AppKit
import Combine

// MARK: - Holding the real pointer

/// Holding the real pointer still while a drag goes on, and always letting it go again.
protocol PointerFreezing: AnyObject {
    var isFrozen: Bool { get }
    /// Stops the pointer following the mouse. `onForcedRelease` is called if it is let go by one of the safety nets rather than by the
    /// drag ending (a timeout, sleep, Kriya quitting), so the drag can stop with it.
    func freeze(at point: CGPoint, maxSeconds: Double, onForcedRelease: @escaping () -> Void)
    /// Lets the pointer follow the mouse again, at `point` if one is given. Safe to call at any time, any number of times.
    func restore(at point: CGPoint?)
}

/// Pointer capture is the riskiest thing Kriya does: if the pointer stayed held, the Mac would seem frozen. So it is let go by every way
/// there is: the end of the drag, Escape, a time limit, sleep, a change of displays, Kriya quitting, and a check at every launch.
final class PointerFreeze: PointerFreezing {
    static let shared = PointerFreeze()

    private let lock = NSLock()
    private(set) var isFrozen = false
    private var watchdog: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var forced: (() -> Void)?

    /// At launch: the pointer follows the mouse again, whatever a run that ended badly left behind. Harmless when it already does.
    static func recoverAtLaunch() { CGAssociateMouseAndMouseCursorPosition(1) }

    func freeze(at point: CGPoint, maxSeconds: Double, onForcedRelease: @escaping () -> Void) {
        lock.lock()
        guard !isFrozen else { lock.unlock(); return }
        isFrozen = true
        forced = onForcedRelease
        lock.unlock()
        CGAssociateMouseAndMouseCursorPosition(0)
        // The time limit: let go after this long whatever happens.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(maxSeconds, 1))
        timer.setEventHandler { [weak self] in self?.forceRelease() }
        timer.resume()
        watchdog = timer
        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        observers = [
            nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.forceRelease() },
            nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.forceRelease() },
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.forceRelease() },
            ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.forceRelease() },
            ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.forceRelease() },
        ]
    }

    func restore(at point: CGPoint?) {
        lock.lock()
        let wasFrozen = isFrozen
        isFrozen = false
        forced = nil
        lock.unlock()
        watchdog?.cancel(); watchdog = nil
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        // Always, even when it was not frozen: following the mouse again is the safe state, and it is cheap.
        if wasFrozen, let point { CGWarpMouseCursorPosition(point) }
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func forceRelease() {
        lock.lock()
        let callback = forced
        lock.unlock()
        restore(at: nil)
        callback?()
    }
}

// MARK: - The virtual pointer

protocol VirtualPointerShowing: AnyObject {
    func show(at point: CGPoint, anchor: CGPoint)
    func move(to point: CGPoint)
    func hide()
}

/// A small click-through window with an arrow, following where the pointer would be. A ring stays where the real pointer is held.
final class VirtualPointerOverlay: VirtualPointerShowing {
    private var arrow: NSPanel?
    private var ring: NSPanel?

    private func make(size: NSSize, content: NSView) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = content
        return panel
    }

    /// Global points with a top left origin are turned into the bottom left origin AppKit windows use.
    private func appKit(_ p: CGPoint) -> NSPoint { NSPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y) }

    func show(at point: CGPoint, anchor: CGPoint) {
        hide()
        let cursor = NSCursor.arrow
        let image = NSImageView(image: cursor.image)
        image.frame = NSRect(origin: .zero, size: cursor.image.size)
        let arrowPanel = make(size: cursor.image.size, content: image)
        let ringView = NSView(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        ringView.wantsLayer = true
        ringView.layer?.cornerRadius = 13
        ringView.layer?.borderWidth = 2
        ringView.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
        let ringPanel = make(size: NSSize(width: 26, height: 26), content: ringView)
        let anchorAt = appKit(anchor)
        ringPanel.setFrameOrigin(NSPoint(x: anchorAt.x - 13, y: anchorAt.y - 13))
        ringPanel.orderFrontRegardless()
        arrow = arrowPanel
        ring = ringPanel
        move(to: point)
        arrowPanel.orderFrontRegardless()
    }

    func move(to point: CGPoint) {
        guard let arrow else { return }
        let at = appKit(point)
        // The arrow's tip is at its top left.
        arrow.setFrameOrigin(NSPoint(x: at.x - NSCursor.arrow.hotSpot.x, y: at.y - arrow.frame.height + NSCursor.arrow.hotSpot.y))
    }

    func hide() {
        for panel in [arrow, ring] { panel?.orderOut(nil); panel?.close() }
        arrow = nil
        ring = nil
    }

    deinit { hide() }
}

// MARK: - Doing things

protocol NavigateActionPosting: AnyObject {
    func scroll(dx: Double, dy: Double, phase: ScrollPhase, at point: CGPoint)
    func zoom(_ amount: Double, at point: CGPoint)
    func run(_ command: NavigateDragCommand)
    func click(button: UInt32, at point: CGPoint)
}

/// Posts scrolls with a gesture phase, the system's own shortcut keys, and Mission Control. Back, forward, Spaces, App Exposé and Show
/// Desktop are the keys macOS uses by default; they work only while those shortcuts are on in System Settings › Keyboard › Shortcuts.
final class SystemNavigateActions: NavigateActionPosting {
    private let scroller = PhasedScrollPoster()
    private var carry = ScrollCarry()

    func scroll(dx: Double, dy: Double, phase: ScrollPhase, at point: CGPoint) {
        let ends = phase == .ended || phase == .cancelled
        let (ix, iy) = carry.take(dx: dx, dy: dy, flush: ends)
        guard ix != 0 || iy != 0 || ends || phase == .began else { return }
        scroller.post(dx: ix, dy: iy, frame: ScrollFrame(dx: Double(ix), dy: Double(iy), phase: phase, momentum: .none), flags: [], location: point)
    }

    func zoom(_ amount: Double, at point: CGPoint) { scroller.zoom(amount, flags: [], location: point) }

    func run(_ command: NavigateDragCommand) {
        switch command {
        case .back: key(33, flags: .maskCommand)             // ⌘[
        case .forward: key(30, flags: .maskCommand)          // ⌘]
        case .spaceLeft: key(123, flags: .maskControl)       // ⌃←
        case .spaceRight: key(124, flags: .maskControl)      // ⌃→
        case .appExpose: key(125, flags: .maskControl)       // ⌃↓
        case .showDesktop: key(103, flags: [])               // F11
        case .commandTab: key(48, flags: .maskCommand)       // ⌘Tab
        case .missionControl:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        }
    }

    private func key(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    func click(button: UInt32, at point: CGPoint) {
        let (down, up): (CGEventType, CGEventType) = button == 0 ? (.leftMouseDown, .leftMouseUp) : button == 1 ? (.rightMouseDown, .rightMouseUp) : (.otherMouseDown, .otherMouseUp)
        let which = CGMouseButton(rawValue: button) ?? .center
        for (index, type) in [down, up].enumerated() {
            guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: which) else { continue }
            e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            e.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
            if index == 0 { e.post(tap: .cghidEventTap) } else { DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { e.post(tap: .cghidEventTap) } }
        }
    }
}

// MARK: - The controller

/// Click-and-drag navigation: hold a side button, drag, and the real pointer stays put while a virtual one moves and the drag scrolls,
/// zooms, goes back or forward, or opens Mission Control, App Exposé, the desktop or another Space. Off unless switched on.
final class NavigateDragController {
    private let events: EventMonitor
    private let freeze: PointerFreezing
    private let overlay: VirtualPointerShowing
    private let poster: NavigateActionPosting
    private let defaults: UserDefaults
    /// What the mouse rules want from a button with these keys: a press already taken by the drag tools or an app left alone is theirs.
    private let mouseClaims: (UInt32, UInt64) -> ButtonClaims
    private var token: EventMonitor.Token?
    private var cancellables = Set<AnyCancellable>()

    private let lock = NSLock()
    private var session: NavigateDragSession?
    private var config = NavigateDragConfig()
    private var scrolled = false
    private var swallowUp: Set<UInt32> = []
    private var settings = NavigateDragSettings()
    private var allowed = false

    private static let types: [CGEventType] = [.otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved, .keyDown]
    /// Before the drag tools (20) so a press is seen first; it gives way to them by asking the claims.
    static let priority = 25

    init(events: EventMonitor, defaults: UserDefaults = .standard, freeze: PointerFreezing = PointerFreeze.shared,
         overlay: VirtualPointerShowing = VirtualPointerOverlay(), poster: NavigateActionPosting = SystemNavigateActions(),
         mouseClaims: @escaping (UInt32, UInt64) -> ButtonClaims = { _, _ in ButtonClaims() }) {
        self.events = events
        self.defaults = defaults
        self.freeze = freeze
        self.overlay = overlay
        self.poster = poster
        self.mouseClaims = mouseClaims
        // Whatever an earlier run left behind, the pointer follows the mouse at the start.
        PointerFreeze.recoverAtLaunch()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    /// Starts or stops listening: only while the feature is switched on, and the system lets Kriya (Input Monitoring on, safe mode off,
    /// Mouse & Trackpad on).
    func refresh(allowed newAllowed: Bool? = nil) {
        let loaded = NavigateDragStore(defaults: defaults).settings
        lock.lock()
        if let newAllowed { allowed = newAllowed }
        settings = loaded
        config = loaded.config
        let shouldListen = allowed && loaded.enabled
        lock.unlock()
        if shouldListen, token == nil {
            token = events.subscribe(owner: "navigate.drag", events: Self.types, mode: .active, priority: Self.priority) { [weak self] type, event in
                self?.handle(type, event) ?? .passThrough
            }
        } else if !shouldListen, token != nil {
            stop()
        }
    }

    func stop() {
        if let token { events.unsubscribe(token) }
        token = nil
        endCapture(cancelled: true)
    }

    /// True while a drag is going on.
    var isCapturing: Bool { lock.lock(); defer { lock.unlock() }; return session != nil }

    // MARK: Events (on the tap's thread)

    func handle(_ type: CGEventType, _ event: CGEvent) -> EventDisposition {
        // Kriya's own events are never captured.
        if event.getIntegerValueField(.eventSourceUserData) == EventMonitor.syntheticMarker { return .passThrough }
        lock.lock()
        let active = session
        let current = config
        let on = settings.enabled && allowed
        lock.unlock()
        let button = UInt32(max(0, event.getIntegerValueField(.mouseEventButtonNumber)))

        // Switched off while a drag is going: it stops, and its release is still taken so nothing is left waiting.
        if !on, active != nil { endCapture(cancelled: true) }

        switch type {
        case .otherMouseDown:
            guard on, active == nil, button == current.button else { return .passThrough }
            let held = KeyModifiers.bits(from: event.flags)
            if current.modifier != 0, held & current.modifier != current.modifier { return .passThrough }
            // Another part of Kriya or an app left alone has this button: it is theirs.
            let claims = mouseClaims(button, held)
            if claims.excluded || claims.dragCapture { return .passThrough }
            begin(at: event.location, button: button, config: current)
            return .drop
        case .otherMouseDragged, .mouseMoved:
            guard let active, active.isActive else { return .passThrough }
            let dx = event.getDoubleValueField(.mouseEventDeltaX), dy = event.getDoubleValueField(.mouseEventDeltaY)
            apply(moving: dx, dy, current)
            return .drop
        case .otherMouseUp:
            lock.lock()
            let swallow = swallowUp.remove(button) != nil
            lock.unlock()
            guard swallow else { return .passThrough }
            finish(button: button)
            return .drop
        case .keyDown:
            // Escape stops a drag at once, and is not also given to the app.
            guard active != nil, event.getIntegerValueField(.keyboardEventKeycode) == 53 else { return .passThrough }
            endCapture(cancelled: true)
            return .drop
        default:
            return .passThrough
        }
    }

    // MARK: A drag

    private func begin(at point: CGPoint, button: UInt32, config: NavigateDragConfig) {
        var id = CGDirectDisplayID(), count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 1, &id, &count)
        if count == 0 { id = CGMainDisplayID() }
        let s = NavigateDragSession(startPoint: point, displayID: id, bounds: CGDisplayBounds(id))
        lock.lock()
        session = s
        scrolled = false
        swallowUp.insert(button)
        lock.unlock()
        freeze.freeze(at: point, maxSeconds: config.maxSeconds) { [weak self] in
            // A safety net let the pointer go: the drag stops with it.
            self?.endCapture(cancelled: true, alreadyRestored: true)
        }
        if config.showVirtualPointer { DispatchQueue.main.async { self.overlay.show(at: point, anchor: point) } }
    }

    private func apply(moving dx: Double, _ dy: Double, _ config: NavigateDragConfig) {
        lock.lock()
        guard var s = session else { lock.unlock(); return }
        let effects = s.move(dx: dx, dy: dy, config: config)
        session = s
        lock.unlock()
        perform(effects, start: s.startPoint, config: config)
    }

    private func perform(_ effects: [NavigateDragEffect], start: CGPoint, config: NavigateDragConfig) {
        for effect in effects {
            switch effect {
            case .pointer(let p):
                if config.showVirtualPointer { DispatchQueue.main.async { self.overlay.move(to: p) } }
            case .scroll(let dx, let dy):
                lock.lock(); let first = !scrolled; scrolled = true; lock.unlock()
                poster.scroll(dx: dx, dy: dy, phase: first ? .began : .changed, at: start)
            case .zoom(let amount):
                poster.zoom(amount, at: start)
            case .run(let command):
                poster.run(command)
            case .click:
                break
            }
        }
    }

    /// The button was let go.
    private func finish(button: UInt32) {
        lock.lock()
        guard var s = session else { lock.unlock(); return }
        let effects = s.end()
        let wasScrolling = scrolled
        let place = s.restorePoint(returnsToStart: config.returnsToStart)
        let start = s.startPoint
        session = nil
        scrolled = false
        lock.unlock()
        if wasScrolling { poster.scroll(dx: 0, dy: 0, phase: .ended, at: start) }
        freeze.restore(at: place)
        DispatchQueue.main.async { self.overlay.hide() }
        // A press and release with no drag between is the click it was.
        if effects.contains(.click) { poster.click(button: button, at: start) }
    }

    /// Stops a drag from outside. The pointer is let go, a scroll in progress is cancelled, and no click is sent.
    private func endCapture(cancelled: Bool, alreadyRestored: Bool = false) {
        lock.lock()
        guard var s = session else { lock.unlock(); if !alreadyRestored { freeze.restore(at: nil) }; return }
        s.cancel()
        let wasScrolling = scrolled
        let start = s.startPoint
        session = nil
        scrolled = false
        lock.unlock()
        if wasScrolling { poster.scroll(dx: 0, dy: 0, phase: .cancelled, at: start) }
        if !alreadyRestored { freeze.restore(at: config.returnsToStart ? start : nil) }
        DispatchQueue.main.async { self.overlay.hide() }
    }
}
