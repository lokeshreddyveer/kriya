import AppKit
import ApplicationServices

/// The icons other apps keep in the menu bar, found through Accessibility, so any of them can be opened from the launcher even
/// when it is hidden behind the arrow or squeezed out by the notch.
final class MenuBarItemIndex {
    struct Item {
        let app: String
        let title: String
        let element: AXUIElement
    }

    private(set) var items: [Item] = []
    private var loadedAt: Date?
    private var loading = false

    func refreshIfNeeded() {
        guard AXIsProcessTrusted() else { return }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 20 { return }
        guard !loading else { return }
        loading = true
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited && $0.processIdentifier != getpid() }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found: [Item] = []
            for app in apps {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 0.25)
                var bar: CFTypeRef?
                guard AXUIElementCopyAttributeValue(root, "AXExtrasMenuBar" as CFString, &bar) == .success, let barElement = bar else { continue }
                var children: CFTypeRef?
                guard AXUIElementCopyAttributeValue(barElement as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success, let list = children as? [AXUIElement] else { continue }
                for element in list {
                    let title = Self.label(of: element) ?? app.localizedName ?? "Menu bar item"
                    found.append(Item(app: app.localizedName ?? "App", title: title, element: element))
                }
            }
            DispatchQueue.main.async {
                self?.items = found
                self?.loadedAt = Date()
                self?.loading = false
            }
        }
    }

    private static func label(of element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let text = value as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty { return text }
        }
        return nil
    }

    func press(_ item: Item) { AXUIElementPerformAction(item.element, kAXPressAction as CFString) }
}

extension LauncherSources {
    /// "mb wifi", "menu bar battery", "status bluetooth": the menu-bar icons whose app or name matches.
    func menuBarItemEntries(_ text: String) -> [PaletteEntry] {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        var query: String?
        for prefix in ["menu bar ", "menubar ", "mb ", "status "] where lower.hasPrefix(prefix) { query = String(lower.dropFirst(prefix.count)); break }
        guard let query, !query.isEmpty else { return [] }
        guard AXIsProcessTrusted() else {
            var e = PaletteEntry(id: "mb:needs-access", title: "Allow Accessibility to search menu-bar icons", subtitle: "Kriya reads the names of the icons; it does not look inside them", symbol: "lock.shield", rememberable: false) {}
            e.queryScore = 600
            return [e]
        }
        menuBarItems.refreshIfNeeded()
        return menuBarItems.items.compactMap { item -> (PaletteEntry, Int)? in
            let score = max(FuzzyMatcher.score(query, in: item.title) ?? -1, FuzzyMatcher.score(query, in: item.app) ?? -1)
            guard score >= 0 else { return nil }
            var e = PaletteEntry(id: "mb:\(item.app):\(item.title)", title: item.title == item.app ? item.app : "\(item.title)", subtitle: "\(item.app) · menu-bar icon", symbol: "menubar.rectangle", rememberable: false) { [weak self] in self?.menuBarItems.press(item) }
            e.queryScore = 700 + min(score / 10, 200)
            return (e, score)
        }.sorted { $0.1 > $1.1 }.prefix(6).map(\.0)
    }
}
