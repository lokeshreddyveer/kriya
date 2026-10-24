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
    @ObservedObject private var updateStore = UpdateHistoryStore.shared
    #if DEBUG
    // For the screenshot harness: KRIYA_SHOT_TAB=install opens this pane on its Install tab.
    @State private var tab: Tab = ProcessInfo.processInfo.environment["KRIYA_SHOT_TAB"] == "install" ? .install : .installed
    #else
    @State private var tab: Tab = .installed
    #endif
    @State private var query = ""
    @State private var sort: Sort = .name
    @State private var removing: InstalledApp?
    @State private var resetting: InstalledApp?
    @State private var message: String?
    @State private var unusedMonths = 0
    @State private var backups: [AppBackup.Entry] = AppBackup.list()
    @State private var dropTargeted = false
    @State private var discarding: AppBackup.Entry?

    enum Tab: String, CaseIterable, Identifiable {
        case installed = "Installed", install = "Install", leftovers = "Leftovers", updates = "Updates", background = "Background"
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
                case .background: BackgroundItemsTab(message: $message)
                }
            }
            .id(tab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.22), value: tab)
        .tabHint($tab)
        .onAppear {
            inventory.startWatching()
            inventory.scan()
            inventory.refreshLeftovers()
            if inventory.lastUpdateCheck.map({ Date().timeIntervalSince($0) > 600 }) ?? true { inventory.checkUpdates() }
        }
        .confirmationDialog("Delete the saved copy of \(discarding?.appName ?? "") \(discarding?.version ?? "")?", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }), titleVisibility: .visible) {
            Button("Delete the Copy", role: .destructive) {
                if let entry = discarding { try? FileManager.default.removeItem(at: entry.folder); backups = AppBackup.list() }
                discarding = nil
            }
            Button("Cancel", role: .cancel) { discarding = nil }
        } message: { Text("It is erased, not moved to the Trash, and the app can no longer be rolled back to this version.") }
        .sheet(item: $removing) { app in
            RemoveSheet(app: app) { failures in
                removing = nil
                message = failures.isEmpty ? "Moved “\(app.name)” to the Trash." : failures.joined(separator: "\n")
            }
        }
        .sheet(item: $resetting) { app in
            RemoveSheet(app: app, resetOnly: true) { failures in
                resetting = nil
                message = failures.isEmpty ? "Reset “\(app.name)”: its saved data went to the Trash." : failures.joined(separator: "\n")
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
        var list = query.isEmpty ? inventory.apps : inventory.apps.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) || $0.info.source.title.localizedCaseInsensitiveContains(query) }
        if unusedMonths > 0 {
            let names = Set(AppInventoryTools.unused(list.map { ($0.name, $0.lastUsed) }, months: unusedMonths))
            list = list.filter { names.contains($0.name) }
        }
        switch sort {
        case .name: return list
        case .size: return list.sorted { (inventory.sizes[$0.id] ?? 0) > (inventory.sizes[$1.id] ?? 0) }
        // Never opened comes first, then the longest ago.
        case .unused: return list.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    private var duplicateIDs: Set<String> { Set(AppInventoryTools.duplicates(inventory.apps.map { ($0.bundleID, $0.url.path) }).keys) }

    private func badge(_ text: String, tint: Color = .secondary, help: String = "") -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(tint.opacity(0.14), in: Capsule()).foregroundStyle(tint).help(help)
    }

    private func badges(_ app: InstalledApp) -> some View {
        HStack(spacing: 4) {
            badge(app.info.source.title + (app.info.confidence == .verified ? "" : " · " + app.info.confidence.title.lowercased()), tint: app.info.confidence == .unknown ? .orange : .accentColor, help: app.info.why)
            if let arch = AppArchitecture.badge(app.architectures) { badge(arch, tint: arch == "Intel only" ? .orange : .secondary, help: "The processors its program supports.") }
            if duplicateIDs.contains(app.bundleID) { badge("Duplicate", tint: .orange, help: "The same app is installed more than once.") }
            if AppInventoryTools.isUnusualLocation(app.url.path) { badge("Unusual place", tint: .orange, help: "Not in an Applications folder: \(app.url.deletingLastPathComponent().path).") }
        }
    }

    /// The inventory as a file: CSV, JSON or Markdown.
    private func export(_ format: String) {
        let rows = filtered.map { AppInventoryTools.Row(name: $0.name, bundleID: $0.bundleID, version: $0.version, source: $0.info.source.title, confidence: $0.info.confidence.title, architecture: AppArchitecture.badge($0.architectures) ?? "—", path: $0.url.path, bytes: inventory.sizes[$0.id] ?? 0, lastOpened: $0.lastUsed) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "kriya-apps.\(format)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data: Data? = format == "csv" ? Data(AppInventoryTools.csv(rows).utf8) : format == "json" ? AppInventoryTools.json(rows) : Data(AppInventoryTools.markdown(rows).utf8)
        do { try (data ?? Data()).write(to: url, options: .atomic); message = "Saved \(rows.count) apps to \(url.lastPathComponent)." } catch { message = "Could not save the file." }
    }

    /// An app file dropped on the list opens the same reviewed removal as the Remove button.
    private func dropped(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension == "app" else { DispatchQueue.main.async { message = "Drop an app (a .app file) to remove it." }; return }
            DispatchQueue.main.async {
                if let app = inventory.apps.first(where: { $0.url.path == url.path }) ?? inventory.apps.first(where: { $0.url.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path }) { removing = app }
                else { message = "“\(url.deletingPathExtension().lastPathComponent)” is not in an Applications folder Kriya watches." }
            }
        }
        return true
    }

    private func detail(_ app: InstalledApp) -> String {
        var parts = [app.version.isEmpty ? "—" : app.version]
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
                Picker("Not opened for", selection: $unusedMonths) { Text("Any time").tag(0); Text("6 months").tag(6); Text("12 months").tag(12); Text("24 months").tag(24) }
                    .pickerStyle(.menu).fixedSize().help("Only apps not opened for this long")
                Picker("Sort by", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                Menu {
                    Button("CSV…") { export("csv") }
                    Button("JSON…") { export("json") }
                    Button("Markdown…") { export("md") }
                } label: { Image(systemName: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize().help("Export this list")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
            .padding(.horizontal, 20).padding(.vertical, 10)
            List(filtered) { app in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) { Text(app.name); badges(app) }
                        Text(detail(app)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }.controlSize(.small)
                    Button("Check Signature") { checkTrust(app) }.controlSize(.small)
                    Button("Reset…") { resetting = app }.controlSize(.small).disabled(app.isProtected).help("Remove its saved data and settings but keep the app")
                    Button("Remove…") { removing = app }.controlSize(.small).disabled(app.isProtected)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6])).padding(6).allowsHitTesting(false) } }
            .animation(.easeInOut(duration: 0.15), value: dropTargeted)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: dropped)
        }
    }

    private func checkTrust(_ app: InstalledApp) {
        DispatchQueue.global(qos: .userInitiated).async {
            func output(_ path: String, _ args: [String]) -> String {
                do { return try ToolRunner.run(path, args, timeout: 15) } catch { return (error as? FileActionError)?.message ?? "\(error)" }
            }
            let codesign = output("/usr/bin/codesign", ["-dv", "--verbose=2", app.url.path])
            let spctl = output("/usr/sbin/spctl", ["-a", "-vv", app.url.path])
            let trust = AppTrust.parse(codesign: codesign, spctl: spctl)
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "\(app.name): \(trust.title)"
                alert.informativeText = [trust.signer.map { "Signed by \($0)." }, trust.teamID.map { "Team \($0)." }, trust.isConcerning ? "Only open it if you trust where it came from." : nil].compactMap { $0 }.joined(separator: " ")
                alert.runModal()
            }
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

    /// Which source an update came from: Homebrew installs, App Store handoffs, and everything else is a feed or developer page.
    private static func source(of update: AppUpdate) -> AppUpdateSource {
        switch update.action {
        case .brew: return .homebrew
        case .appStore, .openStore: return .appStore
        case .open(let url): return (url.host ?? "").contains("github") ? .github : .sparkle
        case .openApp: return .sparkle
        }
    }

    /// Opens the App Store app. Newer macOS has no Updates address to jump to, so the old one is tried and the app opened if it fails.
    private func openAppStore() {
        if let url = URL(string: "macappstore://showUpdatesPage"), NSWorkspace.shared.open(url) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.AppStore") { NSWorkspace.shared.open(app) }
    }

    private var updatesTab: some View {
        Form {
            Section {
                HStack {
                    if inventory.isCheckingUpdates {
                        ProgressView().controlSize(.small)
                        Text(inventory.checkStage ?? "Checking…").foregroundStyle(.secondary)
                    } else if let last = inventory.lastUpdateCheck {
                        Text("Last checked \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())).").foregroundStyle(.secondary)
                    } else {
                        Text("Not checked yet.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if inventory.isCheckingUpdates {
                        Button("Stop") { inventory.cancelCheck() }.controlSize(.small)
                    } else {
                        Button("Check Now") { inventory.checkUpdates() }.controlSize(.small)
                    }
                }
                if let failed = inventory.lastFailedCheck, !inventory.isCheckingUpdates {
                    Text("Last problem, \(RelativeDateTimeFormatter().localizedString(for: failed.at, relativeTo: Date())): \(failed.note)").font(.caption).foregroundStyle(.orange)
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
            if !updateStore.queue.items.isEmpty {
                Section {
                    ForEach(updateStore.queue.items) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.token)
                                Text(item.attempts >= UpdateRetryQueue.maxAttempts ? "Gave up after \(item.attempts) tries: \(item.lastError)" : "Try \(item.attempts + 1) at \(item.nextAttempt.formatted(date: .omitted, time: .shortened)). \(item.lastError)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button("Retry") { updateStore.retryNow(item.token); inventory.retryDueUpgrades() }.controlSize(.small)
                        }
                    }
                    Button("Retry All") { updateStore.retryAll(); inventory.retryDueUpgrades() }.controlSize(.small)
                } header: { Text("Waiting to try again") } footer: { Text("Each failed upgrade is tried again after 1, 2, 4, 8 minutes, then gives up. Retry starts it now. If it needs your password, use Run in Terminal on the Install tab.") }
            }
            if !updateStore.history.entries.isEmpty {
                Section {
                    ForEach(updateStore.history.entries.prefix(10)) { entry in
                        HStack {
                            Image(systemName: entry.ok ? "checkmark.circle" : "xmark.circle").foregroundStyle(entry.ok ? Theme.ok : Theme.danger)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.app)
                                Text("\(entry.from.isEmpty ? "" : "\(entry.from) → ")\(entry.to) · \(entry.source)\(entry.note.isEmpty ? "" : " · \(entry.note)")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(entry.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Clear History") { updateStore.clearHistory() }.controlSize(.small)
                } header: { Text("Update history") }
            }
            let visible = inventory.updates.filter { !inventory.ignoredUpdates.contains($0.appName) && !inventory.ignoredSources.contains(Self.source(of: $0).rawValue) }
            Section {
                if visible.isEmpty { Text(inventory.isCheckingUpdates ? "Checking…" : "Everything that could be checked is up to date.").foregroundStyle(.secondary) }
                ForEach(visible) { update in
                    let pinned = inventory.pinnedUpdates.contains(update.appName)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) { Text(update.appName); badge(Self.source(of: update).title, tint: .accentColor, help: "Where this update comes from."); if pinned { badge("Pinned", tint: .orange, help: "Held at this version. Kriya will not install the update.") } }
                            Text("\(update.installed) → \(update.latest)").font(.caption).foregroundStyle(.secondary)
                            if case .open = update.action { Text("Opens the developer's page; Kriya does not install this one for you.").font(.caption2).foregroundStyle(.tertiary) }
                        }
                        Spacer()
                        switch update.action {
                        case .open(let url): Button("Open Page") { NSWorkspace.shared.open(url) }.controlSize(.small)
                        case .brew(let token):
                            if inventory.upgrading.contains(token) {
                                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Upgrading…").font(.caption).foregroundStyle(.secondary) }
                            } else if pinned {
                                Text("Held").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("Upgrade") { inventory.runBrewUpgrade(token) { message = $0; backups = AppBackup.list() } }.controlSize(.small)
                            }
                        case .appStore: Button("App Store") { openAppStore() }.controlSize(.small)
                        case .openStore(let url): Button("Open in App Store") { if !NSWorkspace.shared.open(url) { openAppStore() } }.controlSize(.small)
                        case .openApp(let url): Button("Open App") { NSWorkspace.shared.open(url) }.controlSize(.small).help("It has no page of its own. Open it and use its own Check for Updates.")
                        }
                        Button(pinned ? "Unpin" : "Pin") { if pinned { inventory.pinnedUpdates.remove(update.appName) } else { inventory.pinnedUpdates.insert(update.appName) } }.controlSize(.small).buttonStyle(.borderless)
                        Button("Ignore") { inventory.ignoredUpdates.insert(update.appName) }.controlSize(.small).buttonStyle(.borderless)
                    }
                }
            } header: { Text("Updates available") } footer: {
                Text("Only Homebrew apps are ever installed by Kriya, and only when automatic upgrades are on. Pin holds an app at its version. Every other source opens the developer's page or the App Store.")
            }
            Section {
                Toggle("Keep a copy of a Homebrew app before upgrading it", isOn: $inventory.backupBeforeUpgrade)
                if backups.isEmpty { Text("No saved copies yet.").font(.callout).foregroundStyle(.secondary) }
                ForEach(backups) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) { Text("\(entry.appName) \(entry.version)"); Text("Saved \(entry.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Put Back") { message = AppBackup.restore(entry) ?? "Put back “\(entry.appName)” \(entry.version). The newer one is in the Trash."; inventory.scan() }.controlSize(.small)
                        Button { discarding = entry } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).accessibilityLabel("Delete the saved copy of \(entry.appName) \(entry.version)")
                    }
                }
            } header: { Text("Rollback") } footer: {
                Text("Copies are kept in Kriya's own folder, the newest two per app, for apps under 3 GB. Putting one back moves the current version to the Trash first.")
            }
            Section {
                ForEach(AppUpdateSource.allCases.filter { [.sparkle, .github, .electron, .homebrew].contains($0) }, id: \.self) { source in
                    Toggle("Hide updates from \(source.title)", isOn: Binding(get: { inventory.ignoredSources.contains(source.rawValue) }, set: { on in if on { inventory.ignoredSources.insert(source.rawValue) } else { inventory.ignoredSources.remove(source.rawValue) } }))
                }
            } header: { Text("By source") }
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
                Toggle("Remove this file", isOn: Binding(get: { chosen.contains(item.id) }, set: { on in if on { chosen.insert(item.id) } else { chosen.remove(item.id) } })).labelsHidden()
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

extension RemoveSheet {
    /// Zips the support files into Documents/Kriya Removed Apps. Returns a line to show; nothing is removed here.
    static func archive(app: InstalledApp, leftovers: [Leftover]) -> [String] {
        let verdict = RemovalArchive.verdict(sizes: leftovers.map(\.bytes))
        guard verdict.archive else { return [verdict.reason ?? "Nothing was zipped."] }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Kriya Removed Apps", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(RemovalArchive.fileName(appName: app.name, at: Date()))
        do {
            _ = try ToolRunner.run("/usr/bin/zip", ["-r", "-q", target.path] + leftovers.map(\.url.path), timeout: 300)
            return ["Kept a zip of its support files: \(target.lastPathComponent) in Documents/Kriya Removed Apps."]
        } catch {
            return ["Could not make the zip, so nothing was zipped: \((error as? FileActionError)?.message ?? error.localizedDescription)"]
        }
    }
}

/// The preview before an app is removed: the app and every file found for it, each with a tick.
struct RemoveSheet: View {
    let app: InstalledApp
    /// Keeps the app and moves only its saved data and settings to the Trash.
    var resetOnly = false
    let onDone: ([String]) -> Void
    @EnvironmentObject private var inventory: AppInventory
    @State private var items: [Leftover] = []
    @State private var chosen = Set<String>()
    @State private var loaded = false
    @State private var keepZip = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading) {
                    Text(resetOnly ? "Reset “\(app.name)”" : "Remove “\(app.name)”").font(.headline)
                    Text(resetOnly ? "The app stays. Its ticked saved data goes to the Trash, so it starts fresh next time and you can put it back." : "Everything ticked goes to the Trash, so you can put it back.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            Divider()
            List {
                if !resetOnly {
                    Section("The app") {
                        Text(app.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    }
                }
                Section(loaded ? "Files it left in your Library (\(items.count))" : "Looking for its files…") {
                    ForEach(items) { item in
                        HStack {
                            Toggle("Remove this file", isOn: Binding(get: { chosen.contains(item.id) }, set: { on in if on { chosen.insert(item.id) } else { chosen.remove(item.id) } }))
                                .labelsHidden().disabled(item.needsAdmin)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                                if item.needsAdmin { Text("Outside your Library: kept, remove it yourself if you want it gone").font(.caption).foregroundStyle(.secondary) }
                                else { Text(item.evidence.title + (item.evidence.preselected ? "" : " — not ticked, check it is really this app's")).font(.caption).foregroundStyle(item.evidence.preselected ? Color.secondary : Color.orange) }
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Toggle("Keep a zip of the ticked support files in Documents first", isOn: $keepZip).font(.caption)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 8)
            HStack {
                Text("\(chosen.count) file\(chosen.count == 1 ? "" : "s")\(resetOnly ? "" : " + the app")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onDone(["Nothing was removed."]) }.keyboardShortcut(.cancelAction)
                Button(resetOnly ? "Reset App Data" : "Move to Trash", role: .destructive) {
                    let picked = items.filter { chosen.contains($0.id) }
                    var notes: [String] = []
                    if keepZip { notes += Self.archive(app: app, leftovers: picked) }
                    onDone(notes + inventory.trash(app: resetOnly ? nil : app, leftovers: picked))
                }
            }
            .padding(12)
        }
        .frame(width: 560, height: 520)
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let found = inventory.leftovers(for: app)
                DispatchQueue.main.async {
                    items = found
                    // Only exact bundle-identifier matches start ticked; a name match is shown but left for the person to decide.
                    chosen = Set(found.filter { !$0.needsAdmin && $0.evidence.preselected }.map(\.id))
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
    @State private var kind: HomebrewParsing.Kind = .cask
    @FocusState private var searching: Bool

    private var typed: String { query.trimmingCharacters(in: .whitespaces) }
    private var featured: [String] { kind == .cask ? HomebrewParsing.featured : HomebrewParsing.featuredTools }
    /// What the list shows: search results while there is a search, otherwise some well-known ones.
    private var shown: [String] { typed.isEmpty ? featured : Array((kind == .cask ? brew.results : brew.formulaResults).prefix(30)) }
    private var installedNames: [String] { kind == .cask ? brew.installed : brew.installedFormulae }
    private var noun: String { kind == .cask ? "apps" : "command-line tools" }

    var body: some View {
        if brew.brewPath == nil {
            notInstalled
        } else {
            VStack(spacing: 0) {
                Picker("Kind", selection: $kind) { ForEach(HomebrewParsing.Kind.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320).padding(.top, 10)
                    .onChange(of: kind) { _, new in
                        brew.clearSearch()
                        brew.describe(new == .cask ? HomebrewParsing.featured : HomebrewParsing.featuredTools, kind: new)
                        if !typed.isEmpty { startSearch(immediately: true) }
                    }
                searchField
                if brew.isRunning || !brew.log.isEmpty { progress }
                List {
                    Section {
                        if shown.isEmpty, typed.count > 0, !brew.isSearching { Text(brew.status ?? "No \(noun) match.").foregroundStyle(.secondary) }
                        ForEach(shown, id: \.self) { appRow($0) }
                    } header: {
                        Text(typed.isEmpty ? "Popular \(noun)" : (brew.isSearching ? "Searching…" : "Results"))
                    } footer: {
                        Text(typed.isEmpty
                             ? "Type above to search every \(kind == .cask ? "app" : "command-line tool") Homebrew offers. Kriya shows you the exact command and asks before anything is installed."
                             : kind == .cask
                             ? "Installing runs “brew install --cask …” for you. Some apps ask for your password to finish; if Homebrew stops for that, run the command in Terminal."
                             : "Installing runs “brew install …” for you. A tool is put in Homebrew's folder and added to your PATH by Homebrew; Kriya does not change your shell.")
                    }
                    if kind == .cask {
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
                ForEach(HomebrewDiagnosis.lines(appleSilicon: HomebrewDiagnosis.runningOnAppleSilicon, foundAt: nil, optHomebrewExists: FileManager.default.fileExists(atPath: "/opt/homebrew"),
                                                usrLocalExists: FileManager.default.fileExists(atPath: "/usr/local/bin"), pathVariable: ProcessInfo.processInfo.environment["PATH"] ?? "").dropFirst(), id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.secondary)
                }
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
                Button { query = ""; brew.clearSearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).accessibilityLabel("Clear the search")
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
            brew.search(text, kind: kind)
        }
    }

    private func appRow(_ token: String) -> some View {
        let info = kind == .cask ? brew.details[token] : brew.formulaDetails[token]
        return HStack(spacing: 12) {
            Image(systemName: kind == .cask ? "shippingbox" : "terminal").font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info?.name ?? token).font(.headline)
                    if let version = info?.version, !version.isEmpty { Text(version).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                }
                Text(info?.description.isEmpty == false ? info!.description : token).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let page = info.flatMap({ URL(string: $0.homepage) }), page.scheme == "https" {
                Link(destination: page) { Image(systemName: "safari") }.help("Open the app's website").accessibilityLabel("Open the app's website")
            }
            if installedNames.contains(token) {
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
                if brew.isRunning {
                    if let fraction = UpdateProgress.fraction(done: brew.installDone, total: brew.installTotal) {
                        ProgressView(value: fraction).frame(width: 90).animation(.smooth(duration: 0.25), value: fraction)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(UpdateProgress.label(done: brew.installDone, total: brew.installTotal, current: brew.currentCask)).foregroundStyle(.secondary)
                        if let stage = brew.stage { Text(stage).font(.caption).foregroundStyle(stage.contains("password") || stage.hasPrefix("No news") ? .orange : .secondary) }
                    }
                } else {
                    Text("What Homebrew said").foregroundStyle(.secondary)
                }
                Spacer()
                if !brew.isRunning, !brew.log.isEmpty {
                    Button("Show Log File") { NSWorkspace.shared.activateFileViewerSelecting([HomebrewManager.logFileURL]) }.controlSize(.small)
                }
                if brew.isRunning, let cask = brew.currentCask {
                    Button("Run in Terminal") { HomebrewManager.runInTerminal(install: cask, kind: kind) }.controlSize(.small)
                        .help("Opens Terminal with the install command, for apps that need your password")
                }
                if brew.isRunning { Button("Stop") { brew.cancel() }.controlSize(.small) }
            }
            if !brew.isRunning, !brew.failures.isEmpty {
                ForEach(brew.failures.keys.sorted(), id: \.self) { token in
                    HStack {
                        Label("\(token): \(brew.failures[token] ?? "")", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Try Again") { confirmAndInstall([token]) }.controlSize(.small)
                        Button("Run in Terminal") { HomebrewManager.runInTerminal(install: token, kind: kind) }.controlSize(.small)
                    }
                }
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
        alert.messageText = tokens.count == 1 ? "Install \(tokens[0])?" : "Install \(tokens.count) \(noun)?"
        alert.informativeText = "These commands will run:\n\n" + tokens.map { HomebrewManager.command(install: $0, kind: kind) }.joined(separator: "\n")
            + (kind == .cask ? "\n\nSome apps ask for your password to finish. If Homebrew stops for that, run the command in Terminal." : "\n\nHomebrew may build a tool from its source if no ready-made one exists, which can take a while.")
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { brew.install(tokens, kind: kind) }
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


/// The launch agents and daemons on this Mac, read-only, with the ones whose program is gone listed first.
private struct BackgroundItemsTab: View {
    @Binding var message: String?
    @State private var items: [LaunchItem.Scope: [LaunchItem]] = [:]
    @State private var query = ""
    @State private var loading = false
    @State private var confirming: LaunchItem?

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search background items", text: $query).textFieldStyle(.plain)
                    if loading { ProgressView().controlSize(.small) }
                    Button("Refresh") { load() }.controlSize(.small)
                }
            } footer: {
                Text("These are the helpers macOS starts for apps and for the system, read from their property lists. Kriya only lists them. An item whose program is missing can only fail each time it starts; for those in your own folder you can move the file to the Trash. Login items you turned on in System Settings are not shown here.")
            }
            ForEach(LaunchItem.Scope.allCases) { scope in
                let list = (items[scope] ?? []).filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || ($0.program ?? "").localizedCaseInsensitiveContains(query) }
                Section {
                    if list.isEmpty { Text(loading ? "Looking…" : "None.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(list) { item in row(item) }
                } header: {
                    Text("\(scope.title) (\(list.count))")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { load() }
        .confirmationDialog("Move “\(confirming?.fileName ?? "")” to the Trash?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let item = confirming { trash(item) }
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("Its program is missing, so it cannot run. You can get it back from the Trash.")
        }
    }

    private func row(_ item: LaunchItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.isOrphaned ? "exclamationmark.triangle.fill" : "gearshape.2").foregroundStyle(item.isOrphaned ? Theme.warn : .secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).lineLimit(1).truncationMode(.middle)
                Text([item.ownerApp, item.when, item.disabled ? "switched off" : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let program = item.program {
                    Text(item.isOrphaned ? "Missing: \(program)" : program).font(.caption.monospaced()).foregroundStyle(item.isOrphaned ? Theme.warn : .secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Show in Finder").accessibilityLabel("Show in Finder")
            if item.isOrphaned, item.scope == .user {
                Button { confirming = item } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Move to Trash").accessibilityLabel("Move to Trash")
            }
        }
    }

    private func load() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [LaunchItem.Scope: [LaunchItem]] = [:]
            for scope in LaunchItem.Scope.allCases { found[scope] = LaunchItems.scan(scope) }
            DispatchQueue.main.async {
                items = found
                loading = false
            }
        }
    }

    private func trash(_ item: LaunchItem) {
        // Only a file in the person's own LaunchAgents folder is ever touched.
        guard item.scope == .user, item.path.hasPrefix(LaunchItem.Scope.user.folder + "/") else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
            AuditLog.shared.record(.files, "Moved launch agent \(item.fileName) to the Trash")
            message = "Moved “\(item.fileName)” to the Trash. It stops being started at the next login."
            load()
        } catch {
            message = "“\(item.fileName)” could not be moved to the Trash."
        }
    }
}
