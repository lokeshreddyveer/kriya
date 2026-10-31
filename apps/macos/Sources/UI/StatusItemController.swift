import AppKit
import Combine
import SwiftUI

/// The menu-bar icon. A click opens the popover; a right-click (or Control-click) opens a small menu.
final class StatusItemController: NSObject {
    private let env: AppEnvironment
    private let openSettings: (SettingsPane?) -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitors: [Any] = []

    init(env: AppEnvironment, openSettings: @escaping (SettingsPane?) -> Void) {
        self.env = env
        self.openSettings = openSettings
        super.init()
        configureButton()
        configurePopover()
        // The icon warns while safe mode is on.
        env.crashGuard.$isSafeMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] safe in self?.updateIcon(safeMode: safe) }
            .store(in: &cancellables)
        // And while every mouse rule is paused.
        env.events.$mouseRulesPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paused in self?.updateIcon(safeMode: self?.env.crashGuard.isSafeMode ?? false, paused: paused) }
            .store(in: &cancellables)
        // The icon also shows while left and right button replacement is on, so it is never on without being seen.
        env.buttonReplacement.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.updateIcon(safeMode: self?.env.crashGuard.isSafeMode ?? false, armed: status == .armed) }
            .store(in: &cancellables)
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // Dropping files, text or a picture on the icon makes a new shelf of them.
        let drop = StatusDropView(frame: button.bounds)
        drop.onDrop = { [weak self] board in self?.env.fileShelf.createShelf(from: board) ?? false }
        button.addSubview(drop)
        updateIcon(safeMode: env.crashGuard.isSafeMode)
    }

    private func updateIcon(safeMode: Bool, armed: Bool? = nil, paused: Bool? = nil) {
        var name = safeMode ? "exclamationmark.triangle" : "cursorarrow.click.2"
        if !safeMode, armed ?? (env.buttonReplacement.status == .armed) { name = "arrow.left.arrow.right.circle.fill" }
        if !safeMode, paused ?? env.events.mouseRulesPaused { name = "pause.circle" }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Kriya")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func configurePopover() {
        // Closed by hand (see `watchForOutsideClicks`): a transient popover closes on mouse-down, and the same click
        // then reopens it, so the icon seemed to work only some of the time.
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        let view = PopoverView(openSettings: { [weak self] pane in
            self?.popover.performClose(nil)
            self?.openSettings(pane)
        }, close: { [weak self] in self?.popover.performClose(nil) }).injecting(env)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        // Build the view now so the first click does not wait for it.
        _ = host.view
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let click = StatusClick.current else { return }
        if click == .secondary {
            popover.performClose(nil)
            showMenu(from: sender)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            // Show first, then bring the permission list up to date, so the click never waits on the system.
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            watchForOutsideClicks()
            DispatchQueue.main.async { [env] in env.permissions.refresh() }
        }
    }

    private func watchForOutsideClicks() {
        stopWatching()
        let close: (NSEvent) -> NSEvent? = { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            let onPopover = event.window === self.popover.contentViewController?.view.window
            let onIcon = event.window === self.statusItem.button?.window
            if event.type == .keyDown, event.keyCode == 53 { self.popover.performClose(nil); return nil }
            if event.type != .keyDown, !onPopover, !onIcon { self.popover.performClose(nil) }
            return event
        }
        outsideClickMonitors = [
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: close) as Any,
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.popover.performClose(nil)
            } as Any
        ]
    }

    private func stopWatching() {
        for monitor in outsideClickMonitors { NSEvent.removeMonitor(monitor) }
        outsideClickMonitors.removeAll()
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        // The one-click way to leave the mouse alone, and to take the rules up again.
        let pauseAll = menu.addItem(withTitle: env.events.mouseRulesPaused ? "Resume Mouse Rules" : "Pause Mouse Rules", action: #selector(menuPauseMouseRules), keyEquivalent: "")
        pauseAll.target = self
        menu.addItem(.separator())
        // Always first when replacement is running: the visible way to pause it.
        switch env.buttonReplacement.status {
        case .armed, .countdown:
            let pause = menu.addItem(withTitle: "Pause Button Replacement", action: #selector(menuPauseReplacement), keyEquivalent: "")
            pause.target = self
            menu.addItem(.separator())
        case .paused:
            let resume = menu.addItem(withTitle: "Resume Button Replacement…", action: #selector(menuPauseReplacement), keyEquivalent: "")
            resume.target = self
            menu.addItem(.separator())
        default:
            break
        }
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Kriya", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        StatusMenu.popUp(menu, from: button)
    }

    @objc private func menuSettings() { openSettings(nil) }

    @objc private func menuPauseReplacement() { env.buttonReplacement.togglePause() }

    @objc private func menuPauseMouseRules() { env.toggleMouseRulesPause() }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) { stopWatching() }
}
