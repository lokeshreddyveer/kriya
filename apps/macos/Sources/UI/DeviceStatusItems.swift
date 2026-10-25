import AppKit
import Combine
import CoreAudio

/// A menu-bar icon for each sound device the person pinned there. It shows whether the device is in use, connected, muted, being
/// reconnected or gone (with the sound on another device in its place). A click makes it the sound output (or input), or mutes it if
/// it already is; an Option-click opens its details; a right-click opens its menu, including connecting a Bluetooth device.
final class DeviceStatusItems: NSObject {
    static let key = "soundDevices.menuBar.v1"
    private let mixer: SoundMixerModel
    private let openSettings: () -> Void
    private var items: [String: NSStatusItem] = [:]
    private var reconnecting: [String: Date] = [:]
    private var transports: [String: DeviceDetails.Transport] = [:]
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let audio = AudioControl.shared

    static func pinned() -> [PinnedDevice] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([PinnedDevice].self, from: $0) } ?? []
    }

    static func save(_ list: [PinnedDevice]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Pins or unpins a device. The icons follow the saved list.
    static func setPinned(_ device: PinnedDevice, _ on: Bool) {
        save(on ? PinnedDevice.adding(device, to: pinned()) : PinnedDevice.removing(device.id, from: pinned()))
    }

    init(mixer: SoundMixerModel, openSettings: @escaping () -> Void) {
        self.mixer = mixer
        self.openSettings = openSettings
        super.init()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }.store(in: &cancellables)
        // An icon follows the device at once when the output or volume changes, or when its name or icon is changed, not at the next
        // three-second look.
        // Throttled, because each look asks Core Audio on the main thread and the mixer publishes on every slider movement.
        mixer.objectWillChange.throttle(for: .milliseconds(400), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &cancellables)
        DeviceNames.shared.objectWillChange.throttle(for: .milliseconds(400), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &cancellables)
        sync()
    }

    private var lastList: [PinnedDevice]?

    private func sync() {
        let list = Self.pinned()
        // Any saved setting anywhere in Kriya comes through here; only a change to this list needs the icons rebuilt.
        guard list != lastList else { return }
        lastList = list
        let ids = Set(list.map(\.id))
        for (id, item) in items where !ids.contains(id) {
            NSStatusBar.system.removeStatusItem(item)
            items[id] = nil
        }
        for device in list where items[device.id] == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.identifier = NSUserInterfaceItemIdentifier(device.id)
            items[device.id] = item
        }
        if items.isEmpty { timer?.invalidate(); timer = nil } else if timer == nil {
            // A device can come or go while nothing else is happening, so the icons look again every few seconds.
            let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        refresh()
    }

    // MARK: Status

    private func live(_ pin: PinnedDevice) -> AudioDevice? { audio.device(uid: pin.uid).flatMap { ($0.isInput && pin.input) || ($0.isOutput && !pin.input) ? $0 : nil } }

    private func status(of pin: PinnedDevice) -> DeviceIconState {
        let device = live(pin)
        if device != nil { reconnecting[pin.id] = nil }
        if let since = reconnecting[pin.id], Date().timeIntervalSince(since) > 20 { reconnecting[pin.id] = nil }
        let current = audio.defaultDevice(input: pin.input).flatMap { audio.uid(of: $0) }
        let muted = device.map { audio.isMuted($0.id, input: pin.input) ?? false } ?? false
        return .resolve(connected: device != nil, inUse: device != nil && current == pin.uid, muted: muted, reconnecting: reconnecting[pin.id] != nil,
                        replacedBy: device == nil && current != nil)
    }

    private func refresh() {
        // An icon saved before the device's own name was kept gets it the first time the device is seen.
        var list = Self.pinned()
        var upgraded = false
        for index in list.indices where list[index].hardwareName == nil {
            if let device = live(list[index]) { list[index].hardwareName = device.name; upgraded = true }
        }
        if upgraded { lastList = list; Self.save(list) }
        for pin in list {
            guard let button = items[pin.id]?.button else { continue }
            let state = status(of: pin)
            if let device = live(pin) { transports[pin.id] = audio.details(of: device).transport }
            button.image = Self.icon(transport: transports[pin.id], input: pin.input, status: state)
            button.alphaValue = state.opacity
            button.toolTip = "\(pin.name) (\(pin.input ? "input" : "output")): \(state.title)\nClick to \(state == .active ? "mute" : state == .muted ? "unmute" : state == .disconnected || state == .fallback ? "connect" : "use") · Option-click for details · right-click for more"
        }
    }

    static func icon(transport: DeviceDetails.Transport?, input: Bool, status: DeviceIconState) -> NSImage {
        let name = input ? "mic" : (transport?.symbol ?? "speaker.wave.2")
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) ?? NSImage()
        guard status.slashed else { base.isTemplate = true; return base }
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX + 1, y: rect.maxY - 1)); path.line(to: NSPoint(x: rect.maxX - 1, y: rect.minY + 1))
            path.lineWidth = 1.5; path.lineCapStyle = .round
            NSColor.black.setStroke(); path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let id = sender.identifier?.rawValue, let pin = Self.pinned().first(where: { $0.id == id }) else { return }
        switch StatusClick.current ?? .primary {
        case .primary: primary(pin)
        case .option: openSettings()
        case .secondary: showMenu(for: pin, from: sender)
        }
        refresh()
    }

    private func primary(_ pin: PinnedDevice) {
        switch status(of: pin) {
        case .active, .muted:
            if let device = live(pin) { _ = audio.setMuted(!(audio.isMuted(device.id, input: pin.input) ?? false), device: device.id, input: pin.input) }
        case .connected:
            if let device = live(pin) { audio.setDefault(device); mixer.refreshNow() }
        case .disconnected, .fallback, .reconnecting:
            connect(pin)
        }
    }

    private func peer(for pin: PinnedDevice) -> BluetoothPeer? { BluetoothAudio.peer(named: pin.lookupName, in: BluetoothAudio.paired()) }

    private func connect(_ pin: PinnedDevice) {
        guard let peer = peer(for: pin) else { return }
        reconnecting[pin.id] = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = BluetoothAudio.set(connected: true, address: peer.address)
            DispatchQueue.main.async { if !ok { self?.reconnecting[pin.id] = nil }; self?.refresh() }
        }
    }

    private func showMenu(for pin: PinnedDevice, from button: NSStatusBarButton) {
        let state = status(of: pin)
        let menu = NSMenu()
        StatusMenu.header(pin.name, to: menu)
        StatusMenu.header(state.title, to: menu)
        menu.addItem(.separator())
        if let device = live(pin) {
            let inUse = state == .active || (state == .muted && audio.defaultDevice(input: pin.input) == device.id)
            StatusMenu.add(pin.input ? "Use as Input" : "Use as Output", symbol: pin.input ? "mic" : "speaker.wave.2", checked: inUse, to: menu) { [weak self] in
                self?.audio.setDefault(device); self?.mixer.refreshNow(); self?.refresh()
            }
            if !pin.input {
                StatusMenu.add("Use for Sound Effects", symbol: "bell", to: menu) { [weak self] in self?.mixer.chooseEffectsOutput(device.id) }
            }
            let muted = audio.isMuted(device.id, input: pin.input) ?? false
            StatusMenu.add(muted ? "Unmute" : "Mute", symbol: muted ? "speaker.wave.2" : "speaker.slash", to: menu) { [weak self] in
                _ = self?.audio.setMuted(!muted, device: device.id, input: pin.input); self?.refresh()
            }
        }
        if let peer = peer(for: pin) {
            menu.addItem(.separator())
            if peer.isConnected {
                StatusMenu.add("Disconnect Bluetooth", symbol: "bolt.slash", to: menu) { [weak self] in
                    DispatchQueue.global(qos: .userInitiated).async { _ = BluetoothAudio.set(connected: false, address: peer.address); DispatchQueue.main.async { self?.refresh() } }
                }
            } else {
                StatusMenu.add("Connect Bluetooth", symbol: "bolt.horizontal", to: menu) { [weak self] in self?.connect(pin) }
            }
        }
        menu.addItem(.separator())
        StatusMenu.add("Device Details…", symbol: "info.circle", to: menu) { [weak self] in self?.openSettings() }
        StatusMenu.add("Remove This Icon", symbol: "menubar.rectangle", to: menu) { Self.setPinned(pin, false) }
        StatusMenu.popUp(menu, from: button)
    }
}
