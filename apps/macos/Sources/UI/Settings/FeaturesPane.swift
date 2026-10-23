import SwiftUI

/// The home screen: every feature on one quiet list, with its switch and a way to its settings. A feature that is
/// working says nothing extra; only something that needs attention gets a note.
struct FeaturesPane: View {
    @EnvironmentObject private var services: ServiceManager
    @EnvironmentObject private var navigator: SettingsNavigator

    private var needAttention: [FeatureId] {
        FeatureId.all.filter { if case .needsPermission = services.state($0) { return true } else { return false } }
    }

    private var runningCount: Int { FeatureId.all.filter { services.state($0) == .running }.count }

    var body: some View {
        VStack(spacing: 0) {
            if !needAttention.isEmpty {
                Banner(
                    symbol: "lock.shield.fill", tint: Theme.warn, title: "Waiting for permission",
                    message: "\(needAttention.map(\.title).joined(separator: ", ")) will start as soon as you allow what they need."
                ) {
                    Button("Review Permissions") { navigator.pane = .permissions }.controlSize(.small)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Form {
                Section {
                    ForEach(FeatureId.all) { feature in
                        FeatureRow(feature: feature)
                    }
                } header: {
                    HStack {
                        Text(runningCount == 0 ? "Nothing running" : "\(runningCount) of \(FeatureId.all.count) running")
                            .smoothly(runningCount)
                        Spacer()
                        Button { navigator.openSetupGuide() } label: { Text("Setup Guide").foregroundStyle(Theme.accent) }
                            .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Turning a feature on asks only for the permissions it needs.")
                }
                RecentChangesSection()
                MoreFeaturesSection()
            }
            .formStyle(.grouped)
        }
        .animation(.smooth(duration: 0.3), value: needAttention)
    }
}

private struct FeatureRow: View {
    let feature: FeatureId
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var services: ServiceManager
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var navigator: SettingsNavigator

    private var binding: Binding<Bool> {
        Binding(
            get: { config.isEnabled(feature) },
            set: { on in withAnimation(.smooth) { services.setFeature(feature, enabled: on) } }
        )
    }

    var body: some View {
        let state = services.state(feature)
        HStack(spacing: 12) {
            RowIcon(symbol: feature.symbol, active: state == .running)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                Text(feature.summary)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                note(state)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: binding).labelsHidden().toggleStyle(.switch).controlSize(.small)
            Button { navigator.pane = feature.pane } label: {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(feature.title) settings")
        }
        .padding(.vertical, 3)
        .smoothly(state)
    }

    @ViewBuilder
    private func note(_ state: FeatureState) -> some View {
        switch state {
        case .off, .running:
            EmptyView()
        case .safeMode:
            StateBadge(text: "Held off by safe mode", color: Theme.warn)
        case .needsPermission(let missing):
            HStack(spacing: 8) {
                StateBadge(text: "Needs \(missing.first?.title ?? "permission")", color: Theme.warn)
                if let first = missing.first {
                    Button("Allow") { permissions.request(first) }.controlSize(.small)
                }
            }
            .padding(.top, 2)
        case .failed:
            HStack(spacing: 8) {
                StateBadge(text: "Could not start", color: Theme.danger)
                Button("Retry") { services.retry(feature) }.controlSize(.small)
            }
            .padding(.top, 2)
        }
    }
}
