import AppKit
import ApplicationServices

/// Keeps an Accessibility menu element with the menu entry that stands for it.
private final class AXEntry: NSObject {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}

/// A menu that opens at the pointer. It holds the person's own items for the app in front, and that app's whole menu
/// bar, built from the Accessibility API only when a submenu is opened. Choosing an entry from the app's menu presses
/// the matching item in the app, as if it had been picked from the menu bar.
final class PointerMenu: NSObject, NSMenuDelegate {
    private let store: PointerMenuStore
    private let library: ActionLibrary
    private let executor: ActionExecutor

    /// Starts a workflow by id. Set when the automation engine exists.
    var runWorkflow: (_ id: String) -> Void = { _ in }

    private var targetPID: pid_t = 0
    /// Menus that still have to be filled in, with the Accessibility element they come from.
    private var pending: [ObjectIdentifier: AXUIElement] = [:]

    init(store: PointerMenuStore, library: ActionLibrary, executor: ActionExecutor) {
        self.store = store
        self.library = library
        self.executor = executor
    }

    // MARK: ⌥ + right-click

    private var optionToken: EventMonitor.Token?
    private weak var optionEvents: EventMonitor?
    private let optionLock = NSLock()
    private var swallowRightUp = false

    /// Opens the menu when the right button is pressed with only ⌥ held. A plain right-click is never touched, so the app's
    /// own menu stays as it is.
    func setOptionRightClick(_ on: Bool, events: EventMonitor) {
        if !on {
            if let optionToken { events.unsubscribe(optionToken) }
            optionToken = nil
            return
        }
        guard optionToken == nil else { return }
        optionEvents = events
        optionToken = events.subscribe(owner: "pointer.menu.option", events: [.rightMouseDown, .rightMouseUp], mode: .active) { [weak self] type, event in
            guard let self else { return .passThrough }
            if type == .rightMouseDown, KeyModifiers.bits(from: event.flags) == KeyModifiers.option {
                optionLock.lock()
                swallowRightUp = true
                optionLock.unlock()
                DispatchQueue.main.async { self.show(appMenuOnly: false) }
                return .drop
            }
            if type == .rightMouseUp {
                optionLock.lock()
                let swallow = swallowRightUp
                swallowRightUp = false
                optionLock.unlock()
                if swallow { return .drop }
            }
            return .passThrough
        }
    }

    /// Opens the menu at the pointer. With `appMenuOnly` it holds just the app's own menus.
    func show(appMenuOnly: Bool) {
        let front = NSWorkspace.shared.frontmostApplication
        // Remember the app now: showing a menu makes Kriya active.
        targetPID = (front?.bundleIdentifier == Bundle.main.bundleIdentifier) ? 0 : (front?.processIdentifier ?? 0)
        let config = store.current
        let menu = NSMenu()
        menu.autoenablesItems = false
        pending.removeAll()

        if !appMenuOnly {
            for item in pointerMenuItemsForApp(items: config.items, appId: front?.bundleIdentifier) {
                let entry = NSMenuItem(title: item.title, action: #selector(runItem(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = item.id
                menu.addItem(entry)
            }
        }
        if (appMenuOnly || config.showAppMenu), targetPID != 0, AXIsProcessTrusted() {
            let bar = menuBarEntries(pid: targetPID)
            if !bar.isEmpty {
                if menu.numberOfItems > 0 { menu.addItem(.separator()) }
                if appMenuOnly {
                    for entry in bar { menu.addItem(entry) }
                } else {
                    let holder = NSMenuItem(title: "\(front?.localizedName ?? "App") Menu", action: nil, keyEquivalent: "")
                    let sub = NSMenu(title: holder.title)
                    sub.autoenablesItems = false
                    for entry in bar { sub.addItem(entry) }
                    holder.submenu = sub
                    menu.addItem(holder)
                }
            }
        }
        if menu.numberOfItems == 0 {
            let none = NSMenuItem(title: "Nothing to show here", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: The person's own items

    @objc private func runItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = store.current.items.first(where: { $0.id == id }) else { return }
        if let workflow = item.workflowId {
            runWorkflow(workflow)
        } else if let actionID = item.actionId, let saved = library.actions.first(where: { $0.id == actionID }) {
            let executor = executor
            Task { _ = await executor.perform(saved.action) }
        }
    }

    // MARK: The app's own menu bar

    /// The app's top-level menus as menu entries. Each fills in when it is opened.
    private func menuBarEntries(pid: pid_t) -> [NSMenuItem] {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.4)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &bar) == .success,
              let barElement = bar, CFGetTypeID(barElement) == AXUIElementGetTypeID() else { return [] }
        let top = children(of: unsafeBitCast(barElement, to: AXUIElement.self))
        var entries: [NSMenuItem] = []
        for item in top {
            let title = string(item, kAXTitleAttribute) ?? ""
            if title.isEmpty || title == "Apple" { continue }
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            sub.autoenablesItems = false
            sub.delegate = self
            pending[ObjectIdentifier(sub)] = item
            entry.submenu = sub
            entries.append(entry)
        }
        return entries
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let owner = pending.removeValue(forKey: ObjectIdentifier(menu)) else { return }
        // The element's menu is its child of role "menu"; its children are the entries.
        let axMenu = children(of: owner).first { string($0, kAXRoleAttribute) == kAXMenuRole as String } ?? owner
        for item in children(of: axMenu) {
            let title = string(item, kAXTitleAttribute) ?? ""
            if title.isEmpty {
                menu.addItem(.separator())
                continue
            }
            let entry = NSMenuItem(title: title, action: #selector(pressed(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = AXEntry(item)
            entry.isEnabled = bool(item, kAXEnabledAttribute) ?? true
            if let mark = string(item, kAXMenuItemMarkCharAttribute), !mark.isEmpty { entry.state = .on }
            applyShortcut(from: item, to: entry)
            let hasSubmenu = children(of: item).contains { string($0, kAXRoleAttribute) == kAXMenuRole as String }
            if hasSubmenu {
                let sub = NSMenu(title: title)
                sub.autoenablesItems = false
                sub.delegate = self
                pending[ObjectIdentifier(sub)] = item
                entry.submenu = sub
                entry.action = nil
            }
            menu.addItem(entry)
        }
    }

    /// Shows the item's shortcut beside it, so the menu teaches the keys.
    private func applyShortcut(from item: AXUIElement, to entry: NSMenuItem) {
        guard let key = string(item, kAXMenuItemCmdCharAttribute), key.count == 1 else { return }
        var modifiers: Int = 0
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &raw) == .success, let number = raw as? Int {
            modifiers = number
        }
        var mask: NSEvent.ModifierFlags = []
        if modifiers & 1 != 0 { mask.insert(.shift) }
        if modifiers & 2 != 0 { mask.insert(.option) }
        if modifiers & 4 != 0 { mask.insert(.control) }
        if modifiers & 8 == 0 { mask.insert(.command) }
        entry.keyEquivalent = key.lowercased()
        entry.keyEquivalentModifierMask = mask
    }

    @objc private func pressed(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? AXEntry else { return }
        let pid = targetPID
        // Give the menu a moment to close and the app its focus back before the item is pressed.
        if pid != 0 { NSRunningApplication(processIdentifier: pid)?.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            AXUIElementPerformAction(entry.element, kAXPressAction as CFString)
        }
    }

    // MARK: Accessibility helpers

    private func children(of element: AXUIElement) -> [AXUIElement] {
        AXUIElementSetMessagingTimeout(element, 0.4)
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &out) == .success else { return [] }
        return out as? [AXUIElement] ?? []
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success else { return nil }
        return out as? String
    }

    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success else { return nil }
        return (out as? NSNumber)?.boolValue
    }
}
