import AppKit
import SwiftUI

/// Remembers which apps and windows were used most recently, for ordering the switcher.
final class WindowRecency {
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

struct SwitcherEntry: Identifiable {
    let window: AXWindow
    let appName: String
    let title: String
    let icon: NSImage?
    let lastUsed: Int64
    var id: String { window.key }
}

final class SwitcherModel: ObservableObject {
    @Published var query = "" { didSet { rank() } }
    @Published private(set) var results: [SwitcherEntry] = []
    @Published var selected = 0
    /// Small pictures of the windows, by window key, when Screen Recording is allowed and the setting is on.
    @Published var thumbnails: [String: NSImage] = [:]

    private var all: [SwitcherEntry] = []

    func load(_ entries: [SwitcherEntry]) {
        all = entries
        thumbnails = [:]
        query = ""
        rank()
    }

    private func rank() {
        let items = all.map { SwitcherItem(id: $0.id, appName: $0.appName, title: $0.title, lastUsed: $0.lastUsed) }
        let order = windowRankSwitcher(items: items, query: query)
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        results = order.compactMap { byID[$0] }
        // With nothing typed, the first row is the window in use now; one step down is the one before it.
        selected = query.isEmpty && results.count > 1 ? 1 : 0
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + delta + results.count) % results.count
    }

    var current: SwitcherEntry? {
        results.indices.contains(selected) ? results[selected] : nil
    }
}

/// A search box over every open window. Type to filter, arrow keys to choose, Return to go there, Escape to close.
/// With nothing typed, the list is in order of last use and the second row is preselected, so the shortcut followed by
/// Return flips to the previous window.
final class WindowSwitcher: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let store: WindowStore
    private let recency: WindowRecency
    private let model = SwitcherModel()
    private var panel: Panel?

    init(store: WindowStore, recency: WindowRecency) {
        self.store = store
        self.recency = recency
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        guard isVisible else { show(); return }
        // In hold-and-release mode a second press steps to the next window, as ⌘Tab does.
        if store.currentConfig.switcherHoldRelease, releaseTimer != nil { model.move(1) } else { close() }
    }

    private var releaseTimer: Timer?

    /// With hold-and-release on: letting go of the keys that opened the switcher goes to the window chosen. Typing a search
    /// turns this off for that opening, so the list stays up.
    private func watchRelease() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift]
        let held = NSEvent.modifierFlags.intersection(relevant)
        guard store.currentConfig.switcherHoldRelease, !held.isEmpty else { return }
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.isVisible, self.model.query.isEmpty else {
                self.releaseTimer?.invalidate()
                self.releaseTimer = nil
                return
            }
            if !NSEvent.modifierFlags.intersection(relevant).isSuperset(of: held) {
                self.releaseTimer?.invalidate()
                self.releaseTimer = nil
                if let entry = self.model.current { self.choose(entry) } else { self.close() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseTimer = timer
    }

    func show() {
        guard AXIsProcessTrusted() else { return }
        let config = store.currentConfig
        let recency = recency
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var entries: [SwitcherEntry] = []
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, !config.isExcluded(appId: id) else { continue }
                for window in AXWindow.windows(ofApp: app.processIdentifier) where window.isStandard {
                    entries.append(SwitcherEntry(
                        window: window, appName: app.localizedName ?? id, title: window.title,
                        icon: app.icon, lastUsed: recency.lastUsed(window: window.key, pid: app.processIdentifier)
                    ))
                }
            }
            DispatchQueue.main.async { self?.present(entries) }
        }
    }

    func close() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        panel?.orderOut(nil)
    }

    private func present(_ entries: [SwitcherEntry]) {
        model.load(entries)
        if store.currentConfig.switcherThumbnails {
            let wanted = entries.compactMap { entry in entry.window.frame.map { (key: entry.window.key, pid: entry.window.pid, frame: $0) } }
            Task { [weak self] in
                let pictures = await WindowThumbnails.capture(wanted)
                await MainActor.run { self?.model.thumbnails = pictures }
            }
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY + frame.height * 0.12))
        }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        watchRelease()
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
        let view = SwitcherView(model: model, onChoose: { [weak self] in self?.choose($0) }, onClose: { [weak self] in self?.close() })
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
    let onChoose: (SwitcherEntry) -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
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
