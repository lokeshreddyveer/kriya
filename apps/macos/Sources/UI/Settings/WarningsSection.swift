import SwiftUI

/// The warnings Kriya can stop showing, with a way to bring each back, all of a feature's, or all of them.
struct WarningsSection: View {
    private let store = WarningStore()
    /// Counted again when a button is pressed, so the rows follow what was reset.
    @State private var refresh = 0

    var body: some View {
        Section {
            let _ = refresh
            ForEach(WarningCatalog.features, id: \.id) { feature in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(feature.title).font(.headline)
                        Spacer()
                        Button("Reset warnings for this feature") { store.reset(feature: feature.id); refresh += 1 }
                            .controlSize(.small)
                            .disabled(!WarningCatalog.warnings(for: feature.id).contains { store.isDismissed($0.id) })
                    }
                    ForEach(WarningCatalog.warnings(for: feature.id)) { warning in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(warning.title)
                                Text(status(of: warning)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button("Reset this warning") { store.reset(warning.id); refresh += 1 }
                                .controlSize(.small)
                                .disabled(!store.isDismissed(warning.id))
                                .accessibilityLabel("Reset the warning “\(warning.title)”")
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            HStack {
                Text(store.dismissedCount == 0 ? "Every warning is showing." : "\(store.dismissedCount) warning\(store.dismissedCount == 1 ? " is" : "s are") switched off.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Reset all warnings") { store.resetAll(); refresh += 1 }.controlSize(.small).disabled(store.dismissedCount == 0)
            }
        } header: { Text("Warnings you switched off") } footer: {
            Text("Some questions can be switched off with “Don't ask again”. Resetting brings them back. A question that guards your files, such as moving old captures to the Trash, can never be switched off.")
        }
    }

    private func status(of warning: WarningDefinition) -> String {
        if let date = store.dismissedAt(warning.id) { return "Switched off \(date.formatted(.relative(presentation: .named))). " + warning.detail }
        return warning.detail
    }
}
