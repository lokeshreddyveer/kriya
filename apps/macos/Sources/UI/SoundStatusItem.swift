import AppKit
import CoreAudio
import Combine
import SwiftUI

/// A speaker in the menu bar. Click for the mixer; right-click for outputs and quick mutes.
final class SoundStatusItem: NSObject, NSPopoverDelegate, NSMenuDelegate {
    static let enabledKey = "soundMenuBar.enabled"
    static let showVolumeKey = "soundMenuBar.showVolume"
    static let showDeviceKey = "soundMenuBar.showDevice"
    static let iconStyleKey = "soundMenuBar.iconStyle"
    static let toggleNotification = Notification.Name("kriya.sound.toggleMixer")
    private let engine: AppAudioEngine
    private let mixer: SoundMixerModel
    private let openSettings: () -> Void
    var quickConfigs: QuickConfigStore?
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var viewing = false

    init(engine: AppAudioEngine, mixer: SoundMixerModel, openSettings: @escaping () -> Void) {
        self.engine = engine
        self.mixer = mixer
        self.openSettings = openSettings
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }.store(in: &cancellables)
        mixer.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in DispatchQueue.main.async { self?.refreshIcon() } }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: Self.toggleNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.toggleMixer() }.store(in: &cancellables)
        sync()
    }

    /// Opens or closes the mixer from a shortcut, even when the menu-bar speaker is switched off.
    private func toggleMixer() {
        if item == nil { UserDefaults.standard.set(true, forKey: Self.enabledKey); sync() }
        if let button = item?.button { clicked(button, forcing: true) }
    }

    private func sync() {
        let on = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if on, item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            i.button?.target = self
            i.button?.action = #selector(clicked(_:))
            i.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item = i
            mixer.viewerAppeared()   // keeps the icon in step with the volume
            refreshIcon()
        } else if !on, let existing = item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(existing)
            item = nil
            mixer.viewerGone()
        }
    }

    /// The speaker (or waveform) for the current state, with the volume and the output's name beside it if those are switched on.
    private func refreshIcon() {
        guard let button = item?.button else { return }
        let style = UserDefaults.standard.string(forKey: Self.iconStyleKey) ?? "speaker"
        // The icon is about the output, always; a muted microphone is a small badge beside it, not a replacement for it, so the icon and
        // the volume figure never describe different things.
        let name: String
        if mixer.muted { name = style == "waveform" ? "waveform.slash" : "speaker.slash.fill" }
        else if style == "waveform" { name = "waveform" }
        else if !mixer.hasVolume { name = style == "match" ? "speaker.wave.2" : "speaker.wave.2.fill" }
        else {
            let level = mixer.volume > 0.66 ? "3" : mixer.volume > 0.33 ? "2" : mixer.volume > 0 ? "1" : ""
            name = level.isEmpty ? (style == "match" ? "speaker" : "speaker.fill") : "speaker.wave.\(level)" + (style == "match" ? "" : ".fill")
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Sound")
        image?.isTemplate = true
        button.image = mixer.micMuted ? Self.badged(image, with: "mic.slash.fill") ?? image : image
        button.toolTip = mixer.micMuted ? "The microphone is muted" : nil
        var text = ""
        if UserDefaults.standard.bool(forKey: Self.showVolumeKey) { text += mixer.muted ? " Muted" : (mixer.hasVolume ? " \(Int((mixer.volume * 100).rounded()))%" : "") }
        if UserDefaults.standard.bool(forKey: Self.showDeviceKey), let device = mixer.outputs.first(where: { $0.id == mixer.outputID }) {
            let label = DeviceNames.shared.name(for: device)
            text += " " + (label.count > 16 ? String(label.prefix(15)) + "…" : label)
        }
        button.title = text
        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
        item?.length = text.isEmpty ? NSStatusItem.squareLength : NSStatusItem.variableLength
    }

    /// The speaker with a small symbol drawn beside it, as one template image (so the menu bar tints it for light and dark).
    private static func badged(_ base: NSImage?, with symbol: String) -> NSImage? {
        guard let base, let badge = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) else { return nil }
        let gap: CGFloat = 1
        let size = NSSize(width: base.size.width + gap + badge.size.width, height: max(base.size.height, badge.size.height))
        let image = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(x: 0, y: (size.height - base.size.height) / 2, width: base.size.width, height: base.size.height))
            badge.draw(in: NSRect(x: base.size.width + gap, y: (size.height - badge.size.height) / 2, width: badge.size.width, height: badge.size.height))
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func clicked(_ sender: NSStatusBarButton) { clicked(sender, forcing: false) }

    private func clicked(_ sender: NSStatusBarButton, forcing: Bool) {
        let event = NSApp.currentEvent
        if !forcing, let event, event.type == .rightMouseUp || event.modifierFlags.contains(.control) { popover.performClose(nil); showMenu(); return }
        if !forcing, event == nil { return }
        if popover.isShown { popover.performClose(nil); return }
        // As tall as fits the display this icon is on, not the main display, which may be a larger one.
        let height = SoundPopoverView.height(on: sender.window?.screen)
        let view = SoundPopoverView(openSettings: { [weak self] in self?.popover.performClose(nil); self?.openSettings() },
                                    setPinned: { [weak self] pinned in self?.popover.behavior = pinned ? .applicationDefined : .transient }, height: height)
            .environmentObject(engine).environmentObject(mixer).environmentObject(quickConfigs ?? QuickConfigStore(engine: engine))
        let host = NSHostingController(rootView: view)
        // A fixed size: the window never resizes while you use it, so opening effects is smooth (the content scrolls inside).
        host.sizingOptions = []
        popover.contentSize = NSSize(width: SoundPopoverView.width, height: height)
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        // As the person left it: pinned open, or closing when they click elsewhere.
        popover.behavior = UserDefaults.standard.bool(forKey: SoundPopoverView.pinnedKey) ? .applicationDefined : .transient
        popover.contentViewController = host
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        if !viewing { viewing = true; engine.viewerAppeared() }
    }

    func popoverDidClose(_ notification: Notification) {
        if viewing { viewing = false; engine.viewerGone() }
    }

    private func showMenu() {
        let menu = NSMenu()
        mixer.refresh()
        let header = NSMenuItem(title: "Play sound on", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for device in mixer.outputs {
            let entry = NSMenuItem(title: device.name, action: #selector(chooseOutput(_:)), keyEquivalent: "")
            entry.target = self; entry.tag = Int(device.id)
            entry.state = device.id == mixer.outputID ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let mute = menu.addItem(withTitle: mixer.muted ? "Unmute Sound" : "Mute Sound", action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self
        let mic = menu.addItem(withTitle: mixer.micMuted ? "Unmute Microphone" : "Mute Microphone", action: #selector(toggleMic), keyEquivalent: "")
        mic.target = self
        // What the mixer has, without opening it: the favourite apps (a check shows one that is muted), the Quick Configs, and the timed
        // mutes that are running.
        if !engine.favorites.isEmpty {
            menu.addItem(.separator())
            let parent = NSMenuItem(title: "Mute or Unmute an App", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for id in engine.favorites {
                let entry = NSMenuItem(title: AudioProcessList.name(for: id), action: #selector(toggleAppMute(_:)), keyEquivalent: "")
                entry.target = self; entry.representedObject = id
                entry.state = engine.current(id).muted ? .on : .off
                sub.addItem(entry)
            }
            parent.submenu = sub
            menu.addItem(parent)
        }
        if let quick = quickConfigs, !quick.configs.isEmpty {
            let parent = NSMenuItem(title: "Quick Configs", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for config in quick.configs {
                let entry = NSMenuItem(title: config.name, action: #selector(applyQuickConfig(_:)), keyEquivalent: "")
                entry.target = self; entry.representedObject = config.id
                sub.addItem(entry)
            }
            parent.submenu = sub
            menu.addItem(parent)
        }
        if !engine.timed.isEmpty {
            menu.addItem(withTitle: "Cancel Timed Mutes and Turn-Downs", action: #selector(cancelTimed), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Sound Settings…", action: #selector(settings), keyEquivalent: "").target = self
        // Opened by the menu bar itself and put away when it closes, so the next click comes back to the popover.
        menu.delegate = self
        item?.menu = menu
        item?.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in self?.item?.menu = nil }
    }

    @objc private func toggleAppMute(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        engine.update(id) { $0.muted.toggle() }
    }
    @objc private func applyQuickConfig(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        quickConfigs?.apply(id)
    }
    @objc private func cancelTimed() { engine.cancelAllTimed() }

    @objc private func chooseOutput(_ sender: NSMenuItem) { mixer.chooseOutput(AudioDeviceID(sender.tag)) }
    @objc private func toggleMute() { mixer.toggleMute() }
    @objc private func toggleMic() { mixer.toggleMicMute() }
    @objc private func settings() { openSettings() }
}
