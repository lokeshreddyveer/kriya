import AppKit
import SwiftUI

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
    @State private var tab: Tab = .installed
    @State private var query = ""
    @State private var removing: InstalledApp?
    @State private var orphans: [Leftover] = []
    @State private var orphansScanned = false
    @State private var message: String?

    enum Tab: String, CaseIterable, Identifiable {
        case installed = "Installed", leftovers = "Leftovers", updates = "Updates"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .paneTabBar(maxWidth: 340)
                .paneHeader()
            Group {
                switch tab {
                case .installed: installedTab
                case .leftovers: leftoversTab
                case .updates: updatesTab
                }
            }
            .id(tab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.22), value: tab)
        .onAppear { if inventory.apps.isEmpty { inventory.scan() } }
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
        query.isEmpty ? inventory.apps : inventory.apps.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }
    }

    private var installedTab: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $query).textFieldStyle(.plain)
                if inventory.isScanning { ProgressView().controlSize(.small) }
                Button { inventory.scan() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Scan again")
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
                        Text("\(app.version.isEmpty ? "—" : app.version) · \(app.source.label)").font(.caption).foregroundStyle(.secondary)
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
                Button(orphansScanned ? "Scan Again" : "Look for Leftovers") {
                    orphans = inventory.orphans()
                    orphansScanned = true
                }
            } footer: {
                Text("Finds files in your Library named after apps that are no longer installed. Nothing is removed until you choose it, and removed files go to the Trash. Apple's own files are never listed.")
            }
            if orphansScanned {
                Section("Found \(orphans.count)") {
                    if orphans.isEmpty { Text("No leftovers found.").foregroundStyle(.secondary) }
                    LeftoverList(items: orphans) { chosen in
                        let failures = inventory.trash(app: nil, leftovers: chosen)
                        orphans = inventory.orphans()
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
                    Button("Check for Updates") { inventory.checkUpdates() }.disabled(inventory.isCheckingUpdates)
                    if inventory.isCheckingUpdates { ProgressView().controlSize(.small) }
                }
            } footer: {
                Text("Checks apps that update themselves (through their own update feed) and Homebrew apps if Homebrew is installed. Nothing is installed without you pressing its button.")
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
