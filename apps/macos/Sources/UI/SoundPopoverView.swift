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
    @State private var pinned = false
    @State private var effectsFor: String?
    @State private var showApps = true

    static let accent = Color(red: 0.36, green: 0.82, blue: 0.58)
    static let surface = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.07)
    static let chip = Color.white.opacity(0.09)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            section("System") { systemRows }
            section("Apps", trailing: { appsToggle }) { if showApps { appRows } }
            footer
        }
        .padding(16)
        .frame(width: 392)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .tint(Self.accent)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: effectsFor)
        .animation(.smooth(duration: 0.2), value: showApps)
        .animation(.smooth(duration: 0.2), value: compact)
        .animation(.smooth(duration: 0.2), value: engine.apps.map(\.id))
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
                glyph(compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical", help: compact ? "Show everything" : "Compact") { compact.toggle() }
                glyph(pinned ? "pin.fill" : "pin", help: pinned ? "Let it close when you click elsewhere" : "Keep it open", active: pinned) { pinned.toggle(); setPinned(pinned) }
                glyph("gearshape", help: "Sound settings", action: openSettings)
            }
        }
    }

    private func glyph(_ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        HoverButton(action: action) { hovering in
            Image(systemName: symbol).font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(active ? Self.accent : Color.white.opacity(hovering ? 0.95 : 0.6))
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        .foregroundStyle(Color.white.opacity(0.85))
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
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(Color.white.opacity(0.42))
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
        Button { showApps.toggle() } label: {
            Image(systemName: showApps ? "chevron.up" : "chevron.down").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Color.white.opacity(0.45)).frame(width: 22, height: 16)
        }.buttonStyle(.plain).accessibilityLabel(showApps ? "Hide apps" : "Show apps")
    }

    // MARK: System rows

    @ViewBuilder
    private var systemRows: some View {
        let systemSettings = engine.current(AppAudioEngine.systemKey)
        MixRow(compact: compact, title: "Output", tile: .symbol("speaker.wave.2.fill"),
               muted: mixer.hasVolume ? mixer.muted : systemSettings.muted,
               level: mixer.hasVolume ? mixer.volume : min(systemSettings.volume, 1), range: 0...1, meter: 0,
               setLevel: { v in mixer.hasVolume ? mixer.setVolume(v) : engine.update(AppAudioEngine.systemKey) { $0.volume = v } },
               toggleMute: { mixer.hasVolume ? mixer.toggleMute() : engine.update(AppAudioEngine.systemKey) { $0.muted.toggle() } },
               accessory: AnyView(HStack(spacing: 6) {
                   deviceChip(mixer.outputs, selected: mixer.outputID, choose: mixer.chooseOutput, fallback: "speaker.wave.2")
                   boostButton(AppAudioEngine.systemKey)
                   fxButton(AppAudioEngine.systemKey)
               }),
               drawer: effectsFor == AppAudioEngine.systemKey ? AnyView(AppEffectsView(key: AppAudioEngine.systemKey)) : nil)
        divider
        MixRow(compact: compact, title: "Input", tile: .symbol("mic.fill"), muted: mixer.micMuted, level: mixer.inputVolume, range: 0...1, meter: 0,
               setLevel: { mixer.setInputVolume($0) }, toggleMute: { mixer.toggleMicMute() },
               accessory: AnyView(deviceChip(mixer.inputs, selected: mixer.inputID, choose: mixer.chooseInput, fallback: "mic")), drawer: nil, disabled: !mixer.hasInputVolume)
        divider
        MixRow(compact: compact, title: "Sound Effects", tile: .symbol("bell.fill"), muted: false, level: mixer.effectsVolume, range: 0...1, meter: 0,
               setLevel: { mixer.setEffectsVolume($0) }, toggleMute: nil,
               accessory: AnyView(deviceChip(mixer.outputs, selected: mixer.effectsID, choose: mixer.chooseEffectsOutput, fallback: "speaker.wave.2")), drawer: nil)
    }

    private var divider: some View { Rectangle().fill(Self.hairline).frame(height: 1).padding(.leading, 60) }

    // MARK: App rows

    @ViewBuilder
    private var appRows: some View {
        if engine.apps.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "waveform").foregroundStyle(Color.white.opacity(0.35))
                Text("Nothing is playing. Star an app to keep it here.").font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.5))
                Spacer()
            }.padding(14)
        }
        ForEach(Array(engine.apps.enumerated()), id: \.element.id) { index, app in
            if index > 0 { divider }
            let settings = engine.current(app.id)
            let boosted = engine.isBoosted(app.id)
            MixRow(compact: compact, title: app.name, tile: .app(app.id), muted: settings.muted || engine.timed[app.id]?.level == 0,
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
                   toggleFavorite: { engine.setFavorite(app.id, !app.isFavorite) })
        }
    }

    private func appDrawer(_ app: AudioApp) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Menu { TimedMuteMenu(key: app.id) } label: { smallLabel("timer", "Timed mute") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Button { engine.setMenuBarIcon(app.id, !engine.menuBarApps.contains(app.id)) } label: { smallLabel("menubar.rectangle", engine.menuBarApps.contains(app.id) ? "In menu bar" : "Menu-bar icon") }.buttonStyle(.plain)
                Button { engine.setExcluded(app.id, true) } label: { smallLabel("nosign", "Leave alone") }.buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            AppEffectsView(key: app.id)
        }
    }

    private func smallLabel(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 5) { Image(systemName: symbol).font(.system(size: 10.5)); Text(title).font(.system(size: 11.5, weight: .medium)) }
            .foregroundStyle(Color.white.opacity(0.8)).padding(.horizontal, 9).padding(.vertical, 5).background(Self.chip, in: Capsule())
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

    private func redirectChip(_ key: String) -> some View {
        let settings = engine.current(key)
        let chosen = settings.outputs.first.flatMap { uid in mixer.outputs.first { $0.uid == uid } }
        return Menu {
            Button { engine.update(key) { $0.outputs = [] } } label: { Label("No Redirect", systemImage: settings.outputs.isEmpty ? "checkmark" : "arrow.up") }
            Divider()
            ForEach(mixer.outputs) { device in
                Button { engine.update(key) { $0.outputs = [device.uid] } } label: { Label(names.name(for: device), systemImage: settings.outputs.contains(device.uid) ? "checkmark" : names.symbol(for: device, fallback: "speaker.wave.2")) }
            }
        } label: {
            chipBody(symbol: chosen.map { names.symbol(for: $0, fallback: "speaker.wave.2") } ?? "arrow.turn.up.right",
                     text: chosen.map { names.name(for: $0) } ?? (settings.outputs.isEmpty ? "Default" : "Other"), highlighted: !settings.outputs.isEmpty)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Send this app's sound to a different output")
    }

    private func chipBody(symbol: String, text: String, highlighted: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            Text(text).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.tail).frame(maxWidth: 92, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5, weight: .bold)).opacity(0.5)
        }
        .foregroundStyle(highlighted ? Self.accent : Color.white.opacity(0.85))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Self.chip, in: Capsule())
    }

    private func boostButton(_ key: String) -> some View {
        let on = engine.isBoosted(key)
        return HoverButton(action: { engine.setBoost(key, !on) }) { hovering in
            Image(systemName: "chevron.up.2").font(.system(size: 10, weight: .bold))
                .foregroundStyle(on ? Color.black : Color.white.opacity(hovering ? 0.95 : 0.6))
                .frame(width: 26, height: 26)
                .background(on ? Self.accent : Color.white.opacity(hovering ? 0.14 : 0.09), in: Circle())
        }
        .help("Boost: let the slider go past 100%").accessibilityLabel("Boost")
    }

    private func fxButton(_ key: String) -> some View {
        let on = effectsFor == key
        return HoverButton(action: { effectsFor = on ? nil : key }) { hovering in
            Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? Color.black : Color.white.opacity(hovering ? 0.95 : 0.6))
                .frame(width: 26, height: 26)
                .background(on ? Self.accent : Color.white.opacity(hovering ? 0.14 : 0.09), in: Circle())
        }
        .help("Effects").accessibilityLabel("Effects")
    }
}

// MARK: - One row

private enum RowTile { case symbol(String), app(String) }

/// A row: a tile that mutes, the name, chips on the right, and the slider with its level line and percentage under them.
private struct MixRow: View {
    let compact: Bool
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                MuteTile(tile: tile, muted: muted, action: toggleMute)
                VStack(alignment: .leading, spacing: compact ? 0 : 7) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).opacity(dimmed ? 0.55 : 1)
                        if let toggleFavorite {
                            Button(action: toggleFavorite) { Image(systemName: favorite ? "star.fill" : "star").font(.system(size: 10.5)).foregroundStyle(favorite ? SoundPopoverView.accent : Color.white.opacity(0.3)) }
                                .buttonStyle(.plain).accessibilityLabel(favorite ? "Remove favorite" : "Make favorite")
                        }
                        Spacer(minLength: 6)
                        if !compact { accessory }
                    }
                    HStack(spacing: 10) {
                        GlowSlider(value: Binding(get: { level }, set: setLevel), range: range, meter: compact ? 0 : meter, unityMark: range.upperBound > 1.01)
                            .opacity(disabled ? 0.35 : 1).disabled(disabled)
                        Text("\(Int((level * 100).rounded()))%").font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                            .foregroundStyle(Color.white.opacity(0.7)).frame(width: 40, alignment: .trailing)
                    }
                }
            }
            if let timed { TimedChangeLabel(change: timed).padding(.leading, 48) }
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(Theme.warn).padding(.leading, 48).fixedSize(horizontal: false, vertical: true) }
            if let drawer {
                drawer.padding(10).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.leading, 48).transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
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
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hovering && action != nil ? 0.13 : 0.08))
                icon.opacity(muted ? 0.35 : 1)
                if muted { Image(systemName: "slash.circle.fill").font(.system(size: 11)).foregroundStyle(.red).background(Circle().fill(Color.black).frame(width: 9, height: 9)).offset(x: 11, y: 11) }
            }
            .frame(width: 36, height: 36)
        }
        .disabled(action == nil)
        .help(action == nil ? "" : (muted ? "Unmute" : "Mute")).accessibilityLabel(muted ? "Unmute" : "Mute")
    }

    @ViewBuilder private var icon: some View {
        switch tile {
        case .symbol(let name): Image(systemName: name).font(.system(size: 15.5, weight: .medium)).foregroundStyle(Color.white.opacity(0.9))
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
    @State private var dragging = false

    private var span: Double { range.upperBound - range.lowerBound }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let fraction = CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.13)).frame(height: 6)
                Capsule().fill(LinearGradient(colors: [SoundPopoverView.accent.opacity(0.75), SoundPopoverView.accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, width * fraction), height: 6)
                if unityMark { Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1.5, height: 10).offset(x: width * CGFloat((1 - range.lowerBound) / span) - 0.75) }
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
                .onChanged { drag in
                    dragging = true
                    value = range.lowerBound + span * Double(min(max(drag.location.x / width, 0), 1))
                }
                .onEnded { _ in dragging = false })
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step = span / 20
            switch direction { case .increment: value = min(value + step, range.upperBound); case .decrement: value = max(value - step, range.lowerBound); @unknown default: break }
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
