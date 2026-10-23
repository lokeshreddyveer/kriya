import SwiftUI

struct DevicesPane: View {
    @EnvironmentObject private var devices: DeviceRegistry
    @EnvironmentObject private var mouse: MouseStore
    @EnvironmentObject private var remap: RemapStore
    @State private var front = NSWorkspace.shared.frontmostApplication
    @State private var secure = SecureInput.current()
    @State private var events: [String] = []
    @State private var testing = false

    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var context: [DeviceContextLine] {
        // Kriya's own window is in front while this pane is open, so the app that was in front before it is used.
        let app = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        return DeviceContext.explain(
            devices: connected.map { ($0.id, $0.displayName) }, presets: mouse.presets, assignments: mouse.assignments,
            defaultPresetID: mouse.config.defaultPresetId, frontAppID: app?.bundleIdentifier, frontAppName: app?.localizedName ?? "Kriya",
            remapRules: remap.config.rules, remapEnabled: remap.config.enabled, secureInput: secure, appName: AppChoice.name(for:)
        )
    }

    private var connected: [InputDevice] { devices.devices.filter(\.isConnected) }
    private var remembered: [InputDevice] { devices.devices.filter { !$0.isConnected } }

    var body: some View {
        Form {
            if devices.devices.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "computermouse").font(.largeTitle).foregroundStyle(.tertiary)
                        Text("No mice or trackpads yet").font(.headline)
                        Text("Plug one in or pair a Bluetooth device and it will appear here.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }
            if !connected.isEmpty {
                Section("Connected") {
                    ForEach(connected) { DeviceRow(device: $0) }
                }
            }
            if !remembered.isEmpty {
                Section {
                    ForEach(remembered) { DeviceRow(device: $0) }
                } header: {
                    Text("Previously connected")
                } footer: {
                    Text("Kriya remembers a device's name and settings, so they come back when it reconnects.")
                }
            }

            if !DeviceTimelineStore.shared.timeline.events.isEmpty {
                DeviceTimelineSection()
            }

            Section {
                ForEach(context) { line in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: line.symbol).frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.title)
                            Text(line.detail).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("What applies right now") } footer: {
                Text("For each device, the mouse settings in effect for the app in front. A choice for a device in an app beats one for the app, which beats one for the device, which beats the default. Change them in the Mouse pane.")
            }

            Section {
                InputTester { event in
                    // Which device it came from is macOS's best guess from the last device that moved.
                    let line = InputTesterFormat.attributed(event, device: devices.activeDeviceName())
                    withAnimation(.smooth(duration: 0.12)) { events = Array(([line] + events).prefix(8)) }
                }
                .frame(height: 96)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 3])))
                .overlay(Text("Click here, then press buttons, scroll or type").font(.callout).foregroundStyle(.tertiary).allowsHitTesting(false))
                ForEach(Array(events.enumerated()), id: \.offset) { index, text in
                    Text(text).font(.system(.callout, design: .monospaced)).foregroundStyle(index == 0 ? Color.primary : Color.secondary)
                }
                if !events.isEmpty { Button("Clear") { events.removeAll() }.controlSize(.small) }
            } header: { Text("Test a device") } footer: {
                Text("Shows what the mouse, trackpad or keyboard sends, as macOS reports it, while the pointer is over the square, with the device it seems to come from (macOS does not say, so this is the device that last moved). It sees nothing outside it, and nothing is kept. To see which part of Kriya acted on a button anywhere else, start a trace in Diagnostics › Trace.")
            }
        }
        .onReceive(ticker) { _ in
            front = NSWorkspace.shared.frontmostApplication
            secure = SecureInput.current()
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.3), value: devices.devices)
    }
}

private struct DeviceRow: View {
    let device: InputDevice
    @EnvironmentObject private var registry: DeviceRegistry

    @State private var expanded = false
    @State private var nickname = ""

    private var connectionChoice: Binding<ConnectionKind?> {
        Binding(
            get: { device.record.connectionOverride },
            set: { registry.setConnectionOverride($0, for: device.id) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: device.record.kind.symbol)
                    .font(.title2)
                    .frame(width: 30)
                    .foregroundStyle(device.isConnected ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.displayName).font(.headline)
                    HStack(spacing: 8) {
                        Label(device.connection.title, systemImage: device.connection.symbol)
                        Text("·")
                        Text(device.record.kind.title)
                        Text("·")
                        StateBadge(
                            text: device.isConnected ? "Connected" : "Last seen " + Date(timeIntervalSince1970: TimeInterval(device.record.lastSeen)).shortDescription,
                            color: device.isConnected ? Theme.ok : .secondary
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if device.isConnected, let status = registry.statuses[device.id] {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(DeviceStatusText.battery(status.battery, connection: device.connection), systemImage: batterySymbol(status.battery))
                            if let text = DeviceStatusText.lastUsed(status.lastUsed) { Text(text) }
                            if let text = DeviceStatusText.reconnected(status.reconnectedAt) { Text(text) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                    }
                }
                Spacer()
                Button {
                    withAnimation(.smooth(duration: 0.25)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .buttonStyle(.borderless)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name", text: $nickname, prompt: Text(device.record.name))
                        .onSubmit(commitNickname)
                    Picker("Connection", selection: connectionChoice) {
                        Text("Detected: \(device.record.detectedConnection.title)").tag(ConnectionKind?.none)
                        Text("Wired").tag(ConnectionKind?.some(.wired))
                        Text("Wireless").tag(ConnectionKind?.some(.wireless))
                    }
                    LabeledContent("Identifier") {
                        Text(identifier).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    LabeledContent("Connection type reported") { Text(device.record.transport) }
                    if !device.isConnected {
                        Button("Forget This Device", role: .destructive) {
                            withAnimation(.smooth) { registry.forget(device.id) }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.leading, 44)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
        .onAppear { nickname = device.record.nickname ?? "" }
        .onChange(of: expanded) { _, isOpen in if !isOpen { commitNickname() } }
    }

    private func batterySymbol(_ state: BatteryState) -> String {
        guard case .level(let percent, let charging) = state else { return "battery.0percent" }
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var identifier: String {
        String(format: "%04X:%04X", device.record.vendorId, device.record.productId)
    }

    private func commitNickname() {
        let trimmed = nickname.trimmingCharacters(in: .whitespaces)
        let new = trimmed.isEmpty ? nil : trimmed
        guard new != device.record.nickname else { return }
        registry.setNickname(new, for: device.id)
    }
}


private struct DeviceTimelineSection: View {
    @ObservedObject private var store = DeviceTimelineStore.shared

    var body: some View {
        let names = Array(Set(store.timeline.events.map(\.device))).sorted()
        Section {
            ForEach(names, id: \.self) { name in
                if let health = store.timeline.health(of: name, now: Date()) {
                    HStack { Text(name); Spacer(); Text("\(health) · \(DeviceTimeline.describe(health: health))").foregroundStyle(.secondary).font(.callout) }
                }
            }
            ForEach(store.timeline.events.prefix(8)) { event in
                HStack {
                    Image(systemName: event.connected ? "plus.circle" : "minus.circle").foregroundStyle(event.connected ? Theme.ok : Theme.warn)
                    Text("\(event.device) \(event.connected ? "connected" : "disconnected")")
                    Spacer()
                    Text(event.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }.font(.callout)
            }
            Button("Clear Timeline") { store.clear() }.controlSize(.small)
        } header: { Text("Connection timeline") } footer: { Text("When each device connected or disconnected. A device that keeps dropping scores lower.") }
    }
}
