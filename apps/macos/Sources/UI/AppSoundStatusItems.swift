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
        // A timed mute starts and ends without the app's settings changing, so the icon follows it separately.
        engine.$timed.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshIcons() }.store(in: &cancellables)
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
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.identifier = NSUserInterfaceItemIdentifier(key)
            items[key] = item
        }
        refreshIcons()
    }

    private func refreshIcons() {
        for (key, item) in items {
            guard let button = item.button else { continue }
            button.image = Self.icon(for: key, muted: engine.current(key).muted || (engine.timed[key]?.level == 0))
            let settings = engine.current(key)
            let state = settings.muted || engine.timed[key]?.level == 0 ? "muted" : "\(Int((settings.volume * 100).rounded()))%"
            button.toolTip = "\(AudioProcessList.name(for: key)): \(state)\nClick to mute · Option-click for effects · right-click for more"
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

    /// Click mutes or unmutes the app; Option-click opens its effects; right-click (or Control-click) opens its menu. The same on every
    /// app's icon, and the same gestures as the main speaker where they apply.
    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let key = sender.identifier?.rawValue else { return }
        switch StatusClick.current ?? .primary {
        case .primary:
            engine.update(key) { $0.muted.toggle() }
            if engine.timed[key] != nil { engine.cancelTimed(key) }
        case .option: toggleEffects(key, from: sender)
        case .secondary: showMenu(for: key, from: sender)
        }
    }

    private func toggleEffects(_ key: String, from sender: NSStatusBarButton) {
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

    private func showMenu(for key: String, from button: NSStatusBarButton) {
        let name = AudioProcessList.name(for: key)
        let settings = engine.current(key)
        let menu = NSMenu()
        StatusMenu.header(name, to: menu)
        let volume = "\(Int((settings.volume * 100).rounded()))%"
        StatusMenu.header(settings.muted ? "Muted" : "Volume \(volume)", to: menu)
        menu.addItem(.separator())
        StatusMenu.add(settings.muted ? "Unmute" : "Mute", symbol: settings.muted ? "speaker.wave.2" : "speaker.slash", to: menu) { [engine] in engine.update(key) { $0.muted.toggle() } }
        let volumes = NSMenuItem(title: "Volume", action: nil, keyEquivalent: "")
        let volumeMenu = NSMenu()
        for percent in [0, 25, 50, 75, 100, 150, 200] {
            StatusMenu.add(percent == 0 ? "Silent" : "\(percent)%", checked: Int((settings.volume * 100).rounded()) == percent, to: volumeMenu) { [engine] in
                engine.update(key) { $0.volume = Double(percent) / 100; $0.muted = false }
            }
        }
        volumes.submenu = volumeMenu
        menu.addItem(volumes)
        let timed = NSMenuItem(title: "Mute For", action: nil, keyEquivalent: "")
        let timedMenu = NSMenu()
        for (title, seconds) in [("5 Minutes", 300.0), ("15 Minutes", 900.0), ("30 Minutes", 1800.0), ("1 Hour", 3600.0)] {
            StatusMenu.add(title, to: timedMenu) { [engine] in engine.startTimed(key, level: 0, duration: seconds) }
        }
        if engine.timed[key] != nil { timedMenu.addItem(.separator()); StatusMenu.add("Cancel the Timer", to: timedMenu) { [engine] in engine.cancelTimed(key) } }
        timed.submenu = timedMenu
        menu.addItem(timed)
        let output = NSMenuItem(title: "Play On", action: nil, keyEquivalent: "")
        let outputMenu = NSMenu()
        StatusMenu.add("Mac's Output", checked: settings.outputs.isEmpty, to: outputMenu) { [engine] in engine.update(key) { $0.outputs = [] } }
        for device in mixer.outputs {
            StatusMenu.add(DeviceNames.shared.name(for: device), checked: settings.outputs == [device.uid], to: outputMenu) { [engine] in engine.update(key) { $0.outputs = [device.uid] } }
        }
        output.submenu = outputMenu
        menu.addItem(output)
        menu.addItem(.separator())
        StatusMenu.add(settings.effectsBypassed ? "Turn Effects Back On" : "Bypass Effects", symbol: "slider.horizontal.3", to: menu) { [engine] in engine.update(key) { $0.effectsBypassed.toggle() } }
        StatusMenu.add("Open Effects…", symbol: "waveform", to: menu) { [weak self] in self?.toggleEffects(key, from: button) }
        StatusMenu.add("Reset This App's Sound", symbol: "arrow.counterclockwise", enabled: !settings.isDefault || engine.timed[key] != nil, to: menu) { [engine] in engine.reset(key) }
        menu.addItem(.separator())
        StatusMenu.add("Remove This Icon", symbol: "menubar.rectangle", to: menu) { [engine] in engine.setMenuBarIcon(key, false) }
        StatusMenu.add("Leave This App Out of Kriya", symbol: "nosign", to: menu) { [engine] in engine.setExcluded(key, true) }
        StatusMenu.popUp(menu, from: button)
    }

    func popoverDidClose(_ notification: Notification) { engine.viewerGone() }
}
