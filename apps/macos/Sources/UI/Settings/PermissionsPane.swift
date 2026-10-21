import SwiftUI

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

private struct PermissionRow: View {
    let permission: Permission
    @EnvironmentObject private var permissions: PermissionManager

    private var neededBy: String {
        let names = FeatureId.all.filter { $0.requiredPermissions.contains(permission) }.map(\.title)
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
