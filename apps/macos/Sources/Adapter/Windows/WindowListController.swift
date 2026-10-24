import AppKit
import Combine
import SwiftUI

/// The windows that are open, as a list that stays: gathered from the Accessibility API, with a picture of each when Screen
/// Recording allows, favorites that survive restarts, and actions on every window.
final class WindowListModel: ObservableObject {
    private static let favoritesKey = "windows.favoriteWindows.v1"

    @Published private(set) var rows: [WindowRow] = []
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var favorites: [PinnedWindow]
    @Published private(set) var isGathering = false
    @Published var query = ""
    @Published var grouping: WindowGrouping = .recent

    private var windows: [String: AXWindow] = [:]
    private let recency: WindowRecency
    private var thumbnailTask: Task<Void, Never>?
    private let defaults: UserDefaults

    init(recency: WindowRecency, defaults: UserDefaults = .standard) {
        self.recency = recency
        self.defaults = defaults
        favorites = (defaults.data(forKey: Self.favoritesKey).flatMap { try? JSONDecoder().decode([PinnedWindow].self, from: $0) }) ?? []
    }

    var sections: [WindowSection] { WindowListOrder.sections(rows, query: query, grouping: grouping) }
    var flat: [WindowRow] { sections.flatMap(\.rows) }

    private func saveFavorites() { if let data = try? JSONEncoder().encode(favorites) { defaults.set(data, forKey: Self.favoritesKey) } }

    // MARK: Gathering

    func refresh(withPictures: Bool = true) {
        guard AXIsProcessTrusted(), !isGathering else { return }
        isGathering = true
        recency.start()
        let favorites = favorites
        let recency = recency
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let displays = DisplayManager.current().map { (name: $0.name, full: $0.full) }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let focused = AXWindow.focused()?.key
            var rows: [WindowRow] = []
            var map: [String: AXWindow] = [:]
            var captures: [(key: String, pid: pid_t, frame: Rect)] = []
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
                for window in AXWindow.windows(ofApp: app.processIdentifier) where window.isStandard {
                    let frame = window.frame
                    let title = window.title
                    let row = WindowRow(
                        id: window.key, appID: id, appName: app.localizedName ?? id, title: title,
                        display: WindowListOrder.displayName(for: frame, displays: displays),
                        isMinimized: window.isMinimized, isAppHidden: app.isHidden,
                        isFront: window.key == focused && app.processIdentifier == front,
                        lastUsed: recency.lastUsed(window: window.key, pid: app.processIdentifier),
                        isFavorite: WindowFavorites.isFavorite(appID: id, title: title, in: favorites))
                    rows.append(row)
                    map[window.key] = window
                    if let frame, !row.isMinimized, !row.isAppHidden { captures.append((window.key, app.processIdentifier, frame)) }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.rows = rows
                self.windows = map
                self.isGathering = false
                if withPictures { self.startPictures(captures) }
            }
        }
    }

    private func startPictures(_ list: [(key: String, pid: pid_t, frame: Rect)]) {
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            await WindowThumbnails.stream(list, width: 220, isCancelled: { Task.isCancelled }) { key, image in
                DispatchQueue.main.async { self?.thumbnails[key] = image }
            }
        }
    }

    func stop() { thumbnailTask?.cancel() }

    // MARK: Actions

    func go(_ id: String) {
        guard let window = windows[id] else { return }
        recency.bump(window: id)
        window.raise()
    }

    func close(_ id: String) {
        guard let window = windows[id], window.close() else { return }
        rows.removeAll { $0.id == id }
        windows[id] = nil
    }

    func toggleMinimized(_ id: String) {
        guard let window = windows[id], let index = rows.firstIndex(where: { $0.id == id }) else { return }
        if rows[index].isMinimized { window.unminimize(); rows[index].isMinimized = false } else if window.minimize() { rows[index].isMinimized = true }
    }

    func hideApp(of id: String) {
        guard let window = windows[id] else { return }
        NSRunningApplication(processIdentifier: window.pid)?.hide()
        for i in rows.indices where windows[rows[i].id]?.pid == window.pid { rows[i].isAppHidden = true }
    }

    func quitApp(of id: String) {
        guard let window = windows[id] else { return }
        NSRunningApplication(processIdentifier: window.pid)?.terminate()
        let pid = window.pid
        rows.removeAll { windows[$0.id]?.pid == pid }
    }

    func toggleFavorite(_ id: String) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        favorites = WindowFavorites.toggled(appID: row.appID, title: row.title, in: favorites)
        saveFavorites()
        for i in rows.indices { rows[i].isFavorite = WindowFavorites.isFavorite(appID: rows[i].appID, title: rows[i].title, in: favorites) }
    }

    func removeFavorite(_ id: String) {
        favorites.removeAll { $0.id == id }
        saveFavorites()
        for i in rows.indices { rows[i].isFavorite = WindowFavorites.isFavorite(appID: rows[i].appID, title: rows[i].title, in: favorites) }
    }

    /// Makes the window in front a favorite, or not. Works without the list being open.
    func toggleFrontFavorite() {
        guard let window = AXWindow.focused(), let app = NSRunningApplication(processIdentifier: window.pid), let id = app.bundleIdentifier else { return }
        favorites = WindowFavorites.toggled(appID: id, title: window.title, in: favorites)
        saveFavorites()
    }

    /// Goes to the nth favorite window that is open (1 is the first favorite).
    func goToFavorite(number: Int) {
        guard AXIsProcessTrusted() else { return }
        let favorites = favorites
        guard favorites.indices.contains(number - 1) else { return }
        let favorite = favorites[number - 1]
        DispatchQueue.global(qos: .userInitiated).async { [recency] in
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == favorite.appID {
                if let match = AXWindow.windows(ofApp: app.processIdentifier).first(where: { $0.isStandard && favorite.matches(appID: favorite.appID, title: $0.title) }) {
                    DispatchQueue.main.async { recency.bump(window: match.key); match.raise() }
                    return
                }
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: favorite.appID) {
                DispatchQueue.main.async { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
            }
        }
    }
}

/// The window list as a panel that opens over everything: type to search, Return goes to the window, Esc closes.
final class WindowListController: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel { override var canBecomeKey: Bool { true } }

    let model: WindowListModel
    private var panel: Panel?

    init(recency: WindowRecency) { model = WindowListModel(recency: recency) }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? close() : show() }

    func show() {
        guard AXIsProcessTrusted() else { return }
        if panel == nil {
            let p = Panel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            p.title = "Windows"
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.applyPopupPrivacy()
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.delegate = self
            p.setFrameAutosaveName("KriyaWindowList")
            p.contentView = NSHostingView(rootView: WindowListView(model: model, onClose: { [weak self] in self?.close() }))
            p.center()
            panel = p
        }
        model.query = ""
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    func close() {
        model.stop()
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}
