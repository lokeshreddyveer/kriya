import SwiftUI

/// What the menu-bar icon opens: a switch for each feature, one line saying how things are, and the way into Settings.
/// Small on purpose: a popover is for a few quick tasks.
struct PopoverView: View {
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var crashGuard: CrashGuard
    @EnvironmentObject private var services: ServiceManager

    let openSettings: (SettingsPane?) -> Void

    private var attentionCount: Int {
        FeatureId.all.filter { if case .needsPermission = services.state($0) { return true } else { return false } }.count
    }

    private var runningCount: Int { FeatureId.all.filter { services.state($0) == .running }.count }

    private var summary: (text: String, color: Color?) {
        if crashGuard.isSafeMode { return ("Safe mode", Theme.warn) }
        if attentionCount > 0 { return (attentionCount == 1 ? "1 needs permission" : "\(attentionCount) need permission", Theme.warn) }
        switch runningCount {
        case 0: return ("Nothing running", nil)
        case FeatureId.all.count: return ("All running", nil)
        default: return ("\(runningCount) running", nil)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if services.state(.windowManagement) == .running {
                WindowStrip()
                Divider()
            }
            VStack(spacing: 8) {
                StatusBanners()
                VStack(spacing: 0) {
                    ForEach(FeatureId.all) { feature in
                        PopoverFeatureRow(feature: feature, openSettings: openSettings)
                    }
                }
            }
            .padding(6)
            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Kriya").font(.headline)
            Spacer()
            HStack(spacing: 6) {
                if let color = summary.color { StatusDot(color: color) }
                Text(summary.text).font(.callout).foregroundStyle(summary.color == nil ? Color.secondary : Color.primary)
            }
            .smoothly(summary.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { openSettings(nil) } label: { Text("Settings…") }
                .keyboardShortcut(",")
            Button { openSettings(.features) } label: { Text("Overview") }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct PopoverFeatureRow: View {
    let feature: FeatureId
    let openSettings: (SettingsPane?) -> Void
    @EnvironmentObject private var config: ConfigStore
    @EnvironmentObject private var services: ServiceManager
    @EnvironmentObject private var permissions: PermissionManager
    @State private var hovering = false

    private var binding: Binding<Bool> {
        Binding(
            get: { config.isEnabled(feature) },
            set: { on in withAnimation(.smooth) { services.setFeature(feature, enabled: on) } }
        )
    }

    var body: some View {
        let state = services.state(feature)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button { openSettings(feature.pane) } label: {
                    HStack(spacing: 10) {
                        RowIcon(symbol: feature.symbol, active: state == .running)
                        Text(feature.title)
                            .foregroundStyle(state == .off ? Color.secondary : Color.primary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .opacity(hovering ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(feature.title) settings")
                Toggle("", isOn: binding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            if case .needsPermission(let missing) = state, let first = missing.first {
                HStack(spacing: 8) {
                    StateBadge(text: "Needs \(first.title)", color: Theme.warn)
                    Button("Allow") { permissions.request(first) }.controlSize(.small)
                }
                .padding(.leading, 34)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if case .failed = state {
                StateBadge(text: "Could not start", color: Theme.danger).padding(.leading, 34)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: hovering)
        .smoothly(state)
    }
}

/// The most used window places, one click each, for the window that was in front when the menu was opened.
private struct WindowStrip: View {
    @EnvironmentObject private var windowController: WindowController

    private struct Place: Identifiable {
        let symbol: String
        let title: String
        let command: String
        var id: String { command }
    }

    private let items: [Place] = [
        Place(symbol: "rectangle.lefthalf.inset.filled", title: "Left half", command: "window.left_half"),
        Place(symbol: "rectangle.righthalf.inset.filled", title: "Right half", command: "window.right_half"),
        Place(symbol: "rectangle.tophalf.inset.filled", title: "Top half", command: "window.top_half"),
        Place(symbol: "rectangle.bottomhalf.inset.filled", title: "Bottom half", command: "window.bottom_half"),
        Place(symbol: "rectangle.inset.filled", title: "Maximize", command: "window.maximize"),
        Place(symbol: "plus.rectangle.on.rectangle", title: "Center", command: "window.center"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            Text("Window").font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            ForEach(items) { item in
                Button { windowController.run(command: item.command) } label: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
