import AppKit
import Combine

/// What the person sees while the five seconds run. A check replaces it with a recorder.
protocol ReplacementHUDShowing: AnyObject {
    func show(_ text: String)
    func hide()
}

final class ReplacementHUD: ReplacementHUDShowing {
    private var panel: NSPanel?
    private var label: NSTextField?

    func show(_ text: String) {
        if panel == nil {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 20, weight: .semibold)
            field.textColor = .white
            field.alignment = .center
            field.maximumNumberOfLines = 3
            field.preferredMaxLayoutWidth = 520
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 110))
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
            box.layer?.cornerRadius = 16
            field.frame = NSRect(x: 30, y: 20, width: 520, height: 70)
            box.addSubview(field)
            let p = NSPanel(contentRect: box.frame, styleMask: .borderless, backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.level = .screenSaver
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.contentView = box
            if let screen = NSScreen.main {
                p.setFrameOrigin(NSPoint(x: screen.frame.midX - 290, y: screen.frame.maxY - 220))
            }
            panel = p
            label = field
        }
        label?.stringValue = text
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        label = nil
    }
}

/// Lets the left and right buttons be replaced. This is the riskiest thing Kriya can do to the mouse, so it is off by default and, even
/// when switched on, does nothing until it is armed with a five-second confirmation. It turns itself off for Escape pressed three times,
/// a button hammered many times, Safe Mode, a lost permission, sleep, a locked screen, a change of displays and a failed event tap, and
/// it can be paused from the menu bar or by a command bound to a key. Nothing is remembered between runs: every start is not armed.
final class PrimaryButtonReplacementController: ObservableObject {
    /// Before the chords (30) and the navigation drag (25): replacing a button comes first.
    static let priority = 35

    enum Status: Equatable {
        case off
        case countdown(confirm: UInt32, seconds: Int)
        case armed
        case paused
        case stopped(String)
    }

    @Published private(set) var status = Status.off

    private let events: EventMonitor
    private let defaults: UserDefaults
    private let run: (String) -> Void
    private let hud: ReplacementHUDShowing
    private let now: () -> Double
    /// Lets go of a press that Kriya itself made by replacing a button. A check replaces it so no real event is posted.
    private let releaseButton: (UInt32) -> Void
    /// Whether a physical button is down right now. A check replaces it.
    private let physicalIsDown: (UInt32) -> Bool
    private var token: EventMonitor.Token?
    private var cancellables = Set<AnyCancellable>()
    private var ticker: DispatchSourceTimer?

    private let lock = NSLock()
    private var arming = ReplacementArming()
    private var settings = PrimaryButtonReplacementSettings()
    private var allowed = false
    private var denial = ReplacementStop.permissionLost
    private var escape = EscapeTriplePress()
    private var rage = RageClickDetector()
    /// Buttons held now, and what each became at the press, so its release and drags match even if the settings change meanwhile.
    private var inFlight: [UInt32: ReplacementTarget] = [:]
    /// A confirming press: its release is not passed on either.
    private var swallowUp: Set<UInt32> = []
    /// Timers waiting for a physical button to come up before releasing a press Kriya made.
    private var owedTimers: [DispatchSourceTimer] = []

    private static let types: [CGEventType] = [
        .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged, .keyDown,
    ]

    init(events: EventMonitor, defaults: UserDefaults = .standard, run: @escaping (String) -> Void,
         hud: ReplacementHUDShowing = ReplacementHUD(), now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         releaseButton: @escaping (UInt32) -> Void = { PrimaryButtonReplacementController.postRelease(button: $0) },
         physicalIsDown: @escaping (UInt32) -> Bool = { PrimaryButtonReplacementController.isPhysicallyDown($0) },
         watchEventTap: Bool = true) {
        self.releaseButton = releaseButton
        self.physicalIsDown = physicalIsDown
        self.events = events
        self.defaults = defaults
        self.run = run
        self.hud = hud
        self.now = now
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.publisher(for: name).sink { [weak self] _ in self?.stop(.sleep) }.store(in: &cancellables)
        }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.stop(.displaysChanged) }.store(in: &cancellables)
        if watchEventTap {
            events.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
                if case .failed = state { self?.stop(.eventTapFailed) }
            }.store(in: &cancellables)
        }
    }

    // MARK: Switching it on and off

    /// Listens only while it is switched on and the system lets Kriya (Input Monitoring on, safe mode off, Mouse & Trackpad on). Losing
    /// any of that turns off a replacement that was armed.
    func refresh(allowed newAllowed: Bool? = nil, denial why: ReplacementStop? = nil) {
        let loaded = PrimaryButtonReplacementStore(defaults: defaults).settings
        lock.lock()
        if let newAllowed { allowed = newAllowed }
        if let why { denial = why }
        settings = loaded
        let canListen = allowed && loaded.enabled
        let wasActive = arming.isArmed || arming.isCountingDown
        let lostIt = !canListen && wasActive
        let reason: ReplacementStop = !loaded.enabled ? .switchedOff : denial
        lock.unlock()
        if canListen {
            if token == nil {
                token = events.subscribe(owner: "button.replacement", events: Self.types, mode: .active, priority: Self.priority) { [weak self] type, event in
                    self?.handle(type, event) ?? .passThrough
                }
            }
        } else {
            if lostIt { stop(reason) }
            if token != nil { unsubscribe() }
            lock.lock(); let idle = arming.state == .off; lock.unlock()
            if !loaded.enabled, !idle { setOff() }
        }
        // The configuration changing under an armed replacement turns it off: what was confirmed is not what is set now.
        lock.lock()
        let changedWhileArmed = canListen && arming.isArmed && !loaded.config.canArm
        lock.unlock()
        if changedWhileArmed { stop(.switchedOff) }
    }

    private func unsubscribe() {
        if let token { events.unsubscribe(token) }
        token = nil
    }

    private func setOff() {
        lock.lock()
        arming.stop(.switchedOff)
        lock.unlock()
        finishStopping(message: nil)
    }

    /// Everything is put back: held buttons released, the countdown window closed, the replacement no longer in force.
    func stop(_ reason: ReplacementStop) {
        lock.lock()
        let was = arming.state
        guard was != .off else { lock.unlock(); return }
        arming.stop(reason)
        lock.unlock()
        finishStopping(message: reason == .switchedOff || reason == .quit ? nil : reason.message)
    }

    /// Releases buttons that were held as another button, closes the window and updates the status.
    private func finishStopping(message: String?) {
        lock.lock()
        let held = inFlight
        inFlight = [:]
        swallowUp = []
        escape.reset(); rage.reset()
        lock.unlock()
        // No blanket release: only a press Kriya itself made, and only once the physical button that caused it has been let go, so a press
        // belonging to another app or device is never cut short.
        for (physical, target) in held { if case .button(let b) = target { owe(release: b, until: physical) } }
        stopTicker()
        DispatchQueue.main.async {
            self.hud.hide()
            self.status = message.map(Status.stopped) ?? .off
        }
    }

    /// A press Kriya made on a replaced button is released once, when the physical button that caused it comes up. Checked every 50 ms for
    /// at most half a minute.
    private func owe(release target: UInt32, until physical: UInt32) {
        let started = now()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        var done = false
        timer.setEventHandler { [weak self] in
            guard let self, !done else { return }
            if self.physicalIsDown(physical), self.now() - started < 30 { return }
            done = true
            timer.cancel()
            self.lock.lock()
            self.owedTimers.removeAll { $0 === timer }
            self.lock.unlock()
            self.releaseButton(target)
        }
        // Kept alive until it has done its one release.
        lock.lock()
        owedTimers.append(timer)
        lock.unlock()
        timer.resume()
    }

    static func isPhysicallyDown(_ button: UInt32) -> Bool {
        guard let b = CGMouseButton(rawValue: button) else { return false }
        return CGEventSource.buttonState(.combinedSessionState, button: b)
    }

    /// The release of one press Kriya made by replacing a button.
    static func postRelease(button: UInt32) {
        let location = CGEvent(source: nil)?.location ?? .zero
        guard let type = ReplacementEvents.converted(.leftMouseUp, toButton: button),
              let up = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: CGMouseButton(rawValue: button) ?? .center) else { return }
        up.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        up.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
        up.post(tap: .cghidEventTap)
    }

    // MARK: Arming

    /// Starts the five seconds. Returns why it could not, or nil.
    @discardableResult
    func arm() -> String? {
        lock.lock()
        guard allowed, settings.enabled else { lock.unlock(); return "Switch button replacement on first. It also needs Input Monitoring, and Safe Mode off." }
        guard settings.config.canArm else {
            lock.unlock()
            return settings.config.replacesAnything ? "That would leave no button that can click. Keep the left button, or make the right button act as the left." : "Choose what a button should become first."
        }
        guard arming.begin(config: settings.config, now: now()) else { lock.unlock(); return "It is already on." }
        let confirm = arming.confirmButton ?? 0
        lock.unlock()
        publishCountdown(confirm: confirm)
        startTicker()
        return nil
    }

    /// The menu-bar command and any key bound to it: pause what is running, or start the confirmation again.
    func togglePause() {
        lock.lock()
        let running = arming.isArmed || arming.isCountingDown
        lock.unlock()
        if running { pause() } else { arm() }
    }

    func pause() {
        lock.lock()
        arming.pause()
        lock.unlock()
        finishStopping(message: nil)
        DispatchQueue.main.async { self.status = .paused }
    }

    private func publishCountdown(confirm: UInt32) {
        lock.lock()
        let seconds = Int(arming.remaining(now: now()).rounded(.up))
        lock.unlock()
        let name = ButtonChord.name(confirm).lowercased()
        let text = "Press the \(name) button to confirm — \(seconds)\nIf you do nothing, the buttons stay as they are."
        DispatchQueue.main.async {
            self.hud.show(text)
            self.status = .countdown(confirm: confirm, seconds: seconds)
        }
    }

    private func startTicker() {
        stopTicker()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        ticker = timer
    }

    private func stopTicker() { ticker?.cancel(); ticker = nil }

    private func tick() {
        lock.lock()
        arming.tick(now: now())
        let state = arming.state
        lock.unlock()
        switch state {
        case .countdown(_, let confirm): publishCountdown(confirm: confirm)
        case .stopped(let reason): finishStopping(message: reason.message)
        default: stopTicker()
        }
    }

    // MARK: Events (on the tap's thread)

    func handle(_ type: CGEventType, _ event: CGEvent) -> EventDisposition {
        if event.getIntegerValueField(.eventSourceUserData) == EventMonitor.syntheticMarker { return .passThrough }
        let t = now()

        // The way out that needs no mouse: Escape three times. It is never swallowed, so the app in front still gets it.
        if type == .keyDown {
            guard event.getIntegerValueField(.keyboardEventKeycode) == 53, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return .passThrough }
            lock.lock()
            let panic = (arming.isArmed || arming.isCountingDown) && escape.press(at: t)
            lock.unlock()
            if panic { stop(.escapeThreeTimes) }
            return .passThrough
        }

        let physical: UInt32 = (type == .leftMouseDown || type == .leftMouseUp || type == .leftMouseDragged) ? 0 : 1
        let isDown = type == .leftMouseDown || type == .rightMouseDown
        let isUp = type == .leftMouseUp || type == .rightMouseUp

        lock.lock()
        // The confirmation: the press asked for, within the five seconds. It, and its release, are not passed on.
        if isDown, arming.isCountingDown, arming.physicalPress(physical, now: t) {
            swallowUp.insert(physical)
            lock.unlock()
            stopTicker()
            DispatchQueue.main.async { self.hud.hide(); self.status = .armed }
            return .drop
        }
        if isUp, swallowUp.remove(physical) != nil { lock.unlock(); return .drop }

        // A release or a drag follows the press it belongs to, whatever the settings say now.
        if !isDown, let target = inFlight[physical] {
            if isUp { inFlight[physical] = nil }
            lock.unlock()
            return disposition(for: target, type: type, event: event, runAction: false)
        }
        guard arming.isArmed, isDown, let target = settings.config.target(for: physical) else { lock.unlock(); return .passThrough }

        // Many presses very quickly: the mouse may not be behaving, so it is turned off.
        if rage.press(at: t) { lock.unlock(); stop(.rageClicking); return .passThrough }
        inFlight[physical] = target
        lock.unlock()
        return disposition(for: target, type: type, event: event, runAction: true)
    }

    private func disposition(for target: ReplacementTarget, type: CGEventType, event: CGEvent, runAction: Bool) -> EventDisposition {
        switch target {
        case .button(let b):
            guard let newType = ReplacementEvents.converted(type, toButton: b), let copy = event.copy() else { return .passThrough }
            copy.type = newType
            copy.setIntegerValueField(.mouseEventButtonNumber, value: Int64(b))
            return .replace(copy)
        case .action(let id):
            if runAction { DispatchQueue.main.async { self.run(id) } }
            return .drop
        }
    }
}
