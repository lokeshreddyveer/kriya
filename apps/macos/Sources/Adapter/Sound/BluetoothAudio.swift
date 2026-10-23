import Foundation
import IOBluetooth

/// A paired Bluetooth audio device (headphones, a speaker, a headset).
struct BluetoothPeer: Identifiable, Equatable {
    let address: String
    let name: String
    let isConnected: Bool
    var id: String { address }
}

/// Connecting and disconnecting paired Bluetooth audio devices. Only devices already paired in System Settings are listed;
/// Kriya cannot pair new ones. macOS asks for Bluetooth permission the first time.
enum BluetoothAudio {
    /// The Bluetooth device class for audio and video devices.
    private static let audioMajorClass: UInt32 = 0x04

    static func paired() -> [BluetoothPeer] {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices
            .filter { $0.deviceClassMajor == audioMajorClass }
            .compactMap { device -> BluetoothPeer? in
                guard let address = device.addressString else { return nil }
                return BluetoothPeer(address: address, name: device.name ?? address, isConnected: device.isConnected())
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The paired device whose name contains `text` (ignoring case).
    static func peer(named text: String, in peers: [BluetoothPeer]) -> BluetoothPeer? {
        let wanted = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        return peers.first { $0.name.lowercased().contains(wanted) }
    }

    /// Connects or disconnects. Blocks until the system answers, so call it off the main thread.
    @discardableResult
    static func set(connected: Bool, address: String) -> Bool {
        guard let device = IOBluetoothDevice(addressString: address) else { return false }
        if connected {
            return device.isConnected() || device.openConnection() == kIOReturnSuccess
        }
        return !device.isConnected() || device.closeConnection() == kIOReturnSuccess
    }
}
