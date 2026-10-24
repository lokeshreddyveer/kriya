import SwiftUI

/// Displays and screen corners: resolution and refresh rate, software dimming, saved display profiles and hot corners.
struct DisplaysPane: View {
    @EnvironmentObject private var store: ScreenToolsStore
    @EnvironmentObject private var library: ActionLibrary
    @EnvironmentObject private var tools: DisplayTools

    @State private var displays: [DisplayEntry] = []
    @State private var tab: Tab = .displays
    @State private var naming = false
    @State private var newName = ""
    /// A change waiting for the person to keep it, and how to put it back.
    @State private var pending: (check: DisplayChangeGuard, undo: () -> Void)?
    @State private var now = Date()
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    enum Tab: String, CaseIterable, Identifiable {
        case displays = "Displays", monitors = "Monitor Controls", profiles = "Profiles", corners = "Hot Corners"
        var id: String { rawValue }
    }

    private var config: ScreenToolsConfig { store.config }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .paneTabBar(maxWidth: 380)
                .paneHeader()
            Group {
                switch tab {
                case .displays: displaysTab
                case .monitors: MonitorControlTab()
                case .profiles: profilesTab
                case .corners: cornersTab
                }
            }
            .id(tab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.22), value: tab)
        .tabHint($tab)
        .animation(.smooth(duration: 0.25), value: pending?.check)
        .onAppear { reload() }
        .onReceive(tick) { _ in
            // Silence means put it back: a mode the display cannot show leaves a screen nobody can click on.
            now = Date()
            if let change = pending, change.check.isExpired() { change.undo(); pending = nil; reload() }
        }
        .onDisappear {
            // Leaving the pane is not an answer: the old setup comes back.
            if let change = pending { change.undo(); pending = nil }
        }
        .alert("Save display profile", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") { saveProfile() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This keeps each display's size, refresh rate and place, so you can come back to it.") }
    }

    private func reload() {
        displays = DisplayTools.displays()
        tools.onChange = { displays = DisplayTools.displays() }
    }

    // MARK: Displays

    /// The banner that asks whether to keep a change, with the seconds left.
    @ViewBuilder private var keepBanner: some View {
        if let change = pending {
            Banner(symbol: "timer", tint: Theme.warn, title: "Keep \(change.check.label)?", message: "If you do nothing, the old setup comes back in \(change.check.secondsLeft(now: now)) seconds.") {
                HStack {
                    Button("Keep") { pending = nil }.controlSize(.small).keyboardShortcut(.defaultAction)
                    Button("Put It Back") { change.undo(); pending = nil; reload() }.controlSize(.small)
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).transition(.opacity)
        }
    }

    /// Changes a display's mode, remembering the one it had so it can be put back.
    private func change(_ entry: DisplayEntry, to mode: DisplayMode) {
        guard let previous = entry.current, previous.id != mode.id else { return }
        if pending == nil || pending?.check.isExpired() == true {
            guard tools.set(mode, on: entry.id) else { return }
            pending = (DisplayChangeGuard(label: "\(mode.title) on \(entry.name)"), { tools.set(previous, on: entry.id) })
        } else if tools.set(mode, on: entry.id), let first = pending {
            // Changed again before answering: both are undone together, back to the first setup.
            pending = (DisplayChangeGuard(label: "\(mode.title) on \(entry.name)"), first.undo)
        }
    }

    private var displaysTab: some View {
        VStack(spacing: 0) {
            keepBanner
            displaysForm
        }
    }

    private var displaysForm: some View {
        Form {
            ForEach(displays) { entry in
                Section {
                    Picker("Resolution", selection: Binding(
                        get: { entry.current?.id ?? "" },
                        set: { id in if let mode = entry.modes.first(where: { $0.id == id }) { change(entry, to: mode) } }
                    )) {
                        ForEach(entry.modes) { Text($0.title).tag($0.id) }
                    }
                    SliderRow(
                        title: "Dim", value: Binding(get: { config.dimLevels.first { $0.key == entry.key }?.level ?? 0 }, set: { tools.setDim($0, forKey: entry.key) }),
                        range: 0...0.9, format: { $0 == 0 ? "Off" : "\(Int($0 * 100))%" },
                        help: "Makes the display darker in software. It is not a hardware brightness control."
                    )
                    SliderRow(
                        title: "Warmth", value: Binding(get: { config.dimLevels.first { $0.key == entry.key }?.warmth ?? 0 }, set: { tools.setWarmth($0, forKey: entry.key) }),
                        range: 0...0.8, format: { $0 == 0 ? "Off" : "\(Int($0 / 0.8 * 100))%" },
                        help: "Takes blue out of the picture for a softer screen in the evening."
                    )
                    if let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == entry.id }) {
                        LabeledContent("High dynamic range", value: DisplayInsight.hdr(potential: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue), current: Double(screen.maximumExtendedDynamicRangeColorComponentValue)))
                    }
                } header: {
                    Text(entry.name + (entry.isMain ? " · main" : ""))
                } footer: {
                    if entry.isMain { Text("After you change a resolution you have ten seconds to keep it. If the screen goes black, do nothing: the old resolution comes back by itself.") }
                }
            }
            if displays.isEmpty { Section { Text("No displays found.").foregroundStyle(.secondary) } }
            DisplayHistorySection()
        }
        .formStyle(.grouped)
    }

    // MARK: Profiles

    private var profilesTab: some View {
        VStack(spacing: 0) {
            keepBanner
            profilesForm
        }
    }

    private var profilesForm: some View {
        Form {
            Section {
                Button("Save the Current Setup…") { newName = ""; naming = true }
                Toggle("Put the matching profile back when a display is plugged in or removed", isOn: Binding(get: { config.restoreProfileOnChange }, set: { v in store.update { $0.restoreProfileOnChange = v } }))
            } footer: {
                Text("A profile matches when exactly the same displays are connected. The command “Apply the next saved display profile” steps through them from a shortcut.")
            }
            Section("Saved profiles") {
                if config.displayProfiles.isEmpty { Text("None yet.").font(.callout).foregroundStyle(.secondary) }
                ForEach(config.displayProfiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                            Text(profile.displays.map { "\($0.width)×\($0.height)" }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Apply") {
                            let before = DisplayProfile(id: "before", name: "before", displays: tools.snapshot())
                            tools.apply(profile)
                            pending = (DisplayChangeGuard(label: "“\(profile.name)”"), { tools.apply(before) })
                        }.controlSize(.small)
                        Button(role: .destructive) { store.update { $0.displayProfiles.removeAll { $0.id == profile.id } } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func saveProfile() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let profile = DisplayProfile(id: UUID().uuidString, name: name, displays: tools.snapshot())
        store.update { $0.displayProfiles.append(profile) }
    }

    // MARK: Hot corners

    private var cornersTab: some View {
        Form {
            Section {
                Toggle("Hot corners", isOn: Binding(get: { config.hotCornersEnabled }, set: { v in store.update { $0.hotCornersEnabled = v } }))
                if config.hotCornersEnabled {
                    SliderRow(title: "Rest for", value: Binding(get: { Double(config.cornerDwellMs) }, set: { v in store.update { $0.cornerDwellMs = UInt32(v) } }),
                              range: 100...1500, format: { "\(Int($0)) ms" }, help: "How long the pointer stays in the corner before it counts.")
                    SliderRow(title: "Corner size", value: Binding(get: { config.cornerSize }, set: { v in store.update { $0.cornerSize = v } }),
                              range: 2...40, format: { "\(Int($0)) pt" })
                }
            } header: { Text("Hot corners") } footer: {
                Text("Rest the pointer in a corner to run a saved action. It must leave the corner before the same one can run again. Off by default.")
            }
            if config.hotCornersEnabled {
                Section("Actions") {
                    ForEach(ScreenCorner.allCases) { corner in
                        Picker(corner.title, selection: Binding(
                            get: { config.corners.first { $0.corner == corner }?.actionId ?? "" },
                            set: { id in
                                store.update { config in
                                    config.corners.removeAll { $0.corner == corner }
                                    if !id.isEmpty { config.corners.append(HotCorner(corner: corner, actionId: id, modifiers: 0)) }
                                }
                            }
                        )) {
                            Text("Nothing").tag("")
                            ForEach(library.actions, id: \.id) { Text($0.name).tag($0.id) }
                        }
                    }
                }
            }
            if let error = store.lastError { Section { Text(error).font(.callout).foregroundStyle(Theme.danger) } }
        }
        .formStyle(.grouped)
    }
}


private struct DisplayHistorySection: View {
    @ObservedObject private var history = DisplayHistoryStore.shared

    var body: some View {
        if !history.timeline.events.isEmpty {
            Section {
                ForEach(history.timeline.events.prefix(8)) { event in
                    HStack {
                        Image(systemName: event.connected ? "plus.circle" : "minus.circle").foregroundStyle(event.connected ? Theme.ok : Theme.warn)
                        Text("\(event.device) \(event.connected ? "connected" : "disconnected")")
                        Spacer()
                        Text(event.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }.font(.callout)
                }
                Button("Clear History") { history.clear() }.controlSize(.small)
            } header: { Text("Connection history") }
        }
    }
}
