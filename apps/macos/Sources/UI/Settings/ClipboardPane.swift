import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardPane: View {
    @EnvironmentObject private var clip: ClipboardStore
    @EnvironmentObject private var service: ClipboardService
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var services: ServiceManager

    @ObservedObject private var lock = ClipboardLock.shared
    @State private var tab: Tab = .history

    enum Tab: String, CaseIterable, Identifiable {
        case history = "History", snippets = "Snippets", privacy = "Privacy", settings = "Settings"
        var id: String { rawValue }
    }

    private var showsLock: Bool { lock.isEnabled && !lock.isOpen && (tab == .history || tab == .snippets) }

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
            } else if clip.vault.isLocked {
                Banner(symbol: "lock.trianglebadge.exclamationmark.fill", tint: Theme.danger, title: "History is locked", message: "It is encrypted, and its key is not on this Mac. Nothing new is saved until you start again (Privacy tab).") {
                    Button("Privacy…") { tab = .privacy }.controlSize(.small)
                }
                .padding(.horizontal, 20).padding(.top, 10).transition(.opacity)
            } else if clip.config.paused {
                Banner(symbol: "pause.circle.fill", tint: Theme.warn, title: "Recording is paused", message: "Copies are not being saved until you resume.") {
                    Button("Resume") { service.setPaused(false) }.controlSize(.small)
                }
                .padding(.horizontal, 20).padding(.top, 10).transition(.opacity)
            }
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .paneTabBar(maxWidth: 440).paneHeader()
            Group {
                switch tab {
                case .history: ClipBrowser(snippetsOnly: false)
                case .snippets: ClipBrowser(snippetsOnly: true)
                case .privacy: ClipPrivacyTab()
                case .settings: ClipSettingsTab()
                }
            }
            .id(tab)
            .transition(.opacity)
            .overlay {
                if showsLock { ClipLockedView().transition(.opacity) }
            }
        }
        .animation(.smooth(duration: 0.2), value: showsLock)
        .onAppear { if lock.needsUnlock { lock.ensureUnlocked(reason: "Open your clipboard history") { _ in } } }
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
                Button { newSnippet = true } label: { Image(systemName: "plus") }.help("New snippet").accessibilityLabel("New snippet")
                Menu {
                    Button("Import Snippets…") { importSnippets() }
                    Button("Export Selected…") { exportSnippets(selected: true) }.disabled(selection == nil)
                    Button("Export All…") { exportSnippets(selected: false) }.disabled(items.isEmpty)
                    Divider()
                    Button("Export Selected, Encrypted…") { exportSnippets(selected: true, encrypted: true) }.disabled(selection == nil)
                    Button("Export All, Encrypted…") { exportSnippets(selected: false, encrypted: true) }.disabled(items.isEmpty)
                } label: { Image(systemName: "square.and.arrow.up.on.square") }.menuStyle(.borderlessButton).fixedSize()
            } else {
                Button { service.setPaused(!clip.config.paused) } label: { Image(systemName: clip.config.paused ? "play.circle" : "pause.circle") }
                    .help(clip.config.paused ? "Resume recording" : "Pause recording")
                Button { confirmClear = true } label: { Image(systemName: "trash") }.help("Clear history").accessibilityLabel("Clear history")
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
        var phrase: String?
        if ClipboardStore.needsPassphrase(url) {
            guard let typed = Self.askPassphrase(title: "This file is encrypted", detail: "Type the passphrase it was exported with.", confirm: false) else { return }
            phrase = typed
        }
        do {
            let s = try clip.importSnippets(from: url, passphrase: phrase)
            message = "Added \(s.added), updated \(s.updated)" + (s.skipped > 0 ? ", skipped \(s.skipped)" : "")
            refresh()
        } catch { clip.lastError = error.userMessage }
    }

    private func exportSnippets(selected: Bool, encrypted: Bool = false) {
        var phrase: String?
        if encrypted {
            guard let typed = Self.askPassphrase(title: "Encrypt the export", detail: "Choose a passphrase of at least \(BackupCrypto.minimumLength) characters. Without it the file cannot be opened, by anyone.", confirm: true) else { return }
            phrase = typed
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = encrypted ? "Kriya snippets (encrypted).json" : "Kriya snippets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ids = selected ? (selection.map { [$0] } ?? []) : items.map(\.id)
        do {
            try clip.exportSnippets(ids, to: url, passphrase: phrase)
            message = "Exported \(ids.count)" + (encrypted ? ", encrypted" : "")
        } catch { clip.lastError = error.userMessage }
    }

    /// Asks for a passphrase. When `confirm` is set it asks twice and refuses a short or mismatched one.
    private static func askPassphrase(title: String, detail: String, confirm: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 280, height: confirm ? 56 : 24))
        stack.orientation = .vertical
        stack.spacing = 8
        let first = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        first.placeholderString = "Passphrase"
        stack.addArrangedSubview(first)
        let second = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        second.placeholderString = "Type it again"
        if confirm { stack.addArrangedSubview(second) }
        alert.accessoryView = stack
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = first
        while alert.runModal() == .alertFirstButtonReturn {
            if !confirm { return first.stringValue.isEmpty ? nil : first.stringValue }
            if first.stringValue.count < BackupCrypto.minimumLength { alert.informativeText = "Use at least \(BackupCrypto.minimumLength) characters."; continue }
            if first.stringValue != second.stringValue { alert.informativeText = "The two do not match."; continue }
            return first.stringValue
        }
        return nil
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
                Button(role: .destructive) { clip.delete(item.id); onChange() } label: { Image(systemName: "trash") }.accessibilityLabel("Delete")
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

// MARK: - Privacy

/// Shown over the history while the lock is on and has not been opened.
private struct ClipLockedView: View {
    @ObservedObject private var lock = ClipboardLock.shared
    @State private var trying = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text("Clipboard history is locked").font(.title3.weight(.semibold))
            Text("Use Touch ID or your Mac's password to open it.").font(.callout).foregroundStyle(.secondary)
            Button {
                trying = true
                lock.ensureUnlocked(reason: "Open your clipboard history") { _ in trying = false }
            } label: { Label("Unlock", systemImage: "touchid") }
                .controlSize(.large).disabled(trying)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

private struct ClipPrivacyTab: View {
    @EnvironmentObject private var clip: ClipboardStore
    @ObservedObject private var lock = ClipboardLock.shared
    @State private var confirmPurge = false
    @State private var note: String?

    private var config: ClipConfig { clip.config }

    var body: some View {
        Form {
            VaultSection(vault: clip.vault)

            Section {
                Toggle("Save them, encrypted and labelled “sensitive”", isOn: Binding(get: { !config.skipSecrets }, set: { v in clip.updateConfig { $0.skipSecrets = !v } }))
                    .disabled(!clip.vault.isEncrypted)
                Picker("Remove sensitive items after", selection: Binding(get: { Int(config.sensitiveRetentionMinutes) }, set: { v in clip.updateConfig { $0.sensitiveRetentionMinutes = UInt32(v) } })) {
                    Text("Never").tag(0); Text("1 minute").tag(1); Text("5 minutes").tag(5); Text("15 minutes").tag(15); Text("1 hour").tag(60); Text("1 day").tag(1440)
                }
                .disabled(config.skipSecrets)
                Button("Remove Sensitive Items Now…", role: .destructive) { confirmPurge = true }
                if let note { Text(note).font(.callout).foregroundStyle(.secondary).transition(.opacity) }
            } header: { Text("Passwords, keys and card numbers") } footer: {
                Text(config.skipSecrets
                    ? "Right now text that looks like a password, key or card number is left out, and never saved. Turn on encryption to be able to keep them."
                    : "These are saved only because the history is encrypted. They show as hidden dots, and are removed on the schedule above. Kriya never deletes them on its own unless you choose a time. Pinned items and snippets are kept.")
            }

            Section {
                if config.excludedAppIds.isEmpty { Text("No excluded apps.").font(.callout).foregroundStyle(.secondary) }
                ForEach(config.excludedAppIds, id: \.self) { id in
                    HStack {
                        Text(AppChoice.name(for: id))
                        Spacer()
                        Button(role: .destructive) { clip.updateConfig { $0.excludedAppIds.removeAll { $0 == id } } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                    }
                }
                Button { if let id = AppChoice.choose(prompt: "Exclude"), !config.excludedAppIds.contains(id) { clip.updateConfig { $0.excludedAppIds.append(id) } } } label: { Label("Exclude an App", systemImage: "plus") }
                    .controlSize(.small)
            } header: { Text("Excluded apps") } footer: {
                Text("Copies from these apps are never recorded, and neither are copies an app marks as secret (password managers do). Password managers are excluded to start with.")
            }

            Section {
                Toggle("Ask for Touch ID or my password to open the history", isOn: Binding(
                    get: { lock.isEnabled },
                    set: { on in
                        if on { lock.enable(reason: "Turn on the clipboard history lock") { ok in if !ok { note = "The lock stayed off, because the Mac did not confirm who you are." } } }
                        else { lock.isEnabled = false }
                    }
                ))
                Picker("Ask again after", selection: $lock.timeoutMinutes) {
                    Text("1 minute").tag(1); Text("5 minutes").tag(5); Text("15 minutes").tag(15); Text("1 hour").tag(60)
                }
                .disabled(!lock.isEnabled)
            } header: { Text("Lock") } footer: {
                Text("The history also locks when the Mac sleeps or the screen locks. The lock covers what Kriya shows you; the saved file itself is protected by encryption.")
            }

            Section {
                Label("Nothing you copy is ever written to Kriya's log, the diagnostics report or an export. They record that a copy was saved or left out, never what it said.", systemImage: "hand.raised")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("What stays out of the logs") }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.2), value: note)
        .confirmationDialog("Remove sensitive items?", isPresented: $confirmPurge, titleVisibility: .visible) {
            Button("Remove Them", role: .destructive) {
                let removed = clip.purgeSensitive()
                note = removed == 0 ? "There were none to remove." : "Removed \(removed) sensitive item\(removed == 1 ? "" : "s")."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every item labelled sensitive is deleted and its space overwritten. Pinned items and snippets stay.")
        }
    }
}

/// Turning encryption on and off, and what to do when the key is gone.
private struct VaultSection: View {
    @ObservedObject var vault: ClipboardVault
    @EnvironmentObject private var clip: ClipboardStore
    @State private var asking: Question?
    @State private var problem: String?

    private enum Question: Identifiable {
        case turnOn, turnOff, startAgain
        var id: Int { hashValue }
    }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(tint).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if vault.isWorking { ProgressView().controlSize(.small) }
            }
            .animation(.smooth(duration: 0.2), value: vault.status)
            Toggle("Encrypt clipboard history", isOn: Binding(get: { vault.isEncrypted }, set: { on in asking = on ? .turnOn : .turnOff }))
                .disabled(vault.isWorking || vault.isLocked)
            if vault.isLocked {
                Button("Delete the Locked History and Start Again…", role: .destructive) { asking = .startAgain }.disabled(vault.isWorking)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(Theme.danger).transition(.opacity) }
        } header: { Text("Encryption") } footer: {
            Text("The key is made on this Mac and kept in your Keychain, for this Mac only. It is never sent anywhere, and never put in a backup. If the key is ever lost the saved history cannot be read, which is the point.")
        }
        .animation(.smooth(duration: 0.2), value: problem)
        .confirmationDialog(question.title, isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), titleVisibility: .visible) {
            Button(question.button, role: asking == .turnOn ? nil : .destructive) { run() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(question.message) }
    }

    private var question: (title: String, message: String, button: String) {
        switch asking {
        case .turnOff: return ("Turn encryption off?", "Everything saved is opened and stored as plain text again, and the key is removed from your Keychain.", "Turn Off")
        case .startAgain: return ("Delete the locked history?", "Everything saved while it was encrypted is deleted, because it cannot be opened without the key. Encryption is turned off, and recording starts again.", "Delete and Start Again")
        default: return ("Encrypt the clipboard history?", "\(clip.stats?.items ?? 0) saved item\((clip.stats?.items ?? 0) == 1 ? "" : "s") will be encrypted now, and so will everything you copy from here on. The old readable copies are overwritten on disk.", "Encrypt")
        }
    }

    private func run() {
        problem = nil
        let finished: (String?) -> Void = { failure in
            problem = failure
            clip.reload()
        }
        switch asking {
        case .turnOff: vault.turnOff(completion: finished)
        case .startAgain: vault.startAgain(completion: finished)
        default: vault.turnOn(completion: finished)
        }
    }

    private var icon: String { vault.isLocked ? "lock.trianglebadge.exclamationmark.fill" : (vault.isEncrypted ? "lock.shield.fill" : "lock.open") }
    private var tint: Color { vault.isLocked ? Theme.danger : (vault.isEncrypted ? Theme.ok : .secondary) }

    private var title: String {
        if vault.isWorking { return vault.isEncrypted ? "Working…" : "Encrypting…" }
        if vault.isLocked { return "Locked: the key is missing" }
        return vault.isEncrypted ? "Encrypted" : "Not encrypted"
    }

    private var detail: String {
        guard let status = vault.status else { return "Checking…" }
        if vault.isLocked { return "\(status.sealedItems) saved item\(status.sealedItems == 1 ? "" : "s") cannot be opened on this Mac." }
        if vault.isEncrypted { return "\(status.sealedItems) saved item\(status.sealedItems == 1 ? "" : "s"), sealed with AES-256." }
        return "What you copy is stored readable, in a file only you can open."
    }
}

// MARK: - Settings

private struct ClipSettingsTab: View {
    @EnvironmentObject private var clip: ClipboardStore
    @EnvironmentObject private var service: ClipboardService
    @EnvironmentObject private var permissions: PermissionManager

    @State private var newCollection = ""
    @State private var confirmClear = false
    @State private var placement = QuickPanelPlacement.current

    private var config: ClipConfig { clip.config }
    @AppStorage(ClipboardMerger.enabledKey) private var mergeCopies = false

    var body: some View {
        Form {
            Section {
                Toggle("Pause recording", isOn: Binding(get: { config.paused }, set: { service.setPaused($0) }))
                Toggle("Text", isOn: Binding(get: { config.captureText }, set: { v in clip.updateConfig { $0.captureText = v } }))
                Toggle("Formatting (rich text)", isOn: Binding(get: { config.captureRichText }, set: { v in clip.updateConfig { $0.captureRichText = v } })).disabled(!config.captureText)
                Toggle("Images", isOn: Binding(get: { config.captureImages }, set: { v in clip.updateConfig { $0.captureImages = v } }))
                Toggle("Files", isOn: Binding(get: { config.captureFiles }, set: { v in clip.updateConfig { $0.captureFiles = v } }))
                Toggle("⌘C twice adds the new copy under the one before", isOn: $mergeCopies)
            } header: { Text("What to record") } footer: {
                Text("Copy something, then select more text and press ⌘C twice quickly: the clipboard then holds both, one under the other. Text only; it looks at when ⌘C was pressed, never at what was typed.")
            }

            ClipboardRulesSection()
            SharedClipboardSection()

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
                Text("Encryption, passwords and keys, excluded apps and the lock are on the Privacy tab.").font(.callout).foregroundStyle(.secondary)
            } header: { Text("Privacy") }

            Section {
                Picker("The quick paste window opens", selection: Binding(get: { placement }, set: { placement = $0; QuickPanelPlacement.current = $0 })) {
                    ForEach(QuickPanelPlacement.allCases) { Text($0.title).tag($0) }
                }
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
            } header: { Text("Shortcuts") } footer: {
                Text("Drag the quick paste window by the bar at its top (or any empty part) to move it. “Where I left it” brings it back to the place you moved it to. Right-click an item for Paste, Copy, Pin, Save as Snippet and Delete.")
            }

            Section {
                ForEach(clip.collections) { c in
                    HStack {
                        Text(c.name); Text("\(c.count)").foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) { clip.deleteCollection(c.id) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
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

/// Rules that tidy what is copied, before it is recorded or pasted.
struct ClipboardRulesSection: View {
    @EnvironmentObject private var store: ClipboardRuleStore
    @State private var editing: ClipboardRule?

    var body: some View {
        Section {
            ForEach($store.rules) { $rule in
                HStack {
                    Toggle("", isOn: $rule.enabled).labelsHidden()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rule.name)
                        Text(summary(rule)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("Edit") { editing = rule }.controlSize(.small)
                    Button(role: .destructive) { store.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                }
            }
            Menu("Add a Rule") {
                Button("Clean links from every app") { store.rules.append(ClipboardRule(name: "Clean links", actions: [.stripTracking])) }
                Button("Plain text from every app") { store.rules.append(ClipboardRule(name: "Always plain text", actions: [.plainText, .trimEnds])) }
                Button("Custom…") { editing = ClipboardRule(name: "New rule", actions: [.trimEnds]) }
            }
        } header: { Text("Rules for what is copied") } footer: {
            Text("A rule tidies text the moment it is copied, so what you paste and what the history keeps is the tidy version. Choose the apps it applies to, or leave that empty for every app. Copies of files and pictures are never touched.")
        }
        .sheet(item: $editing) { rule in
            ClipboardRuleEditor(rule: rule) { saved in
                if let i = store.rules.firstIndex(where: { $0.id == saved.id }) { store.rules[i] = saved } else { store.rules.append(saved) }
                editing = nil
            } onCancel: { editing = nil }
        }
    }

    private func summary(_ rule: ClipboardRule) -> String {
        let apps = rule.apps.isEmpty ? "Every app" : rule.apps.map(AppChoice.name(for:)).joined(separator: ", ")
        return apps + ": " + rule.actions.map(\.title).joined(separator: ", ")
    }
}

private struct ClipboardRuleEditor: View {
    @State var rule: ClipboardRule
    let onSave: (ClipboardRule) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clipboard rule").font(.headline)
            TextField("Name", text: $rule.name)
            GroupBox("Only for copies from") {
                VStack(alignment: .leading, spacing: 6) {
                    if rule.apps.isEmpty { Text("Every app").foregroundStyle(.secondary) }
                    ForEach(rule.apps, id: \.self) { id in
                        HStack { Text(AppChoice.name(for: id)); Spacer(); Button { rule.apps.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove").buttonStyle(.borderless) }
                    }
                    Button("Add an App…") { if let id = AppChoice.choose(), !rule.apps.contains(id) { rule.apps.append(id) } }.controlSize(.small)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            GroupBox("Then") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ClipboardRuleAction.allCases) { action in
                        Toggle(action.title, isOn: Binding(get: { rule.actions.contains(action) }, set: { on in
                            if on { rule.actions.append(action) } else { rule.actions.removeAll { $0 == action } }
                        }))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(rule) }.keyboardShortcut(.defaultAction).disabled(rule.actions.isEmpty || rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18).frame(width: 420)
    }
}

/// Sending the clipboard to your other Macs, on request, through iCloud Drive.
struct SharedClipboardSection: View {
    @EnvironmentObject private var shared: SharedClipboardService
    @State private var phrase = ""
    @State private var problem: String?

    var body: some View {
        Section {
            Toggle("Share the clipboard with my other Macs", isOn: $shared.enabled)
            if shared.enabled {
                if !shared.isAvailable { Label("iCloud Drive is off on this Mac.", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warn) }
                HStack {
                    SecureField(shared.hasPassphrase ? "Passphrase saved. Enter a new one to change it." : "Passphrase (the same on every Mac)", text: $phrase)
                    Button("Save") { problem = shared.setPassphrase(phrase); if problem == nil { phrase = "" } }.disabled(phrase.isEmpty)
                    if shared.hasPassphrase { Button("Remove", role: .destructive) { shared.clearPassphrase() } }
                }
                if let problem { Text(problem).font(.caption).foregroundStyle(Theme.warn) }
                Toggle("Put what arrives on this Mac's clipboard straight away", isOn: $shared.autoReceive)
            }
        } header: { Text("Shared clipboard") } footer: {
            Text("Nothing is sent unless you ask: use the “Send the clipboard to my other Macs” command (give it a shortcut in Keyboard) or type “send clipboard” in the launcher. The text is sealed with your passphrase before it leaves this Mac, passes through your iCloud Drive, and is removed after ten minutes. A Mac with the same passphrase tells you when something arrives; choose “Paste from other Mac” in the launcher to take it. Text only, up to 100 KB.")
        }
    }
}
