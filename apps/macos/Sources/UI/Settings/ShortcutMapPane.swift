import SwiftUI

/// Every keyboard shortcut Kriya has asked for, from all of its features in one list, with the ones that clash pointed out.
struct ShortcutMapPane: View {
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
