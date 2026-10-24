import AppKit
import SwiftUI

extension PointerMenuItem: Identifiable {}

/// Settings for the pointer menu: whether it holds the front app's own menu, and the person's own items, which can be
/// limited to chosen apps.
struct PointerMenuTab: View {
    @EnvironmentObject private var menu: PointerMenuStore
    @EnvironmentObject private var library: ActionLibrary
    @EnvironmentObject private var workflows: WorkflowStore
    @State private var editing: PointerMenuItem?

    var body: some View {
        Form {
            Section {
                Toggle("Add the front app's own menu", isOn: Binding(get: { menu.config.showAppMenu }, set: { v in menu.update { $0.showAppMenu = v } }))
                Toggle("Open it with ⌥ + right-click", isOn: Binding(get: { menu.config.optionRightClick }, set: { v in menu.update { $0.optionRightClick = v } }))
            } header: { Text("Pointer menu") } footer: {
                Text("A menu that opens at the pointer. To open it, give a shortcut (Keyboard), a mouse button or a gesture (Mouse) the action “Open the pointer menu”, or “Open the app's menu at the pointer” for the app's menu alone. Both are in Actions › Add Common Actions. Needs Accessibility to show the app's own menu. “⌥ + right-click” needs Input Monitoring; a plain right-click always keeps the app's own menu.")
            }

            Section {
                if menu.config.items.isEmpty {
                    Text("No items yet. Add one to run a saved action or a workflow from this menu.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(menu.config.items) { item in row(item) }
                    .onMove { menu.move(from: $0, to: $1) }
            } header: {
                HStack {
                    Text("Your items")
                    Spacer()
                    Button { editing = menu.newItem() } label: { Label("Add Item", systemImage: "plus") }.controlSize(.small)
                }
            } footer: {
                Text("An item can be limited to some apps; without any it shows everywhere. Drag to reorder.")
            }

            FavoriteMenuItemsSection()

            if let error = menu.lastError {
                Section { Text(error).font(.callout).foregroundStyle(Theme.danger) }
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: menu.config.items)
        .sheet(item: $editing) { item in
            PointerMenuItemEditor(item: item, onSave: { menu.upsert($0); editing = nil }, onCancel: { editing = nil })
        }
    }

    private func row(_ item: PointerMenuItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { item.enabled }, set: { on in var copy = item; copy.enabled = on; menu.upsert(copy) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(subtitle(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Edit") { editing = item }.controlSize(.small)
            Button { menu.delete(item.id) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
        }
    }

    private func subtitle(_ item: PointerMenuItem) -> String {
        let what: String
        if let id = item.workflowId {
            what = "Workflow: " + (workflows.workflows.first { $0.id == id }?.name ?? "missing")
        } else if let id = item.actionId {
            what = library.actions.first { $0.id == id }?.name ?? "Missing action"
        } else {
            what = "Nothing to run"
        }
        let apps = item.appIds.isEmpty ? "every app" : item.appIds.map(AppChoice.name(for:)).joined(separator: ", ")
        return "\(what) · \(apps)"
    }
}

/// Adds or changes one pointer-menu item.
private struct PointerMenuItemEditor: View {
    @State var item: PointerMenuItem
    let onSave: (PointerMenuItem) -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var workflows: WorkflowStore
    @State private var runsWorkflow: Bool

    init(item: PointerMenuItem, onSave: @escaping (PointerMenuItem) -> Void, onCancel: @escaping () -> Void) {
        _item = State(initialValue: item)
        _runsWorkflow = State(initialValue: item.workflowId != nil)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var problem: String? {
        if item.title.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the item a name." }
        if runsWorkflow ? (item.workflowId ?? "").isEmpty : (item.actionId ?? "").isEmpty { return "Choose what it runs." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $item.title)
                    Picker("Runs", selection: $runsWorkflow) {
                        Text("A saved action").tag(false)
                        Text("A workflow").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if runsWorkflow {
                        Picker("Workflow", selection: Binding(get: { item.workflowId ?? "" }, set: { item.workflowId = $0.isEmpty ? nil : $0; item.actionId = nil })) {
                            Text("Choose…").tag("")
                            ForEach(workflows.workflows) { Text($0.name).tag($0.id) }
                        }
                    } else {
                        ActionPicker(actionID: Binding(get: { item.actionId }, set: { item.actionId = $0; item.workflowId = nil }), allowNone: false)
                    }
                }
                Section {
                    ForEach(item.appIds, id: \.self) { id in
                        HStack {
                            Text(AppChoice.name(for: id))
                            Spacer()
                            Button { item.appIds.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove").buttonStyle(.borderless)
                        }
                    }
                    Button("Add App…") {
                        if let id = AppChoice.choose(prompt: "Add"), !item.appIds.contains(id) { item.appIds.append(id) }
                    }
                } header: { Text("Only in these apps") } footer: {
                    Text(item.appIds.isEmpty ? "Shows in every app." : "Shows only while one of these apps is in front.")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(item) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(problem != nil)
            }
            .padding(14)
        }
        .frame(width: 480, height: 520)
    }
}

/// Which app opens each kind of file, applied to macOS on request.
struct DefaultAppsSection: View {
    @EnvironmentObject private var store: FinderStore
    @State private var newExtension = ""
    @State private var applying = false
    @State private var result: String?

    var body: some View {
        Section {
            ForEach(store.config.defaultApps, id: \.self) { entry in
                HStack {
                    Text(".\(entry.extension)").font(.system(.body, design: .monospaced))
                    Spacer()
                    Text(AppChoice.name(for: entry.appId)).foregroundStyle(.secondary)
                    Button { store.updateConfig { $0.defaultApps.removeAll { $0 == entry } } } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove")
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("File type, like md", text: $newExtension).frame(maxWidth: 190)
                Menu("Common") {
                    ForEach(["md", "csv", "json", "pdf", "txt", "html", "xml", "yaml", "log", "sh"], id: \.self) { type in
                        Button(".\(type)") { newExtension = type }
                    }
                }
                .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                Button("Choose App…") {
                    let ext = newExtension.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    guard !ext.isEmpty, let id = AppChoice.choose(prompt: "Open with") else { return }
                    store.updateConfig { $0.defaultApps.append(DefaultApp(extension: ext, appId: id)) }
                    newExtension = ""
                }
                .disabled(newExtension.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Button(applying ? "Applying…" : "Apply to macOS") {
                    applying = true
                    Task {
                        let problems = await store.applyDefaultApps()
                        result = problems.isEmpty ? "Done. macOS may have asked you to confirm." : problems.joined(separator: "\n")
                        applying = false
                    }
                }
                .disabled(applying || store.config.defaultApps.isEmpty)
                if let result { Text(result).font(.callout).foregroundStyle(.secondary) }
            }
        } header: { Text("Default apps by file type") } footer: {
            Text("List the file types you want opened by a particular app, then apply. This changes how macOS opens them everywhere, the same as Get Info › Open with › Change All.")
        }
        .animation(.smooth(duration: 0.25), value: store.config.defaultApps)
        .animation(.smooth(duration: 0.25), value: result)
    }
}


/// App menu items kept at the top of that app's pointer menu.
struct FavoriteMenuItemsSection: View {
    @ObservedObject private var triggers = WindowTriggerStore.shared

    var body: some View {
        Section {
            if triggers.menuFavorites.isEmpty { Text("None yet. Open the pointer menu, open the app's menu inside it, and hold Option while choosing an item.").font(.callout).foregroundStyle(.secondary) }
            ForEach(triggers.menuFavorites) { favorite in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(favorite.title)
                        Text("\(AppChoice.name(for: favorite.appID))\(favorite.detail.isEmpty ? "" : " · " + favorite.detail)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { triggers.removeMenuFavorite(favorite.id) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete").buttonStyle(.borderless)
                }
            }
        } header: { Text("Favorite menu items") } footer: {
            Text("Items from an app's own menus that you use often. They sit at the top of that app's pointer menu. Choosing one presses the item in the app, as if it had been picked from the menu bar.")
        }
    }
}
