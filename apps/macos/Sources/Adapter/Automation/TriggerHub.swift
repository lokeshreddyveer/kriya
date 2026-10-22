import AppKit

/// Watches for the things workflows start on, and starts them. Each kind of source is set up only while an enabled
/// workflow wants it, so with nothing configured Kriya watches nothing.
final class TriggerHub {
    private weak var engine: AutomationEngine?
    private let context: ServiceContext
    private var workflows: [Workflow] = []

    private var hotkeys: HotkeyCenter?
    private var hotkeyIDs: [String: String] = [:]          // hotkey command → workflow id
    private var mouseMonitor: Any?
    private var gestureMonitor: Any?
    private var moveMonitor: Any?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    private var zone: String?
    private var dwellWork: [DispatchWorkItem] = []
    private var pinch: CGFloat = 0
    private var lastDisplayCount = NSScreen.screens.count
    private var displayWork: DispatchWorkItem?

    init(engine: AutomationEngine, context: ServiceContext) {
        self.engine = engine
        self.context = context
    }

    // MARK: Following the workflows

    func update(_ list: [Workflow]) {
        workflows = list.filter(\.enabled)
        configureHotkeys()
        configureMouse()
        configureGestures()
        configureMoves()
        configureNotifications()
    }

    func stop() {
        update([])
        context.clipboard.monitor.onRecorded = {}
    }

    private func fire(_ workflow: Workflow, _ source: String, input: String? = nil) {
        engine?.fire(workflow.id, source: source, input: input)
    }

    private func matching(_ test: (WorkflowTrigger) -> Bool) -> [Workflow] {
        workflows.filter { test($0.trigger) }
    }

    // MARK: Keyboard

    private func configureHotkeys() {
        let wanted = workflows.compactMap { w -> (String, ShortcutBinding)? in
            guard case .hotkey(let key, let modifiers) = w.trigger else { return nil }
            return (w.id, ShortcutBinding(command: "workflow.\(w.id.lowercased())", keyCode: key, modifiers: modifiers))
        }
        guard !wanted.isEmpty else {
            hotkeys?.unregisterAll()
            hotkeys = nil
            return
        }
        hotkeyIDs = Dictionary(wanted.map { ($0.1.command, $0.0) }, uniquingKeysWith: { first, _ in first })
        if hotkeys == nil {
            hotkeys = HotkeyCenter(owner: "Automation", title: { [weak self] command in
                guard let self, let id = hotkeyIDs[command] else { return command }
                return workflows.first(where: { $0.id == id })?.name ?? command
            }) { [weak self] command in
                guard let self, let id = hotkeyIDs[command], let workflow = workflows.first(where: { $0.id == id }) else { return }
                fire(workflow, "Keyboard shortcut")
            }
        }
        hotkeys?.update(wanted.map(\.1))
    }

    // MARK: Mouse buttons and screen positions

    private func configureMouse() {
        let any = !matching { if case .mouseButton = $0 { return true } else { return false } }.isEmpty
        guard any else {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
            return
        }
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown]) { [weak self] event in
            guard let self else { return }
            let modifiers = KeyModifiers.bits(from: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            for workflow in workflows {
                if case .mouseButton(let button, let wanted) = workflow.trigger, button == UInt32(event.buttonNumber), wanted == modifiers {
                    fire(workflow, "Mouse button")
                }
            }
        }
    }

    private func configureMoves() {
        let any = !matching {
            switch $0 {
            case .hotCorner, .screenEdge: return true
            default: return false
            }
        }.isEmpty
        guard any else {
            if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
            moveMonitor = nil
            dwellWork.forEach { $0.cancel() }
            zone = nil
            return
        }
        guard moveMonitor == nil else { return }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in self?.pointerMoved() }
    }

    /// Which corner or edge of a display the pointer is in, as a name.
    private func currentZone() -> String? {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }) else { return nil }
        let f = screen.frame
        let edge: CGFloat = 3, corner: CGFloat = 40
        let left = point.x <= f.minX + edge, right = point.x >= f.maxX - edge
        let bottom = point.y <= f.minY + edge, top = point.y >= f.maxY - edge
        let nearLeft = point.x <= f.minX + corner, nearRight = point.x >= f.maxX - corner
        let nearBottom = point.y <= f.minY + corner, nearTop = point.y >= f.maxY - corner
        if (left || right) && (nearTop || nearBottom) || (top || bottom) && (nearLeft || nearRight) {
            let isLeft = left || (!right && nearLeft), isTop = top || (!bottom && nearTop)
            return "corner:" + (isTop ? "top" : "bottom") + (isLeft ? "Left" : "Right")
        }
        if left { return "edge:left" }
        if right { return "edge:right" }
        if top { return "edge:top" }
        if bottom { return "edge:bottom" }
        return nil
    }

    private func pointerMoved() {
        let now = currentZone()
        guard now != zone else { return }
        zone = now
        dwellWork.forEach { $0.cancel() }
        dwellWork.removeAll()
        guard let now else { return }
        for workflow in workflows {
            let dwell: UInt32
            switch workflow.trigger {
            case .hotCorner(let corner, let ms):
                let name: String
                switch corner {
                case .topLeft: name = "topLeft"
                case .topRight: name = "topRight"
                case .bottomLeft: name = "bottomLeft"
                case .bottomRight: name = "bottomRight"
                }
                guard now == "corner:\(name)" else { continue }
                dwell = ms
            case .screenEdge(let edge, let ms):
                let name: String
                switch edge {
                case .top: name = "top"
                case .bottom: name = "bottom"
                case .left: name = "left"
                case .right: name = "right"
                }
                guard now == "edge:\(name)" else { continue }
                dwell = ms
            default:
                continue
            }
            let work = DispatchWorkItem { [weak self] in self?.fire(workflow, now.hasPrefix("corner") ? "Hot corner" : "Screen edge") }
            dwellWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(dwell)), execute: work)
        }
    }

    // MARK: Trackpad

    private func configureGestures() {
        let any = !matching { if case .trackpad = $0 { return true } else { return false } }.isEmpty
        guard any else {
            if let gestureMonitor { NSEvent.removeMonitor(gestureMonitor) }
            gestureMonitor = nil
            return
        }
        guard gestureMonitor == nil else { return }
        gestureMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.swipe, .magnify]) { [weak self] event in
            guard let self else { return }
            var gesture: TrackpadGesture?
            switch event.type {
            case .swipe:
                if event.deltaX > 0 { gesture = .swipeLeft } else if event.deltaX < 0 { gesture = .swipeRight }
                else if event.deltaY > 0 { gesture = .swipeUp } else if event.deltaY < 0 { gesture = .swipeDown }
            case .magnify:
                if event.phase == .began { pinch = 0 }
                pinch += event.magnification
                if event.phase == .ended || event.phase == .cancelled {
                    if pinch > 0.25 { gesture = .pinchOut } else if pinch < -0.25 { gesture = .pinchIn }
                    pinch = 0
                }
            default:
                break
            }
            guard let gesture else { return }
            for workflow in workflows {
                if case .trackpad(let wanted) = workflow.trigger, wanted == gesture { fire(workflow, "Trackpad gesture") }
            }
        }
    }

    // MARK: Apps, displays, clipboard, windows

    private func configureNotifications() {
        for entry in observers { entry.center.removeObserver(entry.token) }
        observers.removeAll()
        guard !workflows.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter

        let wantsApps = workflows.contains {
            switch $0.trigger {
            case .appActivated, .appLaunched, .appQuit: return true
            default: return false
            }
        }
        if wantsApps {
            observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                self?.appEvent(note) { if case .appActivated(let id) = $0 { return id } else { return nil } }
            }))
            observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                self?.appEvent(note) { if case .appLaunched(let id) = $0 { return id } else { return nil } }
            }))
            observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                self?.appEvent(note) { if case .appQuit(let id) = $0 { return id } else { return nil } }
            }))
        }

        let wantsDisplays = workflows.contains {
            switch $0.trigger {
            case .displayConnected, .displayDisconnected: return true
            default: return false
            }
        }
        if wantsDisplays {
            lastDisplayCount = NSScreen.screens.count
            let center = NotificationCenter.default
            observers.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.displaysChanged() }))
        }

        let wantsClipboard = workflows.contains { if case .clipboardChanged = $0.trigger { return true } else { return false } }
        context.clipboard.monitor.onRecorded = wantsClipboard ? { NotificationCenter.default.post(name: .kriyaClipboardRecorded, object: nil) } : {}
        if wantsClipboard {
            let center = NotificationCenter.default
            observers.append((center, center.addObserver(forName: .kriyaClipboardRecorded, object: nil, queue: .main) { [weak self] _ in self?.clipboardChanged() }))
        }

        if workflows.contains(where: { if case .windowPlaced = $0.trigger { return true } else { return false } }) {
            let center = NotificationCenter.default
            observers.append((center, center.addObserver(forName: .kriyaWindowPlaced, object: nil, queue: .main) { [weak self] note in
                self?.windowPlaced(note.userInfo?["layout"] as? String)
            }))
        }
    }

    private func appEvent(_ note: Notification, _ pick: (WorkflowTrigger) -> String?) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let id = app.bundleIdentifier else { return }
        for workflow in workflows where pick(workflow.trigger) == id { fire(workflow, "App event", input: app.localizedName) }
    }

    private func displaysChanged() {
        displayWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let count = NSScreen.screens.count
            let connected = count > lastDisplayCount, disconnected = count < lastDisplayCount
            lastDisplayCount = count
            for workflow in workflows {
                switch workflow.trigger {
                case .displayConnected where connected: fire(workflow, "Display connected")
                case .displayDisconnected where disconnected: fire(workflow, "Display disconnected")
                default: break
                }
            }
        }
        displayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func clipboardChanged() {
        let store = context.clipboard.store
        guard let newest = store.search("", limit: 1).first else { return }
        let text = store.blob(newest.id)?.plain
        for workflow in workflows {
            guard case .clipboardChanged(let kind, let contains) = workflow.trigger else { continue }
            if let kind, kind != newest.kind { continue }
            if let contains, !contains.isEmpty, text?.localizedCaseInsensitiveContains(contains) != true { continue }
            fire(workflow, "Copied", input: text)
        }
    }

    private func windowPlaced(_ command: String?) {
        let layout = command.flatMap { windowLayoutFromCommand(command: $0) }
        for workflow in workflows {
            guard case .windowPlaced(let wanted) = workflow.trigger else { continue }
            if let wanted, wanted != layout { continue }
            fire(workflow, "Window placed")
        }
    }
}
