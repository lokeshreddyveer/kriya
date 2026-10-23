import AppKit
import SwiftUI

/// Hides menu-bar icons you do not need to see. Two items sit in the menu bar: a divider and an arrow. Hold ⌘ and drag
/// icons to the left of the divider; the arrow then hides everything left of the divider, and shows it again.
/// This works by making the divider very wide so macOS pushes the icons left of it off the screen. It changes nothing in the
/// other apps, and turning it off puts everything back.
final class MenuBarHider: ObservableObject {
    static let enabledKey = "menuBarHider.enabled"
    static let autoHideKey = "menuBarHider.autoHideSeconds"
    static let autoHideChoices: [(seconds: Int, title: String)] = [(0, "Never"), (5, "After 5 seconds"), (10, "After 10 seconds"), (30, "After 30 seconds"), (60, "After a minute")]

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isCollapsed = false
    @Published private(set) var problem: String?
    @Published var autoHideSeconds: Int {
        didSet { UserDefaults.standard.set(autoHideSeconds, forKey: Self.autoHideKey); scheduleAutoHide() }
    }

    private var toggleItem: NSStatusItem?
    private var dividerItem: NSStatusItem?
    private var autoHide: DispatchWorkItem?
    private let collapsedLength: CGFloat = 10_000
    private let expandedLength: CGFloat = 14

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let saved = UserDefaults.standard.integer(forKey: Self.autoHideKey)
        autoHideSeconds = Self.autoHideChoices.contains { $0.seconds == saved } ? saved : 10
    }

    /// Whether making the divider wide really pushed the icons away: its window should have become wider than the screen.
    static func collapseWorked(dividerWidth: CGFloat, screenWidth: CGFloat) -> Bool { dividerWidth >= screenWidth }

    func start() { if isEnabled { install() } }

    func stop() {
        autoHide?.cancel()
        remove()
    }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        problem = nil
        if on { install() } else { remove() }
    }

    func toggle() {
        guard isEnabled else { return }
        isCollapsed ? expand() : collapse()
    }

    // MARK: Items

    private func install() {
        guard toggleItem == nil else { return }
        // The arrow is made first, so it sits to the right and the divider to its left.
        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggle.autosaveName = "KriyaMenuBarArrow"
        toggle.button?.target = self
        toggle.button?.action = #selector(arrowClicked)
        toggle.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        toggleItem = toggle
        let divider = NSStatusBar.system.statusItem(withLength: expandedLength)
        divider.autosaveName = "KriyaMenuBarDivider"
        dividerItem = divider
        isCollapsed = false
        paint()
    }

    private func remove() {
        autoHide?.cancel()
        for item in [toggleItem, dividerItem].compactMap({ $0 }) { NSStatusBar.system.removeStatusItem(item) }
        toggleItem = nil
        dividerItem = nil
        isCollapsed = false
    }

    @objc private func arrowClicked() { toggle() }

    private func collapse() {
        guard let divider = dividerItem else { return }
        isCollapsed = true
        divider.length = collapsedLength
        paint()
        autoHide?.cancel()
        // Give macOS a moment, then check it really made the room.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.isCollapsed, let window = self.dividerItem?.button?.window else { return }
            let screenWidth = window.screen?.frame.width ?? NSScreen.main?.frame.width ?? 1440
            if !Self.collapseWorked(dividerWidth: window.frame.width, screenWidth: screenWidth) {
                self.problem = "macOS did not make room, so icons cannot be hidden on this Mac."
                self.expand()
            }
        }
    }

    private func expand() {
        guard let divider = dividerItem else { return }
        isCollapsed = false
        divider.length = expandedLength
        paint()
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        autoHide?.cancel()
        guard isEnabled, !isCollapsed, autoHideSeconds > 0, toggleItem != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isEnabled, !self.isCollapsed else { return }
            self.collapse()
        }
        autoHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(autoHideSeconds), execute: work)
    }

    private func paint() {
        let arrow = NSImage(systemSymbolName: isCollapsed ? "chevron.left" : "chevron.right", accessibilityDescription: isCollapsed ? "Show hidden menu bar icons" : "Hide menu bar icons")
        arrow?.isTemplate = true
        toggleItem?.button?.image = arrow
        toggleItem?.button?.toolTip = isCollapsed ? "Show hidden icons" : "Hide icons to the left of the divider"
        if let button = dividerItem?.button {
            button.image = nil
            button.title = isCollapsed ? "" : "│"
            button.alphaValue = 0.45
            button.toolTip = "Hold ⌘ and drag icons to the left of this line to hide them"
        }
    }
}
