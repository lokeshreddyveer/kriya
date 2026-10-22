import AppKit
import ApplicationServices
import Combine
import IOKit.hid

enum Permission: String, CaseIterable, Identifiable {
    case accessibility
    case inputMonitoring
    case screenRecording
    case automation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .screenRecording: return "Screen Recording"
        case .automation: return "Automation"
        }
    }

    var reason: String {
        switch self {
        case .accessibility: return "Lets Kriya move and resize windows, press keys for you, and read the window buttons."
        case .inputMonitoring: return "Lets Kriya see mouse buttons, scrolling and gestures so it can change how they behave."
        case .screenRecording: return "Needed for window previews, and for screenshots when you ask for one. Kriya never records your screen on its own."
        case .automation: return "Lets Kriya's scripts control other apps. macOS asks once for each app a script controls."
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .automation: return "gearshape.2"
        }
    }

    var settingsURL: URL {
        let pane: String
        switch self {
        case .accessibility: pane = "Privacy_Accessibility"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .automation: pane = "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

enum PermissionStatus: Equatable {
    case granted
    case denied
    case notDetermined
    /// Asked per app at the moment it is needed, so there is no single state to show.
    case onDemand
}

/// How the system is asked about permissions. Tests replace it so they never touch the real settings.
protocol PermissionProbe {
    func status(of permission: Permission) -> PermissionStatus
    func request(_ permission: Permission)
}

struct SystemPermissionProbe: PermissionProbe {
    func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: return .granted
            case kIOHIDAccessTypeDenied: return .denied
            default: return .notDetermined
            }
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .automation:
            return .onDemand
        }
    }

    func request(_ permission: Permission) {
        switch permission {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .automation:
            break
        }
    }
}

/// Watches the system permissions Kriya needs. Nothing is requested at launch: a permission is asked for only when the
/// person turns on a feature that needs it. Status is re-checked while the app runs, so a permission granted or taken
/// away in System Settings is noticed within a couple of seconds and features start or stop to match.
final class PermissionManager: ObservableObject {
    @Published private(set) var statuses: [Permission: PermissionStatus] = [:]

    private let probe: PermissionProbe
    private let defaults: UserDefaults
    private var timer: Timer?
    private var activeObserver: NSObjectProtocol?

    init(probe: PermissionProbe = SystemPermissionProbe(), defaults: UserDefaults = .standard) {
        self.probe = probe
        self.defaults = defaults
        refresh()
    }

    deinit { stopMonitoring() }

    func status(_ permission: Permission) -> PermissionStatus {
        statuses[permission] ?? .notDetermined
    }

    func isGranted(_ permission: Permission) -> Bool {
        status(permission) == .granted
    }

    func missing(for feature: FeatureId) -> [Permission] {
        feature.requiredPermissions.filter { !isGranted($0) }
    }

    func refresh() {
        var updated: [Permission: PermissionStatus] = [:]
        for permission in Permission.allCases {
            var state = probe.status(of: permission)
            // macOS cannot say "never asked", so the app remembers whether it asked.
            if state == .denied, !wasRequested(permission) { state = .notDetermined }
            updated[permission] = state
        }
        guard updated != statuses else { return }
        for (permission, state) in updated where statuses[permission] != nil && statuses[permission] != state {
            Log.info("Permissions", "\(permission.title) is now \(state)")
        }
        statuses = updated
    }

    /// Asks for a permission. macOS shows its prompt only once; after that the way forward is the Privacy settings pane.
    func request(_ permission: Permission) {
        if status(permission) == .denied || permission == .automation {
            openSettings(permission)
            return
        }
        markRequested(permission)
        probe.request(permission)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    func openSettings(_ permission: Permission) {
        markRequested(permission)
        NSWorkspace.shared.open(permission.settingsURL)
    }

    func startMonitoring() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
    }

    private func key(_ permission: Permission) -> String { "permissionRequested.\(permission.rawValue)" }
    private func wasRequested(_ permission: Permission) -> Bool { defaults.bool(forKey: key(permission)) }
    private func markRequested(_ permission: Permission) { defaults.set(true, forKey: key(permission)) }
}
