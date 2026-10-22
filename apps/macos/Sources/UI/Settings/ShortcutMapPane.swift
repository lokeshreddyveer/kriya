import SwiftUI

/// Everything that can start something in Kriya, in one place: keyboard shortcuts, remapped keys, mouse buttons, gestures,
/// corners and automation triggers, with the ones that want the same thing pointed out, and the order events are offered.
struct ShortcutMapPane: View {
    @State private var tab: Tab = .everything

    enum Tab: String, CaseIterable, Identifiable {
        case everything = "Everything", keys = "Keyboard Shortcuts", order = "Order"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .paneTabBar(maxWidth: 420)
                .paneHeader()
            Group {
                switch tab {
                case .everything: EverythingTab()
                case .keys: KeysTab()
                case .order: OrderTab()
                }
            }
            .id(tab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.22), value: tab)
    }
}

// MARK: - Everything

private struct EverythingTab: View {
    @EnvironmentObject private var registry: ShortcutRegistry
    @EnvironmentObject private var navigator: SettingsNavigator
    @EnvironmentObject private var remap: RemapStore
    @EnvironmentObject private var mouse: MouseStore
    @EnvironmentObject private var drag: DragToolsStore
    @EnvironmentObject private var traffic: TrafficStore
    @EnvironmentObject private var screen: ScreenToolsStore
    @EnvironmentObject private var workflows: WorkflowStore
    @EnvironmentObject private var pointerMenu: PointerMenuStore
    @EnvironmentObject private var library: ActionLibrary
    @State private var query = ""
    @State private var shown: Set<InteractionEntry.Kind> = Set(InteractionEntry.Kind.allCases)

    private var entries: [InteractionEntry] {
        InteractionMap.entries(InteractionMap.Inputs(
            hotkeys: registry.entries, remapEnabled: remap.config.enabled, remaps: remap.config.rules,
            presets: mouse.presets, assignments: mouse.assignments, defaultPresetID: mouse.config.defaultPresetId,
            drag: drag.config, traffic: traffic.config, screen: screen.config, workflows: workflows.workflows, pointerMenu: pointerMenu.config,
            name: { id in library.actions.first { $0.id == id }?.name ?? WindowCommands.all.first { $0.command == id }?.title ?? id }
        ))
    }

    var body: some View {
        let all = entries
        let clashes = InteractionMap.clashes(all)
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = all.filter { shown.contains($0.kind) && (text.isEmpty || $0.title.lowercased().contains(text) || $0.trigger.lowercased().contains(text) || $0.owner.lowercased().contains(text)) }
        Form {
            if !clashes.isEmpty {
                Section {
                    ForEach(Array(clashes.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(group[0].trigger, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                            ForEach(group) { entry in
                                HStack {
                                    Text("\(entry.owner) › \(entry.title)").font(.callout).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Open") { navigator.pane = entry.pane }.controlSize(.small).buttonStyle(.borderless)
                                }
                            }
                            Text(InteractionMap.explanation(for: group)).font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: { Text("Wanting the same thing") } footer: {
                    Text("These start from the same key, button or place. Change one of them in its own pane.")
                }
            } else {
                Section {
                    Label("Nothing set up wants the same thing as something else.", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                }
            }

            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search everything", text: $query).textFieldStyle(.plain)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(InteractionEntry.Kind.allCases) { kind in
                            let on = shown.contains(kind)
                            let count = all.filter { $0.kind == kind }.count
                            Button {
                                withAnimation(.smooth(duration: 0.15)) { if on { shown.remove(kind) } else { shown.insert(kind) } }
                            } label: {
                                Label("\(kind.title) \(count)", systemImage: kind.symbol)
                                    .font(.system(size: 11, weight: on ? .semibold : .regular))
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(on ? Theme.accent.opacity(0.2) : Color.primary.opacity(0.05), in: Capsule())
                                    .overlay(Capsule().strokeBorder(on ? Theme.accent.opacity(0.6) : Color.primary.opacity(0.1), lineWidth: 1))
                                    .foregroundStyle(on ? Color.primary : Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } footer: {
                Text("\(visible.count) of \(all.count) shown. Change one in the pane of the feature that owns it.")
            }

            ForEach(InteractionEntry.Kind.allCases.filter { kind in visible.contains { $0.kind == kind } }) { kind in
                Section {
                    ForEach(visible.filter { $0.kind == kind }) { entry in
                        HStack(spacing: 10) {
                            Text(entry.trigger)
                                .font(.system(.callout, design: .rounded))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title)
                                Text(entry.owner).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if !entry.apps.isEmpty {
                                Text("In \(entry.apps.count) app\(entry.apps.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                            }
                            Button { navigator.pane = entry.pane } label: { Image(systemName: "arrow.up.forward.square") }
                                .buttonStyle(.borderless).help("Open its settings")
                        }
                    }
                } header: { Label(kind.title, systemImage: kind.symbol) }
            }
            if all.isEmpty { Section { Text("Nothing is set up yet.").foregroundStyle(.secondary) } }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.2), value: shown)
    }
}

// MARK: - Order

/// Which part of Kriya sees an event first. They are offered the event in the order they started listening, and the
/// first one that acts on it keeps it.
private struct OrderTab: View {
    @EnvironmentObject private var events: EventMonitor
    @State private var order: [(owner: String, canChange: Bool)] = []

    var body: some View {
        Form {
            Section {
                if order.isEmpty {
                    Text("Nothing is listening right now. Features that read the keyboard or mouse start listening when you turn them on.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(order.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.system(.callout, design: .rounded)).foregroundStyle(.secondary).frame(width: 22)
                        Text(InteractionMap.friendlyName(forSubscriber: item.owner))
                        Spacer()
                        StateBadge(text: item.canChange ? "Can act on events" : "Only watches", color: item.canChange ? Theme.accent : .secondary)
                    }
                }
            } header: { Text("Who sees an event, in order") } footer: {
                Text("Every key press and mouse action is offered to these in turn, first to last. The first one that acts on it keeps it, and the ones after do not get it. Letting go of a button or key, and changes to modifier keys, still reach everyone, so nothing is left held down. The order is the order features started: it can change when you turn features on and off.")
            }
        }
        .formStyle(.grouped)
        .onAppear { order = events.orderedSubscribers() }
        .onReceive(events.objectWillChange) { _ in DispatchQueue.main.async { order = events.orderedSubscribers() } }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in order = events.orderedSubscribers() }
    }
}

// MARK: - Keyboard shortcuts

/// Every keyboard shortcut Kriya has asked for, from all of its features in one list, with the ones that clash pointed out.
private struct KeysTab: View {
    @EnvironmentObject private var registry: ShortcutRegistry
    @EnvironmentObject private var navigator: SettingsNavigator
    @State private var query = ""

    private var filtered: [ShortcutEntry] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return registry.entries }
        return registry.entries.filter {
            $0.title.lowercased().contains(text) || $0.owner.lowercased().contains(text)
                || KeyNames.describe(keyCode: $0.keyCode, modifiers: $0.modifiers).lowercased().contains(text)
        }
    }

    private var owners: [String] { Array(Set(filtered.map(\.owner))).sorted() }

    private func pane(for owner: String) -> SettingsPane? {
        switch owner {
        case "Windows": return .windows
        case "Keyboard", "Keyboard shortcuts": return .keyboard
        case "Clipboard": return .clipboard
        case "Selection bar": return .selection
        case "Right-click menu": return .finder
        case "Automation": return .automation
        default: return nil
        }
    }

    var body: some View {
        let clashes = registry.conflicts
        Form {
            if !clashes.isEmpty {
                Section {
                    ForEach(Array(clashes.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(KeyNames.describe(keyCode: group[0].keyCode, modifiers: group[0].modifiers), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.warn)
                            ForEach(group) { entry in
                                Text("\(entry.owner) › \(entry.title)" + (entry.status == .refused ? " (not registered)" : ""))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: { Text("Clashes") } footer: {
                    Text("Two shortcuts on the same keys. macOS gives them to the first feature that asked, so the other one does nothing until you change one of them in its own pane.")
                }
            }

            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search shortcuts", text: $query).textFieldStyle(.plain)
                }
            } footer: {
                Text("\(registry.entries.count) shortcuts. Change one in the pane of the feature that owns it.")
            }

            ForEach(owners, id: \.self) { owner in
                Section {
                    ForEach(filtered.filter { $0.owner == owner }) { entry in
                        HStack(spacing: 10) {
                            Text(KeyNames.describe(keyCode: entry.keyCode, modifiers: entry.modifiers))
                                .font(.system(.callout, design: .rounded).monospacedDigit())
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Text(entry.title)
                            Spacer(minLength: 4)
                            if entry.status == .refused {
                                StateBadge(text: "Not registered", color: Theme.warn)
                            } else if !entry.apps.isEmpty {
                                Text("In \(entry.apps.count) app\(entry.apps.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(owner)
                        Spacer()
                        if let target = pane(for: owner) {
                            Button("Open") { navigator.pane = target }.controlSize(.small)
                        }
                    }
                }
            }
            if registry.entries.isEmpty {
                Section { Text("No shortcuts are set yet.").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}
