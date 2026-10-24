import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfilesPane: View {
    @EnvironmentObject private var store: ProfileStore

    @State private var selectedID: String?
    @State private var errorMessage: String?
    @State private var confirmRemove = false

    private var selected: Profile? {
        store.profiles.first { $0.id == selectedID } ?? store.defaultProfile
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Divider()
            Group {
                if let profile = selected {
                    ProfileDetail(profile: profile)
                        .id(profile.id)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.2), value: selected?.id)
        }
        .confirmationDialog("Remove the profile for \(selected?.name ?? "this app")?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { removeSelected() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The app goes back to using the default profile.") }
        .alert("Could not change profiles", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { selected?.id }, set: { selectedID = $0 })) {
                ForEach(store.profiles) { profile in
                    HStack(spacing: 8) {
                        Image(systemName: profile.isDefault ? "globe" : "app")
                            .foregroundStyle(profile.isEnabled ? Theme.accent : .secondary)
                        Text(profile.name).lineLimit(1)
                    }
                    .tag(profile.id)
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button { addApp() } label: { Image(systemName: "plus") }.accessibilityLabel("Add a profile for an app")
                Button { confirmRemove = true } label: { Image(systemName: "minus") }.accessibilityLabel("Remove this profile")
                    .disabled(selected?.isDefault ?? true)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose an app to give its own profile."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.addProfile(forApplicationAt: url)
            if let added = store.appProfiles.last { withAnimation(.smooth) { selectedID = added.id } }
        } catch {
            errorMessage = error.userMessage
        }
    }

    private func removeSelected() {
        guard let profile = selected, !profile.isDefault else { return }
        do {
            try store.delete(profile)
            withAnimation(.smooth) { selectedID = nil }
        } catch {
            errorMessage = error.userMessage
        }
    }
}

private struct ProfileDetail: View {
    let profile: Profile
    @EnvironmentObject private var store: ProfileStore

    private enum Choice: Hashable { case inherit, on, off }

    private func choice(for feature: FeatureId) -> Choice {
        guard let override = profile.featureOverrides.first(where: { $0.feature == feature }) else { return profile.isDefault ? .on : .inherit }
        return override.enabled ? .on : .off
    }

    private func binding(for feature: FeatureId) -> Binding<Choice> {
        Binding(
            get: { choice(for: feature) },
            set: { new in
                switch new {
                case .inherit: store.setOverride(feature, to: nil, in: profile)
                case .on: store.setOverride(feature, to: true, in: profile)
                case .off: store.setOverride(feature, to: false, in: profile)
                }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                if profile.isDefault {
                    Text("Applies everywhere, unless an app has its own profile that says otherwise.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    LabeledContent("App") { Text(profile.appId ?? "").textSelection(.enabled).foregroundStyle(.secondary) }
                    Toggle("Use this profile", isOn: Binding(
                        get: { profile.isEnabled },
                        set: { on in
                            var updated = profile
                            updated.isEnabled = on
                            try? store.save(updated)
                        }
                    ))
                }
            } header: {
                Text(profile.name)
            }

            Section {
                ForEach(FeatureId.all) { feature in
                    // One line per feature: a fixed icon column, the name, and a fixed-width control, so every row lines up.
                    HStack(spacing: 10) {
                        RowIcon(symbol: feature.symbol)
                        Text(feature.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Picker(feature.title, selection: binding(for: feature)) {
                            if !profile.isDefault { Text("Same as default").tag(Choice.inherit) }
                            Text("On").tag(Choice.on)
                            Text("Off").tag(Choice.off)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: profile.isDefault ? 110 : 250)
                    }
                }
            } header: {
                Text("Features")
            } footer: {
                Text(profile.isDefault
                     ? "Switching a feature off here switches it off in every app that does not say otherwise."
                     : "While this app is in front, these choices apply. A feature must also be turned on under Features.")
            }
        }
        .formStyle(.grouped)
        // A profile with no explicit "On" shows as On: the default profile only stores what the person turned off.
        .smoothly(profile)
    }
}
