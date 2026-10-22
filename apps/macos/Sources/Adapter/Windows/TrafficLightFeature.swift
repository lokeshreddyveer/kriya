import AppKit
import Combine
import SwiftUI

/// Carries out what a window button was set to do.
final class TrafficActionRunner {
    private let controller: WindowController
    private let executor: ActionExecutor
    private let library: ActionLibrary
    /// Ask before an app is quit from a window button. Set from the settings before each action.
    var confirmQuit = true

    init(controller: WindowController, executor: ActionExecutor, library: ActionLibrary) {
        self.controller = controller
        self.executor = executor
        self.library = library
    }

    /// `replayNative` performs the button's normal click. It is the way out whenever an action cannot be carried out, so
    /// a click is never just lost.
    func perform(_ action: TrafficAction, on window: AXWindow, button: TrafficButton, replayNative: @escaping () -> Void) {
        switch action {
        case .native:
            replayNative()
        case .doNothing:
            break
        case .closeWindow:
            if !window.press(.close) { replayNative() }
        case .quitApp:
            guard !confirmQuit || confirmQuitting(window.appName) else { return }
            if window.app?.terminate() != true { replayNative() }
        case .closeOrQuit:
            let open = AXWindow.windows(ofApp: window.pid).filter { $0.isStandard && !$0.isMinimized }
            if open.count > 1 {
                if !window.press(.close) { replayNative() }
            } else {
                guard !confirmQuit || confirmQuitting(window.appName) else { return }
                if window.app?.terminate() != true { replayNative() }
            }
        case .restoreMinimized:
            AXWindow.windows(ofApp: window.pid).first { $0.isMinimized }?.raise()
        case .restoreSize:
            // The window has to be the one in front for the undo to find it.
            window.raise()
            let controller = controller
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { controller.run(command: "window.restore") }
        case .layoutPalette:
            window.raise()
            let executor = executor
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Task { _ = await executor.perform(.builtin(command: "window.radial")) } }
        case .hideApp:
            if window.app?.hide() != true { replayNative() }
        case .hideOtherApps:
            for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular && app.processIdentifier != window.pid && app.bundleIdentifier != Bundle.main.bundleIdentifier {
                app.hide()
            }
        case .minimizeWindow:
            if !window.setMinimized(true) { replayNative() }
        case .minimizeAllWindows:
            for other in AXWindow.windows(ofApp: window.pid) where other.isStandard { other.setMinimized(true) }
        case .maximize:
            controller.toggleMaximize(window)
        case .toggleFullScreen:
            if !window.setFullScreen(!window.isFullScreen) { replayNative() }
        case .center:
            controller.center(window)
        case .snap(let layout):
            controller.snap(window, to: layout)
        case .run(let id):
            guard let saved = library.actions.first(where: { $0.id == id }) else { replayNative(); return }
            let executor = executor
            Task { if case .failure = await executor.perform(saved.action) { await MainActor.run { replayNative() } } }
        }
    }
}

private func confirmQuitting(_ appName: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Quit \(appName)?"
    alert.informativeText = "Anything you have not saved may be lost."
    alert.addButton(withTitle: "Quit")
    alert.addButton(withTitle: "Cancel")
    alert.alertStyle = .warning
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertFirstButtonReturn
}

/// Window buttons that do what you choose: per button, per modifier key, per app. Clicks that Kriya has no rule for, and
/// every click it cannot read, go straight through to the app untouched.
final class TrafficLightFeature: FeatureModule {
    let feature = FeatureId.trafficLights

    private struct Pending {
        let window: AXWindow
        let button: TrafficButton
        let frame: Rect
        let action: TrafficAction?       // nil: a repeat press to swallow
        let flags: CGEventFlags
        let downLocation: CGPoint
    }

    /// A press this soon after the last handled one, on the same window, is treated as a duplicate.
    private static let duplicateWindowNs: UInt64 = 350_000_000

    private var context: ServiceContext?
    private var runner: TrafficActionRunner?
    private var token: EventMonitor.Token?
    private var cancellables = Set<AnyCancellable>()

    private let lock = NSLock()
    private var pending: Pending?                                            // guarded by lock
    /// A title-bar click being held back until it is released.
    private struct TitlePending {
        let window: AXWindow
        let action: TrafficAction
    }
    private var titlePending: TitlePending?                                   // guarded by lock
    private var lastHandled: (key: String, at: UInt64)?                      // guarded by lock

    private var moveMonitor: Any?
    private var hoverWork: DispatchWorkItem?
    private var lastProbe: UInt64 = 0
    private let hoverMenu = HoverMenu()

    // MARK: FeatureModule

    func start(context: ServiceContext) throws {
        self.context = context
        runner = TrafficActionRunner(controller: context.windowController, executor: context.executor, library: context.library)
        context.windowController.displays.refresh()

        context.traffic.$config
            .combineLatest(context.traffic.$profiles)
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.reconfigure() }
            .store(in: &cancellables)
        reconfigure()
        Log.info("Buttons", "Window buttons started")
    }

    func stop() {
        cancellables.removeAll()
        if let token { context?.events.unsubscribe(token) }
        token = nil
        stopHover()
        lock.lock()
        pending = nil
        lastHandled = nil
        lock.unlock()
        context?.traffic.interceptionIssue = nil
        runner = nil
        context = nil
    }

    func systemDidWake() {
        reconfigure()
    }

    // MARK: Keeping the watchers in step with the settings

    /// Clicks are watched only while some button is customized. With nothing set, Kriya does not look at the mouse at all.
    private func reconfigure() {
        guard let context else { return }
        let traffic = context.traffic
        let config = traffic.currentConfig

        if traffic.isIdle {
            if let token { context.events.unsubscribe(token) }
            token = nil
            traffic.interceptionIssue = nil
        } else if token == nil {
            token = context.events.subscribe(owner: "buttons", events: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .otherMouseDown, .otherMouseUp], mode: .active) { [weak self] type, event in
                self?.handle(type, event) ?? .passThrough
            }
            // If macOS refuses the tap, the buttons keep working normally and the settings say why nothing changed.
            if case .failed(let reason) = context.events.state {
                traffic.interceptionIssue = reason
                if let token { context.events.unsubscribe(token) }
                token = nil
                Log.warning("Buttons", "Could not watch clicks; window buttons keep their normal behavior")
            } else {
                traffic.interceptionIssue = nil
            }
        }

        if config.hoverEnabled, config.hoverSets.contains(where: { !$0.actions.isEmpty }) {
            startHover()
        } else {
            stopHover()
        }
    }

    // MARK: Clicks (event tap thread)

    private func handle(_ type: CGEventType, _ event: CGEvent) -> EventDisposition {
        guard let context, context.profiles.isFeatureActive(.trafficLights) else { return .passThrough }
        let traffic = context.traffic
        let location = event.location

        switch type {
        case .otherMouseDown:
            // A middle-click on the title bar.
            guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else { return .passThrough }
            return startTitleBarPress(event, action: traffic.currentConfig.titleMiddleClick)
        case .otherMouseUp:
            return endTitleBarPress(event)
        case .leftMouseDown:
            // A double-click on the title bar.
            if event.getIntegerValueField(.mouseEventClickState) == 2,
               case .drop = startTitleBarPress(event, action: traffic.currentConfig.titleDoubleClick) {
                return .drop
            }
            guard !traffic.isIdle, Self.isInTitleBarCorner(location) else { return .passThrough }
            // A button that cannot be read is left alone, so the app keeps its normal behavior.
            guard let hit = AXWindow.trafficButton(at: location) else {
                traffic.count { $0.leftNative += 1 }
                return .passThrough
            }
            let modifiers = KeyModifiers.bits(from: event.flags) & ~KeyModifiers.function
            let action = traffic.resolve(appID: hit.window.appID, button: hit.button, modifiers: modifiers)
            if case .native = action {
                traffic.count { $0.leftNative += 1 }
                return .passThrough
            }
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            defer { lock.unlock() }
            if let last = lastHandled, last.key == hit.window.key, now &- last.at < Self.duplicateWindowNs {
                // The same button pressed again too soon: swallow it so the action does not run twice.
                pending = Pending(window: hit.window, button: hit.button, frame: hit.frame, action: nil, flags: event.flags, downLocation: location)
                traffic.count { $0.duplicatesSuppressed += 1 }
                return .drop
            }
            pending = Pending(window: hit.window, button: hit.button, frame: hit.frame, action: action, flags: event.flags, downLocation: location)
            return .drop

        case .leftMouseDragged:
            lock.lock()
            defer { lock.unlock() }
            return pending == nil ? .passThrough : .drop

        case .leftMouseUp:
            if case .drop = endTitleBarPress(event) { return .drop }
            lock.lock()
            let press = pending
            pending = nil
            if press?.action != nil, let press { lastHandled = (press.window.key, DispatchTime.now().uptimeNanoseconds) }
            lock.unlock()
            guard let press else { return .passThrough }
            // Like a real button: it acts only if the pointer is still on it when released.
            let inside = press.frame.cg.insetBy(dx: -3, dy: -3).contains(location)
            if inside, let action = press.action {
                traffic.count { $0.handled += 1 }
                let confirm = traffic.currentConfig.confirmQuit
                DispatchQueue.main.async { [weak self] in
                    self?.runner?.confirmQuit = confirm
                    self?.runner?.perform(action, on: press.window, button: press.button) {
                        traffic.count { $0.replayedAsNormal += 1 }
                        Self.replayClick(at: press.downLocation, flags: press.flags)
                    }
                }
            }
            return .drop

        default:
            return .passThrough
        }
    }

    /// Holds back a title-bar click that has an action. Anything that is not a plain stretch of title bar is left alone.
    private func startTitleBarPress(_ event: CGEvent, action: TrafficAction) -> EventDisposition {
        if case .native = action { return .passThrough }
        let location = event.location
        guard Self.isInTitleBarBand(location), let window = Self.titleBarWindow(at: location),
              let context, !context.traffic.isExcluded(appID: window.appID) else { return .passThrough }
        lock.lock()
        titlePending = TitlePending(window: window, action: action)
        lock.unlock()
        return .drop
    }

    /// Runs the held-back title-bar action when the button comes up.
    private func endTitleBarPress(_ event: CGEvent) -> EventDisposition {
        lock.lock()
        let press = titlePending
        titlePending = nil
        lock.unlock()
        guard let press else { return .passThrough }
        let confirm = context?.traffic.currentConfig.confirmQuit ?? true
        DispatchQueue.main.async { [weak self] in
            self?.runner?.confirmQuit = confirm
            self?.runner?.perform(press.action, on: press.window, button: .zoom, replayNative: {})
        }
        return .drop
    }

    /// The strip along the top of the window under the pointer, clear of the three buttons.
    static func isInTitleBarBand(_ point: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point) else { continue }
            return point.x - rect.minX > 84 && point.y - rect.minY < 38
        }
        return false
    }

    /// The window whose title bar is under the point: the point must be on the window itself or its title text, not on a
    /// button, a tab or a search field in the title bar.
    static func titleBarWindow(at point: CGPoint) -> AXWindow? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let element = hit else { return nil }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let name = role as? String, name == (kAXWindowRole as String) || name == (kAXStaticTextRole as String) else { return nil }
        guard let window = AXWindow.at(point), window.isStandard else { return nil }
        return window
    }

    /// The normal click, posted marked as Kriya's own so it passes straight through.
    static func replayClick(at location: CGPoint, flags: CGEventFlags) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let click = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left) else { continue }
            click.flags = flags
            click.setIntegerValueField(.mouseEventClickState, value: 1)
            click.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
            click.post(tap: .cghidEventTap)
        }
    }

    /// Cheap check first: only a click in the top-left corner of the window under the pointer can be on a window button,
    /// so every other click skips the Accessibility lookup entirely.
    static func isInTitleBarCorner(_ point: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point) else { continue }
            // The first window found is the one in front at this point, and it alone decides.
            return point.x - rect.minX < 110 && point.y - rect.minY < 50
        }
        return false
    }

    // MARK: Hover menus

    private func startHover() {
        guard moveMonitor == nil else { return }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            self?.pointerMoved(isClick: event.type == .leftMouseDown)
        }
    }

    private func stopHover() {
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
        moveMonitor = nil
        hoverWork?.cancel()
        hoverWork = nil
        hoverMenu.hide()
    }

    private func pointerMoved(isClick: Bool) {
        guard let context else { return }
        let point = DisplayManager.mouseLocation()
        if isClick {
            hoverWork?.cancel()
            hoverMenu.hide(unless: point)
            return
        }
        hoverMenu.pointerMoved(to: point)
        // The corner check costs a little, so it runs at most a dozen times a second.
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastProbe > 80_000_000 else { return }
        lastProbe = now
        hoverWork?.cancel()
        guard !hoverMenu.isVisible, Self.isInTitleBarCorner(point) else { return }

        let traffic = context.traffic
        let config = traffic.currentConfig
        let work = DispatchWorkItem { [weak self] in
            // Still resting where it was?
            let here = DisplayManager.mouseLocation()
            guard hypot(here.x - point.x, here.y - point.y) < 6, let hit = AXWindow.trafficButton(at: here) else { return }
            let appID = hit.window.appID
            guard !traffic.isExcluded(appID: appID) else { return }
            let actions = config.hoverActions(for: hit.button)
            guard !actions.isEmpty else { return }
            DispatchQueue.main.async { self?.showHover(hit, actions: actions) }
        }
        hoverWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(Int(config.hoverDelayMs)), execute: work)
    }

    private func showHover(_ hit: TrafficHit, actions: [TrafficAction]) {
        guard let runner else { return }
        hoverMenu.show(actions: actions, below: hit.frame, library: context?.library) { [weak self] action in
            self?.hoverMenu.hide()
            self?.context?.traffic.count { $0.handled += 1 }
            runner.perform(action, on: hit.window, button: hit.button) {}
        }
    }
}

extension TrafficConfig {
    func hoverActions(for button: TrafficButton) -> [TrafficAction] {
        hoverSets.first { $0.button == button }?.actions ?? []
    }
}

/// The small menu that appears when the pointer rests on a button. It goes away when the pointer leaves it.
final class HoverMenu {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
    }

    private var panel: Panel?
    private var buttonFrame = CGRect.zero

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(actions: [TrafficAction], below frame: Rect, library: ActionLibrary?, choose: @escaping (TrafficAction) -> Void) {
        let names = Dictionary(uniqueKeysWithValues: (library?.actions ?? []).map { ($0.id, $0.name) })
        let view = HoverMenuView(actions: actions, savedNames: names, choose: choose)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = self.panel ?? makePanel()
        self.panel = panel
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        buttonFrame = frame.cg
        let appKit = DisplayManager.appKitFrame(frame)
        panel.setFrame(NSRect(x: appKit.minX - 8, y: appKit.minY - size.height - 6, width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            if let panel, panel.alphaValue == 0 { panel.orderOut(nil) }
        })
    }

    /// A click outside the menu closes it.
    func hide(unless point: CGPoint) {
        guard let panel, panel.isVisible else { return }
        if !Self.contains(point, in: panel.frame, margin: 0) { hide() }
    }

    func pointerMoved(to point: CGPoint) {
        guard let panel, panel.isVisible else { return }
        let nearMenu = Self.contains(point, in: panel.frame, margin: 14)
        let nearButton = buttonFrame.insetBy(dx: -14, dy: -14).contains(point)
        if !nearMenu && !nearButton { hide() }
    }

    private static func contains(_ point: CGPoint, in appKitFrame: NSRect, margin: CGFloat) -> Bool {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let topLeft = CGRect(x: appKitFrame.minX, y: height - appKitFrame.maxY, width: appKitFrame.width, height: appKitFrame.height)
        return topLeft.insetBy(dx: -margin, dy: -margin).contains(point)
    }

    private func makePanel() -> Panel {
        let panel = Panel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        return panel
    }
}

private struct HoverMenuView: View {
    let actions: [TrafficAction]
    let savedNames: [String: String]
    let choose: (TrafficAction) -> Void

    /// The snap places, drawn as a small grid of screens with the target shaded. Everything else stays a list.
    private var snaps: [(action: TrafficAction, layout: WindowLayout)] {
        actions.compactMap { action in
            if case .snap(let layout) = action { return (action, layout) }
            return nil
        }
    }

    private var others: [TrafficAction] {
        actions.filter { if case .snap = $0 { return false } else { return true } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if snaps.count >= 3 {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(46), spacing: 6), count: 4), spacing: 6) {
                    ForEach(Array(snaps.enumerated()), id: \.offset) { _, item in
                        Button { choose(item.action) } label: { LayoutTile(layout: item.layout) }
                            .buttonStyle(HoverTileStyle())
                            .help(item.action.title)
                    }
                }
                .padding(6)
                if !others.isEmpty { Divider().padding(.horizontal, 6) }
            }
            ForEach(Array((snaps.count >= 3 ? others : actions).enumerated()), id: \.offset) { _, action in
                Button { choose(action) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: action.symbol).frame(width: 18)
                        Text(label(for: action))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverRowStyle())
            }
        }
        .padding(6)
        .frame(minWidth: 210)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
    }

    private func label(for action: TrafficAction) -> String {
        if case .run(let id) = action { return savedNames[id] ?? action.title }
        return action.title
    }
}

/// A tiny screen with the part a layout fills shaded in.
private struct LayoutTile: View {
    let layout: WindowLayout

    var body: some View {
        // Drawn from a full-size screen, so the layout's minimum window sizes do not stretch the little picture.
        let area = Rect(x: 0, y: 0, width: 1600, height: 1000)
        let frame = windowLayoutFrame(layout: layout, area: area, current: Rect(x: 400, y: 250, width: 800, height: 500), gap: 0)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08))
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.accent.opacity(0.75))
                .frame(width: max(4, 44 * frame.width / 1600), height: max(4, 28 * frame.height / 1000))
                .offset(x: 44 * frame.x / 1600, y: 28 * frame.y / 1000)
        }
        .frame(width: 44, height: 28)
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.3), lineWidth: 1))
        .padding(1)
    }
}

private struct HoverTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(1)
            .background(configuration.isPressed ? Theme.accent.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

private struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.accent.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }
}
