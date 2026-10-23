import AppKit
import Combine

/// What window management has been doing, for the Diagnostics pane.
final class WindowDiagnostics: ObservableObject {
    @Published private(set) var operations = 0
    @Published private(set) var failures = 0
    @Published private(set) var lastMilliseconds = 0.0
    @Published private(set) var worstMilliseconds = 0.0
    @Published private(set) var recent: [String] = []
    /// Apps that did not end up where they were told, by how many times. Often a minimum or fixed window size.
    @Published private(set) var resistedApps: [String: Int] = [:]
    @Published var hotkeyFailures: [String] = []

    private var totalMilliseconds = 0.0

    var averageMilliseconds: Double { operations == 0 ? 0 : totalMilliseconds / Double(operations) }

    func record(label: String, app: String, milliseconds: Double, miss: Double, ok: Bool) {
        operations += 1
        totalMilliseconds += milliseconds
        lastMilliseconds = milliseconds
        worstMilliseconds = max(worstMilliseconds, milliseconds)
        if !ok { failures += 1 }
        if ok, miss > 3 { resistedApps[app, default: 0] += 1 }
        let result = ok ? (miss > 3 ? "off by \(Int(miss)) pt" : "ok") : "failed"
        note("\(label) · \(app) · \(String(format: "%.0f", milliseconds)) ms · \(result)")
    }

    func note(_ text: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        recent.append("\(stamp)  \(text)")
        if recent.count > 40 { recent.removeFirst(recent.count - 40) }
    }

    func reset() {
        operations = 0; failures = 0; lastMilliseconds = 0; worstMilliseconds = 0
        totalMilliseconds = 0; recent = []; resistedApps = [:]
    }
}

struct RestoreOutcome: Equatable {
    var placed = 0
    var missing = 0
    /// Windows the layout did not place that were minimized, hidden or closed as the layout asks.
    var tidied = 0
    /// Apps that were not running and were opened, to be placed once their window appears.
    var opened = 0
    /// Window by window, what became of the layout.
    var report: RestoreReport?
}

/// A window that is open now, offered as a replacement for one a layout could not find.
struct WindowChoice: Identifiable {
    let id = UUID()
    let appID: String
    let appName: String
    let title: String
    fileprivate let window: AXWindow
    fileprivate let frame: Rect
}

/// Moves and resizes other apps' windows. Every operation checks that there is a window, that its app is not excluded and
/// that it can be resized, remembers where the window was (for undo), and measures what happened.
final class WindowController: ObservableObject {
    let displays: DisplayManager
    let diagnostics = WindowDiagnostics()
    @Published private(set) var lastMessage: String?
    /// How the latest layout restore went, window by window.
    @Published private(set) var lastReport: RestoreReport?
    /// The layout that report is about, so a replacement window can be remembered for it and the restore can be tried again.
    @Published private(set) var lastLayout: SavedLayout?

    private let core: KriyaCore
    let store: WindowStore
    private let history = FrameHistory()
    private var lastApplied: [String: (layout: WindowLayout, frame: Rect)] = [:]
    /// The frame a window had before Kriya snapped it, kept while it stays snapped, so dragging it away can give that size back.
    private var sizeBeforeSnap: [String: Rect] = [:]
    private var snapshotTimer: Timer?
    private var suppressSnapshotUntil = Date.distantPast
    private var lastSnapshotFingerprint = ""
    private var previousDisplayKey = ""
    /// Windows parked at the screen edge.
    /// The app kept in a column at the side.
    lazy var todo = TodoManager(controller: self)
    lazy var stash = StashManager(displays: displays, config: { [unowned self] in self.store.currentConfig })

    init(core: KriyaCore, store: WindowStore, displays: DisplayManager) {
        self.core = core
        self.store = store
        self.displays = displays
        previousDisplayKey = displays.setKey
    }

    // MARK: Commands

    /// Set while a "…under the pointer" command runs, so it acts on the window the pointer is over, not the focused one.
    private var pointerOverride = false

    /// Runs a window command by name (`window.left_half`, `window.size.<id>`, …). Returns false if it is not one of ours.
    @discardableResult
    func run(command: String) -> Bool {
        // "window.pointer.left_half" is "window.left_half" for the window under the pointer, even if it is not in front.
        if command.hasPrefix("window.pointer.") {
            pointerOverride = true
            defer { pointerOverride = false }
            return run(command: "window." + command.dropFirst("window.pointer.".count))
        }
        switch command {
        case "window.screen_left": moveToScreen(dx: -1, dy: 0); return true
        case "window.screen_right": moveToScreen(dx: 1, dy: 0); return true
        case "window.screen_up": moveToScreen(dx: 0, dy: -1); return true
        case "window.screen_down": moveToScreen(dx: 0, dy: 1); return true
        default: break
        }
        if let layout = windowLayoutFromCommand(command: command) {
            apply(layout)
            return true
        }
        if command.hasPrefix("window.size."), let size = store.sizes.first(where: { store.sizeCommand($0) == command }) {
            applyCustom(size)
            return true
        }
        if command.hasPrefix("window.layout."), let layout = store.layouts.first(where: { store.layoutCommand($0) == command }) {
            restore(layout)
            return true
        }
        switch command {
        case "window.restore": undo()
        case "window.restore_original": restoreOriginal()
        case "window.next_display": moveToDisplay(offset: 1)
        case "window.previous_display": moveToDisplay(offset: -1)
        case "window.apply_rules": applyRulesToOpenWindows()
        case "window.pointer_to_window": movePointerToActiveWindow()
        case "window.stash": stash.toggleFocused()
        case "window.unstash_all": stash.unstashAll()
        case "window.todo_toggle": todo.toggleFocused()
        case "window.todo_focus": todo.focus()
        default:
            if runExtraOp(command) { return true }
            if let direction = windowDirectionFromCommand(command: command) {
                focusWindow(direction)
                return true
            }
            return false
        }
        return true
    }

    // MARK: Layouts

    func apply(_ layout: WindowLayout, cycle: Bool = true) {
        guard let (window, current, display) = target() else { return }
        var chosen = layout
        let config = store.currentConfig
        if cycle, config.cycleSizes, let last = lastApplied[window.key], windowFrameMiss(wanted: last.frame, actual: current) < 4 {
            chosen = windowCycleLayout(pressed: layout, previous: last.layout)
        }
        var frame = windowLayoutFrame(layout: chosen, area: usableArea(display), current: current, gap: config.gap)
        // On an ultrawide display a maximized window can be kept to a comfortable width.
        if chosen == .maximize { frame = windowLimitWidth(frame: frame, area: usableArea(display), maxWidth: config.ultrawideMaxWidth) }
        place(window, to: frame, from: current, label: chosen.title, layout: chosen)
    }

    func applyCustom(_ size: CustomSize) {
        guard let (window, current, display) = target() else { return }
        place(window, to: windowCustomFrame(size: size, area: usableArea(display)), from: current, label: "Size: \(size.name)", layout: nil)
    }

    /// Puts a window in a layout, for drag snapping and rules, where the caller already has the window and the display.
    func place(_ window: AXWindow, layout: WindowLayout, on display: DisplayInfo, from original: Rect? = nil) {
        guard let current = original ?? window.frame else { return }
        let frame = windowLayoutFrame(layout: layout, area: usableArea(display), current: current, gap: store.currentConfig.gap)
        place(window, to: frame, from: current, label: layout.title, layout: layout)
    }

    // MARK: Displays

    func moveToDisplay(offset: Int) {
        guard let (window, current, display) = target() else { return }
        let ordered = displays.ordered
        guard ordered.count > 1, let index = ordered.firstIndex(where: { $0.id == display.id }) else {
            note("Only one display is connected")
            return
        }
        let next = ordered[(index + offset + ordered.count) % ordered.count]
        let frame = windowTranslateFrame(frame: current, from: usableArea(display), to: usableArea(next), preserveProportions: store.currentConfig.preserveProportions)
        let previous = lastApplied[window.key]?.layout
        place(window, to: frame, from: current, label: "Move to \(next.name)", layout: previous)
    }

    /// Moves the window to the display that lies in a direction from the one it is on. Down is positive, as on screen.
    func moveToScreen(dx: Double, dy: Double) {
        guard let (window, current, display) = target() else { return }
        func centre(_ r: Rect) -> (x: Double, y: Double) { (r.x + r.width / 2, r.y + r.height / 2) }
        let here = centre(display.full)
        let candidates = displays.ordered.filter { $0.id != display.id }.filter { other in
            let c = centre(other.full)
            return dx != 0 ? (c.x - here.x) * dx > 0 : (c.y - here.y) * dy > 0
        }
        guard let next = candidates.min(by: { a, b in
            let ca = centre(a.full), cb = centre(b.full)
            return hypot(ca.x - here.x, ca.y - here.y) < hypot(cb.x - here.x, cb.y - here.y)
        }) else {
            note("There is no display that way")
            return
        }
        let frame = windowTranslateFrame(frame: current, from: usableArea(display), to: usableArea(next), preserveProportions: store.currentConfig.preserveProportions)
        place(window, to: frame, from: current, label: "Move to \(next.name)", layout: lastApplied[window.key]?.layout)
    }

    // MARK: Actions on a given window (used by the window buttons)

    func snap(_ window: AXWindow, to layout: WindowLayout) {
        guard let frame = window.frame, !window.isFullScreen, let display = displays.display(containing: frame) else { return }
        place(window, layout: layout, on: display, from: frame)
    }

    func center(_ window: AXWindow) {
        snap(window, to: .center)
    }

    /// Fills the display without native full screen. Doing it again puts the window back.
    func toggleMaximize(_ window: AXWindow) {
        guard let frame = window.frame, !window.isFullScreen, let display = displays.display(containing: frame) else { return }
        let limit = store.currentConfig.ultrawideMaxWidth
        let full = windowLimitWidth(
            frame: windowLayoutFrame(layout: .maximize, area: usableArea(display), current: frame, gap: store.currentConfig.gap),
            area: usableArea(display), maxWidth: limit
        )
        if windowFrameMiss(wanted: full, actual: frame) < 6, let back = history.undo(key: window.key, current: frame) {
            apply(back, to: window, label: "Restore from maximize")
        } else {
            place(window, to: full, from: frame, label: "Maximize", layout: .maximize)
        }
    }

    /// A window that was snapped by Kriya and is now being dragged away: gives it back the size it had before, with the
    /// pointer at the same place along its title bar. Returns the new frame, or nil if the window was not snapped.
    func restoreSizeForDrag(_ window: AXWindow, current: Rect, pointer: CGPoint) -> Rect? {
        guard let last = lastApplied[window.key], windowFrameMiss(wanted: last.frame, actual: current) < 6,
              let before = sizeBeforeSnap[window.key] else { return nil }
        let share = current.width > 0 ? (pointer.x - current.x) / current.width : 0.5
        let frame = Rect(x: pointer.x - share * before.width, y: current.y, width: before.width, height: before.height)
        lastApplied[window.key] = nil
        sizeBeforeSnap[window.key] = nil
        guard AXWindow.withoutEnhancedInterface(pid: window.pid, { window.setFrame(frame) }) else { return nil }
        return window.frame ?? frame
    }

    // MARK: Undo

    func undo() {
        guard let (window, current, _) = target(checkResizable: false), let back = history.undo(key: window.key, current: current) else {
            note("Nothing to undo")
            return
        }
        apply(back, to: window, label: "Undo")
    }

    func restoreOriginal() {
        guard let (window, _, _) = target(checkResizable: false), let original = history.original(key: window.key) else {
            note("No original position is remembered")
            return
        }
        apply(original, to: window, label: "Restore original")
    }

    private func apply(_ frame: Rect, to window: AXWindow, label: String) {
        lastApplied[window.key] = nil
        let started = DispatchTime.now()
        let ok = AXWindow.withoutEnhancedInterface(pid: window.pid) { window.setFrame(frame) }
        record(label: label, window: window, wanted: frame, started: started, ok: ok)
    }

    // MARK: The one place windows are moved

    func place(_ window: AXWindow, to frame: Rect, from current: Rect, label: String, layout: WindowLayout?) {
        if let id = window.app?.bundleIdentifier, WindowLockStore.shared.isLocked(appID: id, title: window.title) {
            setMessage("\(window.appName) is locked, so Kriya did not move it.")
            return
        }
        history.record(key: window.key, frame: current)
        let wasSnapped = lastApplied[window.key].map { windowFrameMiss(wanted: $0.frame, actual: current) < 6 } ?? false
        let started = DispatchTime.now()
        let ok = AXWindow.withoutEnhancedInterface(pid: window.pid) { window.setFrame(frame) }
        let actual = record(label: label, window: window, wanted: frame, started: started, ok: ok)
        if ok, layout != nil, !wasSnapped { sizeBeforeSnap[window.key] = current }
        if let layout, ok { lastApplied[window.key] = (layout, actual) } else { lastApplied[window.key] = nil }
        if ok { NotificationCenter.default.post(name: .kriyaWindowPlaced, object: nil, userInfo: ["layout": layout?.command ?? ""]) }
    }

    @discardableResult
    private func record(label: String, window: AXWindow, wanted: Rect, started: DispatchTime, ok: Bool) -> Rect {
        let actual = window.frame ?? wanted
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        diagnostics.record(label: label, app: window.appName, milliseconds: ms, miss: windowFrameMiss(wanted: wanted, actual: actual), ok: ok)
        if !ok { setMessage("\(window.appName) did not allow its window to be moved.") }
        return actual
    }

    /// The focused window, if Kriya may and can move it.
    func target(checkResizable: Bool = true) -> (AXWindow, Rect, DisplayInfo)? {
        guard AXIsProcessTrusted() else {
            note("Accessibility permission is needed")
            setMessage("Accessibility permission is needed to move windows.")
            return nil
        }
        let pointed = (store.currentConfig.actOnPointerWindow || pointerOverride) ? AXWindow.at(DisplayManager.mouseLocation()) : nil
        guard let window = pointed ?? AXWindow.focused(), let frame = window.frame else {
            note("No window to move")
            return nil
        }
        if store.currentConfig.isExcluded(appId: window.appID) {
            note("\(window.appName) is excluded")
            return nil
        }
        if window.isFullScreen {
            note("\(window.appName) is full screen")
            return nil
        }
        if checkResizable, !window.canResize {
            note("\(window.appName)'s window cannot be resized")
            setMessage("\(window.appName)'s window cannot be resized.")
            return nil
        }
        guard let display = displays.display(containing: frame) else { return nil }
        return (window, frame, display)
    }

    private func note(_ text: String) {
        diagnostics.note(text)
    }

    private func setMessage(_ text: String) {
        lastMessage = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.lastMessage == text { self?.lastMessage = nil }
        }
    }

    // MARK: Windows of every app

    /// Windows a restore could not find yet, tried again as apps and windows appear.
    var retry: RestoreRetry { RestoreRetry.shared(for: self) }

    struct OpenWindow {
        let window: AXWindow
        let appID: String
        let title: String
        let frame: Rect
    }

    /// Standard, visible windows of ordinary apps (not Kriya, not excluded ones).
    static func openWindows(excluding config: WindowConfig) -> [OpenWindow] {
        var out: [OpenWindow] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isHidden {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, !config.isExcluded(appId: id) else { continue }
            for window in AXWindow.windows(ofApp: app.processIdentifier) where window.isStandard && !window.isMinimized {
                if let frame = window.frame { out.append(OpenWindow(window: window, appID: id, title: window.title, frame: frame)) }
            }
        }
        return out
    }

    // MARK: Saved layouts

    /// The arrangement of every open window, with positions as fractions of each window's display.
    func snapshot(displays list: [DisplayInfo]? = nil) -> [LayoutEntry] {
        let known = list ?? displays.displays
        let all = Self.openWindows(excluding: store.currentConfig)
        return all.compactMap { open in
            guard let index = windowDisplayIndex(frame: open.frame, areas: known.map(\.full)) else { return nil }
            let display = known[Int(index)]
            let area = display.area
            guard area.width > 0, area.height > 0 else { return nil }
            return LayoutEntry(
                appId: open.appID, title: open.title, displayId: display.id,
                frame: Rect(
                    x: (open.frame.x - area.x) / area.width, y: (open.frame.y - area.y) / area.height,
                    width: open.frame.width / area.width, height: open.frame.height / area.height
                )
            )
        }
    }

    func saveCurrentLayout(named name: String) {
        let entries = snapshot()
        guard !entries.isEmpty else {
            store.lastError = "There are no open windows to save."
            return
        }
        store.saveLayout(SavedLayout(
            id: UUID().uuidString, name: name, displayKey: displays.setKey, isAuto: false,
            createdAt: SystemInfo.nowSeconds, entries: entries, unplaced: .leave, launchMissing: false, isGroup: false
        ))
        diagnostics.note("Saved layout “\(name)” with \(entries.count) windows")
    }

    /// Puts open windows where a layout says. Windows the layout does not mention stay where they are. Runs off the
    /// main thread because asking many apps to move can take a moment. Afterwards `lastReport` says, window by window,
    /// what was done and what could not be.
    func restore(_ layout: SavedLayout, completion: ((RestoreOutcome) -> Void)? = nil) {
        let known = displays.displays
        let config = store.currentConfig
        let history = history
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let open = Self.openWindows(excluding: config)
            let matches = windowMatchEntries(
                entries: layout.entries, openWindows: open.map { WindowRef(appId: $0.appID, title: $0.title) }
            )
            var outcome = RestoreOutcome()
            var moved = [Bool](repeating: false, count: open.count)
            for (index, match) in matches.enumerated() {
                guard let match, let frame = Self.target(for: layout.entries[Int(match)], displays: known) else { continue }
                if WindowLockStore.shared.isLocked(appID: open[index].appID, title: open[index].title) { continue }
                let window = open[index].window
                history.record(key: window.key, frame: open[index].frame)
                let ok = AXWindow.withoutEnhancedInterface(pid: window.pid) { window.setFrame(frame) }
                moved[index] = ok
                if ok { outcome.placed += 1 }
            }
            let matchedEntries = Set(matches.compactMap { $0 }.map(Int.init))
            outcome.missing = max(0, layout.entries.count - matchedEntries.count)

            // What the layout asks for the windows it did not place.
            let placedWindows = Set(matches.enumerated().compactMap { $0.element == nil ? nil : $0.offset })
            let unplaced = open.enumerated().filter { !placedWindows.contains($0.offset) }.map(\.element)
            let placedApps = Set(placedWindows.map { open[$0].appID })
            switch layout.unplaced {
            case .leave:
                break
            case .minimize:
                for item in unplaced where item.window.minimize() { outcome.tidied += 1 }
            case .close:
                for item in unplaced where item.window.close() { outcome.tidied += 1 }
            case .hide:
                // An app is hidden whole, so only one with none of its windows placed.
                let apps = Set(unplaced.map(\.appID)).subtracting(placedApps)
                DispatchQueue.main.sync {
                    for id in apps { if NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.hide() == true { outcome.tidied += 1 } }
                }
            }

            // What was true of the Mac just now, for explaining the entries that found no window.
            var facts = RestoreFacts()
            for id in Set(layout.entries.map(\.appId)) {
                if config.isExcluded(appId: id) { facts.excludedApps.insert(id) }
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { !$0.isTerminated }) else { continue }
                facts.runningApps.insert(id)
                if app.isHidden { facts.hiddenApps.insert(id) }
                let minimized = AXWindow.windows(ofApp: app.processIdentifier).filter { $0.isStandard && $0.isMinimized }.count
                if minimized > 0 { facts.minimizedWindows[id] = minimized }
            }
            let raised = layout.isGroup ? open.enumerated().filter { moved[$0.offset] }.map(\.element.window) : []

            // Apps that are not running are opened, and their windows placed as they appear.
            let toOpen = layout.launchMissing ? layout.entries.indices.filter { !matchedEntries.contains($0) } : []
            let unresolved = layout.entries.indices.filter { !matchedEntries.contains($0) }.map { (index: $0, appID: layout.entries[$0].appId, title: layout.entries[$0].title) }
            DispatchQueue.main.async {
                guard let self else { return }
                var opened = Set<Int>()
                for index in toOpen {
                    let entry = layout.entries[index]
                    guard NSRunningApplication.runningApplications(withBundleIdentifier: entry.appId).isEmpty,
                          let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.appId) else { continue }
                    outcome.opened += 1
                    opened.insert(index)
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    self.placeWhenWindowAppears(entry: entry, displays: known)
                }
                if RestoreRetry.enabled, !unresolved.isEmpty { self.retry.enqueue(layout: layout, entries: unresolved) }
                // A group comes to the front together, in the order it was saved.
                for window in raised { window.raise() }
                let report = RestoreDiagnosis.build(
                    layoutID: layout.id, layoutName: layout.name, entries: layout.entries,
                    matches: matches.map { $0.map(Int.init) }, open: open.map { ($0.appID, $0.title) }, moved: moved,
                    opened: opened, displays: known, facts: facts, appName: AppChoice.name(for:)
                )
                outcome.report = report
                self.lastReport = report
                self.lastLayout = layout
                self.diagnostics.note("Restored “\(layout.name)”: \(report.summary)")
                self.lastApplied.removeAll()
                completion?(outcome)
            }
        }
    }

    // MARK: Windows to choose from, groups

    /// The windows open now, to pick from. The slow part (asking each app) runs away from the main thread.
    func loadWindowChoices(_ completion: @escaping ([WindowChoice]) -> Void) {
        let config = store.currentConfig
        DispatchQueue.global(qos: .userInitiated).async {
            let choices = Self.openWindows(excluding: config).map {
                WindowChoice(appID: $0.appID, appName: AppChoice.name(for: $0.appID), title: $0.title, window: $0.window, frame: $0.frame)
            }
            DispatchQueue.main.async { completion(choices) }
        }
    }

    /// Puts a window the person chose where a layout entry says. With `remember`, the layout is changed to name that window
    /// (when it is one of the person's own, not an automatic snapshot) so the next restore finds it.
    @discardableResult
    func place(_ choice: WindowChoice, forEntry index: Int, of layout: SavedLayout, remember: Bool) -> Bool {
        defer { if let latest = store.layouts.first(where: { $0.id == layout.id }) { lastLayout = latest } }
        guard layout.entries.indices.contains(index), let frame = Self.target(for: layout.entries[index], displays: displays.displays) else { return false }
        history.record(key: choice.window.key, frame: choice.frame)
        let ok = AXWindow.withoutEnhancedInterface(pid: choice.window.pid) { choice.window.setFrame(frame) }
        guard ok else { return false }
        choice.window.raise()
        if remember, !layout.isAuto {
            var changed = layout
            changed.entries[index].appId = choice.appID
            changed.entries[index].title = choice.title
            store.saveLayout(changed)
        }
        if var report = lastReport, report.layoutID == layout.id, let row = report.results.firstIndex(where: { $0.id == index }) {
            report.results[row].status = .placed(display: displays.displays.first { $0.id == layout.entries[index].displayId }?.name ?? "a display")
            report.results[row].matchedByAppOnly = false
            lastReport = report
        }
        return true
    }

    /// Saves the chosen windows as a group: a named set that can be restored, brought forward and moved together.
    @discardableResult
    func saveGroup(named name: String, windows: [WindowChoice]) -> Bool {
        let known = displays.displays
        let entries = windows.compactMap { Self.entry(app: $0.appID, title: $0.title, frame: $0.frame, displays: known) }
        guard !entries.isEmpty else {
            store.lastError = "Choose at least one window for the group."
            return false
        }
        store.saveLayout(SavedLayout(
            id: UUID().uuidString, name: name, displayKey: displays.setKey, isAuto: false,
            createdAt: SystemInfo.nowSeconds, entries: entries, unplaced: .leave, launchMissing: true, isGroup: true
        ))
        diagnostics.note("Saved group “\(name)” with \(entries.count) windows")
        return store.lastError == nil
    }

    /// Moves and resizes a group as one: the windows keep their places in the group, which is fitted into `region` of the
    /// display. Nothing saved is changed.
    func moveGroup(_ group: SavedLayout, to display: DisplayInfo, region: GroupRegion) {
        var moved = group
        moved.entries = GroupGeometry.fit(entries: group.entries, displays: displays.displays, target: display, region: region)
        restore(moved)
    }

    private static func entry(app: String, title: String, frame: Rect, displays known: [DisplayInfo]) -> LayoutEntry? {
        guard let index = windowDisplayIndex(frame: frame, areas: known.map(\.full)) else { return nil }
        let display = known[Int(index)]
        let area = display.area
        guard area.width > 0, area.height > 0 else { return nil }
        return LayoutEntry(
            appId: app, title: title, displayId: display.id,
            frame: Rect(
                x: (frame.x - area.x) / area.width, y: (frame.y - area.y) / area.height,
                width: frame.width / area.width, height: frame.height / area.height
            )
        )
    }

    /// Where a layout entry puts a window, in screen coordinates. The display it was made for, or the main one if that
    /// is not connected, and always inside the usable area.
    static func target(for entry: LayoutEntry, displays known: [DisplayInfo]) -> Rect? {
        let display = known.first { $0.id == entry.displayId } ?? known.first { $0.isMain } ?? known.first
        guard let area = display?.area else { return nil }
        return windowContain(
            frame: Rect(
                x: area.x + entry.frame.x * area.width, y: area.y + entry.frame.y * area.height,
                width: entry.frame.width * area.width, height: entry.frame.height * area.height
            ),
            area: area
        )
    }

    /// Waits for a window of a just-opened app and puts it where the layout says. Gives up after about ten seconds.
    private func placeWhenWindowAppears(entry: LayoutEntry, displays known: [DisplayInfo], attempt: Int = 0) {
        guard attempt < 16 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: entry.appId).first,
                  let window = AXWindow.windows(ofApp: app.processIdentifier).first(where: { $0.isStandard && !$0.isMinimized }),
                  let frame = Self.target(for: entry, displays: known) else {
                self.placeWhenWindowAppears(entry: entry, displays: known, attempt: attempt + 1)
                return
            }
            AXWindow.withoutEnhancedInterface(pid: window.pid) { window.setFrame(frame) }
        }
    }

    // MARK: Placement rules

    func applyRulesToOpenWindows() {
        let config = store.currentConfig
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, !config.isExcluded(appId: id),
                  windowRuleForApp(rules: store.rules, appId: id) != nil,
                  let window = AXWindow.windows(ofApp: app.processIdentifier).first(where: { $0.isStandard && !$0.isMinimized })
            else { continue }
            applyRule(to: window, appID: id)
        }
    }

    /// Waits for a newly launched app's first window to appear, then places it by the app's rule.
    func applyRuleAfterLaunch(of app: NSRunningApplication, attempt: Int = 0) {
        let config = store.currentConfig
        guard config.applyRulesOnLaunch, let id = app.bundleIdentifier, !config.isExcluded(appId: id),
              windowRuleForApp(rules: store.rules, appId: id) != nil, attempt < 8 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !app.isTerminated else { return }
            if let window = AXWindow.windows(ofApp: app.processIdentifier).first(where: { $0.isStandard && !$0.isMinimized }) {
                applyRule(to: window, appID: id)
            } else {
                applyRuleAfterLaunch(of: app, attempt: attempt + 1)
            }
        }
    }

    /// When an app comes to the front, puts its focused window where its rule says, if the person asked for that.
    func applyRuleOnActivate(of app: NSRunningApplication) {
        let config = store.currentConfig
        guard config.applyRulesOnActivate, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, !config.isExcluded(appId: id),
              windowRuleForApp(rules: store.rules, appId: id) != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !app.isTerminated, let window = AXWindow.windows(ofApp: app.processIdentifier).first(where: { $0.isStandard && !$0.isMinimized }) else { return }
            applyRule(to: window, appID: id)
        }
    }

    private func applyRule(to window: AXWindow, appID: String) {
        guard let rule = windowRuleForApp(rules: store.rules, appId: appID), let current = window.frame, !window.isFullScreen else { return }
        let display = rule.displayId.flatMap { displays.info(id: $0) } ?? displays.display(containing: current)
        guard let display else { return }
        if let layout = rule.layout {
            place(window, layout: layout, on: display, from: current)
        } else if let sizeID = rule.customSizeId, let size = store.sizes.first(where: { $0.id == sizeID }) {
            place(window, to: windowCustomFrame(size: size, area: usableArea(display)), from: current, label: "Rule: \(size.name)", layout: nil)
        }
    }

    // MARK: Displays coming and going

    /// Called after the set of displays changed. A setup seen before gets its last arrangement back; windows left off
    /// every display are always pulled back on.
    func displaysChanged(from before: [DisplayInfo], to after: [DisplayInfo]) {
        suppressSnapshotUntil = Date().addingTimeInterval(6)
        let key = displays.setKey
        let changedSet = key != previousDisplayKey
        previousDisplayKey = key
        let config = store.currentConfig
        let bindings = DisplaySetupBindings()
        bindings.prune(existing: Set(store.layouts.map(\.id)))
        if changedSet, let chosen = bindings.layoutID(forSetup: key).flatMap({ id in store.layouts.first { $0.id == id } }) {
            diagnostics.note("Display setup recognised: restoring “\(chosen.name)”")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.restore(chosen) { _ in self?.containOffscreenWindows() }
            }
        } else if changedSet, config.restoreOnReconnect, let saved = try? core.autoLayoutFor(displayKey: key) {
            diagnostics.note(after.count > before.count ? "Display connected: restoring its arrangement" : "Display disconnected: restoring the arrangement for the remaining displays")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.restore(saved) { _ in self?.containOffscreenWindows() }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.containOffscreenWindows() }
        }
    }

    /// Moves any window that is mostly outside every display back onto the nearest one.
    func containOffscreenWindows() {
        let areas = displays.displays.map(\.area)
        guard !areas.isEmpty else { return }
        let config = store.currentConfig
        let history = history
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var moved = 0
            for open in Self.openWindows(excluding: config) {
                let visible = areas.map { open.frame.cg.intersection($0.cg).width * open.frame.cg.intersection($0.cg).height }.max() ?? 0
                guard visible < open.frame.width * open.frame.height * 0.3, let index = windowDisplayIndex(frame: open.frame, areas: areas) else { continue }
                let fitted = windowContain(frame: open.frame, area: areas[Int(index)])
                history.record(key: open.window.key, frame: open.frame)
                if open.window.setFrame(fitted) { moved += 1 }
            }
            if moved > 0 { DispatchQueue.main.async { self?.diagnostics.note("Moved \(moved) off-screen window(s) back") } }
        }
    }

    // MARK: Automatic snapshots

    /// Keeps the latest arrangement for the current set of displays, so it can be brought back when they return.
    func startSnapshots() {
        guard snapshotTimer == nil else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.captureSnapshot() }
        RunLoop.main.add(timer, forMode: .common)
        snapshotTimer = timer
    }

    func stopSnapshots() {
        captureSnapshot()
        snapshotTimer?.invalidate()
        snapshotTimer = nil
    }

    func captureSnapshot() {
        guard Date() > suppressSnapshotUntil, AXIsProcessTrusted() else { return }
        let key = displays.setKey
        let known = displays.displays
        let config = store.currentConfig
        let core = core
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let open = Self.openWindows(excluding: config)
            let entries: [LayoutEntry] = open.compactMap { window in
                guard let index = windowDisplayIndex(frame: window.frame, areas: known.map(\.full)) else { return nil }
                let display = known[Int(index)]
                let area = display.area
                guard area.width > 0, area.height > 0 else { return nil }
                return LayoutEntry(
                    appId: window.appID, title: window.title, displayId: display.id,
                    frame: Rect(
                        x: (window.frame.x - area.x) / area.width, y: (window.frame.y - area.y) / area.height,
                        width: window.frame.width / area.width, height: window.frame.height / area.height
                    )
                )
            }
            let fingerprint = key + "#" + entries.map { "\($0.appId)|\($0.displayId)|\(Int($0.frame.x * 100))|\(Int($0.frame.y * 100))|\(Int($0.frame.width * 100))|\(Int($0.frame.height * 100))" }.joined(separator: ";")
            DispatchQueue.main.async {
                guard let self, fingerprint != self.lastSnapshotFingerprint else { return }
                self.lastSnapshotFingerprint = fingerprint
                try? core.saveAutoLayout(displayKey: key, entries: entries, now: SystemInfo.nowSeconds)
            }
        }
    }

    func forgetHistory() {
        lastApplied.removeAll()
    }
}

extension WindowConfig {
    func isExcluded(appId: String?) -> Bool {
        guard let appId else { return false }
        return excludedAppIds.contains(appId)
    }
}


extension WindowController {
    /// What restoring this layout would do right now. Moves nothing.
    func previewRestore(_ layout: SavedLayout) -> [LayoutPreviewRow] {
        let known = displays.displays
        let open = Self.openWindows(excluding: store.currentConfig)
        let matches = windowMatchEntries(entries: layout.entries, openWindows: open.map { WindowRef(appId: $0.appID, title: $0.title) })
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return LayoutPreview.rows(
            entries: layout.entries.map { ($0.appId, $0.title, $0.displayId) }, launchMissing: layout.launchMissing,
            open: open.map { ($0.appID, $0.title) }, matches: matches.map { $0.map(Int.init) }, runningApps: running,
            displayIDs: Set(known.map(\.id)), isLocked: { WindowLockStore.shared.isLocked(appID: $0, title: $1) }
        )
    }
}


/// Runs the retry queue: every few seconds, and when an app launches, looks for the windows that were missing.
final class RestoreRetry: ObservableObject {
    private static var instance: RestoreRetry?
    static func shared(for controller: WindowController) -> RestoreRetry {
        if let instance { return instance }
        let made = RestoreRetry(controller: controller)
        instance = made
        return made
    }

    static let key = "windows.retryUnresolved"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    @Published private(set) var queue = RestoreRetryQueue()
    private weak var controller: WindowController?
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    private init(controller: WindowController) { self.controller = controller }

    func enqueue(layout: SavedLayout, entries: [(index: Int, appID: String, title: String)]) {
        queue.add(layoutID: layout.id, layoutName: layout.name, entries: entries, now: Date())
        startIfNeeded()
    }

    func cancel(_ id: String) { queue.cancel(id) }
    func clear() { queue.clear(); stop() }

    private func startIfNeeded() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in self?.pass() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.pass() }
        }
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    private func pass() {
        guard let controller, !queue.items.isEmpty else { stop(); return }
        let open = WindowController.openWindows(excluding: controller.store.currentConfig)
        let windows = open.map { RestoreRetryQueue.OpenWindow(appID: $0.appID, title: $0.title, role: $0.window.subrole, key: $0.window.key) }
        let pairs = queue.pass(windows: windows, now: Date())
        for pair in pairs {
            guard let layout = controller.store.layouts.first(where: { $0.id == pair.item.layoutID }), layout.entries.indices.contains(pair.item.entryIndex),
                  let target = open.first(where: { $0.window.key == pair.window.key }),
                  !WindowLockStore.shared.isLocked(appID: target.appID, title: target.title),
                  let frame = WindowController.target(for: layout.entries[pair.item.entryIndex], displays: controller.displays.displays) else { continue }
            _ = AXWindow.withoutEnhancedInterface(pid: target.window.pid) { target.window.setFrame(frame) }
        }
        objectWillChange.send()
        if queue.items.isEmpty { stop() }
    }
}


/// Arranging windows again when the person moves to another Space. macOS does not let an app move windows between Spaces, so
/// this only places the windows that are on the Space now.
final class SpaceChangeLayouts {
    static let shared = SpaceChangeLayouts()
    static let layoutKey = "windows.layoutOnSpaceChange"
    private var observer: NSObjectProtocol?
    private var work: DispatchWorkItem?
    weak var controller: WindowController?

    static var layoutID: String? {
        get { UserDefaults.standard.string(forKey: layoutKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue ?? "", forKey: layoutKey); shared.update() }
    }

    func update() {
        if Self.layoutID == nil {
            if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            observer = nil
            return
        }
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.work?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, let controller, let id = Self.layoutID, let layout = controller.store.layouts.first(where: { $0.id == id }) else { return }
                controller.restore(layout)
            }
            self?.work = item
            // Spaces slide for a moment; wait until it has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
        }
    }
}
