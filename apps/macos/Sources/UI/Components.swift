import SwiftUI

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

extension FeatureState {
    var label: String {
        switch self {
        case .off: return "Off"
        case .safeMode: return "Held off by safe mode"
        case .needsPermission: return "Needs permission"
        case .running: return "Running"
        case .failed: return "Could not start"
        }
    }

    var color: Color {
        switch self {
        case .off: return .secondary
        case .safeMode, .needsPermission: return Theme.warn
        case .running: return Theme.ok
        case .failed: return Theme.danger
        }
    }
}

extension PermissionStatus {
    var label: String {
        switch self {
        case .granted: return "Allowed"
        case .denied: return "Not allowed"
        case .notDetermined: return "Not asked yet"
        case .onDemand: return "Asked when needed"
        }
    }

    var color: Color {
        switch self {
        case .granted: return Theme.ok
        case .denied: return Theme.danger
        case .notDetermined, .onDemand: return .secondary
        }
    }
}

/// A coloured dot and a short word, for a feature's or permission's current state.
struct StateBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: color)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .animation(.smooth(duration: 0.25), value: text)
    }
}

/// A tinted message with room for buttons, used for safe mode, recovery notices and warnings.
struct Banner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String?
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                if let title { Text(title).font(.headline) }
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { actions() }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Safe mode and recovery notices. Shown at the top of the popover and of every settings pane.
struct StatusBanners: View {
    @EnvironmentObject private var crashGuard: CrashGuard

    var body: some View {
        VStack(spacing: 8) {
            if crashGuard.isSafeMode {
                Banner(
                    symbol: "exclamationmark.shield.fill", tint: Theme.warn, title: "Safe mode",
                    message: crashGuard.safeModeReason ?? "All features are held off."
                ) {
                    Button("Leave Safe Mode") { withAnimation(.smooth) { crashGuard.leaveSafeMode() } }
                        .controlSize(.small)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let notice = crashGuard.notice {
                Banner(symbol: "info.circle.fill", tint: Theme.accent, title: nil, message: notice) {
                    Button("Dismiss") { withAnimation(.smooth) { crashGuard.notice = nil } }
                        .controlSize(.small)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.smooth(duration: 0.3), value: crashGuard.isSafeMode)
        .animation(.smooth(duration: 0.3), value: crashGuard.notice)
    }
}

/// Wraps text in a small rounded label, for things like "Phase 2".
struct Capsule2: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

extension View {
    /// The same gentle easing for every state change in the app.
    func smoothly<V: Equatable>(_ value: V) -> some View {
        animation(.smooth(duration: 0.25), value: value)
    }
}

extension Date {
    var shortDescription: String {
        formatted(date: .abbreviated, time: .shortened)
    }
}
