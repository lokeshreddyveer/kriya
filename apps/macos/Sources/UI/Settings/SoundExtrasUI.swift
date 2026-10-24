import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The timed mute and turn-down choices for one app, as menu content.
struct TimedMuteMenu: View {
    @EnvironmentObject private var engine: AppAudioEngine
    let key: String
    @AppStorage("soundTimedFadeSeconds") private var fade = 2.0

    var body: some View {
        Menu("Mute for…") {
            ForEach(TimedChange.presets, id: \.seconds) { preset in
                Button(preset.title) { engine.startTimed(key, level: 0, duration: preset.seconds, fadeOut: fade, fadeIn: fade) }
            }
            Button("Another Time…") { ask(level: 0) }
        }
        Menu("Turn Down to 30% for…") {
            ForEach(TimedChange.presets, id: \.seconds) { preset in
                Button(preset.title) { engine.startTimed(key, level: 0.3, duration: preset.seconds, fadeOut: fade, fadeIn: fade) }
            }
            Button("Another Time…") { ask(level: 0.3) }
        }
        Menu("Fade") {
            ForEach([0.0, 1.0, 2.0, 5.0], id: \.self) { seconds in
                Button { fade = seconds } label: { Label(seconds == 0 ? "No fade" : "\(Int(seconds)) second fade", systemImage: fade == seconds ? "checkmark" : "") }
            }
        }
        if engine.timed[key] != nil { Button("Cancel the Timer") { engine.cancelTimed(key) } }
    }

    private func ask(level: Float) {
        let alert = NSAlert()
        alert.messageText = level == 0 ? "Mute for how many minutes?" : "Turn down for how many minutes?"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = "For example, 10"
        alert.accessoryView = field
        alert.addButton(withTitle: "Start"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, let minutes = Double(field.stringValue.trimmingCharacters(in: .whitespaces)), minutes > 0 else { return }
        engine.startTimed(key, level: level, duration: min(minutes, 600) * 60, fadeOut: fade, fadeIn: fade)
    }
}

/// "Muted for 0:42" under an app's name while a timed change runs.
struct TimedChangeLabel: View {
    let change: TimedChange

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = Int(change.remaining(at: context.date).rounded(.up))
            Text("\(change.level == 0 ? "Muted" : "Turned down") for \(left / 60):\(String(format: "%02d", left % 60))")
        }
        .font(.caption).foregroundStyle(Theme.accent)
    }
}

/// Preamp, balance, bypass and the equaliser for one app (or for all sound).
struct AppEffectsView: View {
    @EnvironmentObject private var engine: AppAudioEngine
    let key: String

    var body: some View {
        let s = engine.current(key)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Bypass effects", isOn: Binding(get: { s.effectsBypassed }, set: { v in engine.update(key) { $0.effectsBypassed = v } }))
                    .toggleStyle(.switch).controlSize(.small)
                    .help("Plays the sound without the equaliser, preamp and balance, and keeps them set for later")
                Spacer()
                Button("Reset Effects") { engine.update(key) { $0.eq = EQPreset.flat.gains; $0.preamp = 0; $0.balance = 0; $0.effectsBypassed = false } }
                    .controlSize(.small).disabled(s.effectsAreFlat && !s.effectsBypassed)
            }
            HStack(spacing: 10) {
                Text("Preamp").frame(width: 58, alignment: .leading)
                Slider(value: Binding(get: { Double(s.preamp) }, set: { v in engine.update(key) { $0.preamp = Float(abs(v) < 0.3 ? 0 : v) } }), in: -Double(SoundPreamp.limit)...Double(SoundPreamp.limit))
                Text(String(format: "%+.0f dB", s.preamp)).monospacedDigit().font(.callout).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Text("Balance").frame(width: 58, alignment: .leading)
                Slider(value: Binding(get: { Double(s.balance) }, set: { v in engine.update(key) { $0.balance = Float(abs(v) < 0.04 ? 0 : v) } }), in: -1...1)
                Text(s.balance == 0 ? "Centre" : (s.balance < 0 ? "L \(Int(-s.balance * 100))" : "R \(Int(s.balance * 100))")).font(.callout).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            }
            EQView(key: key)
        }
        .opacity(s.effectsBypassed ? 0.55 : 1)
    }
}

/// Add Favorite, and the order of the favorites.
struct FavoriteAppsControls: View {
    @EnvironmentObject private var engine: AppAudioEngine

    var body: some View {
        HStack {
            Button { addFavorite() } label: { Label("Add Favorite…", systemImage: "star") }.controlSize(.small)
            if !engine.favorites.isEmpty {
                Menu {
                    ForEach(engine.favorites, id: \.self) { id in
                        Menu(AudioProcessList.name(for: id)) {
                            Button("Move Up") { engine.moveFavorite(id, by: -1) }.disabled(engine.favorites.first == id)
                            Button("Move Down") { engine.moveFavorite(id, by: 1) }.disabled(engine.favorites.last == id)
                            Divider()
                            Button("Remove Favorite", role: .destructive) { engine.setFavorite(id, false) }
                        }
                    }
                } label: { Label("Favorites", systemImage: "list.star") }.controlSize(.small).fixedSize()
            }
            Spacer()
        }
    }

    private func addFavorite() {
        guard let id = AppChoice.choose(prompt: "Add as a favorite") else { return }
        engine.setFavorite(AudioProcessList.groupKey(forBundleID: id), true)
    }
}

/// Saved whole-sound setups.
struct QuickConfigsSection: View {
    @EnvironmentObject private var quick: QuickConfigStore

    var body: some View {
        if quick.configs.isEmpty { Text("No Quick Configs yet. “Save Current Sound” keeps the devices, volumes, every app's settings and the favorites as they are now.").font(.callout).foregroundStyle(.secondary) }
        ForEach(quick.configs) { config in
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(config.name)
                    Text("\(config.apps.count) app\(config.apps.count == 1 ? "" : "s") set · \(config.favorites.count) favorite\(config.favorites.count == 1 ? "" : "s") · give it a shortcut in Keyboard")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Apply") { quick.apply(config.id) }.controlSize(.small)
                Menu {
                    Button("Rename…") { rename(config) }
                    Button("Duplicate") { quick.duplicate(config.id) }
                    Button("Copy Command Name") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(QuickConfigStore.command(for: config.id), forType: .string) }
                    Divider()
                    Button("Delete", role: .destructive) { quick.delete(config.id) }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("More").menuStyle(.borderlessButton).frame(width: 28)
            }
        }
        HStack {
            Button { saveCurrent() } label: { Label("Save Current Sound…", systemImage: "plus") }.controlSize(.small)
            Button("Export…") { export() }.controlSize(.small).disabled(quick.configs.isEmpty)
            Button("Import…") { importFile() }.controlSize(.small)
            Spacer()
            if let message = quick.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func ask(_ title: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let n = field.stringValue.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? nil : n
    }

    private func saveCurrent() { if let name = ask("Name this Quick Config", initial: "Desk") { quick.saveCurrent(named: name) } }
    private func rename(_ config: QuickConfig) { if let name = ask("Rename", initial: config.name) { quick.rename(config.id, to: name) } }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Kriya Quick Configs.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = quick.exportData() else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        quick.importData(data)
    }
}

/// Apps Kriya never listens to or changes.
struct ExcludedAppsSection: View {
    @EnvironmentObject private var engine: AppAudioEngine

    var body: some View {
        if engine.excluded.isEmpty { Text("Every app can be changed in the mixer.").font(.callout).foregroundStyle(.secondary) }
        ForEach(engine.excluded.sorted(), id: \.self) { id in
            HStack {
                Text(AudioProcessList.name(for: id))
                Spacer()
                Button(role: .destructive) { engine.setExcluded(id, false) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
            }
        }
        Button {
            if let id = AppChoice.choose(prompt: "Never change this app's sound") { engine.setExcluded(AudioProcessList.groupKey(forBundleID: id), true) }
        } label: { Label("Leave Out an App", systemImage: "plus") }.controlSize(.small)
        Stepper("Keep an app in the list for \(engine.recentMinutes) minute\(engine.recentMinutes == 1 ? "" : "s") after it stops", value: Binding(get: { engine.recentMinutes }, set: { engine.recentMinutes = $0 }), in: 1...240)
    }
}

/// Problems the mixer ran into, newest first.
struct SoundAlertsSection: View {
    @EnvironmentObject private var engine: AppAudioEngine

    var body: some View {
        if engine.alerts.isEmpty { Text("No problems so far.").font(.callout).foregroundStyle(.secondary) }
        ForEach(engine.alerts.prefix(12)) { alert in
            VStack(alignment: .leading, spacing: 1) {
                HStack { Text(alert.app).font(.callout.weight(.medium)); Spacer(); Text(alert.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.tertiary) }
                Text(alert.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        if !engine.alerts.isEmpty { Button("Clear") { engine.clearAlerts() }.controlSize(.small) }
    }
}

/// A name and a picture for the output or input that is in use, and what it adds in delay.
struct DeviceLabelRow: View {
    @ObservedObject private var names = DeviceNames.shared
    let device: AudioDevice?
    let input: Bool

    var body: some View {
        if let device {
            HStack {
                Image(systemName: names.symbol(for: device, fallback: input ? "mic" : "speaker.wave.2")).frame(width: 22).foregroundStyle(Theme.accent)
                Text(names.name(for: device)).lineLimit(1)
                if let ms = AudioControl.shared.latencyMilliseconds(of: device.id, input: input) {
                    Text(String(format: "about %.0f ms delay", ms)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Rename…") { rename(device) }
                    Menu("Icon") {
                        ForEach(DeviceLabel.symbols, id: \.symbol) { option in
                            Button { set(device) { $0.symbol = option.symbol } } label: { Label(option.title, systemImage: option.symbol) }
                        }
                        Button("Default Icon") { set(device) { $0.symbol = nil } }
                    }
                    Button("Use the Device's Own Name") { set(device) { $0.nickname = nil } }
                } label: { Image(systemName: "pencil") }.accessibilityLabel("Rename or change icon").menuStyle(.borderlessButton).frame(width: 28)
            }
        }
    }

    private func set(_ device: AudioDevice, _ change: (inout DeviceLabel) -> Void) {
        var label = names.labels[device.uid] ?? DeviceLabel()
        change(&label)
        names.set(label, for: device.uid)
    }

    private func rename(_ device: AudioDevice) {
        let alert = NSAlert()
        alert.messageText = "Name for “\(device.name)”"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = names.labels[device.uid]?.nickname ?? ""
        field.placeholderString = device.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        set(device) { $0.nickname = field.stringValue }
    }
}
