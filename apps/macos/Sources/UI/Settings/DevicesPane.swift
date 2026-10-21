import SwiftUI

struct DevicesPane: View {
    @EnvironmentObject private var devices: DeviceRegistry

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
