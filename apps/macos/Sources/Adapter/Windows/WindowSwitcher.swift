import AppKit
import Combine
import SwiftUI

/// Remembers which apps and windows were used most recently, for ordering the switcher.
final class WindowRecency {
    /// One tally shared by the switcher and the window list, so both order windows by when they were really used.
    static let shared = WindowRecency()
    private let lock = NSLock()
    private var counter: Int64 = 0
    private var apps: [pid_t: Int64] = [:]
    private var windows: [String: Int64] = [:]
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        if let front = NSWorkspace.shared.frontmostApplication { bump(app: front.processIdentifier) }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.bump(app: app.processIdentifier)
            }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    func bump(app pid: pid_t) {
        lock.lock()
        counter += 1
        apps[pid] = counter
        lock.unlock()
    }

    func bump(window key: String) {
        lock.lock()
        counter += 1
        windows[key] = counter
        lock.unlock()
    }

    func lastUsed(window key: String, pid: pid_t) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return max(windows[key] ?? 0, apps[pid] ?? 0)
    }
}

/// How the switcher looks: a grid of window cards like AltTab, or a searchable list.
enum SwitcherStyle: String {
    case cards, list
    static let key = "switcherStyle"
    static var current: SwitcherStyle { SwitcherStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .cards }
}

struct SwitcherEntry: Identifiable {
    let window: AXWindow
    let appID: String
    let appName: String
    let title: String
    let icon: NSImage?
    let lastUsed: Int64
    var minimized: Bool
    var appHidden: Bool
    var id: String { window.key }
}

final class SwitcherModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { rank(reset: true) } } }
    @Published private(set) var results: [SwitcherEntry] = []
    @Published var selected = 0
    /// Small pictures of the windows, by window key, when Screen Recording is allowed.
    @Published var thumbnails: [String: NSImage] = [:]
    @Published var style: SwitcherStyle = .cards
    /// How many cards sit in a row, so the up and down arrows know how far to move.
    var columns = 1

    private var all: [SwitcherEntry] = []
    /// Only the windows of this app (the "windows of the front app" shortcut).
    private var appFilter: String?
    private var backwards = false
    /// The mouse has to move before pointing at a card chooses it, so a pointer left over a card does not pick it.
    private var armed = false
    private var openPointer = CGPoint.zero

    /// Starts over with a new list of windows.
    func load(_ entries: [SwitcherEntry], appOnly: String?, backwards: Bool, thumbnails seed: [String: NSImage]) {
        all = entries
        appFilter = appOnly
        self.backwards = backwards
        thumbnails = seed
        armed = false
        openPointer = NSEvent.mouseLocation
        if !query.isEmpty { query = "" } else { rank(reset: true) }
    }

    /// A fresher list arrived while the switcher is open: windows come and go, but the highlight stays on the same window.
    func reconcile(_ entries: [SwitcherEntry]) {
        let keep = current?.id
        all = entries
        rank(reset: false)
        if let keep, let index = results.firstIndex(where: { $0.id == keep }) { selected = index }
    }

    private func rank(reset: Bool) {
        let pool = appFilter.map { app in all.filter { $0.appID == app } } ?? all
        let items = pool.map { SwitcherItem(id: $0.id, appName: $0.appName, title: $0.title, lastUsed: $0.lastUsed) }
        let order = windowRankSwitcher(items: items, query: query)
        let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        results = order.compactMap { byID[$0] }
        if reset {
            // With nothing typed, the first card is the window in use now; one step on is the one before it.
            selected = query.isEmpty ? SwitcherLayout.startIndex(count: results.count, backwards: backwards) : 0
        } else {
            selected = min(selected, max(results.count - 1, 0))
        }
    }

    /// Takes one window out of the list (it was closed, or its app quit) and keeps the highlight in place.
    func remove(_ id: String) {
        all.removeAll { $0.id == id }
        let keep = selected
        results.removeAll { $0.id == id }
        selected = min(keep, max(results.count - 1, 0))
    }

    func update(_ id: String, _ change: (inout SwitcherEntry) -> Void) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[index])
        rank(reset: false)
    }

    func move(_ direction: SwitcherLayout.Direction) {
        selected = SwitcherLayout.move(from: selected, direction, count: results.count, columns: columns)
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + delta + results.count) % results.count
    }

    /// Goes to the next window of the app that is highlighted.
    func nextWindowOfSameApp() {
        if let next = SwitcherLayout.nextOfSameApp(from: selected, appIDs: results.map(\.appID)) { selected = next }
    }

    /// The pointer is over a card. It chooses it once the mouse has really moved.
    func hover(_ index: Int) {
        guard results.indices.contains(index), index != selected else { return }
        if !armed {
            let now = NSEvent.mouseLocation
            guard hypot(now.x - openPointer.x, now.y - openPointer.y) >= 4 else { return }
            armed = true
        }
        selected = index
    }

    var current: SwitcherEntry? {
        results.indices.contains(selected) ? results[selected] : nil
    }
}

/// A grid of cards (or a searchable list) over every open window, in the order they were last used. The shortcut followed
/// by letting go goes to the window before this one, and pressing it again steps on, as ⌘Tab does. Typing filters,
/// the arrow keys, Return, 1 to 9 and the mouse choose, ⌘W closes a window, ⌘M minimizes it, ⌘H hides its app, ⌘Q quits it.
final class WindowSwitcher: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let store: WindowStore
    private let recency: WindowRecency
    private let model = SwitcherModel()
    private var panel: Panel?
    private var screenFrame = CGRect.zero
    private var resizeWatcher: AnyCancellable?

    init(store: WindowStore, recency: WindowRecency) {
        self.store = store
        self.recency = recency
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: Keeping a fresh list ready

    /// The windows as last gathered, and the pictures taken of them, so the switcher can open at once and fill in after.
    private var cache: (entries: [SwitcherEntry], at: Date)?
    private var thumbnailCache: [String: NSImage] = [:]
    private var observers: [NSObjectProtocol] = []
    private var prewarmWork: DispatchWorkItem?

    /// Starts gathering the list in the background whenever apps change, so ⌥Tab never has to wait for it.
    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.schedulePrewarm() })
        }
        schedulePrewarm()
    }

    func stop() {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        prewarmWork?.cancel()
        close()
    }

    private func schedulePrewarm() {
        guard AXIsProcessTrusted(), session == nil else { return }
        prewarmWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.gather { entries in self?.cache = (entries, Date()) } }
        prewarmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: One use of the switcher

    /// One use of the switcher, from the first press of the shortcut to the choice.
    private struct Session {
        /// The keys held when the shortcut was pressed. Letting go of them is the choice (when hold-and-release is on).
        var held: NSEvent.ModifierFlags
        var backwards: Bool
        var appOnly: Bool
        var loaded = false
        /// Presses that came before the window list was ready; each one steps to the next window.
        var extraPresses = 0
        /// The keys were let go before the list was ready, so the choice is made the moment it is.
        var releasedEarly = false
    }

    private var session: Session?
    private var releaseTimer: Timer?
    private var thumbnailTask: Task<Void, Never>?
    private static let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift]

    /// The shortcut was pressed: opens the switcher, or steps on if it is already open.
    func toggle(backwards: Bool = false, appOnly: Bool = false) {
        guard var current = session else { begin(backwards: backwards, appOnly: appOnly); return }
        // Pressed again while open. With hold-and-release it steps on, as ⌘Tab does; otherwise it closes.
        if store.currentConfig.switcherHoldRelease, !current.held.isEmpty {
            if current.loaded { model.move(backwards ? -1 : 1) } else { current.extraPresses += backwards ? -1 : 1; session = current }
        } else {
            close()
        }
    }

    func show() { toggle() }

    /// Starts a use of the switcher right away, so keys let go of a moment later are not missed.
    private func begin(backwards: Bool, appOnly: Bool) {
        guard AXIsProcessTrusted() else { return }
        let hold = store.currentConfig.switcherHoldRelease
        let held = hold ? NSEvent.modifierFlags.intersection(Self.relevant) : []
        session = Session(held: held, backwards: backwards, appOnly: appOnly)
        if !held.isEmpty { watchRelease() }
        // The list gathered in the background is shown at once; a fresh one follows and is folded in.
        if let cache, Date().timeIntervalSince(cache.at) < 300 {
            loaded(cache.entries)
            gather { [weak self] fresh in self?.refreshed(fresh) }
        } else {
            gather { [weak self] fresh in self?.loaded(fresh) }
        }
    }

    /// Watches for the keys that opened the switcher being let go: that is the choice.
    private func watchRelease() {
        releaseTimer?.invalidate()
        let timer = Timer(timeInterval: 0.015, repeats: true) { [weak self] _ in
            guard let self, var current = self.session else { return }
            // Typing a search keeps the list open instead.
            if current.loaded, !self.model.query.isEmpty { self.stopWatching(); return }
            guard !NSEvent.modifierFlags.intersection(Self.relevant).isSuperset(of: current.held) else { return }
            self.stopWatching()
            if current.loaded {
                if let entry = self.model.current { self.choose(entry) } else { self.close() }
            } else {
                current.releasedEarly = true
                self.session = current
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseTimer = timer
    }

    private func stopWatching() {
        releaseTimer?.invalidate()
        releaseTimer = nil
    }

    /// Lists the windows away from the main thread and hands the list back on the main thread.
    private func gather(_ done: @escaping ([SwitcherEntry]) -> Void) {
        let config = store.currentConfig
        let recency = recency
        DispatchQueue.global(qos: .userInitiated).async {
            var entries: [SwitcherEntry] = []
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, !config.isExcluded(appId: id) else { continue }
                for window in AXWindow.windows(ofApp: app.processIdentifier) where window.isStandard {
                    entries.append(SwitcherEntry(
                        window: window, appID: id, appName: app.localizedName ?? id, title: window.title,
                        icon: app.icon, lastUsed: recency.lastUsed(window: window.key, pid: app.processIdentifier),
                        minimized: window.isMinimized, appHidden: app.isHidden
                    ))
                }
            }
            DispatchQueue.main.async {
                self.cache = (entries, Date())
                done(entries)
            }
        }
    }

    /// The list is ready. If the keys were already let go, go straight to the window (no flash of the switcher); otherwise
    /// show it with the steps that were pressed meanwhile applied.
    private func loaded(_ entries: [SwitcherEntry]) {
        guard var current = session, !current.loaded else { return }
        model.style = SwitcherStyle.current
        let appOnly = current.appOnly ? NSWorkspace.shared.frontmostApplication?.bundleIdentifier : nil
        model.load(entries, appOnly: appOnly, backwards: current.backwards, thumbnails: thumbnailCache)
        if current.extraPresses != 0 { model.move(current.extraPresses) }
        current.loaded = true
        current.extraPresses = 0
        session = current
        if current.releasedEarly {
            if let entry = model.current { choose(entry) } else { close() }
            return
        }
        present()
    }

    /// A fresher list arrived after the switcher opened from the saved one.
    private func refreshed(_ entries: [SwitcherEntry]) {
        guard session != nil, isVisible else { return }
        model.reconcile(entries)
        startThumbnails()
    }

    func close() {
        stopWatching()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        session = nil
        resizeWatcher = nil
        panel?.orderOut(nil)
        schedulePrewarm()
    }

    // MARK: The window

    private func present() {
        let config = store.currentConfig
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let pointerScreen = NSScreen.screens.first { $0.frame.contains(mouse) }
        let screen = config.switcherFollowPointer ? (pointerScreen ?? NSScreen.main) : (NSScreen.main ?? pointerScreen)
        screenFrame = screen?.visibleFrame ?? .zero
        fitPanel(animated: false, centered: true)
        // The window grows or shrinks by itself as typing narrows the cards.
        resizeWatcher = model.$results.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.fitPanel(animated: true, centered: false) }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 1
        }
        startThumbnails()
    }

    /// Sizes the window for the cards it holds, around the centre of the screen (or around where it already is).
    private func fitPanel(animated: Bool, centered: Bool) {
        guard let panel, !screenFrame.isEmpty else { return }
        let scale = store.currentConfig.switcherScale
        let target: NSRect
        if model.style == .cards {
            let width = screenFrame.width * 0.92
            let size = SwitcherLayout.size(count: model.results.count, maxWidth: width, scale: scale, searching: !model.query.isEmpty, maxHeight: screenFrame.height * 0.9)
            model.columns = SwitcherLayout.columns(count: model.results.count, maxWidth: width, scale: scale)
            let midX = centered ? screenFrame.midX : panel.frame.midX
            let midY = centered ? screenFrame.midY : panel.frame.midY
            target = NSRect(x: midX - size.width / 2, y: midY - size.height / 2, width: size.width, height: size.height)
        } else {
            target = NSRect(x: screenFrame.midX - 310, y: screenFrame.midY + screenFrame.height * 0.12 - 215, width: 620, height: 430)
        }
        guard target != panel.frame else { return }
        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: false)
        }
    }

    /// Takes pictures of the windows one at a time, the chosen window first, and shows each as it arrives. Pictures from
    /// earlier are already on the cards, so this only freshens them.
    private func startThumbnails() {
        let wantsPictures = model.style == .cards ? CGPreflightScreenCaptureAccess() : store.currentConfig.switcherThumbnails && CGPreflightScreenCaptureAccess()
        guard wantsPictures else { return }
        thumbnailTask?.cancel()
        let chosen = model.selected
        let ordered = model.results.enumerated().sorted { abs($0.offset - chosen) < abs($1.offset - chosen) }.map(\.element)
        let wanted = ordered.compactMap { entry in entry.window.frame.map { (key: entry.window.key, pid: entry.window.pid, frame: $0) } }
        let width = SwitcherMetrics(scale: store.currentConfig.switcherScale).previewWidth * 2
        thumbnailTask = Task { [weak self] in
            await WindowThumbnails.stream(wanted, width: width, isCancelled: { Task.isCancelled }) { key, picture in
                DispatchQueue.main.async {
                    guard let self, self.session != nil else { return }
                    if self.thumbnailCache.count > 120 { self.thumbnailCache.removeAll() }
                    self.thumbnailCache[key] = picture
                    withAnimation(.smooth(duration: 0.15)) { self.model.thumbnails[key] = picture }
                }
            }
        }
    }

    private func makePanel() -> Panel {
        let panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let view = SwitcherView(model: model, scale: { [weak self] in self?.store.currentConfig.switcherScale ?? 1 }, onChoose: { [weak self] in self?.choose($0) }, onClose: { [weak self] in self?.close() })
        let host = NSHostingView(rootView: view)
        host.wantsLayer = true
        panel.contentView = host
        return panel
    }

    private func choose(_ entry: SwitcherEntry) {
        recency.bump(window: entry.window.key)
        close()
        entry.window.raise()
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

private struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    let scale: () -> Double
    let onChoose: (SwitcherEntry) -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        if model.style == .cards { cards } else { listBody }
    }

    // MARK: Cards, like AltTab

    private var cards: some View {
        SwitcherCardsView(
            cards: model.results.map { SwitcherCardData(id: $0.id, appName: $0.appName, title: $0.title, icon: $0.icon, thumbnail: model.thumbnails[$0.window.key], isMinimized: $0.minimized, isHidden: $0.appHidden) },
            selected: model.selected, columns: model.columns, metrics: SwitcherMetrics(scale: scale()), query: model.query,
            onChoose: { index in if model.results.indices.contains(index) { onChoose(model.results[index]) } },
            onHover: { model.hover($0) },
            onClose: { index in
                guard model.results.indices.contains(index) else { return }
                let entry = model.results[index]
                if entry.window.close() { withAnimation(.smooth(duration: 0.18)) { model.remove(entry.id) } }
            }
        )
        .onAppear { focused = true }
        .focusable()
        // Keys are taken here, but the system's square focus outline is not drawn around the panel.
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: [.down, .repeat]) { press in cardKey(press) }
    }

    private func cardKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .leftArrow: model.move(.left); return .handled
        case .rightArrow: model.move(.right); return .handled
        case .upArrow: model.move(.up); return .handled
        case .downArrow: model.move(.down); return .handled
        case .tab: model.move(press.modifiers.contains(.shift) ? .left : .right); return .handled
        case .return: if let current = model.current { onChoose(current) }; return .handled
        case .escape:
            if model.query.isEmpty { onClose() } else { model.query = "" }
            return .handled
        case .delete:
            if !model.query.isEmpty { model.query.removeLast(); return .handled }
            return .ignored
        default:
            let typed = press.key.character
            let text = String(typed)
            if press.modifiers.contains(.command) {
                guard let current = model.current else { return .ignored }
                switch text.lowercased() {
                case "w":
                    if current.window.close() { withAnimation(.smooth(duration: 0.18)) { model.remove(current.id) } }
                case "m":
                    if current.window.minimize() { model.update(current.id) { $0.minimized = true } }
                case "h":
                    NSRunningApplication(processIdentifier: current.window.pid)?.hide()
                    for other in model.results where other.window.pid == current.window.pid { model.update(other.id) { $0.appHidden = true } }
                case "q":
                    NSRunningApplication(processIdentifier: current.window.pid)?.terminate()
                    withAnimation(.smooth(duration: 0.18)) { for other in model.results where other.window.pid == current.window.pid { model.remove(other.id) } }
                default: return .ignored
                }
                return .handled
            }
            if text == "`" || text == "~" { model.nextWindowOfSameApp(); return .handled }
            if model.query.isEmpty, let index = SwitcherLayout.index(forDigit: text, count: model.results.count) {
                onChoose(model.results[index])
                return .handled
            }
            // Anything else that can be typed narrows the cards to windows whose app or title match.
            if typed.isLetter || typed.isNumber || (typed == " " && !model.query.isEmpty) || ".-_".contains(typed) {
                model.query += text
                return .handled
            }
            return .ignored
        }
    }

    private var listBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search windows", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { if let current = model.current { onChoose(current) } }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                List(Array(model.results.enumerated()), id: \.element.id) { index, entry in
                    row(entry, selected: index == model.selected)
                        .id(entry.id)
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(index == model.selected ? Theme.accent.opacity(0.25) : .clear)
                                .padding(.horizontal, 6)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { onChoose(entry) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: model.selected) { _, new in
                    if model.results.indices.contains(new) { withAnimation(.smooth(duration: 0.15)) { proxy.scrollTo(model.results[new].id) } }
                }
                .overlay {
                    if model.results.isEmpty {
                        Text(model.query.isEmpty ? "No open windows" : "No matching windows").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
    }

    private func row(_ entry: SwitcherEntry, selected: Bool) -> some View {
        HStack(spacing: 12) {
            if let picture = model.thumbnails[entry.window.key] {
                Image(nsImage: picture)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 84, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                    .transition(.opacity)
            }
            if let icon = entry.icon {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title.isEmpty ? entry.appName : entry.title).lineLimit(1)
                if !entry.title.isEmpty {
                    Text(entry.appName).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if entry.window.isMinimized {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .animation(.smooth(duration: 0.2), value: model.thumbnails.count)
    }
}
