import AppKit
import CoreAudio
import SwiftUI

/// The menu-bar mixer. Black, flat and quiet: one soft card per group, a tile for each row that mutes it, a custom slider with a live
/// level line under it, small chips for the device, boost and effects, and one restrained accent. Narrow enough to sit under the icon.
struct SoundPopoverView: View {
    @EnvironmentObject private var engine: AppAudioEngine
    @EnvironmentObject private var mixer: SoundMixerModel
    @EnvironmentObject private var quick: QuickConfigStore
    @ObservedObject private var names = DeviceNames.shared
    var openSettings: () -> Void = {}
    var setPinned: (Bool) -> Void = { _ in }
    @AppStorage("soundMixer.compact") private var compact = false
    @AppStorage("soundMixer.density") private var densityRaw: String?
    @AppStorage("soundMixer.appearance") private var appearanceRaw: String?
    @AppStorage("soundVolumeStep") private var step = VolumeStep.standard
    @AppStorage("soundHoldToRamp") private var ramp = true
    /// Kept between openings: a popover pinned open stays pinned until the person lets it go.
    static let pinnedKey = "soundMixer.pinned"
    @State private var pinned = UserDefaults.standard.bool(forKey: SoundPopoverView.pinnedKey)
    @State private var effectsFor: String?
    @State private var showApps = true
    @State private var query = ""
    @State private var selection: String?
    @State private var repeats = 0
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var density: SoundDensity { SoundDensity.resolve(stored: densityRaw, legacyCompact: compact) }
    private var appearance: SoundAppearance { SoundAppearance.resolve(appearanceRaw) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// How tall this window is, worked out for the display it opens on.
    private let height: CGFloat

    init(openSettings: @escaping () -> Void = {}, setPinned: @escaping (Bool) -> Void = { _ in }, startWithEffects: String? = nil, height: CGFloat? = nil) {
        self.openSettings = openSettings
        self.setPinned = setPinned
        self.height = height ?? Self.height(on: nil)
        _effectsFor = State(initialValue: startWithEffects)
    }

    static let accent = Color(red: 0.36, green: 0.82, blue: 0.58)
    /// Black in a dark window, the ordinary window colour in a light one, so the mixer follows whichever it is shown in.
    static let background = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .windowBackgroundColor })
    static let surface = Color.primary.opacity(0.06)
    static let hairline = Color.primary.opacity(0.07)
    static let chip = Color.primary.opacity(0.09)

    /// The popover never changes size: opening the effects of an app scrolls inside it instead of resizing the window, which is what
    /// made it jump. It is as tall as fits the screen, up to 640 points.
    static var height: CGFloat { height(on: nil) }

    /// The height for the display the icon is on (the main display if that is not known).
    static func height(on screen: NSScreen?) -> CGFloat { min(640, ((screen ?? NSScreen.main)?.visibleFrame.height ?? 800) - 90) }
    static let width: CGFloat = 392

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
            searchField.padding(.horizontal, 16).padding(.bottom, 10)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if searching, !matchingDevices.isEmpty { section("Devices") { deviceRows } }
                    if !searching || !visibleSystemRows.isEmpty { section("System") { systemRows } }
                    if !searching || !visibleApps.isEmpty { section("Apps", trailing: { appsToggle }) { if showApps || searching { appRows } } }
                    if searching, matchingDevices.isEmpty, visibleSystemRows.isEmpty, visibleApps.isEmpty {
                        Text("Nothing matches “\(query)”.").font(.system(size: 12.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                    footer
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
                // Only the list of apps animates when apps come and go; sliders and meters never do.
                .animation(.smooth(duration: 0.22), value: engine.apps.map(\.id))
            }
        }
        .frame(width: Self.width, height: height)
        .clipped()
        .background(Self.background)
        .preferredColorScheme(appearance.colorScheme)
        .tint(Self.accent)
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onAppear { listFocused = true }
        .onKeyPress(phases: [.down, .repeat]) { press in key(press) }
    }

    private func animated(_ change: @escaping () -> Void) { withAnimation(.smooth(duration: 0.24), change) }


    // MARK: Search, keyboard and the menu

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search apps and devices", text: $query)
                .textFieldStyle(.plain).font(.system(size: 12.5)).focused($searchFocused)
                .onSubmit { moveFocusToList() }
                .onKeyPress(.downArrow) { moveFocusToList(); return .handled }
                .onKeyPress(.escape) { if searching { query = ""; return .handled }; searchFocused = false; listFocused = true; return .handled }
            if searching {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Self.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(.easeOut(duration: 0.12), value: searching)
    }

    private func moveFocusToList() {
        searchFocused = false; listFocused = true
        if selection == nil { selection = rowIDs.first }
    }

    private var visibleApps: [AudioApp] { searching ? engine.apps.filter { SoundSearch.matches(query, in: $0.name) } : engine.apps }

    private var visibleSystemRows: [String] {
        guard searching else { return ["system.output", "system.input", "system.effects"] }
        return [("system.output", "Output"), ("system.input", "Input"), ("system.effects", "Sound Effects")].filter { SoundSearch.matches(query, in: $0.1) }.map(\.0)
    }

    /// Devices whose names match what was typed, outputs first. Choosing one makes it the output (or input).
    private var matchingDevices: [(device: AudioDevice, input: Bool)] {
        guard searching else { return [] }
        let outputs = mixer.outputs.filter { SoundSearch.matches(query, in: names.name(for: $0)) }.map { ($0, false) }
        let inputs = mixer.inputs.filter { SoundSearch.matches(query, in: names.name(for: $0)) }.map { ($0, true) }
        return outputs + inputs
    }

    /// The rows the arrow keys move through, top to bottom.
    private var rowIDs: [String] { visibleSystemRows + (showApps || searching ? visibleApps.map(\.id) : []) }

    @ViewBuilder
    private var deviceRows: some View {
        ForEach(Array(matchingDevices.enumerated()), id: \.offset) { index, entry in
            if index > 0 { divider }
            let current = entry.input ? mixer.inputID : mixer.outputID
            Button { entry.input ? mixer.chooseInput(entry.device.id) : mixer.chooseOutput(entry.device.id) } label: {
                HStack(spacing: 12) {
                    Image(systemName: names.symbol(for: entry.device, fallback: entry.input ? "mic" : "speaker.wave.2")).frame(width: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(names.name(for: entry.device)).font(.system(size: 13, weight: .medium))
                        Text(entry.input ? "Input" : "Output").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if entry.device.id == current { Image(systemName: "checkmark").foregroundStyle(Self.accent) }
                }
                .padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }

    /// The same things the speaker's right-click menu does, for when a right click does not reach the icon.
    private var moreMenu: some View {
        Menu {
            Menu("Play Sound On") {
                ForEach(mixer.outputs) { device in
                    Button { mixer.chooseOutput(device.id) } label: { Label(names.name(for: device), systemImage: device.id == mixer.outputID ? "checkmark" : names.symbol(for: device, fallback: "speaker.wave.2")) }
                }
            }
            Button(mixer.muted ? "Unmute Sound" : "Mute Sound") { mixer.toggleMute() }
            Button(mixer.micMuted ? "Unmute Microphone" : "Mute Microphone") { mixer.toggleMicMute() }
            if !quick.configs.isEmpty {
                Menu("Quick Configs") { ForEach(quick.configs) { config in Button(config.name) { quick.apply(config.id) } } }
            }
            Divider()
            Menu("Density") {
                ForEach(SoundDensity.allCases) { d in Button { densityRaw = d.rawValue } label: { Label(d.title, systemImage: density == d ? "checkmark" : "") } }
            }
            Menu("Appearance") {
                ForEach(SoundAppearance.allCases) { a in Button { appearanceRaw = a.rawValue } label: { Label(a.title, systemImage: appearance == a ? "checkmark" : "") } }
            }
            Divider()
            Button("Sound Settings…", action: openSettings)
            Button("Quit Kriya") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 13.5, weight: .medium)).foregroundStyle(Color.primary.opacity(0.6)).frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More").accessibilityLabel("More")
    }

    /// One key press in the mixer. Up and down choose a row; left and right change its volume (held keys speed up if that is on); M mutes,
    /// E opens the effects, F makes an app a favorite, B lets it go past 100%, "/" or ⌘F searches.
    private func key(_ press: KeyPress) -> KeyPress.Result {
        if press.phase == .down { repeats = 0 } else { repeats += 1 }
        let ids = rowIDs
        let index = selection.flatMap { ids.firstIndex(of: $0) }
        switch press.key {
        case .downArrow:
            guard !ids.isEmpty else { return .handled }
            animated { selection = ids[min((index ?? -1) + 1, ids.count - 1)] }
            return .handled
        case .upArrow:
            guard !ids.isEmpty else { return .handled }
            animated { selection = ids[max((index ?? 1) - 1, 0)] }
            return .handled
        case .leftArrow, .rightArrow:
            guard let id = selection else { return .ignored }
            nudge(id, up: press.key == .rightArrow, amount: VolumeStep.step(base: step, repeats: repeats, ramp: ramp))
            return .handled
        case .escape:
            if selection != nil { animated { selection = nil }; return .handled }
            return .ignored
        case .return, .space:
            guard let id = selection else { return .ignored }
            toggleMute(id); return .handled
        default: break
        }
        let typed = press.characters.lowercased()
        if typed == "/" || (typed == "f" && press.modifiers.contains(.command)) { searchFocused = true; return .handled }
        guard let id = selection, press.modifiers.isEmpty else { return .ignored }
        switch typed {
        case "m": toggleMute(id); return .handled
        case "e": animated { effectsFor = effectsFor == keyFor(id) ? nil : keyFor(id) }; return .handled
        case "f": if engine.apps.contains(where: { $0.id == id }) { engine.setFavorite(id, !engine.isFavorite(id)) }; return .handled
        case "b": if engine.apps.contains(where: { $0.id == id }) || id == "system.output" { engine.setBoost(keyFor(id), !engine.isBoosted(keyFor(id))) }; return .handled
        default: return .ignored
        }
    }

    private func keyFor(_ id: String) -> String { id == "system.output" ? AppAudioEngine.systemKey : id }

    private func toggleMute(_ id: String) {
        switch id {
        case "system.output": mixer.hasVolume ? mixer.toggleMute() : engine.update(AppAudioEngine.systemKey) { $0.muted.toggle() }
        case "system.input": mixer.toggleMicMute()
        case "system.effects": break
        default: engine.update(id) { $0.muted.toggle() }
        }
    }

    private func nudge(_ id: String, up: Bool, amount: Double) {
        switch id {
        case "system.output":
            if mixer.hasVolume { mixer.setVolume(VolumeStep.next(mixer.volume, up: up, step: amount)) }
            else { engine.update(AppAudioEngine.systemKey) { $0.volume = VolumeStep.next($0.volume, up: up, step: amount) } }
        case "system.input": mixer.setInputVolume(VolumeStep.next(mixer.inputVolume, up: up, step: amount))
        case "system.effects": mixer.setEffectsVolume(VolumeStep.next(mixer.effectsVolume, up: up, step: amount))
        default:
            let top = engine.isBoosted(id) ? AppAudioSettings.maxVolume : 1
            engine.update(id) { $0.volume = VolumeStep.next($0.volume, up: up, step: amount, range: 0...top) }
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Sound").font(.system(size: 19, weight: .semibold, design: .rounded))
                if let out = mixer.outputs.first(where: { $0.id == mixer.outputID }) {
                    Text(names.name(for: out)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 2) {
                glyph(density == .compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical", help: density == .compact ? "Show everything" : "Compact") {
                    animated { densityRaw = density == .compact ? SoundDensity.comfortable.rawValue : SoundDensity.compact.rawValue; compact = densityRaw == SoundDensity.compact.rawValue }
                }
                glyph(pinned ? "pin.fill" : "pin", help: pinned ? "Let it close when you click elsewhere" : "Keep it open", active: pinned) { pinned.toggle(); UserDefaults.standard.set(pinned, forKey: Self.pinnedKey); setPinned(pinned) }
                moreMenu
            }
        }
    }

    private func glyph(_ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        HoverButton(action: action) { hovering in
            Image(systemName: symbol).font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(active ? Self.accent : Color.primary.opacity(hovering ? 0.95 : 0.6))
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .help(help).accessibilityLabel(help)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                let candidates = engine.apps.filter { !$0.isFavorite }
                ForEach(candidates) { app in Button(app.name) { engine.setFavorite(app.id, true) } }
                if !candidates.isEmpty { Divider() }
                Button("Choose an App…") { if let id = AppChoice.choose(prompt: "Add as a favorite") { engine.setFavorite(AudioProcessList.groupKey(forBundleID: id), true) } }
            } label: { chipLabel("star", "Add Favorite") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Menu {
                ForEach(quick.configs) { config in Button(config.name) { quick.apply(config.id) } }
                if !quick.configs.isEmpty { Divider() }
                Button("Save Current Sound…") { saveQuickConfig() }
                Button("Manage…", action: openSettings)
            } label: { chipLabel("square.stack.3d.up", "Quick Configs") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Spacer(minLength: 0)
        }
    }

    private func chipLabel(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
            Text(title).font(.system(size: 12, weight: .medium))
            Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).opacity(0.5)
        }
        .foregroundStyle(Color.primary.opacity(0.85))
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Self.chip, in: Capsule())
    }

    private func saveQuickConfig() {
        let alert = NSAlert()
        alert.messageText = "Name this Quick Config"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "Desk"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { quick.saveCurrent(named: name) }
    }

    // MARK: Sections

    private func section<Content: View, Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(Color.primary.opacity(0.42))
                Spacer()
                trailing()
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) { content() }
                .background(Self.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Self.hairline, lineWidth: 1))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        section(title, trailing: { EmptyView() }, content: content)
    }

    private var appsToggle: some View {
        Button { animated { showApps.toggle() } } label: {
            Image(systemName: showApps ? "chevron.up" : "chevron.down").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Color.primary.opacity(0.45)).frame(width: 22, height: 16)
        }.buttonStyle(.plain).accessibilityLabel(showApps ? "Hide apps" : "Show apps")
    }

    // MARK: System rows

    @ViewBuilder
    private var systemRows: some View {
        let systemSettings = engine.current(AppAudioEngine.systemKey)
        let shown = visibleSystemRows
        if shown.contains("system.output") {
        MixRow(density: density, title: "Output", tile: .symbol("speaker.wave.2.fill"),
               muted: mixer.hasVolume ? mixer.muted : systemSettings.muted,
               level: mixer.hasVolume ? mixer.volume : min(systemSettings.volume, 1), range: 0...1, meter: 0,
               setLevel: { v in mixer.hasVolume ? mixer.setVolume(v) : engine.update(AppAudioEngine.systemKey) { $0.volume = v } },
               toggleMute: { mixer.hasVolume ? mixer.toggleMute() : engine.update(AppAudioEngine.systemKey) { $0.muted.toggle() } },
               accessory: AnyView(HStack(spacing: 6) {
                   deviceChip(mixer.outputs, selected: mixer.outputID, choose: mixer.chooseOutput, fallback: "speaker.wave.2")
                   boostButton(AppAudioEngine.systemKey)
                   fxButton(AppAudioEngine.systemKey)
               }),
               drawer: effectsFor == AppAudioEngine.systemKey ? AnyView(PopoverEffects(key: AppAudioEngine.systemKey)) : nil,
               selected: selection == "system.output", scrolled: { nudge("system.output", up: $0 > 0, amount: abs($0)) })
        }
        if shown.contains("system.input") {
        if shown.first != "system.input" { divider }
        MixRow(density: density, title: "Input", tile: .symbol("mic.fill"), muted: mixer.micMuted, level: mixer.inputVolume, range: 0...1, meter: 0,
               setLevel: { mixer.setInputVolume($0) }, toggleMute: { mixer.toggleMicMute() },
               accessory: AnyView(deviceChip(mixer.inputs, selected: mixer.inputID, choose: mixer.chooseInput, fallback: "mic")), drawer: nil, disabled: !mixer.hasInputVolume,
               selected: selection == "system.input", scrolled: { nudge("system.input", up: $0 > 0, amount: abs($0)) })
        }
        if shown.contains("system.effects") {
        if shown.first != "system.effects" { divider }
        MixRow(density: density, title: "Sound Effects", tile: .symbol("bell.fill"), muted: false, level: mixer.effectsVolume, range: 0...1, meter: 0,
               setLevel: { mixer.setEffectsVolume($0) }, toggleMute: nil,
               accessory: AnyView(deviceChip(mixer.outputs, selected: mixer.effectsID, choose: mixer.chooseEffectsOutput, fallback: "speaker.wave.2")), drawer: nil,
               selected: selection == "system.effects", scrolled: { nudge("system.effects", up: $0 > 0, amount: abs($0)) })
        }
    }

    private var divider: some View { Rectangle().fill(Self.hairline).frame(height: 1).padding(.leading, 60) }

    // MARK: App rows

    @ViewBuilder
    private var appRows: some View {
        if engine.apps.isEmpty, !searching {
            HStack(spacing: 10) {
                Image(systemName: "waveform").foregroundStyle(Color.primary.opacity(0.35))
                Text("Nothing is playing. Star an app to keep it here.").font(.system(size: 12.5)).foregroundStyle(Color.primary.opacity(0.5))
                Spacer()
            }.padding(14)
        }
        ForEach(Array(visibleApps.enumerated()), id: \.element.id) { index, app in
            if index > 0 { divider }
            let settings = engine.current(app.id)
            let boosted = engine.isBoosted(app.id)
            MixRow(density: density, title: app.name, tile: .app(app.id), muted: settings.muted || engine.timed[app.id]?.level == 0,
                   level: settings.volume, range: 0...(boosted ? AppAudioSettings.maxVolume : 1), meter: Double(engine.level(of: app.id)),
                   setLevel: { v in engine.update(app.id) { $0.volume = abs(v - 1) < 0.03 ? 1 : v } },
                   toggleMute: { engine.update(app.id) { $0.muted.toggle() } },
                   accessory: AnyView(HStack(spacing: 6) {
                       redirectChip(app.id)
                       boostButton(app.id)
                       fxButton(app.id)
                   }),
                   drawer: effectsFor == app.id ? AnyView(appDrawer(app)) : nil,
                   note: engine.problems[app.id], timed: engine.timed[app.id], favorite: app.isFavorite, dimmed: !app.isPlaying && !app.isFavorite,
                   toggleFavorite: { engine.setFavorite(app.id, !app.isFavorite) },
                   more: AnyView(appMoreMenu(app)),
                   selected: selection == app.id,
                   scrolled: { nudge(app.id, up: $0 > 0, amount: abs($0)) })
        }
    }

    /// Everything an app's row can do that has no room on the row itself.
    private func appMoreMenu(_ app: AudioApp) -> some View {
        Menu {
            Button(app.isFavorite ? "Remove from Favorites" : "Make a Favorite") { engine.setFavorite(app.id, !app.isFavorite) }
            Button(engine.menuBarApps.contains(app.id) ? "Remove Its Menu-Bar Icon" : "Put It in the Menu Bar") { engine.setMenuBarIcon(app.id, !engine.menuBarApps.contains(app.id)) }
            TimedMuteMenu(key: app.id)
            Button("Reset Its Sound") { engine.reset(app.id) }.disabled(engine.current(app.id).isDefault && engine.timed[app.id] == nil)
            Divider()
            Button("Leave This App Alone") { engine.setExcluded(app.id, true) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.primary.opacity(0.55)).frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More").accessibilityLabel("More for \(app.name)")
    }

    private func appDrawer(_ app: AudioApp) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Each chip keeps its words on one line and shares the width, so none of them wraps.
            HStack(spacing: 6) {
                Menu { TimedMuteMenu(key: app.id) } label: { smallLabel("timer", "Timed mute") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Button { engine.setMenuBarIcon(app.id, !engine.menuBarApps.contains(app.id)) } label: { smallLabel("menubar.rectangle", engine.menuBarApps.contains(app.id) ? "In menu bar" : "Menu bar", on: engine.menuBarApps.contains(app.id)) }.buttonStyle(.plain)
                Button { engine.setExcluded(app.id, true) } label: { smallLabel("nosign", "Leave alone") }.buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            PopoverEffects(key: app.id)
        }
    }

    private func smallLabel(_ symbol: String, _ title: String, on: Bool = false) -> some View {
        HStack(spacing: 5) { Image(systemName: symbol).font(.system(size: 10.5)); Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1).fixedSize() }
            .foregroundStyle(on ? Self.accent : Color.primary.opacity(0.8)).padding(.horizontal, 9).padding(.vertical, 5).background(Self.chip, in: Capsule())
    }

    // MARK: Chips

    private func deviceChip(_ devices: [AudioDevice], selected: AudioDeviceID, choose: @escaping (AudioDeviceID) -> Void, fallback: String) -> some View {
        let current = devices.first { $0.id == selected }
        return Menu {
            ForEach(devices) { device in
                Button { choose(device.id) } label: { Label(names.name(for: device), systemImage: device.id == selected ? "checkmark" : names.symbol(for: device, fallback: fallback)) }
            }
        } label: {
            chipBody(symbol: current.map { names.symbol(for: $0, fallback: fallback) } ?? fallback, text: current.map { names.name(for: $0) } ?? "None")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    /// Where an app's sound plays. One device sends it there instead of the Mac's output; several play it on all of them at once
    /// (speakers and AirPlay, say). Each device is a switch, so adding a second one does not take the first away.
    private func redirectChip(_ key: String) -> some View {
        let settings = engine.current(key)
        let chosen = settings.outputs.compactMap { uid in mixer.outputs.first { $0.uid == uid } }
        return Menu {
            Button { engine.update(key) { $0.outputs = [] } } label: { Label("Follow the Mac’s Output", systemImage: settings.outputs.isEmpty ? "checkmark" : "arrow.up") }
            Divider()
            ForEach(mixer.outputs) { device in
                let on = settings.outputs.contains(device.uid)
                Button {
                    engine.update(key) { $0.outputs = on ? $0.outputs.filter { $0 != device.uid } : $0.outputs + [device.uid] }
                } label: { Label(names.name(for: device), systemImage: on ? "checkmark" : names.symbol(for: device, fallback: "speaker.wave.2")) }
            }
            if settings.outputs.count > 1 { Divider(); Text("Playing on \(settings.outputs.count) devices at once") }
        } label: {
            chipBody(symbol: chosen.count > 1 ? "speaker.wave.3" : (chosen.first.map { names.symbol(for: $0, fallback: "speaker.wave.2") } ?? "arrow.turn.up.right"),
                     text: chosen.count > 1 ? "\(chosen.count) devices" : (chosen.first.map { names.name(for: $0) } ?? (settings.outputs.isEmpty ? "Default" : "Other")), highlighted: !settings.outputs.isEmpty)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Send this app's sound to a different output, or to several at once")
    }

    private func chipBody(symbol: String, text: String, highlighted: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            // A menu's label ignores a width cap, so a long device name is shortened here; the full name is in the menu.
            Text(text.count > 14 ? String(text.prefix(13)) + "…" : text).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5, weight: .bold)).opacity(0.5)
        }
        .foregroundStyle(highlighted ? Self.accent : Color.primary.opacity(0.85))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Self.chip, in: Capsule())
    }

    private func boostButton(_ key: String) -> some View {
        let on = engine.isBoosted(key)
        return HoverButton(action: { engine.setBoost(key, !on) }) { hovering in
            Image(systemName: "chevron.up.2").font(.system(size: 10, weight: .bold))
                .foregroundStyle(on ? Color.black : Color.primary.opacity(hovering ? 0.95 : 0.6))
                .frame(width: 26, height: 26)
                .background(on ? Self.accent : Color.primary.opacity(hovering ? 0.14 : 0.09), in: Circle())
        }
        .help("Boost: let the slider go past 100%").accessibilityLabel("Boost")
    }

    private func fxButton(_ key: String) -> some View {
        let on = effectsFor == key
        return HoverButton(action: { animated { effectsFor = on ? nil : key } }) { hovering in
            Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? Color.black : Color.primary.opacity(hovering ? 0.95 : 0.6))
                .frame(width: 26, height: 26)
                .background(on ? Self.accent : Color.primary.opacity(hovering ? 0.14 : 0.09), in: Circle())
        }
        .help("Effects").accessibilityLabel("Effects")
    }
}

// MARK: - One row

private enum RowTile { case symbol(String), app(String) }

/// A row: a tile that mutes, the name, chips on the right, and the slider with its level line and percentage under them.
private struct MixRow: View {
    let density: SoundDensity
    let title: String
    let tile: RowTile
    let muted: Bool
    let level: Double
    let range: ClosedRange<Double>
    let meter: Double
    let setLevel: (Double) -> Void
    let toggleMute: (() -> Void)?
    var accessory: AnyView
    var drawer: AnyView?
    var disabled = false
    var note: String?
    var timed: TimedChange?
    var favorite = false
    var dimmed = false
    var toggleFavorite: (() -> Void)?
    var more: AnyView?
    var selected = false
    /// Scrolling over the slider: a signed change in the volume, already scaled to the range.
    var scrolled: ((Double) -> Void)?

    private var compact: Bool { !density.showsChips }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                MuteTile(tile: tile, muted: muted, action: toggleMute)
                VStack(alignment: .leading, spacing: compact ? 0 : 7) {
                    HStack(spacing: 8) {
                        // The name keeps its room; the device chip is what gives way (it shortens with an ellipsis).
                        Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).opacity(dimmed ? 0.55 : 1).layoutPriority(1)
                        if let toggleFavorite {
                            Button(action: toggleFavorite) { Image(systemName: favorite ? "star.fill" : "star").font(.system(size: 10.5)).foregroundStyle(favorite ? SoundPopoverView.accent : Color.primary.opacity(0.3)) }
                                .buttonStyle(.plain).accessibilityLabel(favorite ? "Remove favorite" : "Make favorite")
                        }
                        Spacer(minLength: 6)
                        if !compact { accessory }
                        if let more { more }
                    }
                    HStack(spacing: 10) {
                        GlowSlider(value: Binding(get: { level }, set: setLevel), range: range, meter: compact ? 0 : meter, unityMark: range.upperBound > 1.01)
                            .opacity(disabled ? 0.35 : 1).disabled(disabled)
                        Text("\(Int((level * 100).rounded()))%").font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                            .foregroundStyle(Color.primary.opacity(0.7)).frame(width: 40, alignment: .trailing)
                    }
                    .background(ScrollWheelCatcher { change in scrolled?(change * (range.upperBound - range.lowerBound)) })
                }
            }
            if let timed { TimedChangeLabel(change: timed).padding(.leading, 48) }
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(Theme.warn).padding(.leading, 48).fixedSize(horizontal: false, vertical: true) }
            if let drawer {
                // The drawer uses the card's whole width, not the part to the right of the icon, so nothing inside it overflows.
                drawer.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, density.rowPadding)
        .background(selected ? SoundPopoverView.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

/// Lets the mouse wheel and the trackpad change a slider's value when the pointer is over it, without getting in the way of clicks or of
/// scrolling the list anywhere else. `change` is a signed fraction of the slider's range.
private struct ScrollWheelCatcher: NSViewRepresentable {
    let change: (Double) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.change = change }

    final class CatcherView: NSView {
        var change: (Double) -> Void = { _ in }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let local = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(local), UserDefaults.standard.object(forKey: "soundMenuBar.scrollVolume") as? Bool ?? true else { return event }
                let delta = VolumeStep.scrollChange(delta: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas, fine: event.modifierFlags.contains(.option), inverted: event.isDirectionInvertedFromDevice)
                if delta != 0 { self.change(delta) }
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// The square at the start of a row: the icon, dimmed and slashed while muted. A click mutes or unmutes.
private struct MuteTile: View {
    let tile: RowTile
    let muted: Bool
    let action: (() -> Void)?

    var body: some View {
        HoverButton(action: { action?() }) { hovering in
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering && action != nil ? 0.13 : 0.08))
                icon.opacity(muted ? 0.35 : 1)
                if muted { Image(systemName: "slash.circle.fill").font(.system(size: 11)).foregroundStyle(.red).background(Circle().fill(SoundPopoverView.background).frame(width: 9, height: 9)).offset(x: 11, y: 11) }
            }
            .frame(width: 36, height: 36)
        }
        .disabled(action == nil)
        .help(action == nil ? "" : (muted ? "Unmute" : "Mute")).accessibilityLabel(muted ? "Unmute" : "Mute")
    }

    @ViewBuilder private var icon: some View {
        switch tile {
        case .symbol(let name): Image(systemName: name).font(.system(size: 15.5, weight: .medium)).foregroundStyle(Color.primary.opacity(0.9))
        case .app(let id):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit().frame(width: 26, height: 26)
            } else {
                Image(systemName: "app.dashed").font(.system(size: 16)).foregroundStyle(SoundPopoverView.accent)
            }
        }
    }
}

/// A slider drawn for this window: a thin capsule track, a soft accent fill, a white thumb, a mark where 100% is when the range goes
/// past it, and a fine line under the track that follows the app's live level.
private struct GlowSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var meter: Double = 0
    var unityMark = false
    /// The fill runs from the middle, for a control that is flat at zero (preamp, balance).
    var bipolar = false
    var label = "Volume"
    @State private var dragging = false
    /// While a finger or pointer is down the thumb follows it directly from here. The value that goes out to the audio engine (which
    /// saves, republishes and redraws the whole list) is sent at most every 33 ms and once more at the end, so the drag is never
    /// waiting on the engine and the engine is not flooded.
    @State private var drag: Double?
    @State private var lastSent = Date.distantPast

    private var span: Double { range.upperBound - range.lowerBound }

    private func send(_ v: Double, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastSent) >= 0.033 else { return }
        lastSent = now
        value = v
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let shown = drag ?? value
            let fraction = CGFloat(min(max((shown - range.lowerBound) / span, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.13)).frame(height: 6)
                if bipolar {
                    let mid = width / 2, x = width * fraction
                    Capsule().fill(SoundPopoverView.accent).frame(width: max(abs(x - mid), 2), height: 6).offset(x: min(x, mid))
                    Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 1.5, height: 10).offset(x: mid - 0.75)
                } else {
                    Capsule().fill(LinearGradient(colors: [SoundPopoverView.accent.opacity(0.75), SoundPopoverView.accent], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, width * fraction), height: 6)
                }
                if unityMark { Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 1.5, height: 10).offset(x: width * CGFloat((1 - range.lowerBound) / span) - 0.75) }
                if meter > 0.01 {
                    Capsule().fill(SoundPopoverView.accent.opacity(0.55)).frame(width: width * CGFloat(min(meter, 1)), height: 2).offset(y: 9)
                        .animation(.easeOut(duration: 0.12), value: meter)
                }
                Circle().fill(Color.white).frame(width: dragging ? 18 : 16, height: dragging ? 18 : 16)
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    .offset(x: width * fraction - (dragging ? 9 : 8))
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        dragging = true
                        let v = range.lowerBound + span * Double(min(max(gesture.location.x / width, 0), 1))
                        drag = v
                        send(v)
                    }
                }
                .onEnded { gesture in
                    let v = range.lowerBound + span * Double(min(max(gesture.location.x / width, 0), 1))
                    send(v, force: true)
                    drag = nil
                    dragging = false
                })
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(bipolar ? String(format: "%.1f", value) : "\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step = span / 20
            switch direction { case .increment: value = min(value + step, range.upperBound); case .decrement: value = max(value - step, range.lowerBound); @unknown default: break }
        }
    }
}

/// The effects of one app (or all sound), drawn for this window and sized to the card: switches as chips, preamp and balance as the
/// same sliders as the volumes, and a ten-band equaliser that divides whatever width it is given, so nothing can overflow.
private struct PopoverEffects: View {
    @EnvironmentObject private var engine: AppAudioEngine
    let key: String

    var body: some View {
        let s = engine.current(key)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                toggleChip("Bypass", symbol: "slash.circle", on: s.effectsBypassed, help: "Plays the sound without the equaliser, preamp and balance, and keeps them set for later") {
                    engine.update(key) { $0.effectsBypassed.toggle() }
                }
                toggleChip("Magic Boost", symbol: "wand.and.stars", on: s.magicBoost, help: "Adds the small-speaker shaping and a little gain, for laptop and monitor speakers") {
                    engine.update(key) { $0.magicBoost.toggle() }
                }
                Spacer(minLength: 0)
                Button { engine.update(key) { $0.eq = EQPreset.flat.gains; $0.preamp = 0; $0.balance = 0; $0.effectsBypassed = false } } label: {
                    Text("Reset").font(.system(size: 11.5, weight: .medium)).lineLimit(1).fixedSize()
                        .foregroundStyle(SoundPopoverView.accent).padding(.horizontal, 9).padding(.vertical, 5)
                        .background(SoundPopoverView.chip, in: Capsule())
                }
                .buttonStyle(.plain).disabled(s.effectsAreFlat && !s.effectsBypassed).opacity(s.effectsAreFlat && !s.effectsBypassed ? 0.4 : 1)
            }
            VStack(alignment: .leading, spacing: 10) {
                slider("Preamp", value: Double(s.preamp), range: -Double(SoundPreamp.limit)...Double(SoundPreamp.limit), text: String(format: "%+.0f dB", s.preamp)) { v in
                    engine.update(key) { $0.preamp = Float(abs(v) < 0.3 ? 0 : v) }
                }
                slider("Balance", value: Double(s.balance), range: -1...1, text: s.balance == 0 ? "Centre" : (s.balance < 0 ? "L \(Int(-s.balance * 100))" : "R \(Int(s.balance * 100))")) { v in
                    engine.update(key) { $0.balance = Float(abs(v) < 0.04 ? 0 : v) }
                }
            }
            equaliser(s.eq)
            AudioUnitList(key: key)
        }
        .opacity(s.effectsBypassed ? 0.55 : 1)
    }

    private func toggleChip(_ title: String, symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5))
                Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(on ? Color.black : Color.primary.opacity(0.85))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(on ? SoundPopoverView.accent : SoundPopoverView.chip, in: Capsule())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(title).accessibilityValue(on ? "on" : "off")
        .animation(.easeOut(duration: 0.12), value: on)
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, text: String, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.75)).frame(width: 52, alignment: .leading)
            GlowSlider(value: Binding(get: { value }, set: set), range: range, bipolar: true, label: title)
            Text(text).font(.system(size: 11.5, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(Color.primary.opacity(0.65)).frame(width: 48, alignment: .trailing)
        }
    }

    private func equaliser(_ gains: [Float]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(EQPreset.allCases) { preset in Button(preset.title) { engine.update(key) { $0.eq = preset.gains } } }
                } label: {
                    HStack(spacing: 5) {
                        Text(EQPreset.matching(gains)?.title ?? "Custom").font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5, weight: .bold)).opacity(0.5)
                    }
                    .foregroundStyle(SoundPopoverView.accent).padding(.horizontal, 10).padding(.vertical, 5).background(SoundPopoverView.chip, in: Capsule())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Text("Equaliser").font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.45))
                Spacer(minLength: 0)
            }
            // Ten equal columns of whatever width there is.
            HStack(spacing: 0) {
                ForEach(0..<EQBands.count, id: \.self) { band in
                    EQBand(gain: Double(gains[band]), label: Self.label(EQBands.frequencies[band])) { v in
                        engine.update(key) { $0.eq[band] = Float(abs(v) < 0.4 ? 0 : v) }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private static func label(_ f: Float) -> String { f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))" }
}

/// One equaliser band: a thin vertical track with a thumb, flat in the middle, and its frequency under it.
private struct EQBand: View {
    let gain: Double
    let label: String
    let set: (Double) -> Void
    @State private var dragging = false
    private let limit = Double(EQBands.limit)

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let h = max(geo.size.height, 1)
                let fraction = CGFloat(min(max((limit - gain) / (2 * limit), 0), 1))
                let mid = h / 2, y = h * fraction
                ZStack(alignment: .top) {
                    Capsule().fill(Color.primary.opacity(0.13)).frame(width: 4)
                    Capsule().fill(SoundPopoverView.accent).frame(width: 4, height: max(abs(y - mid), 2)).offset(y: min(y, mid))
                    Rectangle().fill(Color.primary.opacity(0.3)).frame(width: 10, height: 1).offset(y: mid)
                    Circle().fill(Color.white).frame(width: dragging ? 14 : 12, height: dragging ? 14 : 12).shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .offset(y: y - (dragging ? 7 : 6))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        set(limit - Double(min(max(drag.location.y / h, 0), 1)) * 2 * limit)
                    }
                    .onEnded { _ in dragging = false })
                .animation(.easeOut(duration: 0.1), value: dragging)
            }
            .frame(height: 78)
            Text(label).font(.system(size: 9)).foregroundStyle(Color.primary.opacity(0.5))
        }
        .accessibilityElement()
        .accessibilityLabel("\(label) hertz")
        .accessibilityValue(String(format: "%.1f dB", gain))
        .accessibilityAdjustableAction { direction in
            switch direction { case .increment: set(min(gain + 1, limit)); case .decrement: set(max(gain - 1, -limit)); @unknown default: break }
        }
    }
}

/// A plain button that tells its content when the pointer is over it, so each control can light up its own way.
private struct HoverButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) { content(hovering) }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension SoundAppearance {
    /// The colour scheme to force on the mixer, or nil to follow the Mac.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
