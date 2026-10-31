import AppKit

/// The list of links found in text read from a picture, shown as a menu at the pointer. Nothing in it is chosen for the person:
/// each link has its own actions, and the menu goes away if they click elsewhere.
final class OCRLinkMenu: NSObject {
    private let links: [DetectedLink]
    private let handlers: OCRLinkHandlers

    init(links: [DetectedLink], handlers: OCRLinkHandlers) {
        self.links = links
        self.handlers = handlers
    }

    private final class Choice: NSObject {
        let link: DetectedLink
        let action: OCRLinkAction
        init(_ link: DetectedLink, _ action: OCRLinkAction) { self.link = link; self.action = action }
    }

    /// Shows the menu at a point on the screen. Call it on the main thread.
    func show(at point: NSPoint = NSEvent.mouseLocation) {
        let menu = NSMenu(title: "Links in the picture")
        let header = NSMenuItem(title: links.count == 1 ? "A link in the text (it does not open by itself)" : "\(links.count) links in the text (none open by themselves)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for link in links {
            let item = NSMenuItem(title: Self.shortened(link.shown), action: nil, keyEquivalent: "")
            let sub = NSMenu(title: link.shown)
            for action in OCRLinkAction.allCases where action.isAvailable(for: link) {
                let entry = NSMenuItem(title: action.title, action: #selector(chosen(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = Choice(link, action)
                sub.addItem(entry)
            }
            item.submenu = sub
            menu.addItem(item)
        }
        // Held for as long as the menu is open: popping it up waits for a choice or a click elsewhere.
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    @objc private func chosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice else { return }
        OCRLinks.perform(choice.action, on: choice.link, using: handlers)
    }

    static func shortened(_ text: String, limit: Int = 60) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}

extension ScreenCaptureService {
    /// What choosing an action on a link does: opening in the default browser, copying, handing it to Link Routing (which picks the
    /// browser by the person's rules), or ignoring it from now on.
    var linkHandlers: OCRLinkHandlers {
        OCRLinkHandlers(
            open: { NSWorkspace.shared.open($0) },
            copy: { [weak self] text in
                self?.pasteboard.clearContents()
                self?.pasteboard.setString(text, forType: .string)
                self?.toast.show("Link copied")
            },
            route: { [weak self] url in self?.routeLink(url) },
            ignore: { [weak self] url in
                let store = IgnoredLinkStore()
                store.links = store.links.adding(url)
                self?.toast.show("This link will not be offered again.")
            }
        )
    }

    /// Lists the links found in text that was read from a picture, if any, for the person to choose from.
    func offerLinks(in text: String) {
        let offers = OCRLinks.offers(in: text, policy: deliveryPolicy().text, ignored: IgnoredLinkStore().links)
        guard !offers.isEmpty else { return }
        let menu = OCRLinkMenu(links: offers, handlers: linkHandlers)
        DispatchQueue.main.async { menu.show() }
    }
}
