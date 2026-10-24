import CoreLocation
import SwiftUI

/// What was changed lately, across every feature.
struct RecentChangesSection: View {
    @ObservedObject private var activity = FeatureActivity.shared

    var body: some View {
        let recent = activity.log.recentChanges().prefix(6)
        if !recent.isEmpty {
            Section {
                ForEach(Array(recent)) { change in
                    HStack {
                        Text(ActivityFeed.title(for: change.feature))
                        Text(change.what).foregroundStyle(.secondary)
                        Spacer()
                        Text(change.at.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.tertiary)
                    }
                    .font(.callout)
                }
            } header: { Text("Changed lately") }
        }
    }
}

/// The features that are not among the original eight, each with its own status: on or off, what it needs, what is wrong, when it
/// last did something, what it relies on, and a way to reset or export it.
struct MoreFeaturesSection: View {
    @EnvironmentObject private var navigator: SettingsNavigator
    @EnvironmentObject private var permissions: PermissionManager
    @ObservedObject private var activity = FeatureActivity.shared
    @State private var tick = 0
    @State private var message: String?
    @State private var confirming: ResettableArea?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        let board = FeatureSwitchboard.shared
        let _ = tick
        Section {
            ForEach(FeatureRegistry.extras) { feature in
                row(feature, board: board)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        } header: { Text("More features") } footer: {
            Text("Each has its own switch where it can be switched, and its own place in Kriya's settings. “Reset” clears only that part's saved settings and restarts Kriya; the part's last settings are kept for a day so the reset can be undone in Diagnostics.")
        }
        // The statuses are read fresh every couple of seconds. Reading `tick` is what asks for that; the rows keep their identity, so an
        // open menu or a dialog is not torn down each time.
        .onReceive(timer) { _ in tick &+= 1 }
        .confirmationDialog("Reset \(confirming?.title ?? "")?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            Button("Reset and Restart", role: .destructive) { if let area = confirming { message = FeatureResetService.reset(area, onRollback: { message = $0 }) }; confirming = nil }
        } message: { Text(confirming?.detail ?? "") }
    }

    @ViewBuilder
    private func row(_ feature: ManagedFeature, board: FeatureSwitchboard) -> some View {
        let on = board.isOn(feature.id)
        let problem = board.problem(feature.id)
        let failure = activity.log.failures[feature.id]
        let area = feature.resetArea.flatMap { id in FeatureReset.areas.first { $0.id == id } }
        let missing = missingPermissions(feature)
        HStack(alignment: .top, spacing: 12) {
            RowIcon(symbol: feature.symbol, active: on)
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                Text(feature.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let headline = board.headline(feature.id) { Text(headline).font(.caption).foregroundStyle(.secondary) }
                    if let used = activity.log.lastUsed[feature.id] { Text("Last used \(used.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary) }
                    else if on { Text("Not used yet").font(.caption).foregroundStyle(.tertiary) }
                }
                HStack(spacing: 6) {
                    ForEach(missing, id: \.self) { StateBadge(text: "Needs \($0)", color: Theme.warn) }
                    if let problem { StateBadge(text: problem, color: Theme.danger) }
                    else if let failure { StateBadge(text: "\(failure.count) problem\(failure.count == 1 ? "" : "s"): \(failure.last)", color: Theme.danger) }
                }
                if !feature.dependsOn.isEmpty {
                    Text("Relies on " + feature.dependsOn.map { ActivityFeed.title(for: $0) }.joined(separator: ", ") + (dependencyOff(feature, board) ? " (currently off)" : ""))
                        .font(.caption).foregroundStyle(dependencyOff(feature, board) ? Theme.warn : Color.secondary.opacity(0.7))
                }
            }
            Spacer(minLength: 8)
            if board.isSwitchable(feature.id) {
                Toggle("", isOn: Binding(get: { board.isOn(feature.id) }, set: { board.set(feature.id, $0); tick &+= 1 })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel(feature.title)
                    .accessibilityValue(on ? "on" : "off")
            }
            Menu {
                Button("Open Settings") { go(feature) }
                if let area {
                    Divider()
                    Button("Export Settings…") { message = FeatureResetService.export(area) }
                    Button("Import Settings…") { message = FeatureResetService.importSettings(area) }
                    Button("Reset This Part…", role: .destructive) { confirming = area }
                }
                if activity.log.failures[feature.id] != nil { Button("Clear Problem Count") { activity.clearProblems(feature.id) } }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More for \(feature.title)")
            Button { go(feature) } label: { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 18, height: 24).contentShape(Rectangle()) }
                .buttonStyle(.plain).help("Open \(feature.title) settings").accessibilityLabel("Open \(feature.title) settings")
        }
        .padding(.vertical, 3)
    }

    private func go(_ feature: ManagedFeature) {
        guard let pane = SettingsPane(rawValue: feature.pane) else { return }
        navigator.go(pane, tab: feature.tab)
    }

    private func dependencyOff(_ feature: ManagedFeature, _ board: FeatureSwitchboard) -> Bool {
        feature.dependsOn.contains { id in
            if FeatureRegistry.feature(id) != nil { return !board.isOn(id) }
            return false
        }
    }

    /// Names of system permissions this feature needs that are not allowed yet.
    private func missingPermissions(_ feature: ManagedFeature) -> [String] {
        let board = FeatureSwitchboard.shared
        guard board.isOn(feature.id) || !board.isSwitchable(feature.id) else { return [] }
        // Every permission the feature names is checked by the same state machine as the rest: only "denied" is shown as missing (a
        // permission not asked for yet is asked when the feature first needs it, and Automation is asked per app).
        return feature.permissions.compactMap { name in
            guard let permission = Permission.named(name) else { return nil }
            let status = permissions.status(permission)
            // The three the features need to work at all show as missing until allowed; the rest only once they were refused.
            if [.accessibility, .inputMonitoring, .screenRecording].contains(permission) { return status == .granted ? nil : name }
            return status == .denied ? name : nil
        }
    }
}
