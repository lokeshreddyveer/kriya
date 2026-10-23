import SwiftUI

/// Settings for the file shelf.
struct ShelfPane: View {
    @EnvironmentObject private var store: ScreenToolsStore
    @ObservedObject private var shelves = ShelfLibraryStore.shared
    let shelf: FileShelf

    private var config: ScreenToolsConfig { store.config }

    var body: some View {
        Form {
            Section {
                Toggle("File shelf", isOn: Binding(get: { config.shelfEnabled }, set: { v in store.update { $0.shelfEnabled = v } }))
                if config.shelfEnabled {
                    Button("Open the Shelf Now") { shelf.show() }
                }
            } header: { Text("File shelf") } footer: {
                Text("A small panel that holds files, text and images while you move them between apps. Drop things on it, then drag them out into any app or folder. Off by default.")
            }

            if config.shelfEnabled {
                Section {
                    Toggle("Open when I shake the pointer while dragging files", isOn: Binding(get: { config.shelfOnShake }, set: { v in store.update { $0.shelfOnShake = v } }))
                    Toggle("Open as soon as I start dragging files", isOn: Binding(get: { config.shelfOnDrag }, set: { v in store.update { $0.shelfOnDrag = v } }))
                    Picker("Appears", selection: Binding(get: { config.shelfEdge }, set: { v in store.update { $0.shelfEdge = v } })) {
                        Text("Next to the pointer").tag(ShelfEdge.pointer)
                        Text("Left edge").tag(ShelfEdge.left)
                        Text("Right edge").tag(ShelfEdge.right)
                        Text("Bottom edge").tag(ShelfEdge.bottom)
                    }
                    SliderRow(title: "Hide after", value: Binding(get: { config.shelfAutoHideSeconds }, set: { v in store.update { $0.shelfAutoHideSeconds = v } }),
                              range: 0...60, format: { $0 < 1 ? "Never" : "\(Int($0)) s" }, help: "How long after the pointer leaves it.")
                } header: { Text("How it opens") } footer: {
                    Text("You can also give the action “Open the file shelf” a shortcut. Drag detection needs no extra permission.")
                }

                Section {
                    if config.shelfExcludedAppIds.isEmpty { Text("The shelf can open from any app.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(config.shelfExcludedAppIds, id: \.self) { id in
                        HStack {
                            Text(AppChoice.name(for: id))
                            Spacer()
                            Button(role: .destructive) { store.update { $0.shelfExcludedAppIds.removeAll { $0 == id } } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                        }
                    }
                    Button {
                        if let id = AppChoice.choose(prompt: "Do not open the shelf in"), !config.shelfExcludedAppIds.contains(id) { store.update { $0.shelfExcludedAppIds.append(id) } }
                    } label: { Label("Leave Out an App", systemImage: "plus") }
                } header: { Text("Apps it leaves alone") }

                Section {
                    Picker("Let go of items after", selection: Binding(get: { shelves.library.expiryDays ?? 0 }, set: { days in shelves.change { $0.expiryDays = days == 0 ? nil : days } })) {
                        Text("Never").tag(0); Text("1 day").tag(1); Text("1 week").tag(7); Text("1 month").tag(30)
                    }
                    ForEach(shelves.library.shelves) { shelf in
                        LabeledContent(shelf.name, value: "\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s")")
                    }
                    LabeledContent("History", value: "\(shelves.library.history.count)")
                    HStack {
                        Button("Clear the History") { shelves.change { $0.clearHistory() } }.disabled(shelves.library.history.isEmpty)
                        Button("Empty Every Shelf", role: .destructive) { shelves.change { library in for shelf in library.shelves { library.clear(shelf.id) } } }
                    }
                    let expiring = shelves.library.expiring(within: 24)
                    if !expiring.isEmpty { Label("\(expiring.count) item\(expiring.count == 1 ? "" : "s") will be let go within a day.", systemImage: "clock.badge.exclamationmark").font(.callout).foregroundStyle(Theme.warn) }
                    let missing = shelves.library.missingFiles(exists: { FileManager.default.fileExists(atPath: $0) })
                    if !missing.isEmpty {
                        HStack {
                            Label("\(missing.count) file\(missing.count == 1 ? " has" : "s have") moved or been deleted.", systemImage: "questionmark.folder").font(.callout)
                            Spacer()
                            Button("Take Them Off") { shelves.change { $0.remove(missing.map(\.id)) } }.controlSize(.small)
                        }
                    }
                    ForEach(Array(shelves.library.duplicatesAcrossShelves().enumerated()), id: \.offset) { _, group in
                        Label("“\(group[0].record.title)” is on \(group.compactMap(\.shelf).joined(separator: " and ")).", systemImage: "square.on.square").font(.callout)
                    }
                } header: { Text("Shelves") } footer: {
                    Text("The shelf keeps what you put on it until you take it off, even after Kriya restarts. Switch shelves, make new ones and search them from the shelf's own header. Items taken off, or let go after the time above, stay in the history for 30 days and can be put back. Files stay where they are; the shelf only remembers where. Pictures and text are kept on this Mac only.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
