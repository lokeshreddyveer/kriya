import AppKit
import Combine
import SwiftUI

/// The floating bar of actions that appears next to selected text.
final class SelectionToolbar {
    private final class Panel: NSPanel {
        /// Off by default: the bar never takes the keyboard from the app with the selection. Turned on for keyboard mode.
        var keyboardMode = false
        var onKey: (NSEvent) -> Bool = { _ in false }
        override var canBecomeKey: Bool { keyboardMode }
        override var canBecomeMain: Bool { false }
        override func keyDown(with event: NSEvent) { if !onKey(event) { super.keyDown(with: event) } }
    }

    private var panel: Panel?
    private let keys = ToolbarKeyModel()
    private var flat: [SelectionAction] = []
    private var chooseHandler: ((SelectionAction) -> Void)?
    private var hideWork: DispatchWorkItem?
    private(set) var isVisible = false

    func show(actions: [SelectionAction], config: SelectionConfig, anchor: CGRect?, pointer: CGPoint, onChoose: @escaping (SelectionAction) -> Void) {
        hideWork?.cancel()
        flat = actions
        chooseHandler = onChoose
        keys.reset()
        let view = ToolbarView(actions: actions, config: config, keys: keys, onChoose: { [weak self] action in
            self?.hide()
            onChoose(action)
        })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = host
        panel.setFrame(NSRect(origin: origin(for: size, anchor: anchor, pointer: pointer, position: config.position), size: size), display: true)
        panel.alphaValue = isVisible ? 1 : 0
        panel.orderFrontRegardless()
        isVisible = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        if config.autoHideSeconds > 0 {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Int(config.autoHideSeconds)), execute: work)
        }
    }

    /// Takes the keyboard so the bar can be driven without the mouse. Arrow keys or Tab move, Return runs, 1 to 9 run one, Escape leaves.
    /// The bar stays open until one is run or Escape is pressed.
    func beginKeyboard() {
        guard isVisible, let panel, !flat.isEmpty else { return }
        hideWork?.cancel()
        panel.keyboardMode = true
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        keys.begin(count: flat.count, titles: flat.map(\.title))
        panel.makeKeyAndOrderFront(nil)
        announce()
    }

    var isKeyboardMode: Bool { keys.active }

    private func announce() {
        let text = keys.announcement
        guard !text.isEmpty else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let key = ToolbarNavigator.key(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, shift: event.modifierFlags.contains(.shift)) else { return false }
        switch keys.press(key) {
        case .moved: announce(); return true
        case .choose(let i):
            if flat.indices.contains(i), let handler = chooseHandler { let action = flat[i]; hide(); handler(action) }
            return true
        case .close: hide(); return true
        case .ignored: return true
        }
    }

    func hide() {
        hideWork?.cancel()
        if let panel, panel.keyboardMode { panel.keyboardMode = false; panel.resignKey() }
        keys.end()
        guard isVisible, let panel else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            if self?.isVisible == false { panel?.orderOut(nil) }
        })
    }

    func contains(_ appKitPoint: NSPoint) -> Bool {
        guard isVisible, let panel else { return false }
        return panel.frame.insetBy(dx: -4, dy: -4).contains(appKitPoint)
    }

    /// Where the bar goes, in AppKit coordinates, kept on screen.
    private func origin(for size: NSSize, anchor: CGRect?, pointer: CGPoint, position: ToolbarPosition) -> NSPoint {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let target: CGRect
        if let anchor, position != .nearPointer {
            target = CGRect(x: anchor.minX, y: height - anchor.maxY, width: anchor.width, height: anchor.height)   // AppKit coordinates
        } else {
            target = CGRect(x: pointer.x, y: height - pointer.y, width: 1, height: 1)
        }
        var point = NSPoint(x: target.midX - size.width / 2, y: position == .belowSelection ? target.minY - size.height - 8 : target.maxY + 8)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: target.midX, y: target.midY)) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            point.x = min(max(point.x, frame.minX + 6), frame.maxX - size.width - 6)
            if point.y + size.height > frame.maxY { point.y = target.minY - size.height - 8 }   // no room above: go below
            if point.y < frame.minY { point.y = target.maxY + 8 }
            point.y = min(max(point.y, frame.minY + 6), frame.maxY - size.height - 6)
        }
        return point
    }

    private func makePanel() -> Panel {
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }
}

/// Which button the keyboard is on.
final class ToolbarKeyModel: ObservableObject {
    @Published private(set) var index = 0
    @Published private(set) var active = false
    private var navigator = ToolbarNavigator(count: 0)
    private var titles: [String] = []

    func reset() { active = false; index = 0 }
    func begin(count: Int, titles: [String]) { navigator = ToolbarNavigator(count: count); self.titles = titles; index = 0; active = true }
    func end() { active = false }
    func press(_ key: ToolbarNavigator.Key) -> ToolbarNavigator.Outcome {
        let outcome = navigator.handle(key)
        index = navigator.index
        return outcome
    }
    var announcement: String { navigator.announcement(titles: titles) }
    var highlightedTitle: String? { active && titles.indices.contains(index) ? titles[index] : nil }
}

private struct ToolbarView: View {
    let actions: [SelectionAction]
    let config: SelectionConfig
    @ObservedObject var keys: ToolbarKeyModel
    let onChoose: (SelectionAction) -> Void

    /// One button in the bar: an action, or a group of actions that opens a small menu.
    private enum Entry: Identifiable {
        case single(SelectionAction)
        case group(String, [SelectionAction])

        var id: String {
            switch self {
            case .single(let action): return action.id
            case .group(let name, _): return "group:" + name
            }
        }
    }

    /// Actions that share a group take the place of the first of them.
    private var entries: [Entry] {
        var result: [Entry] = []
        var position: [String: Int] = [:]
        for action in actions {
            if let group = action.group, !group.isEmpty {
                if let index = position[group], case .group(let name, let members) = result[index] {
                    result[index] = .group(name, members + [action])
                } else {
                    position[group] = result.count
                    result.append(.group(group, [action]))
                }
            } else {
                result.append(.single(action))
            }
        }
        return result
    }

    private var visible: [Entry] { Array(entries.prefix(Int(config.maxVisible))) }
    private var overflow: [Entry] { Array(entries.dropFirst(Int(config.maxVisible))) }

    private var button: CGFloat {
        switch config.size {
        case .small: return 26
        case .regular: return 32
        case .large: return 40
        }
    }

    private var font: Font {
        switch config.size {
        case .small: return .system(size: 12, weight: .medium)
        case .regular: return .system(size: 14, weight: .medium)
        case .large: return .system(size: 17, weight: .medium)
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(visible) { entry in
                switch entry {
                case .single(let action):
                    Button { onChoose(action) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: action.symbol.isEmpty ? "star" : action.symbol).symbolRenderingMode(.hierarchical)
                            if config.showLabels { Text(action.title).font(.system(size: 12)) }
                        }
                        .font(font)
                        .frame(minWidth: button, minHeight: button)
                        .padding(.horizontal, config.showLabels ? 6 : 0)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ToolbarButtonStyle(accent: config.theme == .accent))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent, lineWidth: keys.active && keys.highlightedTitle == action.title ? 2 : 0))
                    .help(action.title)
                case .group(let name, let members):
                    Menu {
                        ForEach(members) { action in
                            Button { onChoose(action) } label: { Label(action.title, systemImage: action.symbol.isEmpty ? "star" : action.symbol) }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: members.first.map { $0.symbol.isEmpty ? "star" : $0.symbol } ?? "star")
                            if config.showLabels { Text(name).font(.system(size: 12)) }
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
                        }
                        .font(font)
                        .frame(minWidth: button, minHeight: button)
                        .padding(.horizontal, 4)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(name)
                }
            }
            if !overflow.isEmpty {
                Rectangle().fill(Color.primary.opacity(0.16)).frame(width: 1, height: button * 0.5).padding(.horizontal, 2)
                Menu {
                    ForEach(overflow) { entry in
                        switch entry {
                        case .single(let action):
                            Button { onChoose(action) } label: { Label(action.title, systemImage: action.symbol.isEmpty ? "star" : action.symbol) }
                        case .group(let name, let members):
                            Menu(name) {
                                ForEach(members) { action in
                                    Button { onChoose(action) } label: { Label(action.title, systemImage: action.symbol.isEmpty ? "star" : action.symbol) }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(font).frame(minWidth: button, minHeight: button)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(5)
        .overlay(alignment: .bottom) {
            if let title = keys.highlightedTitle { Text("\(title) · Return").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.thinMaterial, in: Capsule()).offset(y: 18) }
        }
        .foregroundStyle(config.theme == .accent ? Color.white : Color.primary)
        .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        // A thin edge that is brighter at the top, like light catching a glass pill.
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.30), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5).padding(-0.5))
        .environment(\.colorScheme, scheme)
        .padding(6)   // room for the window shadow
    }

    private var scheme: ColorScheme {
        switch config.theme {
        case .light: return .light
        case .dark, .accent: return .dark
        case .system: return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        }
    }

    private var background: AnyShapeStyle {
        switch config.theme {
        case .accent: return AnyShapeStyle(Theme.accent)
        case .dark: return AnyShapeStyle(Color.black.opacity(0.82))
        case .light: return AnyShapeStyle(Color.white.opacity(0.95))
        case .system: return AnyShapeStyle(.regularMaterial)
        }
    }
}

private struct ToolbarButtonStyle: ButtonStyle {
    let accent: Bool

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    /// A button that lights up softly under the pointer and dips a little when pressed.
    private struct Face: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.26 : hovering ? 0.14 : 0))
                )
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .onHover { hovering = $0 }
                .animation(.smooth(duration: 0.12), value: hovering)
                .animation(.smooth(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// Shows the bar when text is selected and runs what is chosen.
final class SelectionService: ObservableObject {
    let store: SelectionStore
    let runner: SelectionActionRunner
    let toolbar = SelectionToolbar()
    let approvals: ScriptApprovals

    @Published private(set) var isRunning = false
    @Published private(set) var lastProblem: String?

    private let clipboard: ClipboardService
    private weak var profiles: ProfileStore?
    private var eventMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var hotkeys: HotkeyCenter?
    private var cancellables = Set<AnyCancellable>()
    private var pending: DispatchWorkItem?
    private var downPoint = CGPoint.zero
    private var downTime: TimeInterval = 0
    private var snapshot: SelectionSnapshot?
    private var pointer = CGPoint.zero
    /// Bumped on every new mouse press, so a slow or late check for an older selection is dropped.
    private var generation = 0
    private let queue = DispatchQueue(label: "app.kriya.selection", qos: .userInitiated)

    init(store: SelectionStore, clipboard: ClipboardService, approvals: ScriptApprovals) {
        self.store = store
        self.clipboard = clipboard
        self.approvals = approvals
        runner = SelectionActionRunner(store: store, clipboard: clipboard, approvals: approvals)
    }

    func start(profiles: ProfileStore) {
        guard !isRunning else { return }
        isRunning = true
        self.profiles = profiles
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .scrollWheel]
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in self?.handle(event) }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.toolbar.hide()
        }
        hotkeys = HotkeyCenter(owner: "Selection bar") { [weak self] _ in self?.showManually() }
        store.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in
                if let key = config.manualKey, config.manualModifiers != 0 {
                    self?.hotkeys?.update([ShortcutBinding(command: "selection.manual", keyCode: key, modifiers: config.manualModifiers)])
                } else {
                    self?.hotkeys?.update([])
                }
            }
            .store(in: &cancellables)
        Log.info("Selection", "Selection bar started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        cancellables.removeAll()
        hotkeys?.unregisterAll()
        hotkeys = nil
        pending?.cancel()
        toolbar.hide()
        store.flushPendingSaves()
        Log.info("Selection", "Selection bar stopped")
    }

    // MARK: Watching the mouse

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pending?.cancel()
            generation += 1
            if !toolbar.contains(NSEvent.mouseLocation) { toolbar.hide() }
            downPoint = DisplayManager.mouseLocation()
            downTime = event.timestamp
        case .leftMouseUp:
            let up = DisplayManager.mouseLocation()
            // A selection is made by dragging, or by double or triple clicking.
            let dragged = hypot(up.x - downPoint.x, up.y - downPoint.y) >= 6
            guard dragged || event.clickCount >= 2 else { return }
            pointer = up
            scheduleCheck()
        case .scrollWheel:
            if toolbar.isVisible { toolbar.hide() }
        default:
            break
        }
    }

    private func scheduleCheck() {
        let config = store.current.config
        // Apps update their selection a moment after the mouse is released. Look once early, and once more shortly
        // after if the first look found nothing, so a slow app still gets its bar.
        let delay = min(Int(config.activationDelayMs), 120)
        let work = DispatchWorkItem { [weak self] in self?.check(manual: false, retriesLeft: 2) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
    }

    /// Shows the bar for text that came from somewhere else, such as a browser extension, next to the pointer.
    func showText(_ text: String) {
        guard isRunning, profiles?.isFeatureActive(.selectionBar) ?? true else { return }
        pointer = DisplayManager.mouseLocation()
        let (actions, config) = store.current
        guard selectionLengthOk(config: config, text: text) else { return }
        let snapshot = SelectionSnapshot(text: text, editable: false, element: nil, bounds: nil, appID: nil, pid: 0)
        let ids = selectionActionsFor(actions: actions, config: config, appId: nil, editable: false, text: text)
        present(snapshot, ids: ids)
    }

    func showManually() {
        // Pressing the shortcut again while the bar is up hands the keyboard to it.
        if toolbar.isVisible, !toolbar.isKeyboardMode { toolbar.beginKeyboard(); return }
        pointer = DisplayManager.mouseLocation()
        openInKeyboardNext = UserDefaults.standard.bool(forKey: Self.startInKeyboardKey)
        check(manual: true)
    }

    /// Settings › Selection Bar › "Open straight in keyboard mode": the shortcut shows the bar already waiting for keys.
    static let startInKeyboardKey = "selection.startInKeyboard"
    private(set) var openInKeyboardNext = false

    /// A bar with only paste actions, next to the pointer, for a place where nothing can be selected (blank space in a
    /// document, an empty field). It does not look for a selection, and it does not move focus: the paste goes where the
    /// caret already is.
    func showPasteBar() {
        guard isRunning, profiles?.isFeatureActive(.selectionBar) ?? true else { return }
        pointer = DisplayManager.mouseLocation()
        let app = NSWorkspace.shared.frontmostApplication
        guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let (_, config) = store.current
        let actions = [
            SelectionAction(id: "paste-here", title: "Paste", symbol: "doc.on.clipboard", kind: .paste, enabled: true, applies: .anything, appIds: []),
            SelectionAction(id: "paste-here-plain", title: "Paste without formatting", symbol: "doc.plaintext", kind: .pastePlain, enabled: true, applies: .anything, appIds: []),
        ]
        snapshot = SelectionSnapshot(text: "", editable: true, element: nil, bounds: nil, appID: app?.bundleIdentifier, pid: app?.processIdentifier ?? 0)
        lastProblem = nil
        toolbar.show(actions: actions, config: config, anchor: nil, pointer: pointer) { [weak self] action in
            guard let self, let snapshot = self.snapshot else { return }
            self.runner.run(action, on: snapshot, pointer: self.pointer)
        }
    }

    // MARK: Finding the selection

    private func check(manual: Bool, retriesLeft: Int = 0) {
        // A request for keyboard mode belongs to one press of the shortcut; every way out of that press drops it.
        if !manual { openInKeyboardNext = false }
        guard isRunning, profiles?.isFeatureActive(.selectionBar) ?? true else { openInKeyboardNext = false; return }
        let app = NSWorkspace.shared.frontmostApplication
        guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else { openInKeyboardNext = false; return }
        let (actions, config) = store.current
        let behavior = selectionBehavior(config: config, appId: app?.bundleIdentifier)
        guard behavior.mode == .automatic || (manual && behavior.mode == .manualOnly) else { openInKeyboardNext = false; return }
        let monitor = clipboard.monitor
        let started = generation
        queue.async { [weak self] in
            if self?.generation != started { return }
            var found = SelectionReader.read()
            // Try the quick, silent read again before resorting to copying, which is slower and touches the clipboard.
            if found == nil, retriesLeft > 0, !manual {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(110)) { [weak self] in
                    guard let self, self.generation == started else { return }
                    self.check(manual: false, retriesLeft: retriesLeft - 1)
                }
                return
            }
            if found == nil, behavior.allowCopyFallback, let text = SelectionReader.readByCopying(monitor: monitor), !text.isEmpty, let app {
                found = SelectionSnapshot(text: text, editable: false, element: nil, bounds: nil, appID: app.bundleIdentifier, pid: app.processIdentifier)
            }
            if self?.generation != started { return }
            guard let snapshot = found, selectionLengthOk(config: config, text: snapshot.text) else {
                // Nothing to act on, so offer what still makes sense there: pasting. Keyboard mode was for a bar that never came.
                self?.openInKeyboardNext = false
                if manual { DispatchQueue.main.async { self?.lastProblem = "Nothing is selected, or this app does not share its selection."; self?.showPasteBar() } }
                return
            }
            let ids = selectionActionsFor(actions: actions, config: config, appId: snapshot.appID, editable: snapshot.editable, text: snapshot.text)
            DispatchQueue.main.async { self?.present(snapshot, ids: ids) }
        }
    }

    /// Lets part of the app leave an action out of the bar. Apple Intelligence's actions are left out on a Mac that cannot
    /// run it, or when the person turned them off. Set by the app.
    var isOffered: (SelectionAction) -> Bool = { _ in true }

    private func present(_ snapshot: SelectionSnapshot, ids: [String]) {
        let keyboard = openInKeyboardNext
        openInKeyboardNext = false
        let (actions, config) = store.current
        let chosen = ids.compactMap { id in actions.first { $0.id == id } }.filter(isOffered)
        guard !chosen.isEmpty else { return }
        self.snapshot = snapshot
        lastProblem = nil
        toolbar.show(actions: chosen, config: config, anchor: snapshot.bounds, pointer: pointer) { [weak self] action in
            guard let self, let snapshot = self.snapshot else { return }
            runner.run(action, on: snapshot, pointer: pointer)
        }
        if keyboard { toolbar.beginKeyboard() }
    }
}
