import AppKit
import Combine
import SwiftUI

/// A small menu-bar icon for each app the person pinned there: the app's own icon, dimmed and slashed while it is muted, and a
/// click opens that app's volume, mute and effects.
final class AppSoundStatusItems: NSObject, NSPopoverDelegate {
    private let engine: AppAudioEngine
    private let mixer: SoundMixerModel
    private let quick: QuickConfigStore
    private var items: [String: NSStatusItem] = [:]
    private var popovers: [String: NSPopover] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(engine: AppAudioEngine, mixer: SoundMixerModel, quick: QuickConfigStore) {
        self.engine = engine
        self.mixer = mixer
        self.quick = quick
        super.init()
        engine.$menuBarApps.receive(on: DispatchQueue.main).sink { [weak self] list in self?.sync(list) }.store(in: &cancellables)
        engine.$settings.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshIcons() }.store(in: &cancellables)
    }

    private func sync(_ keys: [String]) {
        for (key, item) in items where !keys.contains(key) {
            popovers[key]?.performClose(nil); popovers[key] = nil
            NSStatusBar.system.removeStatusItem(item)
            items[key] = nil
        }
        for key in keys where items[key] == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            item.button?.identifier = NSUserInterfaceItemIdentifier(key)
            items[key] = item
        }
        refreshIcons()
    }

    private func refreshIcons() {
        for (key, item) in items {
            guard let button = item.button else { continue }
            button.image = Self.icon(for: key, muted: engine.current(key).muted || (engine.timed[key]?.level == 0))
            button.toolTip = AudioProcessList.name(for: key)
        }
    }

    /// The app's icon at menu-bar size; with a slash across it, and dimmed, when muted.
    static func icon(for key: String, muted: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let base: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) { base = NSWorkspace.shared.icon(forFile: url.path) }
        else { base = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage() }
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: muted ? 0.45 : 1)
            if muted {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 2, y: 2)); path.line(to: NSPoint(x: 16, y: 16))
                path.lineWidth = 2
                NSColor.systemRed.setStroke()
                path.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let key = sender.identifier?.rawValue else { return }
        if let open = popovers[key], open.isShown { open.performClose(nil); return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let view = Form { AppMixerRow(key: key, name: AudioProcessList.name(for: key), symbol: "app", bundleID: key, isFavorite: engine.isFavorite(key)) }
            .formStyle(.grouped)
            .frame(width: 380, height: 150)
            .environmentObject(engine).environmentObject(mixer).environmentObject(quick)
        popover.contentViewController = NSHostingController(rootView: view)
        popover.contentSize = NSSize(width: 380, height: 150)
        popovers[key] = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        engine.viewerAppeared()
    }

    func popoverDidClose(_ notification: Notification) { engine.viewerGone() }
}
