import AppKit
import CoreAudio
import Combine
import SwiftUI

/// A speaker in the menu bar. Click for the mixer; right-click for outputs and quick mutes.
final class SoundStatusItem: NSObject, NSPopoverDelegate {
    static let enabledKey = "soundMenuBar.enabled"
    private let engine: AppAudioEngine
    private let mixer: SoundMixerModel
    private let openSettings: () -> Void
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
        sync()
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

    private func refreshIcon() {
        guard let button = item?.button else { return }
        let name: String
        if mixer.micMuted { name = "mic.slash.fill" }
        else if mixer.muted { name = "speaker.slash.fill" }
        else if !mixer.hasVolume { name = "speaker.wave.2.fill" }
        else { name = mixer.volume > 0.66 ? "speaker.wave.3.fill" : mixer.volume > 0.33 ? "speaker.wave.2.fill" : mixer.volume > 0 ? "speaker.wave.1.fill" : "speaker.fill" }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Sound")
        image?.isTemplate = true
        button.image = image
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) { popover.performClose(nil); showMenu(); return }
        if popover.isShown { popover.performClose(nil); return }
        let view = ScrollView { Form { SoundMixerContent() }.formStyle(.grouped).scrollDisabled(true) }
            .frame(width: 400, height: 560)
            .environmentObject(engine).environmentObject(mixer)
        popover.contentViewController = NSHostingController(rootView: view)
        popover.contentSize = NSSize(width: 400, height: 560)
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
