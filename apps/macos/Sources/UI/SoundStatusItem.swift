import AppKit
import CoreAudio
import Combine
import SwiftUI

/// A speaker in the menu bar. Click for the mixer; right-click for outputs and quick mutes.
final class SoundStatusItem: NSObject, NSPopoverDelegate {
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
        let name: String
        if mixer.micMuted { name = "mic.slash.fill" }
        else if mixer.muted { name = style == "waveform" ? "waveform.slash" : "speaker.slash.fill" }
        else if style == "waveform" { name = "waveform" }
        else if !mixer.hasVolume { name = style == "match" ? "speaker.wave.2" : "speaker.wave.2.fill" }
        else {
            let level = mixer.volume > 0.66 ? "3" : mixer.volume > 0.33 ? "2" : mixer.volume > 0 ? "1" : ""
            name = level.isEmpty ? (style == "match" ? "speaker" : "speaker.fill") : "speaker.wave.\(level)" + (style == "match" ? "" : ".fill")
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Sound")
        image?.isTemplate = true
        button.image = image
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

    @objc private func clicked(_ sender: NSStatusBarButton) { clicked(sender, forcing: false) }

    private func clicked(_ sender: NSStatusBarButton, forcing: Bool) {
        let event = NSApp.currentEvent
        if !forcing, let event, event.type == .rightMouseUp || event.modifierFlags.contains(.control) { popover.performClose(nil); showMenu(); return }
        if !forcing, event == nil { return }
        if popover.isShown { popover.performClose(nil); return }
        let view = SoundPopoverView(openSettings: { [weak self] in self?.popover.performClose(nil); self?.openSettings() },
                                    setPinned: { [weak self] pinned in self?.popover.behavior = pinned ? .applicationDefined : .transient })
            .environmentObject(engine).environmentObject(mixer).environmentObject(quickConfigs ?? QuickConfigStore(engine: engine))
        let host = NSHostingController(rootView: view)
        // A fixed size: the window never resizes while you use it, so opening effects is smooth (the content scrolls inside).
        host.sizingOptions = []
        popover.contentSize = NSSize(width: SoundPopoverView.width, height: SoundPopoverView.height)
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
        menu.addItem(.separator())
        menu.addItem(withTitle: "Sound Settings…", action: #selector(settings), keyEquivalent: "").target = self
        item?.menu = menu
        item?.button?.performClick(nil)
        item?.menu = nil
    }

    @objc private func chooseOutput(_ sender: NSMenuItem) { mixer.chooseOutput(AudioDeviceID(sender.tag)) }
    @objc private func toggleMute() { mixer.toggleMute() }
    @objc private func toggleMic() { mixer.toggleMicMute() }
    @objc private func settings() { openSettings() }
}
