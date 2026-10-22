import SwiftUI

/// Chooses what the menu-bar window shows and how it looks.
struct MenuBarPane: View {
    @EnvironmentObject private var prefs: PopoverPrefs
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $prefs.theme) {
                    Text("Match the system").tag("system")
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                }
                LabeledContent("Colour") {
                    HStack(spacing: 8) {
                        ForEach(PopoverCatalog.tints, id: \.id) { tint in
                            Button { prefs.tint = tint.id } label: {
                                Circle().fill(tint.color).frame(width: 20, height: 20)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(prefs.tint == tint.id ? 0.9 : 0.15), lineWidth: prefs.tint == tint.id ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                            .help(tint.name)
                        }
                    }
                }
                Toggle("Compact spacing", isOn: $prefs.compact)
                Toggle("Show a search box", isOn: $prefs.showSearch)
                Toggle("Show names under the quick actions", isOn: $prefs.showLabels)
                Toggle("Show the features in two columns", isOn: $prefs.featuresAsGrid)
                Picker("Quick actions per row", selection: $prefs.columns) {
                    ForEach(3...6, id: \.self) { Text("\($0)").tag($0) }
                }
                SliderRow(title: "Tallest", value: $prefs.maxHeight, range: 380...780, format: { "\(Int($0)) pt" }, help: "The window scrolls when it needs more room.")
            } header: { Text("Look") } footer: {
                Text("Open the window from the menu-bar icon to see a change. The search box finds actions, window places, saved actions and settings, and Return runs the first one.")
            }

            Section {
                ForEach(Array(prefs.sectionOrder.enumerated()), id: \.element) { index, id in
                    HStack {
                        Toggle("", isOn: Binding(get: { !prefs.hiddenSections.contains(id) }, set: { on in
                            if on { prefs.hiddenSections.remove(id) } else { prefs.hiddenSections.insert(id) }
                        })).labelsHidden()
                        Text(PopoverCatalog.sections.first { $0.id == id }?.title ?? id)
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(index == prefs.sectionOrder.count - 1)
                    }
                }
            } header: { Text("Sections") } footer: {
                Text("Tick the sections to show, and use the arrows to put them in order. The window section appears only while Window Management is on.")
            }

            Section {
                if prefs.tiles.isEmpty { Text("No quick actions are shown.").font(.callout).foregroundStyle(.secondary) }
                ForEach(Array(prefs.tiles.enumerated()), id: \.element) { index, id in
                    if let tile = PopoverCatalog.tile(id) {
                        HStack {
                            Image(systemName: tile.symbol).frame(width: 22).foregroundStyle(.secondary)
                            Text(tile.title)
                            Spacer()
                            Button { moveTile(index, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(index == 0)
                            Button { moveTile(index, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(index == prefs.tiles.count - 1)
                            Button(role: .destructive) { prefs.tiles.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                }
            } header: { Text("Quick actions shown") }

            Section {
                let available = PopoverCatalog.tiles.filter { !prefs.tiles.contains($0.id) }
                if available.isEmpty { Text("Every quick action is already shown.").font(.callout).foregroundStyle(.secondary) }
                ForEach(available) { tile in
                    HStack {
                        Image(systemName: tile.symbol).frame(width: 22).foregroundStyle(.secondary)
                        Text(tile.title)
                        Spacer()
                        Button { prefs.tiles.append(tile.id) } label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless)
                    }
                }
            } header: { Text("Add a quick action") }

            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(windowLayouts(), id: \.command) { layout in
                        let on = prefs.layouts.contains(layout.command)
                        Button {
                            if on { prefs.layouts.removeAll { $0 == layout.command } } else { prefs.layouts.append(layout.command) }
                        } label: {
                            VStack(spacing: 3) {
                                MiniScreen(layout: layout)
                                Text(layout.title).font(.system(size: 9)).lineLimit(1).foregroundStyle(.secondary)
                            }
                            .padding(4)
                            .background(on ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(on ? Theme.accent : Color.primary.opacity(0.1), lineWidth: on ? 1.5 : 1))
                            .opacity(on ? 1 : 0.6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            } header: { Text("Window places") } footer: {
                Text("Click a place to show or hide it in the window section.")
            }

            Section {
                ForEach(PopoverCatalog.extras, id: \.id) { extra in
                    Toggle(isOn: Binding(get: { prefs.extras.contains(extra.id) }, set: { on in
                        if on { if !prefs.extras.contains(extra.id) { prefs.extras.append(extra.id) } } else { prefs.extras.removeAll { $0 == extra.id } }
                    })) { Label(extra.title, systemImage: extra.symbol) }
                }
            } header: { Text("Switches in “More”") }

            Section {
                Button("Restore the Original Window…", role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.2), value: prefs.tiles)
        .confirmationDialog("Restore the menu-bar window?", isPresented: $confirmReset) {
            Button("Restore", role: .destructive) { prefs.reset() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Its look, sections, quick actions and window places go back to how they started.") }
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard prefs.sectionOrder.indices.contains(target) else { return }
        prefs.sectionOrder.swapAt(index, target)
    }

    private func moveTile(_ index: Int, by delta: Int) {
        let target = index + delta
        guard prefs.tiles.indices.contains(target) else { return }
        prefs.tiles.swapAt(index, target)
    }
}
