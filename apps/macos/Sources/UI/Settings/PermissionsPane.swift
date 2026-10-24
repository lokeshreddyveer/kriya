import SwiftUI
import UserNotifications

struct PermissionsPane: View {
    @EnvironmentObject private var permissions: PermissionManager

    var body: some View {
        Form {
            Section {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(permission: permission)
                }
            } footer: {
                Text("Kriya asks for a permission only when you turn on a feature that needs it. macOS shows its own prompt once; after that, use Open Settings. This list updates by itself when you change a permission.")
            }

            Section {
                NotificationsRow()
            } header: { Text("Notifications") } footer: {
                Text("Used by File Shelf expiry reminders, focus session breaks and system monitor alerts. Nothing is sent to anyone: these are notices on this Mac.")
            }

            Section {
                ForEach(FeatureRegistry.permissionMatrix(core: FeatureId.all.map { (title: $0.title, permissions: $0.requiredPermissions.map(\.title)) }), id: \.permission) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(row.permission).font(.headline)
                            if let permission = Permission.allCases.first(where: { $0.title == row.permission }) {
                                let status = permissions.status(permission)
                                StateBadge(text: status == .granted ? "Allowed" : status.label, color: status == .granted ? Theme.ok : status.color)
                            }
                        }
                        Text(row.features.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: { Text("Which features need what") } footer: {
                Text("Features not listed here need no system permission. Location is asked by macOS the first time Sound by Place is switched on.")
            }

            Section {
                let history = FeatureActivity.shared.log.changes.filter { $0.feature.hasPrefix("permission:") }.prefix(8)
                if history.isEmpty { Text("No permission has changed since Kriya started keeping this.").font(.callout).foregroundStyle(.secondary) }
                ForEach(Array(history)) { change in
                    HStack { Text(change.what); Spacer(); Text(change.at.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.tertiary) }.font(.callout)
                }
            } header: { Text("Permission history") }

            Section {
                HStack {
                    Text("If a permission shows as allowed but a feature still does not work, restart Kriya.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Kriya") { SystemInfo.relaunch() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct NotificationsRow: View {
    @State private var status: UNAuthorizationStatus?

    private var label: (text: String, color: Color) {
        switch status {
        case .authorized, .provisional, .ephemeral: return ("Allowed", Theme.ok)
        case .denied: return ("Denied", Theme.danger)
        case .notDetermined: return ("Not asked yet", Theme.warn)
        default: return ("Checking…", .secondary)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bell.badge").frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text("Notifications").font(.headline); StateBadge(text: label.text, color: label.color) }
                Text("Lets Kriya show reminders, such as a shelf item that is about to expire.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if status == .notDetermined {
                Button("Allow…") { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in refresh() } }.controlSize(.small)
            } else {
                Button("Open Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }.controlSize(.small)
            }
        }
        .animation(.smooth(duration: 0.2), value: status)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { status = settings.authorizationStatus }
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    @EnvironmentObject private var permissions: PermissionManager

    private var neededBy: String {
        let names = FeatureRegistry.features(needing: permission)
        return names.isEmpty ? "Not needed by any feature yet" : "Used by " + names.joined(separator: ", ")
    }

    var body: some View {
        let status = permissions.status(permission)
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: permission.symbol)
                .font(.title2)
                .frame(width: 30)
                .foregroundStyle(status == .granted ? Theme.ok : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(permission.title).font(.headline)
                Text(permission.reason).font(.callout).foregroundStyle(.secondary)
                Text(neededBy).font(.caption).foregroundStyle(.tertiary)
                if status != .granted { StateBadge(text: status.label, color: status.color) }
            }
            Spacer()
            action(for: status)
        }
        .padding(.vertical, 4)
        .smoothly(status)
    }

    @ViewBuilder
    private func action(for status: PermissionStatus) -> some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok).font(.title3)
        case .notDetermined:
            Button("Allow…") { permissions.request(permission) }
        case .denied, .onDemand:
            Button("Open Settings") { permissions.openSettings(permission) }
        }
    }
}
