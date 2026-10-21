import AppKit

/// Hold a modifier and drag anywhere in a window to move it, or hold another and drag to resize from the nearest
/// corner. The click is taken by Kriya, so it never reaches the app underneath. Needs Input Monitoring, because it
/// changes mouse events as they happen.
final class ModifierDrag {
    private enum Mode { case move, resize }

    private let events: EventMonitor
    private let store: WindowStore
    private var token: EventMonitor.Token?

    // Read on the tap's thread, written there too.
    private let lock = NSLock()
    private var engaged: Mode?

    // Used only on `work`.
    private let work = DispatchQueue(label: "app.kriya.windowdrag", qos: .userInteractive)
    private var window: AXWindow?
    private var startFrame = Rect(x: 0, y: 0, width: 0, height: 0)
    private var startMouse = CGPoint.zero
    private var mode: Mode = .move
    private var corner = (left: false, top: false)
    private var latest = CGPoint.zero
    private var updateQueued = false

    init(events: EventMonitor, store: WindowStore) {
        self.events = events
        self.store = store
    }

    func start() {
        guard token == nil else { return }
        token = events.subscribe(
            owner: "windows.drag", events: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp], mode: .active
        ) { [weak self] type, event in self?.handle(type, event) ?? .passThrough }
    }

    func stop() {
        if let token { events.unsubscribe(token) }
        token = nil
        lock.lock()
        engaged = nil
        lock.unlock()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> EventDisposition {
        switch type {
        case .rightMouseDown:
            // The move keys plus the right button resize from the nearest corner, so one set of keys does both.
            let config = store.currentConfig
            guard config.moveModifier != 0, KeyModifiers.bits(from: event.flags) == config.moveModifier else { return .passThrough }
            lock.lock()
            engaged = .resize
            lock.unlock()
            let location = event.location
            work.async { [self] in begin(.resize, at: location) }
            return .drop

        case .leftMouseDown:
            let config = store.currentConfig
            let held = KeyModifiers.bits(from: event.flags)
            let wanted: Mode?
            if config.moveModifier != 0, held == config.moveModifier {
                wanted = .move
            } else if config.resizeModifier != 0, held == config.resizeModifier {
                wanted = .resize
            } else {
                wanted = nil
            }
            guard let wanted else { return .passThrough }
            lock.lock()
            engaged = wanted
            lock.unlock()
            let location = event.location
            work.async { [self] in begin(wanted, at: location) }
            return .drop

        case .leftMouseDragged, .rightMouseDragged:
            lock.lock()
            let active = engaged != nil
            lock.unlock()
            guard active else { return .passThrough }
            let location = event.location
            work.async { [self] in
                latest = location
                guard !updateQueued else { return }
                updateQueued = true
                work.asyncAfter(deadline: .now() + .milliseconds(8)) { [self] in
                    updateQueued = false
                    update()
                }
            }
            return .drop

        case .leftMouseUp, .rightMouseUp:
            lock.lock()
            let active = engaged != nil
            engaged = nil
            lock.unlock()
            guard active else { return .passThrough }
            work.async { [self] in window = nil }
            return .drop

        default:
            return .passThrough
        }
    }

    private func begin(_ newMode: Mode, at point: CGPoint) {
        window = nil
        let config = store.currentConfig
        guard let found = AXWindow.at(point), !config.isExcluded(appId: found.appID), !found.isFullScreen,
              let frame = found.frame else { return }
        window = found
        mode = newMode
        startFrame = frame
        startMouse = point
        latest = point
        // Resize from whichever corner the pointer is nearest.
        corner = (point.x < frame.x + frame.width / 2, point.y < frame.y + frame.height / 2)
        found.raise()
    }

    private func update() {
        guard let window else { return }
        let dx = latest.x - startMouse.x
        let dy = latest.y - startMouse.y
        switch mode {
        case .move:
            window.setPosition(startFrame.x + dx, startFrame.y + dy)
        case .resize:
            let minimum = 120.0
            var x = startFrame.x, y = startFrame.y, width = startFrame.width, height = startFrame.height
            if corner.left {
                width = max(minimum, startFrame.width - dx)
                x = startFrame.x + (startFrame.width - width)
            } else {
                width = max(minimum, startFrame.width + dx)
            }
            if corner.top {
                height = max(minimum, startFrame.height - dy)
                y = startFrame.y + (startFrame.height - height)
            } else {
                height = max(minimum, startFrame.height + dy)
            }
            window.setSize(width, height)
            if corner.left || corner.top { window.setPosition(x, y) }
        }
    }
}
