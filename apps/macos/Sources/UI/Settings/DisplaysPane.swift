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
        .onAppear { reload() }
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

    private var displaysTab: some View {
        Form {
            ForEach(displays) { entry in
                Section {
                    Picker("Resolution", selection: Binding(
                        get: { entry.current?.id ?? "" },
                        set: { id in if let mode = entry.modes.first(where: { $0.id == id }) { tools.set(mode, on: entry.id) } }
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
                } header: {
                    Text(entry.name + (entry.isMain ? " · main" : ""))
                } footer: {
                    if entry.isMain { Text("If a mode shows a black screen, wait a few seconds: macOS goes back to the old one by itself.") }
                }
            }
            if displays.isEmpty { Section { Text("No displays found.").foregroundStyle(.secondary) } }
        }
        .formStyle(.grouped)
    }

    // MARK: Profiles

    private var profilesTab: some View {
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
                        Button("Apply") { tools.apply(profile) }.controlSize(.small)
                        Button(role: .destructive) { store.update { $0.displayProfiles.removeAll { $0.id == profile.id } } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
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
