import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardPane: View {
    @EnvironmentObject private var clip: ClipboardStore
    @EnvironmentObject private var service: ClipboardService
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var services: ServiceManager

    @State private var tab: Tab = .history

    enum Tab: String, CaseIterable, Identifiable {
        case history = "History", snippets = "Snippets", settings = "Settings"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !config.isEnabled(.clipboard) || services.state(.clipboard) != .running {
                Banner(
                    symbol: "doc.on.clipboard", tint: Theme.warn,
                    title: "Clipboard history is \(config.isEnabled(.clipboard) ? services.state(.clipboard).label.lowercased() : "off")",
                    message: "Nothing is being recorded. What is already saved stays on this Mac."
                ) {
                    if !config.isEnabled(.clipboard) { Button("Turn On") { services.setFeature(.clipboard, enabled: true) }.controlSize(.small) }
                }
                .padding(.horizontal, 20).padding(.top, 10).transition(.opacity)
            } else if clip.config.paused {
                Banner(symbol: "pause.circle.fill", tint: Theme.warn, title: "Recording is paused", message: "Copies are not being saved until you resume.") {
                    Button("Resume") { service.setPaused(false) }.controlSize(.small)
                }
                .padding(.horizontal, 20).padding(.top, 10).transition(.opacity)
            }
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .paneTabBar(maxWidth: 360).paneHeader()
            Group {
                switch tab {
                case .history: ClipBrowser(snippetsOnly: false)
                case .snippets: ClipBrowser(snippetsOnly: true)
                case .settings: ClipSettingsTab()
                }
            }
            .id(tab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.22), value: tab)
        .animation(.smooth(duration: 0.25), value: clip.config.paused)
        .overlay(alignment: .bottom) {
            if let error = clip.lastError {
                Text(error).font(.callout).padding(10).background(Theme.danger.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .padding().transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

// MARK: - Browsing history and snippets

private struct ClipBrowser: View {
    let snippetsOnly: Bool
    @EnvironmentObject private var clip: ClipboardStore
    @EnvironmentObject private var service: ClipboardService

    @State private var query = ""
    @State private var chip: ClipChip = .all
    @State private var collection: String?
    @State private var items: [ClipItem] = []
    @State private var selection: String?
    @State private var newSnippet = false
    @State private var confirmClear = false
    @State private var message: String?

    private var filter: ClipFilter {
        var f = (snippetsOnly ? ClipChip.snippets : chip).filter(collection: collection)
        if snippetsOnly { f.favoritesOnly = true }
        return f
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $query).textFieldStyle(.plain)
                }
                .padding(10)
                if !snippetsOnly {
                    Picker("", selection: $chip) { ForEach(ClipChip.allCases.filter { $0 != .snippets }) { Text($0.rawValue).tag($0) } }
                        .labelsHidden().pickerStyle(.menu).padding(.horizontal, 10).padding(.bottom, 6)
                }
                Divider()
                List(items, selection: $selection) { item in ClipRow(item: item).tag(item.id) }
                    .listStyle(.plain)
                    .overlay { if items.isEmpty { Text(snippetsOnly ? "No snippets yet" : (clip.isEmpty ? "Nothing copied yet" : "No matching items")).foregroundStyle(.secondary) } }
                Divider()
                toolbar
            }
            .frame(width: 330)
            Divider()
            Group {
                if let id = selection, let item = items.first(where: { $0.id == id }) {
                    ClipDetail(item: item, onChange: refresh).id(item.id).transition(.opacity)
                } else {
                    Text("Select an item").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .animation(.smooth(duration: 0.15), value: selection)
        }
        .onAppear(perform: refresh)
        .onChange(of: query) { _, _ in refresh() }
        .onChange(of: chip) { _, _ in refresh() }
        .onChange(of: collection) { _, _ in refresh() }
        .onChange(of: clip.stats) { _, _ in refresh() }
        .sheet(isPresented: $newSnippet) { SnippetEditor(onSaved: refresh) }
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Clear History, Keep Pinned and Snippets") { _ = clip.clear(keepPinned: true, keepSnippets: true); refresh() }
            Button("Clear Everything", role: .destructive) { _ = clip.clear(keepPinned: false, keepSnippets: false); refresh() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Cleared items are overwritten on disk and cannot be brought back.") }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            if snippetsOnly {
                Button { newSnippet = true } label: { Image(systemName: "plus") }.help("New snippet")
                Menu {
                    Button("Import Snippets…") { importSnippets() }
                    Button("Export Selected…") { exportSnippets(selected: true) }.disabled(selection == nil)
                    Button("Export All…") { exportSnippets(selected: false) }.disabled(items.isEmpty)
                } label: { Image(systemName: "square.and.arrow.up.on.square") }.menuStyle(.borderlessButton).fixedSize()
            } else {
                Button { service.setPaused(!clip.config.paused) } label: { Image(systemName: clip.config.paused ? "play.circle" : "pause.circle") }
                    .help(clip.config.paused ? "Resume recording" : "Pause recording")
                Button { confirmClear = true } label: { Image(systemName: "trash") }.help("Clear history")
            }
            if !clip.collections.isEmpty {
                Menu {
                    Button("All collections") { collection = nil }
                    Divider()
                    ForEach(clip.collections) { c in Button("\(c.name) (\(c.count))") { collection = c.id } }
                } label: { Image(systemName: collection == nil ? "folder" : "folder.fill") }.menuStyle(.borderlessButton).fixedSize()
            }
            Spacer()
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1).transition(.opacity) }
        }
        .buttonStyle(.borderless)
        .padding(8)
        .animation(.smooth(duration: 0.2), value: message)
    }

    private func refresh() {
        items = clip.search(query, filter: filter, limit: 500)
        if let selection, !items.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    private func importSnippets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let s = try clip.importSnippets(from: url)
            message = "Added \(s.added), updated \(s.updated)" + (s.skipped > 0 ? ", skipped \(s.skipped)" : "")
            refresh()
        } catch { clip.lastError = error.userMessage }
    }

    private func exportSnippets(selected: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Kriya snippets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ids = selected ? (selection.map { [$0] } ?? []) : items.map(\.id)
        do {
            try clip.exportSnippets(ids, to: url)
            message = "Exported \(ids.count)"
        } catch { clip.lastError = error.userMessage }
    }
}

private struct ClipDetail: View {
    let item: ClipItem
    let onChange: () -> Void
    @EnvironmentObject private var clip: ClipboardStore
    @EnvironmentObject private var service: ClipboardService

    @State private var title = ""
    @State private var tagsText = ""
    @State private var blob: ClipBlob?
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ClipPreview(item: item, blob: blob).frame(maxHeight: .infinity)
            Form {
                if item.favorite { TextField("Name", text: $title, prompt: Text("Snippet name")).onSubmit { clip.setTitle(item.id, title); onChange() } }
                TextField("Tags", text: $tagsText, prompt: Text("comma separated")).onSubmit(commitTags)
                Picker("Collection", selection: Binding(get: { item.collectionId ?? "" }, set: { clip.setCollection(item.id, $0.isEmpty ? nil : $0); onChange() })) {
                    Text("None").tag("")
                    ForEach(clip.collections) { Text($0.name).tag($0.id) }
                }
            }
            .formStyle(.grouped).frame(height: item.favorite ? 150 : 110)
            HStack {
                Button("Copy") { service.paster.put(item, plain: false); clip.markUsed(item.id) }
                Button("Copy as Plain Text") { service.paster.put(item, plain: true) }.disabled(item.kind == .image || item.kind == .files)
                Spacer()
                Button { clip.setPinned(item.id, !item.pinned); onChange() } label: { Label(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash" : "pin") }
                if item.favorite {
                    if item.kind == .text || item.kind == .url { Button("Edit Text") { editing = true } }
                    Button("Remove from Snippets") { clip.setFavorite(item.id, false); onChange() }
                } else {
                    Button { clip.setFavorite(item.id, true, title: nil); onChange() } label: { Label("Save as Snippet", systemImage: "star") }
                }
                Button(role: .destructive) { clip.delete(item.id); onChange() } label: { Image(systemName: "trash") }
            }
            .padding(.bottom, 4)
        }
        .padding(14)
        .onAppear { title = item.title ?? ""; tagsText = item.tags.joined(separator: ", "); blob = clip.blob(item.id) }
        .onDisappear(perform: commitTags)
        .sheet(isPresented: $editing) { SnippetEditor(existing: item, onSaved: onChange) }
    }

    private func commitTags() {
        let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard tags != item.tags else { return }
        clip.setTags(item.id, tags)
        onChange()
    }
}

private struct SnippetEditor: View {
    var existing: ClipItem?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var clip: ClipboardStore

    @State private var title = ""
    @State private var text = ""
    @State private var collection = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "New Snippet" : "Edit Snippet").font(.title3.bold())
            Form {
                TextField("Name", text: $title)
                TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(height: 160)
                if existing == nil {
                    Picker("Collection", selection: $collection) { Text("None").tag(""); ForEach(clip.collections) { Text($0.name).tag($0.id) } }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 500)
        .onAppear {
            if let existing { title = existing.title ?? ""; text = clip.blob(existing.id)?.plain ?? existing.preview }
        }
    }

    private func save() {
        if let existing {
            clip.updateSnippet(existing.id, title: title, text: text)
        } else {
            clip.addSnippet(title: title, text: text, collection: collection.isEmpty ? nil : collection)
        }
        if clip.lastError == nil { onSaved(); dismiss() }
    }
}

// MARK: - Settings

private struct ClipSettingsTab: View {
    @EnvironmentObject private var clip: ClipboardStore
    @EnvironmentObject private var service: ClipboardService
    @EnvironmentObject private var permissions: PermissionManager

    @State private var newCollection = ""
    @State private var confirmClear = false

    private var config: ClipConfig { clip.config }

    var body: some View {
        Form {
            Section {
                Toggle("Pause recording", isOn: Binding(get: { config.paused }, set: { service.setPaused($0) }))
                Toggle("Text", isOn: Binding(get: { config.captureText }, set: { v in clip.updateConfig { $0.captureText = v } }))
                Toggle("Formatting (rich text)", isOn: Binding(get: { config.captureRichText }, set: { v in clip.updateConfig { $0.captureRichText = v } })).disabled(!config.captureText)
                Toggle("Images", isOn: Binding(get: { config.captureImages }, set: { v in clip.updateConfig { $0.captureImages = v } }))
                Toggle("Files", isOn: Binding(get: { config.captureFiles }, set: { v in clip.updateConfig { $0.captureFiles = v } }))
            } header: { Text("What to record") }

            Section {
                Stepper("Keep up to \(config.maxItems) items", value: Binding(get: { Int(config.maxItems) }, set: { v in clip.updateConfig { $0.maxItems = UInt32(v) } }), in: 20...10_000, step: 20)
                Picker("Remove items after", selection: Binding(get: { Int(config.retentionDays) }, set: { v in clip.updateConfig { $0.retentionDays = UInt32(v) } })) {
                    Text("Never").tag(0); Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90); Text("1 year").tag(365)
                }
                Stepper("Largest item: \(config.maxItemMb) MB", value: Binding(get: { Int(config.maxItemMb) }, set: { v in clip.updateConfig { $0.maxItemMb = UInt32(v) } }), in: 1...500)
                Stepper("History size limit: \(config.maxTotalMb) MB", value: Binding(get: { Int(config.maxTotalMb) }, set: { v in clip.updateConfig { $0.maxTotalMb = UInt32(v) } }), in: 16...50_000, step: 16)
                if let stats = clip.stats {
                    LabeledContent("Now", value: "\(stats.items) items, \(ByteCountFormatter.string(fromByteCount: Int64(stats.bytes), countStyle: .file))")
                }
            } header: { Text("Limits and cleanup") } footer: {
                Text("Pinned items and snippets are never removed by cleanup. Cleanup runs after each copy and every hour.")
            }

            Section {
                Toggle("Skip text that looks like a password, key or card number", isOn: Binding(get: { config.skipSecrets }, set: { v in clip.updateConfig { $0.skipSecrets = v } }))
                if config.excludedAppIds.isEmpty { Text("No excluded apps.").font(.callout).foregroundStyle(.secondary) }
                ForEach(config.excludedAppIds, id: \.self) { id in
                    HStack {
                        Text(AppChoice.name(for: id))
                        Spacer()
                        Button(role: .destructive) { clip.updateConfig { $0.excludedAppIds.removeAll { $0 == id } } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                Button { if let id = AppChoice.choose(prompt: "Exclude"), !config.excludedAppIds.contains(id) { clip.updateConfig { $0.excludedAppIds.append(id) } } } label: { Label("Exclude an App", systemImage: "plus") }
                    .controlSize(.small)
            } header: { Text("Privacy") } footer: {
                Text("Copies from these apps are never recorded, and neither are copies an app marks as secret (password managers do). Password managers are excluded to start with. Everything is stored only on this Mac, in a private file, and is never sent anywhere.")
            }

            Section {
                shortcutRow("Open the clipboard window", key: \.quickKey, mods: \.quickModifiers)
                shortcutRow("Paste as plain text", key: \.plainKey, mods: \.plainModifiers)
                shortcutRow("Remove formatting from the clipboard", key: \.stripKey, mods: \.stripModifiers)
                Toggle("Paste right away after choosing an item", isOn: Binding(get: { config.autoPaste }, set: { v in clip.updateConfig { $0.autoPaste = v } }))
                if config.autoPaste, !permissions.isGranted(.accessibility) {
                    HStack {
                        Label("Pasting for you needs Accessibility.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                        Spacer()
                        Button("Allow…") { permissions.request(.accessibility) }.controlSize(.small)
                    }
                }
            } header: { Text("Shortcuts") }

            Section {
                ForEach(clip.collections) { c in
                    HStack {
                        Text(c.name); Text("\(c.count)").foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) { clip.deleteCollection(c.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("New collection", text: $newCollection).onSubmit(addCollection)
                    Button("Add", action: addCollection).disabled(newCollection.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { Text("Collections") }

            Section {
                Button("Clear History…", role: .destructive) { confirmClear = true }
            } footer: {
                Text("macOS may ask whether Kriya can read what other apps copy. Choose “Allow”, or clipboard history cannot work (System Settings › Privacy & Security › Paste from Other Apps).")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Clear, Keep Pinned and Snippets") { _ = clip.clear(keepPinned: true, keepSnippets: true) }
            Button("Clear Everything", role: .destructive) { _ = clip.clear(keepPinned: false, keepSnippets: false) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func addCollection() {
        let name = newCollection.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        clip.saveCollection(name: name)
        if clip.lastError == nil { newCollection = "" }
    }

    private func shortcutRow(_ title: String, key: WritableKeyPath<ClipConfig, UInt16?>, mods: WritableKeyPath<ClipConfig, UInt64>) -> some View {
        LabeledContent(title) {
            ShortcutRecorder(shortcut: Binding(
                get: { config[keyPath: key].map { RecordedShortcut(keyCode: $0, modifiers: config[keyPath: mods]) } },
                set: { new in clip.updateConfig { $0[keyPath: key] = new?.keyCode; $0[keyPath: mods] = new?.modifiers ?? 0 } }
            ))
            .frame(width: 180, height: 26)
        }
    }
}
