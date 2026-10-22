import Foundation

/// One line of "what applies right now".
struct DeviceContextLine: Identifiable, Equatable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
}

/// Explaining which settings are in effect for each device and the app in front, and why. It asks the core which mouse
/// preset applies (so the answer is the one Kriya really uses), then says in words what decided it.
enum DeviceContext {
    static func explain(
        devices: [(id: String, name: String)], presets: [MousePreset], assignments: [MouseAssignment], defaultPresetID: String,
        frontAppID: String?, frontAppName: String?, remapRules: [RemapRule], remapEnabled: Bool, secureInput: SecureInputStatus,
        appName: (String) -> String = { $0 }
    ) -> [DeviceContextLine] {
        var lines: [DeviceContextLine] = []
        lines.append(DeviceContextLine(
            id: "front", symbol: "macwindow", title: "In front now", detail: frontAppName ?? "No app"
        ))

        for device in devices {
            let presetID = resolveMousePreset(assignments: assignments, defaultPresetId: defaultPresetID, deviceId: device.id, appId: frontAppID)
            let preset = presets.first { $0.id == presetID }?.name ?? presetID
            lines.append(DeviceContextLine(
                id: "device-\(device.id)", symbol: "computermouse", title: device.name,
                detail: "Uses the “\(preset)” settings. " + reason(presetID: presetID, deviceID: device.id, appID: frontAppID, assignments: assignments, defaultPresetID: defaultPresetID, appName: appName)
            ))
        }
        if devices.isEmpty {
            lines.append(DeviceContextLine(id: "no-devices", symbol: "computermouse", title: "Mice and trackpads", detail: "None connected."))
        }

        let active = remapEnabled ? remapRules.filter { $0.enabled && ($0.appIds.isEmpty || frontAppID.map($0.appIds.contains) == true) } : []
        if !remapEnabled {
            lines.append(DeviceContextLine(id: "remap", symbol: "arrow.left.arrow.right", title: "Key remapping", detail: "Off."))
        } else if active.isEmpty {
            lines.append(DeviceContextLine(id: "remap", symbol: "arrow.left.arrow.right", title: "Key remapping", detail: "On, with no rule for \(frontAppName ?? "this app")."))
        } else {
            let names = active.prefix(4).map(\.name).joined(separator: ", ") + (active.count > 4 ? " and \(active.count - 4) more" : "")
            lines.append(DeviceContextLine(id: "remap", symbol: "arrow.left.arrow.right", title: "Key remapping", detail: "\(active.count) rule\(active.count == 1 ? " applies" : "s apply") here: \(names)."))
        }

        if secureInput.enabled {
            let holder = secureInput.appName.map { " (held by \($0))" } ?? ""
            lines.append(DeviceContextLine(id: "secure", symbol: "lock.fill", title: "Secure input", detail: "On\(holder), so key rules and text expansion cannot see typing until it is released."))
        }
        return lines
    }

    /// What decided the preset, in the same order the core uses: device and app, then app, then device, then the default.
    static func reason(presetID: String, deviceID: String, appID: String?, assignments: [MouseAssignment], defaultPresetID: String, appName: (String) -> String) -> String {
        func matching(_ test: (MouseAssignment) -> Bool) -> Bool { assignments.contains { $0.presetId == presetID && test($0) } }
        if let appID, matching({ $0.deviceId == deviceID && $0.appId == appID }) { return "You chose it for this device in \(appName(appID))." }
        if let appID, matching({ $0.deviceId == nil && $0.appId == appID }) { return "You chose it for \(appName(appID))." }
        if matching({ $0.deviceId == deviceID && $0.appId == nil }) { return "You chose it for this device." }
        return presetID == defaultPresetID ? "It is the default, and nothing more specific is set." : "It applies by an assignment you made."
    }
}
