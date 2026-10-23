import SwiftUI

/// The sound mixer: the Mac's output and input, and each app that is making sound with its own volume, mute, output and equaliser.
struct SoundPane: View {
    @EnvironmentObject private var engine: AppAudioEngine
    @EnvironmentObject private var mixer: SoundMixerModel
    @AppStorage(SoundStatusItem.enabledKey) private var menuBar = false
    @State private var keys = VolumeKeys.isEnabled {
        didSet { VolumeKeys.isEnabled = keys }
    }

    var body: some View {
        Form {
            if !AppAudioEngine.isSupported {
                Section { Label("Changing one app's sound needs macOS 14.2 or later. The system volume below still works.", systemImage: "info.circle").foregroundStyle(.secondary) }
            }
            Section {
                Toggle("Show a speaker in the menu bar", isOn: $menuBar)
                Toggle("Keyboard volume keys work on outputs without a volume", isOn: $keys)
            } footer: { Text("Many monitors over HDMI or DisplayPort ignore the volume keys. With this on, the keys change Kriya’s “All sound” level instead, only while such an output is in use. Click the menu-bar speaker for this mixer; right-click it for outputs and mutes. Shortcuts has actions to set an app’s volume, mute an app, switch the output and set the Mac’s volume.") }
            SoundMixerContent()
            Section {
                DictationSection()
            } header: { Text("Dictation") } footer: {
                Text("Give “Start or stop dictation” a shortcut in Keyboard (or use the Dictate tile). Press it, speak, press it again, and the words are typed where you are. Say “comma”, “period”, “question mark”, “new line” or “new paragraph” for punctuation. It listens only between the two presses and uses the Mac's on-device recogniser.")
            }
            Section {
                SpeechSection()
            } header: { Text("Read aloud") } footer: {
                Text("Used by the Read Aloud command and tile, which reads the text on the clipboard. Better voices can be downloaded in System Settings › Accessibility › Spoken Content.")
            }
            Section {
                ProfilesSection()
            } header: { Text("Sound profiles") } footer: {
                Text("A profile is a saved volume, output and equaliser you can give to any app, or to all sound. Save one from the ••• menu of an app.")
            }
            Section {
                SoundModesSection()
            } header: { Text("Sound modes") } footer: {
                Text("A mode is several sound changes turned on together, such as headset, microphone and volume for a meeting. Turn it off to put the sound back how it was. The starting two only set the volume; edit them to add your own headset and microphone. Modes can also be run from shortcuts and workflows with the commands sound.mode.<name>.")
            }
            Section {
                BluetoothSection()
            } header: { Text("Bluetooth audio") } footer: {
                Text("Connect or disconnect headphones and speakers that are already paired in System Settings. macOS asks Kriya for Bluetooth access the first time. Kriya cannot pair new devices.")
            }
            Section {
                SoundRulesSection()
            } header: { Text("Sound rules") } footer: {
                Text("Do something when headphones connect or an app opens or quits: switch the output, mute the microphone, set the volume, or connect a Bluetooth device.")
            }
            Section {
                SoundHistorySection()
            } header: { Text("Device history") } footer: {
                Text("When sound devices connected and disconnected. A device that keeps coming back is a flaky connection.")
            }
        }
        .formStyle(.grouped)
        .onAppear { engine.viewerAppeared(); mixer.viewerAppeared() }
        .onDisappear { engine.viewerGone(); mixer.viewerGone() }
    }
}

/// The mixer itself, shared by the settings page and the menu-bar window.
struct SoundMixerContent: View {
    @EnvironmentObject private var engine: AppAudioEngine
    @EnvironmentObject private var mixer: SoundMixerModel

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Button { mixer.toggleMute() } label: { Image(systemName: mixer.muted ? "speaker.slash.fill" : volumeSymbol) }.buttonStyle(.borderless).frame(width: 22)
                Slider(value: Binding(get: { mixer.volume }, set: { mixer.setVolume($0) }), in: 0...1)
                Text("\(Int((mixer.volume * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
            .disabled(!mixer.hasVolume)
            if !mixer.hasVolume { Text("This output has no volume of its own. Use “All sound” below, or the keyboard volume keys.").font(.caption).foregroundStyle(.secondary) }
            Picker("Output", selection: Binding(get: { mixer.outputID }, set: { mixer.chooseOutput($0) })) {
                ForEach(mixer.outputs) { Text($0.name).tag($0.id) }
            }
            Picker("Input", selection: Binding(get: { mixer.inputID }, set: { mixer.chooseInput($0) })) {
                ForEach(mixer.inputs) { Text($0.name).tag($0.id) }
            }
            HStack(spacing: 10) {
                Image(systemName: mixer.micMuted ? "mic.slash.fill" : "mic.fill").frame(width: 22)
                Slider(value: Binding(get: { mixer.inputVolume }, set: { mixer.setInputVolume($0) }), in: 0...1)
                Button(mixer.micMuted ? "Unmute" : "Mute") { mixer.toggleMicMute() }.controlSize(.small)
            }
            .disabled(!mixer.hasInputVolume)
            DeviceSettingsRow()
        } header: { Text("This Mac") }

        Section {
            AppMixerRow(key: AppAudioEngine.systemKey, name: "All sound", symbol: "speaker.wave.3.fill", bundleID: nil)
            if engine.apps.isEmpty { Text("No app is making sound right now.").foregroundStyle(.secondary) }
            ForEach(engine.apps) { app in AppMixerRow(key: app.id, name: app.name, symbol: "app", bundleID: app.bundleID) }
        } header: { Text("Apps") } footer: {
            Text("Move an app's slider past 100% to make it louder, up to 400%. Kriya listens to the app's sound only to change it and plays it straight back; nothing is recorded. The first time, macOS asks you to allow it.")
        }
    }

    private var volumeSymbol: String { mixer.volume > 0.66 ? "speaker.wave.3.fill" : mixer.volume > 0.33 ? "speaker.wave.2.fill" : mixer.volume > 0 ? "speaker.wave.1.fill" : "speaker.fill" }
}

/// One app: icon, level meter, volume, mute, output and equaliser.
struct AppMixerRow: View {
    @EnvironmentObject private var engine: AppAudioEngine
    @EnvironmentObject private var mixer: SoundMixerModel
    let key: String
    let name: String
    let symbol: String
    let bundleID: String?
    @State private var showEQ = false

    private var settings: AppAudioSettings { engine.current(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                icon.frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).lineLimit(1)
                    if let problem = engine.problems[key] { Text(problem).font(.caption).foregroundStyle(Theme.warn).lineLimit(3) }
                    else if !settings.isDefault { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                LevelMeter(level: engine.level(of: key)).frame(width: 46, height: 6)
                Menu {
                    Button("Equaliser…") { showEQ.toggle() }
                    Menu("Output") {
                        Button { engine.update(key) { $0.outputs = [] } } label: { Label("Follow the Mac's output", systemImage: settings.outputs.isEmpty ? "checkmark" : "") }
                        ForEach(mixer.outputs) { device in
                            Button { toggleOutput(device) } label: { Label(device.name, systemImage: settings.outputs.contains(device.uid) ? "checkmark" : "") }
                        }
                    }
                    Menu("Profile") {
                        ForEach(engine.profiles) { profile in Button(profile.name) { engine.apply(profile: profile, to: key) } }
                        if !engine.profiles.isEmpty { Divider() }
                        Button("Save These Settings as a Profile…") { saveProfile() }
                    }
                    Divider()
                    Button("Reset", role: .destructive) { engine.reset(key) }.disabled(settings.isDefault)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 28)
            }
            HStack(spacing: 10) {
                Button { engine.update(key) { $0.muted.toggle() } } label: { Image(systemName: settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }.buttonStyle(.borderless).frame(width: 26)
                Slider(value: Binding(get: { settings.volume }, set: { v in engine.update(key) { $0.volume = (abs(v - 1) < 0.03 ? 1 : v) } }), in: 0...AppAudioSettings.maxVolume)
                Text("\(Int((settings.volume * 100).rounded()))%").monospacedDigit().font(.callout).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
            if showEQ { EQView(key: key).transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .padding(.vertical, 2)
        .animation(.smooth(duration: 0.18), value: showEQ)
    }

    @ViewBuilder private var icon: some View {
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Theme.accent)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if settings.muted { parts.append("Muted") } else if abs(settings.volume - 1) > 0.005 { parts.append("Volume \(Int((settings.volume * 100).rounded()))%") }
        if !settings.outputs.isEmpty {
            let names = settings.outputs.compactMap { uid in mixer.outputs.first { $0.uid == uid }?.name }
            parts.append(names.isEmpty ? "Other output" : names.joined(separator: " + "))
        }
        if let preset = EQPreset.matching(settings.eq), preset != .flat { parts.append(preset.title) } else if !settings.eq.allSatisfy({ abs($0) < 0.01 }) { parts.append("Custom equaliser") }
        return parts.joined(separator: " · ")
    }

    private func toggleOutput(_ device: AudioDevice) {
        engine.update(key) { s in
            if let i = s.outputs.firstIndex(of: device.uid) { s.outputs.remove(at: i) } else { s.outputs.append(device.uid) }
        }
    }

    private func saveProfile() {
        let alert = NSAlert()
        alert.messageText = "Name this profile"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "For example, Music loud"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let n = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { engine.saveProfile(named: n, from: key) }
    }
}

struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(level > 0.9 ? Theme.warn : Theme.ok).frame(width: max(2, geo.size.width * CGFloat(min(level, 1))))
                    .animation(.easeOut(duration: 0.1), value: level)
            }
        }
    }
}

/// Ten sliders, one for each band, and the ready-made shapes.
struct EQView: View {
    @EnvironmentObject private var engine: AppAudioEngine
    let key: String

    var body: some View {
        let gains = engine.current(key).eq
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Shape", selection: Binding(get: { EQPreset.matching(gains) }, set: { p in if let p { engine.update(key) { $0.eq = p.gains } } })) {
                    Text("Custom").tag(EQPreset?.none)
                    ForEach(EQPreset.allCases) { Text($0.title).tag(EQPreset?.some($0)) }
                }
                Button("Flat") { engine.update(key) { $0.eq = EQPreset.flat.gains } }.controlSize(.small)
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<EQBands.count, id: \.self) { band in
                    VStack(spacing: 3) {
                        Slider(value: Binding(get: { Double(gains[band]) }, set: { v in engine.update(key) { $0.eq[band] = Float(abs(v) < 0.4 ? 0 : v) } }), in: -Double(EQBands.limit)...Double(EQBands.limit))
                            .rotationEffect(.degrees(-90)).frame(width: 70, height: 70).frame(width: 24, height: 76)
                        Text(label(EQBands.frequencies[band])).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func label(_ f: Float) -> String { f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))" }
}

private struct DeviceSettingsRow: View {
    @EnvironmentObject private var mixer: SoundMixerModel

    var body: some View {
        if let rates = mixer.sampleRates, !rates.isEmpty {
            Picker("Sample rate", selection: Binding(get: { mixer.sampleRate }, set: { mixer.setSampleRate($0) })) {
                ForEach(rates, id: \.self) { Text(String(format: "%g kHz", $0 / 1000)).tag($0) }
            }
        }
        if mixer.hasBalance {
            HStack {
                Text("Balance")
                Slider(value: Binding(get: { mixer.balance }, set: { mixer.setBalance($0) }), in: 0...1)
                Button("Centre") { mixer.setBalance(0.5) }.controlSize(.small)
            }
        }
    }
}

private struct ProfilesSection: View {
    @EnvironmentObject private var engine: AppAudioEngine

    var body: some View {
        if engine.profiles.isEmpty { Text("No profiles yet.").foregroundStyle(.secondary) }
        ForEach(engine.profiles) { profile in
            HStack {
                VStack(alignment: .leading) {
                    Text(profile.name)
                    Text(describe(profile.settings)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Give to") {
                    Button("All sound") { engine.apply(profile: profile, to: AppAudioEngine.systemKey) }
                    ForEach(engine.apps) { app in Button(app.name) { engine.apply(profile: profile, to: app.id) } }
                }.menuStyle(.borderlessButton).fixedSize()
                Button(role: .destructive) { engine.profiles.removeAll { $0.id == profile.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
        }
    }

    private func describe(_ s: AppAudioSettings) -> String {
        var parts = ["Volume \(Int((s.volume * 100).rounded()))%"]
        if s.muted { parts = ["Muted"] }
        if let p = EQPreset.matching(s.eq), p != .flat { parts.append(p.title) }
        if !s.outputs.isEmpty { parts.append("\(s.outputs.count) output\(s.outputs.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

private struct SoundRulesSection: View {
    @EnvironmentObject private var runner: SoundRuleRunner
    @EnvironmentObject private var mixer: SoundMixerModel
    @State private var adding = false

    var body: some View {
        if runner.rules.isEmpty { Text("No rules yet.").foregroundStyle(.secondary) }
        ForEach($runner.rules) { $rule in
            HStack {
                Toggle("", isOn: $rule.enabled).labelsHidden()
                Text(rule.summary).lineLimit(2)
                Spacer()
                Button(role: .destructive) { runner.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
        }
        Button("Add a Rule…") { adding = true }
            .sheet(isPresented: $adding) { RuleEditor { runner.rules.append($0); adding = false } onCancel: { adding = false } }
    }
}

private struct RuleEditor: View {
    enum TriggerKind: String, CaseIterable { case deviceConnected = "A sound device connects", deviceDisconnected = "A sound device disconnects", appLaunched = "An app opens", appQuit = "An app quits" }
    enum ActionKind: String, CaseIterable { case useOutput = "Play sound on…", useInput = "Use the microphone…", muteMic = "Mute the microphone", unmuteMic = "Unmute the microphone", muteSound = "Mute the sound", unmuteSound = "Unmute the sound", volume = "Set the volume", connectBT = "Connect Bluetooth device…", disconnectBT = "Disconnect Bluetooth device…" }

    let onSave: (SoundRule) -> Void
    let onCancel: () -> Void
    @State private var trigger = TriggerKind.deviceConnected
    @State private var action = ActionKind.useOutput
    @State private var deviceText = ""
    @State private var appID = ""
    @State private var actionText = ""
    @State private var percent = 50.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sound rule").font(.headline)
            Picker("When", selection: $trigger) { ForEach(TriggerKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            if trigger == .deviceConnected || trigger == .deviceDisconnected {
                TextField("Part of its name, for example AirPods", text: $deviceText)
            } else {
                HStack { Text(appID.isEmpty ? "No app chosen" : AppChoice.name(for: appID)).foregroundStyle(.secondary); Spacer(); Button("Choose App…") { if let id = AppChoice.choose() { appID = id } } }
            }
            Picker("Then", selection: $action) { ForEach(ActionKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            if action == .useOutput || action == .useInput || action == .connectBT || action == .disconnectBT { TextField("Part of the device's name", text: $actionText) }
            if action == .volume { HStack { Slider(value: $percent, in: 0...100, step: 1); Text("\(Int(percent))%").monospacedDigit() } }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Add") { if let rule = make() { onSave(rule) } }.keyboardShortcut(.defaultAction).disabled(make() == nil)
            }
        }
        .padding(18).frame(width: 420)
    }

    private func make() -> SoundRule? {
        let device = deviceText.trimmingCharacters(in: .whitespaces)
        let t: SoundTrigger
        switch trigger {
        case .deviceConnected: guard !device.isEmpty else { return nil }; t = .deviceConnected(contains: device)
        case .deviceDisconnected: guard !device.isEmpty else { return nil }; t = .deviceDisconnected(contains: device)
        case .appLaunched: guard !appID.isEmpty else { return nil }; t = .appLaunched(bundleID: appID)
        case .appQuit: guard !appID.isEmpty else { return nil }; t = .appQuit(bundleID: appID)
        }
        let name = actionText.trimmingCharacters(in: .whitespaces)
        let a: SoundAction
        switch action {
        case .useOutput: guard !name.isEmpty else { return nil }; a = .useOutput(nameContains: name)
        case .useInput: guard !name.isEmpty else { return nil }; a = .useInput(nameContains: name)
        case .muteMic: a = .muteMic(true)
        case .unmuteMic: a = .muteMic(false)
        case .muteSound: a = .muteSound(true)
        case .unmuteSound: a = .muteSound(false)
        case .volume: a = .setVolume(percent: Int(percent))
        case .connectBT: guard !name.isEmpty else { return nil }; a = .connectBluetooth(nameContains: name)
        case .disconnectBT: guard !name.isEmpty else { return nil }; a = .disconnectBluetooth(nameContains: name)
        }
        return SoundRule(trigger: t, action: a)
    }
}

private struct SpeechSection: View {
    @EnvironmentObject private var speaker: Speaker

    var body: some View {
        Picker("Voice", selection: $speaker.voiceID) {
            Text("System voice").tag("")
            ForEach(Speaker.voices(), id: \.identifier) { voice in Text("\(voice.name) (\(voice.language))\(voice.quality == .enhanced ? " · enhanced" : voice.quality == .premium ? " · premium" : "")").tag(voice.identifier) }
        }
        HStack { Text("Speed"); Slider(value: $speaker.rate, in: 0.2...0.7); Text(speaker.rate < 0.42 ? "Slow" : speaker.rate > 0.55 ? "Fast" : "Normal").frame(width: 50, alignment: .trailing).foregroundStyle(.secondary) }
        HStack { Text("Pitch"); Slider(value: $speaker.pitch, in: 0.6...1.6) }
        Button("Hear It") { speaker.preview() }
    }
}

private struct DictationSection: View {
    @EnvironmentObject private var dictation: DictationService

    var body: some View {
        HStack {
            Label(dictation.isListening ? "Listening…" : "Not listening", systemImage: dictation.isListening ? "mic.fill" : "mic").foregroundStyle(dictation.isListening ? Theme.danger : Color.secondary)
            Spacer()
            Button(dictation.isListening ? "Stop" : "Try It") { dictation.toggle() }.controlSize(.small)
        }
        Picker("Language", selection: $dictation.language) {
            ForEach(DictationService.languages(), id: \.identifier) { Text($0.localizedString(forIdentifier: $0.identifier) ?? $0.identifier).tag($0.identifier) }
        }
        Toggle("Allow Apple's servers when the language is not available on this Mac", isOn: $dictation.allowServer)
    }
}


private struct SoundModesSection: View {
    @EnvironmentObject private var runner: SoundRuleRunner
    @State private var editing: SoundMode?

    var body: some View {
        ForEach(runner.modes) { mode in
            HStack {
                Image(systemName: mode.symbol).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.name)
                    Text(mode.actions.map(\.title).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(runner.activeModeID == mode.id ? "Turn Off" : "Turn On") { runner.toggle(mode) }.controlSize(.small)
                    .buttonStyle(.borderedProminent).tint(runner.activeModeID == mode.id ? .orange : Theme.accent)
                Button("Edit") { editing = mode }.controlSize(.small)
            }
        }
        HStack {
            Button("New Mode…") { editing = SoundMode(name: "", actions: []) }
            Spacer()
            Button("Put the Sound Back") { runner.putSoundBack() }.disabled(runner.snapshot == nil)
                .help("Restores the output, microphone, volume and mutes from before Kriya changed them")
        }
        EmptyView().sheet(item: $editing) { mode in
            ModeEditor(mode: mode, canDelete: runner.modes.contains { $0.id == mode.id }) { saved in
                if let saved {
                    if let index = runner.modes.firstIndex(where: { $0.id == saved.id }) { runner.modes[index] = saved } else { runner.modes.append(saved) }
                }
                editing = nil
            } onDelete: {
                runner.modes.removeAll { $0.id == mode.id }
                editing = nil
            }
        }
    }
}

private struct ModeEditor: View {
    @State var mode: SoundMode
    let canDelete: Bool
    let onClose: (SoundMode?) -> Void
    let onDelete: () -> Void
    @State private var kind = Kind.useOutput
    @State private var text = ""
    @State private var percent = 60.0

    enum Kind: String, CaseIterable, Identifiable {
        case useOutput = "Play sound on…", useInput = "Use the microphone…", muteMic = "Mute the microphone", unmuteMic = "Unmute the microphone", muteSound = "Mute the sound", unmuteSound = "Unmute the sound", volume = "Set the volume", connectBT = "Connect Bluetooth device…", disconnectBT = "Disconnect Bluetooth device…"
        var id: String { rawValue }
        var needsName: Bool { [.useOutput, .useInput, .connectBT, .disconnectBT].contains(self) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sound mode").font(.headline)
            TextField("Name", text: $mode.name)
            if mode.actions.isEmpty { Text("No changes yet. Add some below.").font(.callout).foregroundStyle(.secondary) }
            ForEach(Array(mode.actions.enumerated()), id: \.offset) { index, action in
                HStack {
                    Text(action.title.prefix(1).uppercased() + action.title.dropFirst())
                    Spacer()
                    Button { mode.actions.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            Divider()
            HStack {
                Picker("Add", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }
                if kind.needsName { TextField("Part of its name", text: $text) }
                if kind == .volume { Slider(value: $percent, in: 0...100, step: 1); Text("\(Int(percent))%").monospacedDigit() }
                Button("Add") { if let action = make() { mode.actions.append(action); text = "" } }.disabled(make() == nil)
            }
            HStack {
                if canDelete { Button("Delete", role: .destructive, action: onDelete) }
                Spacer()
                Button("Cancel") { onClose(nil) }.keyboardShortcut(.cancelAction)
                Button("Save") { onClose(mode) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(mode.name.trimmingCharacters(in: .whitespaces).isEmpty || mode.actions.isEmpty)
            }
        }
        .padding(18).frame(width: 520)
    }

    private func make() -> SoundAction? {
        let name = text.trimmingCharacters(in: .whitespaces)
        if kind.needsName, name.isEmpty { return nil }
        switch kind {
        case .useOutput: return .useOutput(nameContains: name)
        case .useInput: return .useInput(nameContains: name)
        case .muteMic: return .muteMic(true)
        case .unmuteMic: return .muteMic(false)
        case .muteSound: return .muteSound(true)
        case .unmuteSound: return .muteSound(false)
        case .volume: return .setVolume(percent: Int(percent))
        case .connectBT: return .connectBluetooth(nameContains: name)
        case .disconnectBT: return .disconnectBluetooth(nameContains: name)
        }
    }
}

private struct BluetoothSection: View {
    @State private var peers: [BluetoothPeer] = []
    @State private var busy: String?

    var body: some View {
        if peers.isEmpty { Text("No paired Bluetooth audio devices found.").font(.callout).foregroundStyle(.secondary) }
        ForEach(peers) { peer in
            HStack {
                Image(systemName: peer.isConnected ? "headphones" : "headphones").foregroundStyle(peer.isConnected ? Theme.ok : .secondary)
                Text(peer.name)
                Spacer()
                if busy == peer.address { ProgressView().controlSize(.small) }
                Button(peer.isConnected ? "Disconnect" : "Connect") { toggle(peer) }.controlSize(.small).disabled(busy != nil)
            }
        }
        Button("Refresh") { load() }.controlSize(.small)
            .onAppear { load() }
    }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = BluetoothAudio.paired()
            DispatchQueue.main.async { peers = found }
        }
    }

    private func toggle(_ peer: BluetoothPeer) {
        busy = peer.address
        DispatchQueue.global(qos: .userInitiated).async {
            BluetoothAudio.set(connected: !peer.isConnected, address: peer.address)
            let found = BluetoothAudio.paired()
            DispatchQueue.main.async { peers = found; busy = nil }
        }
    }
}

private struct SoundHistorySection: View {
    @EnvironmentObject private var runner: SoundRuleRunner

    var body: some View {
        if runner.history.events.isEmpty { Text("Nothing yet.").font(.callout).foregroundStyle(.secondary) }
        ForEach(runner.history.events.prefix(30)) { event in
            HStack {
                Image(systemName: event.connected ? "plus.circle" : "minus.circle").foregroundStyle(event.connected ? Theme.ok : .secondary)
                Text(event.name)
                if event.connected, runner.history.reconnects(of: event.name) >= 3 { Text("keeps reconnecting").font(.caption).foregroundStyle(Theme.warn) }
                Spacer()
                Text(event.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
        }
        if !runner.history.events.isEmpty { Button("Clear the History", role: .destructive) { runner.clearHistory() }.controlSize(.small) }
    }
}
