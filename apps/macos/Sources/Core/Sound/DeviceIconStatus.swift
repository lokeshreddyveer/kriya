import Foundation

/// What a device's menu-bar icon says about it.
enum DeviceIconState: String, Equatable {
    /// The Mac is using it now.
    case active
    /// Connected, not in use.
    case connected
    /// In use (or connected) with its sound muted.
    case muted
    /// Not connected.
    case disconnected
    /// Being connected to again after it dropped.
    case reconnecting
    /// Not connected, and the sound is on another device in its place.
    case fallback

    static func resolve(connected: Bool, inUse: Bool, muted: Bool, reconnecting: Bool, replacedBy otherInUse: Bool) -> DeviceIconState {
        if connected { return muted ? .muted : (inUse ? .active : .connected) }
        if reconnecting { return .reconnecting }
        return otherInUse ? .fallback : .disconnected
    }

    var title: String {
        switch self {
        case .active: return "In use"
        case .connected: return "Connected"
        case .muted: return "Muted"
        case .disconnected: return "Not connected"
        case .reconnecting: return "Reconnecting…"
        case .fallback: return "Not connected, using another device"
        }
    }

    /// How faded its icon is: a device that is not there is drawn dimmer than one that is.
    var opacity: Double {
        switch self {
        case .active, .muted: return 1
        case .connected: return 0.8
        case .reconnecting: return 0.6
        case .disconnected, .fallback: return 0.4
        }
    }

    /// Whether a slash is drawn across the icon.
    var slashed: Bool { self == .muted || self == .disconnected || self == .fallback }
}

/// A device the person put in the menu bar. Saved by its unique name so it is found again after being unplugged.
struct PinnedDevice: Codable, Equatable, Identifiable {
    var uid: String
    var name: String
    var input: Bool
    var id: String { (input ? "in:" : "out:") + uid }

    static func adding(_ device: PinnedDevice, to list: [PinnedDevice]) -> [PinnedDevice] { list.contains { $0.id == device.id } ? list : list + [device] }
    static func removing(_ id: String, from list: [PinnedDevice]) -> [PinnedDevice] { list.filter { $0.id != id } }
}
