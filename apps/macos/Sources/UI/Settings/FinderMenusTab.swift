import SwiftUI

/// What the newer right-click submenus offer, and where each action shows: tag presets, folder sets (shared with Finder windows), and
/// profiles that limit actions to some folders.
struct FinderMenusTab: View {
    @EnvironmentObject private var store: FinderStore
    @ObservedObject private var sets = FolderSetStore.shared
    @State private var editingTag: FinderTagPreset?
    @State private var editingProfile: FinderMenuFile.Profile?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                ForEach(store.tagPresets) { preset in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title).font(.headline)
                            Text(summary(preset)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editingTag = preset }.controlSize(.small)
                        Button(role: .destructive) { store.tagPresets.removeAll { $0.id == preset.id } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text("Quick Tag presets")
                    Spacer()
                    Button { editingTag = FinderTagPreset(id: UUID().uuidString, title: "", tags: []) } label: { Label("New", systemImage: "plus") }.controlSize(.small)
                }
            } footer: { Text("Add the “Quick Tag” action to the menu (Add Common Actions) and each preset becomes one click: it adds its tags to what the item has, can write a comment, or take every tag off.") }

            Section {
                if sets.sets.isEmpty { Text("No folder sets yet. Save the folders open in Finder as a set in Setup › Folder memory.").foregroundStyle(.secondary) }
                ForEach(sets.sets) { set in
                    HStack { Text(set.name); Spacer(); Text("\(set.paths.count) folder\(set.paths.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary) }
                }
            } header: { Text("Folder sets") } footer: {
                Text("“Move To Folder Set” and “Copy To Folder Set” list every folder of every set as “Set › Folder”. The same sets open together from the launcher and the Finder windows list. A folder is only used if it is still in a set when you choose it.")
            }

            Section {
                ForEach(store.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).font(.headline)
                            Text("\(profile.itemIDs.count) action\(profile.itemIDs.count == 1 ? "" : "s") · \(profile.folders.isEmpty ? "everywhere" : profile.folders.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editingProfile = profile }.controlSize(.small)
                        Button(role: .destructive) { store.profiles.removeAll { $0.id == profile.id } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                    }
                }
            } header: {
                HStack {
                    Text("Profiles")
                    Spacer()
                    Menu {
                        Button("Developer — code folders") { editingProfile = Self.developerProfile(store: store) }
                        Button("Photos — Pictures") { editingProfile = Self.simpleProfile("Photos", folders: [NSHomeDirectory() + "/Pictures"], ids: ["convert", "share"], store: store) }
                        Button("Downloads — secure cleanup") { editingProfile = Self.simpleProfile("Downloads", folders: [NSHomeDirectory() + "/Downloads"], ids: ["remove-quarantine", "tidy-folder", "undo-last", "inspect"], store: store) }
                        Divider()
                        Button("Blank profile") { editingProfile = FinderMenuFile.Profile(id: UUID().uuidString, name: "", folders: [], itemIDs: []) }
                    } label: { Label("New", systemImage: "plus") }.menuStyle(.button).controlSize(.small).fixedSize()
                }
            } footer: { Text("A profile makes the actions you pick appear only inside the folders you list (and their subfolders). An action in no profile shows everywhere. Use it to keep the menu short: developer actions in your code folders, cleanup in Downloads.") }

            if let message { Section { Text(message).font(.callout).foregroundStyle(.secondary) } }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: store.tagPresets)
        .animation(.smooth(duration: 0.25), value: store.profiles)
        .sheet(item: $editingTag) { TagPresetEditor(preset: $0) }
        .sheet(item: $editingProfile) { ProfileEditor(profile: $0) }
    }

    private func summary(_ preset: FinderTagPreset) -> String {
        var parts: [String] = []
        if preset.clearsTags { parts.append("removes every tag") }
        if !preset.tags.isEmpty { parts.append((preset.clearsTags ? "then sets " : "adds ") + preset.tags.joined(separator: ", ")) }
        if let comment = preset.comment { parts.append("comment “\(comment)”") }
        return parts.isEmpty ? "does nothing yet" : parts.joined(separator: " · ")
    }

    private static func simpleProfile(_ name: String, folders: [String], ids: [String], store: FinderStore) -> FinderMenuFile.Profile {
        FinderMenuFile.Profile(id: UUID().uuidString, name: name, folders: folders, itemIDs: ids.filter { id in store.items.contains { $0.id == id } })
    }

    private static func developerProfile(store: FinderStore) -> FinderMenuFile.Profile {
        let home = NSHomeDirectory()
        let folders = ["Developer", "Projects", "Code", "dev", "src", "repos"].map { home + "/" + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
        return simpleProfile("Developer", folders: folders, ids: ["open-in-ide", "open-in-vscode", "open-terminal", "copy-path-as", "copy-shell-path"], store: store)
    }
}

private struct TagPresetEditor: View {
    @State var preset: FinderTagPreset
    @EnvironmentObject private var store: FinderStore
    @Environment(\.dismiss) private var dismiss
    @State private var tagsText = ""
    @State private var comment = ""
    @State private var hasComment = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick Tag preset").font(.title3.bold())
            Form {
                TextField("Name in the menu", text: $preset.title)
                TextField("Tags to add", text: $tagsText, prompt: Text("Review, Client"))
                Toggle("Remove every existing tag first", isOn: $preset.clearsTags)
                Toggle("Also write a Finder comment", isOn: $hasComment)
                if hasComment { TextField("Comment", text: $comment) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(preset.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 480)
        .onAppear { tagsText = preset.tags.joined(separator: ", "); comment = preset.comment ?? ""; hasComment = preset.comment != nil }
    }

    private func save() {
        preset.title = preset.title.trimmingCharacters(in: .whitespaces)
        preset.tags = FinderMetadata.parseTags(tagsText)
        preset.comment = hasComment ? comment.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        if let i = store.tagPresets.firstIndex(where: { $0.id == preset.id }) { store.tagPresets[i] = preset } else { store.tagPresets.append(preset) }
        dismiss()
    }
}

private struct ProfileEditor: View {
    @State var profile: FinderMenuFile.Profile
    @EnvironmentObject private var store: FinderStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Profile").font(.title3.bold())
            Form {
                TextField("Name", text: $profile.name)
                Section("Show these actions only in") {
                    ForEach(profile.folders, id: \.self) { folder in
                        HStack { Text((folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.head); Spacer(); Button { profile.folders.removeAll { $0 == folder } } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).accessibilityLabel("Remove folder") }
                    }
                    Button("Add Folder…") { addFolder() }
                    if profile.folders.isEmpty { Text("No folder: the actions show everywhere.").font(.caption).foregroundStyle(.secondary) }
                }
                Section("Actions in this profile") {
                    List(store.items) { item in
                        Toggle(item.title, isOn: Binding(get: { profile.itemIDs.contains(item.id) }, set: { on in if on { profile.itemIDs.append(item.id) } else { profile.itemIDs.removeAll { $0 == item.id } } }))
                    }
                    .frame(height: 170)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 520)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for url in panel.urls where !profile.folders.contains(url.path) { profile.folders.append(url.path) } }
    }

    private func save() {
        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
        if let i = store.profiles.firstIndex(where: { $0.id == profile.id }) { store.profiles[i] = profile } else { store.profiles.append(profile) }
        dismiss()
    }
}
