import AppKit

/// What a click on a menu-bar icon means. The same everywhere, so every Kriya icon answers the same way.
enum StatusClick: Equatable {
    /// A plain left click: the icon's main window or action.
    case primary
    /// A right click, or a Control-click (what a one-button trackpad sends): the icon's menu.
    case secondary
    /// An Option-click: the icon's second action (effects, for an app's icon).
    case option

    static func classify(rightMouse: Bool, modifiers: NSEvent.ModifierFlags) -> StatusClick {
        if rightMouse || modifiers.contains(.control) { return .secondary }
        if modifiers.contains(.option) { return .option }
        return .primary
    }

    /// The click being handled, or nil when the action was not sent by a click (a shortcut, say).
    static var current: StatusClick? {
        guard let event = NSApp.currentEvent else { return nil }
        return classify(rightMouse: event.type == .rightMouseUp || event.type == .rightMouseDown, modifiers: event.modifierFlags)
    }
}

/// Shows a menu under a menu-bar icon.
///
/// The menu is opened directly, at a place worked out from where the icon's window is on screen, rather than attached to the item and
/// opened by a simulated click. Nothing is left attached to the icon afterwards, so the next left click still reaches the icon's own
/// action, and the place does not depend on which display the icon is on or on how the button draws itself.
enum StatusMenu {
    /// Where the top-left of a menu goes for this icon, in screen coordinates: the icon's left edge, just under the menu bar.
    static func anchor(forIconFrame frame: NSRect) -> NSPoint {
        NSPoint(x: frame.minX, y: frame.minY - 2)
    }

    /// The anchor pulled back inside the display, so a menu for an icon near the right edge does not run off it.
    static func fitted(_ point: NSPoint, menuWidth: CGFloat, in screenFrame: NSRect) -> NSPoint {
        NSPoint(x: min(max(point.x, screenFrame.minX), max(screenFrame.maxX - menuWidth - 4, screenFrame.minX)), y: point.y)
    }

    static func popUp(_ menu: NSMenu, from button: NSStatusBarButton) {
        guard let window = button.window else { return }
        var origin = anchor(forIconFrame: window.frame)
        if let screen = window.screen { origin = fitted(origin, menuWidth: max(menu.size.width, 200), in: screen.frame) }
        menu.popUp(positioning: nil, at: origin, in: nil)
    }

    /// Adds a titled, enabled item that runs `handler`, with an optional symbol and check mark.
    @discardableResult
    static func add(_ title: String, symbol: String? = nil, checked: Bool = false, enabled: Bool = true, to menu: NSMenu, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        let action = MenuAction(handler)
        item.target = action
        item.representedObject = action   // keeps the handler alive as long as the item
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(item)
        return item
    }

    static func header(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }
}

/// A menu item's closure, so a menu can be built in one place without a method for every entry.
final class MenuAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}
