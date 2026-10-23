import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension InstalledApp.Source {
    var label: String {
        switch self {
        case .appStore: return "App Store"
        case .sparkle: return "Updates itself"
        case .homebrew: return "Homebrew"
        case .other: return "Other"
        }
    }
}

/// Installed apps: remove one with the files it leaves behind, find leftovers of apps that are gone, and check for updates.
struct AppsPane: View {
    @EnvironmentObject private var inventory: AppInventory
    #if DEBUG
    // For the screenshot harness: KRIYA_SHOT_TAB=install opens this pane on its Install tab.
    @State private var tab: Tab = ProcessInfo.processInfo.environment["KRIYA_SHOT_TAB"] == "install" ? .install : .installed
    #else
    @State private var tab: Tab = .installed
    #endif
    @State private var query = ""
    @State private var sort: Sort = .name
    @State private var removing: InstalledApp?
    @State private var message: String?

    enum Tab: String, CaseIterable, Identifiable {
        case installed = "Installed", install = "Install", leftovers = "Leftovers", updates = "Updates"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case name = "Name", size = "Largest", unused = "Least used"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .paneTabBar(maxWidth: 440)
                .paneHeader()
            Group {
                switch tab {
                case .installed: installedTab
                case .install: InstallTab()
                case .leftovers: leftoversTab
                case .updates: updatesTab
                }
            }
            .id(tab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.22), value: tab)
        .onAppear {
            inventory.startWatching()
            inventory.scan()
            inventory.refreshLeftovers()
            if inventory.lastUpdateCheck.map({ Date().timeIntervalSince($0) > 600 }) ?? true { inventory.checkUpdates() }
        }
        .sheet(item: $removing) { app in
            RemoveSheet(app: app) { failures in
                removing = nil
                message = failures.isEmpty ? "Moved “\(app.name)” to the Trash." : failures.joined(separator: "\n")
            }
        }
        .overlay(alignment: .bottom) {
            if let message {
                Text(message).font(.callout).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { self.message = nil }
            }
        }
        .animation(.smooth(duration: 0.25), value: message)
    }

    // MARK: Installed

    private var filtered: [InstalledApp] {
        let list = query.isEmpty ? inventory.apps : inventory.apps.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }
        switch sort {
        case .name: return list
        case .size: return list.sorted { (inventory.sizes[$0.id] ?? 0) > (inventory.sizes[$1.id] ?? 0) }
        // Never opened comes first, then the longest ago.
        case .unused: return list.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    private func detail(_ app: InstalledApp) -> String {
        var parts = [app.version.isEmpty ? "—" : app.version, app.source.label]
        if let bytes = inventory.sizes[app.id] { parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        if let used = app.lastUsed {
            parts.append("Opened " + RelativeDateTimeFormatter().localizedString(for: used, relativeTo: Date()))
        } else {
            parts.append("Never opened")
        }
        return parts.joined(separator: " · ")
    }

    private var installedTab: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $query).textFieldStyle(.plain)
                if inventory.isScanning { ProgressView().controlSize(.small) }
                Picker("", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
            .padding(.horizontal, 20).padding(.vertical, 10)
            List(filtered) { app in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                        Text(detail(app)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }.controlSize(.small)
                    Button("Remove…") { removing = app }.controlSize(.small).disabled(app.isProtected)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        }
    }

    // MARK: Leftovers

    private var leftoversTab: some View {
        Form {
            Section {
                HStack {
                    Text(inventory.isFindingLeftovers ? "Looking for leftovers…" : "Kriya looks by itself, and again whenever an app is added or removed.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if inventory.isFindingLeftovers { ProgressView().controlSize(.small) }
                }
            } footer: {
                Text("These are files in your Library named after apps that are no longer installed. Nothing is removed until you choose it, and removed files go to the Trash. Apple's own files are never listed.")
            }
            do {
                Section("Found \(inventory.orphanList.count)") {
                    if inventory.orphanList.isEmpty && !inventory.isFindingLeftovers { Text("No leftovers found.").foregroundStyle(.secondary) }
                    LeftoverList(items: inventory.orphanList) { chosen in
                        let failures = inventory.trash(app: nil, leftovers: chosen)
                        inventory.refreshLeftovers()
                        message = failures.isEmpty ? "Moved \(chosen.count) item\(chosen.count == 1 ? "" : "s") to the Trash." : failures.joined(separator: "\n")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Updates

    private var updatesTab: some View {
        Form {
            Section {
                HStack {
                    if inventory.isCheckingUpdates {
                        Text("Checking…").foregroundStyle(.secondary)
                        ProgressView().controlSize(.small)
                    } else if let last = inventory.lastUpdateCheck {
                        Text("Last checked \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())).").foregroundStyle(.secondary)
                    } else {
                        Text("Not checked yet.").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Toggle("Upgrade Homebrew apps automatically", isOn: $inventory.upgradeHomebrewAutomatically)
            } footer: {
                Text("Kriya checks apps that update themselves (through their own update feed) and Homebrew apps when this opens and then every hour. Homebrew apps are upgraded by themselves unless you ignore them or turn this off. An app that updates itself is only listed here, because it installs its own updates.")
            }
            if !inventory.activity.isEmpty {
                Section("What was done") {
                    ForEach(Array(inventory.activity.enumerated()), id: \.offset) { _, line in Text(line).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
            }
            let visible = inventory.updates.filter { !inventory.ignoredUpdates.contains($0.appName) }
            Section("Updates available") {
                if visible.isEmpty { Text(inventory.isCheckingUpdates ? "Checking…" : "Everything that could be checked is up to date.").foregroundStyle(.secondary) }
                ForEach(visible) { update in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(update.appName)
                            Text("\(update.installed) → \(update.latest)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        switch update.action {
                        case .open(let url): Button("Open Page") { NSWorkspace.shared.open(url) }.controlSize(.small)
                        case .brew(let token): Button("Upgrade") { inventory.runBrewUpgrade(token) { message = $0 } }.controlSize(.small)
                        case .appStore: Button("App Store") { NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!) }.controlSize(.small)
                        }
                        Button("Ignore") { inventory.ignoredUpdates.insert(update.appName) }.controlSize(.small).buttonStyle(.borderless)
                    }
                }
            }
            if let note = inventory.updateNote { Section { Text(note).font(.callout).foregroundStyle(.secondary) } }
            if !inventory.ignoredUpdates.isEmpty {
                Section("Ignored") {
                    ForEach(Array(inventory.ignoredUpdates).sorted(), id: \.self) { name in
                        HStack { Text(name); Spacer(); Button("Stop Ignoring") { inventory.ignoredUpdates.remove(name) }.controlSize(.small) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A list of files with a tick for each, and a button that moves the ticked ones to the Trash.
private struct LeftoverList: View {
    let items: [Leftover]
    let onRemove: ([Leftover]) -> Void
    @State private var chosen = Set<String>()

    var body: some View {
        ForEach(items) { item in
            HStack {
                Toggle("", isOn: Binding(get: { chosen.contains(item.id) }, set: { on in if on { chosen.insert(item.id) } else { chosen.remove(item.id) } })).labelsHidden()
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.url.lastPathComponent).lineLimit(1)
                    Text(item.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
            }
        }
        if !items.isEmpty {
            HStack {
                Button("Select All") { chosen = Set(items.map(\.id)) }.controlSize(.small)
                Spacer()
                Button("Move \(chosen.count) to Trash") {
                    onRemove(items.filter { chosen.contains($0.id) })
                    chosen.removeAll()
                }
                .disabled(chosen.isEmpty)
            }
        }
    }
}

/// The preview before an app is removed: the app and every file found for it, each with a tick.
private struct RemoveSheet: View {
    let app: InstalledApp
    let onDone: ([String]) -> Void
    @EnvironmentObject private var inventory: AppInventory
    @State private var items: [Leftover] = []
    @State private var chosen = Set<String>()
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading) {
                    Text("Remove “\(app.name)”").font(.headline)
                    Text("Everything ticked goes to the Trash, so you can put it back.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            Divider()
            List {
                Section("The app") {
                    Text(app.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                }
                Section(loaded ? "Files it left in your Library (\(items.count))" : "Looking for its files…") {
                    ForEach(items) { item in
                        HStack {
                            Toggle("", isOn: Binding(get: { chosen.contains(item.id) }, set: { on in if on { chosen.insert(item.id) } else { chosen.remove(item.id) } }))
                                .labelsHidden().disabled(item.needsAdmin)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                                if item.needsAdmin { Text("Outside your Library: kept, remove it yourself if you want it gone").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("\(chosen.count) file\(chosen.count == 1 ? "" : "s") + the app").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onDone(["Nothing was removed."]) }.keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) {
                    onDone(inventory.trash(app: app, leftovers: items.filter { chosen.contains($0.id) }))
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 520)
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let found = inventory.leftovers(for: app)
                DispatchQueue.main.async {
                    items = found
                    chosen = Set(found.filter { !$0.needsAdmin }.map(\.id))
                    loaded = true
                }
            }
        }
    }
}


/// Finding and installing apps with Homebrew, and saving or reinstalling a list of them. Every command is shown before it
/// runs, and what Homebrew says while it works is kept below.
private struct InstallTab: View {
    @EnvironmentObject private var brew: HomebrewManager
    @EnvironmentObject private var inventory: AppInventory
    @State private var query = ""
    @State private var missing: [String] = []
    @State private var chosen = Set<String>()
    @State private var message: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searching: Bool

    private var typed: String { query.trimmingCharacters(in: .whitespaces) }
    /// What the list shows: search results while there is a search, otherwise some well-known apps.
    private var shown: [String] { typed.isEmpty ? HomebrewParsing.featured : Array(brew.results.prefix(30)) }

    var body: some View {
        if brew.brewPath == nil {
            notInstalled
        } else {
            VStack(spacing: 0) {
                searchField
                if brew.isRunning || !brew.log.isEmpty { progress }
                List {
                    Section {
                        if shown.isEmpty, typed.count > 0, !brew.isSearching { Text(brew.status ?? "No apps match.").foregroundStyle(.secondary) }
                        ForEach(shown, id: \.self) { appRow($0) }
                    } header: {
                        Text(typed.isEmpty ? "Popular apps" : (brew.isSearching ? "Searching…" : "Results"))
                    } footer: {
                        Text(typed.isEmpty
                             ? "Type above to search every app Homebrew offers. Kriya shows you the exact command and asks before anything is installed."
                             : "Installing runs “brew install --cask …” for you. Some apps ask for your password to finish; if Homebrew stops for that, run the command in Terminal.")
                    }
                    Section {
                        Button("Save My Apps as a List…") { exportList() }
                        Button("Reinstall from a List…") { importList() }
                        if !missing.isEmpty {
                            ForEach(missing, id: \.self) { token in
                                Toggle(token, isOn: Binding(get: { chosen.contains(token) }, set: { on in if on { chosen.insert(token) } else { chosen.remove(token) } }))
                            }
                            HStack {
                                Button("Select All") { chosen = Set(missing) }.controlSize(.small)
                                Spacer()
                                Button("Install \(chosen.count)…") { confirmAndInstall(missing.filter { chosen.contains($0) }) }.disabled(chosen.isEmpty || brew.isRunning)
                            }
                        } else if let message {
                            Text(message).font(.callout).foregroundStyle(.secondary)
                        }
                    } header: { Text("Move to another Mac") } footer: {
                        Text("A list holds the names of the Homebrew apps installed here. Open it on another Mac to see which ones are missing and install the ones you pick. System apps are never part of it.")
                    }
                }
                .animation(.smooth(duration: 0.2), value: shown)
                .animation(.smooth(duration: 0.2), value: brew.details.count)
            }
            .onAppear { brew.locate(); searching = true; brew.describe(HomebrewParsing.featured) }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if brew.brewPath == nil { brew.locate() }
                }
            }
        }
    }

    private var notInstalled: some View {
        Form {
            Section {
                Text("Homebrew is not installed on this Mac.")
                HStack {
                    Link("About Homebrew", destination: URL(string: "https://brew.sh")!)
                    Spacer()
                    Text("Kriya notices when it is installed.").font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Homebrew is a free tool that installs Mac apps from a list, without dragging them from a disk image. Kriya uses it, if you have it, to find and install apps. It never installs Homebrew itself.")
            }
        }
        .formStyle(.grouped)
        .onAppear { brew.locate() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if brew.brewPath == nil { brew.locate() }
            }
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search for an app to install, such as Firefox or VLC", text: $query)
                .textFieldStyle(.plain).focused($searching)
                .onSubmit { startSearch(immediately: true) }
                .onChange(of: query) { _, _ in startSearch(immediately: false) }
            if brew.isSearching { ProgressView().controlSize(.small) }
            if !query.isEmpty {
                Button { query = ""; brew.clearSearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    /// Searches a moment after typing stops, so each letter does not start its own search.
    private func startSearch(immediately: Bool) {
        searchTask?.cancel()
        let text = typed
        guard !text.isEmpty else { brew.clearSearch(); return }
        searchTask = Task {
            if !immediately { try? await Task.sleep(nanoseconds: 350_000_000) }
            guard !Task.isCancelled else { return }
            brew.search(text)
        }
    }

    private func appRow(_ token: String) -> some View {
        let info = brew.details[token]
        return HStack(spacing: 12) {
            Image(systemName: "shippingbox").font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info?.name ?? token).font(.headline)
                    if let version = info?.version, !version.isEmpty { Text(version).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                }
                Text(info?.description.isEmpty == false ? info!.description : token).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let page = info.flatMap({ URL(string: $0.homepage) }), page.scheme == "https" {
                Link(destination: page) { Image(systemName: "safari") }.help("Open the app's website")
            }
            if brew.installed.contains(token) {
                StateBadge(text: "Installed", color: Theme.ok)
            } else {
                Button("Install…") { confirmAndInstall([token]) }.controlSize(.small).disabled(brew.isRunning)
            }
        }
        .padding(.vertical, 3)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if brew.isRunning { ProgressView().controlSize(.small); Text("Working…").foregroundStyle(.secondary) } else { Text("What Homebrew said").foregroundStyle(.secondary) }
                Spacer()
                if brew.isRunning { Button("Stop") { brew.cancel() }.controlSize(.small) }
            }
            ScrollView {
                Text(brew.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 110)
        }
        .padding(.horizontal, 20).padding(.bottom, 8)
        .transition(.opacity)
    }

    /// Shows the exact commands and installs only if the person agrees.
    private func confirmAndInstall(_ tokens: [String]) {
        let alert = NSAlert()
        alert.messageText = tokens.count == 1 ? "Install \(tokens[0])?" : "Install \(tokens.count) apps?"
        alert.informativeText = "These commands will run:\n\n" + tokens.map { HomebrewManager.command(install: $0) }.joined(separator: "\n")
            + "\n\nSome apps ask for your password to finish. If Homebrew stops for that, run the command in Terminal."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { brew.install(tokens) }
    }

    private func exportList() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Kriya apps.json"
        panel.message = "Save the list of Homebrew apps installed on this Mac."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try brew.exportList(to: url, apps: inventory.apps.map { ($0.name, $0.bundleID) })
            message = "Saved \(brew.installed.count) apps to \(url.lastPathComponent)."
        } catch {
            message = error.localizedDescription
        }
    }

    private func importList() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a list saved by Kriya."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let wanted = try brew.readList(from: url)
            brew.refreshInstalled()
            missing = HomebrewParsing.missing(wanted: wanted, installed: brew.installed)
            chosen = Set(missing)
            message = missing.isEmpty ? "Everything in that list is already installed." : nil
        } catch {
            message = error.localizedDescription
        }
    }
}
