import SwiftUI

/// Settings for the file shelf.
struct ShelfPane: View {
    @EnvironmentObject private var store: ScreenToolsStore
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
                            Button(role: .destructive) { store.update { $0.shelfExcludedAppIds.removeAll { $0 == id } } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                    Button {
                        if let id = AppChoice.choose(prompt: "Do not open the shelf in"), !config.shelfExcludedAppIds.contains(id) { store.update { $0.shelfExcludedAppIds.append(id) } }
                    } label: { Label("Leave Out an App", systemImage: "plus") }
                } header: { Text("Apps it leaves alone") }
            }
        }
        .formStyle(.grouped)
    }
}
