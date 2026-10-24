import AppKit
import ApplicationServices
import AVFoundation
import Combine
import CoreBluetooth
import CoreLocation
import EventKit
import IOKit.hid
import UserNotifications

enum Permission: String, CaseIterable, Identifiable {
    case accessibility
    case inputMonitoring
    case screenRecording
    case automation
    case location
    case notifications
    case camera
    case microphone
    case bluetooth
    case calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .screenRecording: return "Screen Recording"
        case .automation: return "Automation"
        case .location: return "Location"
        case .notifications: return "Notifications"
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .bluetooth: return "Bluetooth"
        case .calendar: return "Calendar"
        }
    }

    /// The permission a feature's list names, by its title (the registry lists permissions as plain words).
    static func named(_ name: String) -> Permission? { allCases.first { $0.title.caseInsensitiveCompare(name) == .orderedSame } }

    var reason: String {
        switch self {
        case .accessibility: return "Lets Kriya move and resize windows, press keys for you, and read the window buttons."
        case .inputMonitoring: return "Lets Kriya see mouse buttons, scrolling and gestures so it can change how they behave."
        case .screenRecording: return "Needed for window previews, and for screenshots when you ask for one. Kriya never records your screen on its own."
        case .automation: return "Lets Kriya's scripts control other apps. macOS asks once for each app a script controls."
        case .location: return "Only for Sound by Place: compares where this Mac is with the places you saved. The position is never stored or sent."
        case .notifications: return "Expiry reminders for the file shelf, focus session breaks and system monitor alerts. Notices on this Mac only."
        case .camera: return "Only to show your camera in a small window while you record the screen with the camera on."
        case .microphone: return "Only for dictation, and for screen recordings that include the microphone. Nothing is kept except the recording you make."
        case .bluetooth: return "Lets sound rules connect and disconnect your paired headphones and speakers, and read whether they are connected."
        case .calendar: return "Lets the launcher show your next event and open its video call. It stays on this Mac."
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .automation: return "gearshape.2"
        case .location: return "location"
        case .notifications: return "bell.badge"
        case .camera: return "camera"
        case .microphone: return "mic"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .calendar: return "calendar"
        }
    }

    var settingsURL: URL {
        if self == .notifications { return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")! }
        let pane: String
        switch self {
        case .accessibility: pane = "Privacy_Accessibility"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .automation: pane = "Privacy_Automation"
        case .location: pane = "Privacy_LocationServices"
        case .camera: pane = "Privacy_Camera"
        case .microphone: pane = "Privacy_Microphone"
        case .bluetooth: pane = "Privacy_Bluetooth"
        case .calendar: pane = "Privacy_Calendars"
        case .notifications: pane = ""
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

/// What to tell the person when a permission changes while Kriya is running.
enum PermissionChange {
    /// A sentence for a permission that was taken away or given, or nil for a change that needs no notice (such as the first
    /// check, or "not asked yet" turning into "asked").
    static func notice(_ permission: Permission, from old: PermissionStatus?, to new: PermissionStatus) -> String? {
        guard let old, old != new else { return nil }
        if old == .granted, new != .granted {
            return "\(permission.title) was turned off for Kriya. Features that need it have stopped. Turn it back on in System Settings › Privacy & Security."
        }
        if new == .granted, old != .granted {
            return "\(permission.title) is on for Kriya. Features that were waiting for it can start."
        }
        return nil
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
        case .location:
            switch CLLocationManager().authorizationStatus {
            case .authorizedAlways, .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .notDetermined
            }
        case .notifications:
            // The system answers asynchronously, so the last answer is shown and the next one is asked for.
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: Self.notifications.set(.granted)
                case .denied: Self.notifications.set(.denied)
                default: Self.notifications.set(.notDetermined)
                }
            }
            return Self.notifications.value
        case .camera: return Self.media(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone: return Self.media(AVCaptureDevice.authorizationStatus(for: .audio))
        case .bluetooth:
            switch CBCentralManager.authorization {
            case .allowedAlways: return .granted
            case .denied, .restricted: return .denied
            default: return .notDetermined
            }
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess, .authorized: return .granted
            case .denied, .restricted, .writeOnly: return .denied
            default: return .notDetermined
            }
        }
    }

    private static func media(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    /// The newest answer about notifications, kept between checks.
    private final class Cached {
        private let lock = NSLock()
        private var stored = PermissionStatus.notDetermined
        var value: PermissionStatus { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ status: PermissionStatus) { lock.lock(); stored = status; lock.unlock() }
    }
    private static let notifications = Cached()
    private static let locationManager = CLLocationManager()
    private static var bluetooth: CBCentralManager?

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
        case .location: Self.locationManager.requestWhenInUseAuthorization()
        case .notifications: UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        case .camera: AVCaptureDevice.requestAccess(for: .video) { _ in }
        case .microphone: AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .bluetooth: Self.bluetooth = CBCentralManager(delegate: nil, queue: nil)   // creating the manager is what makes macOS ask
        case .calendar: EKEventStore().requestFullAccessToEvents { _, _ in }
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
            FeatureActivity.shared.changed("permission:" + permission.rawValue, "\(permission.title) is now \(state == .granted ? "allowed" : (state == .denied ? "denied" : "not set"))")
            if defaults.object(forKey: "permissionNotices") as? Bool ?? true, let text = PermissionChange.notice(permission, from: statuses[permission], to: state) {
                Toast().show(text, isError: state != .granted)
            }
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
