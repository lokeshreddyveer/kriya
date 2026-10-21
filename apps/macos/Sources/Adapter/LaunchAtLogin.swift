import ServiceManagement

/// Starting Kriya when the person logs in, through the system's login-item service.
enum LaunchAtLogin {
    enum Status: Equatable {
        case enabled
        case disabled
        /// The person must approve the item in System Settings > General > Login Items.
        case requiresApproval
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .disabled
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else {
            if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
        }
        Log.info("Startup", "Launch at login is now \(enabled ? "on" : "off")")
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
