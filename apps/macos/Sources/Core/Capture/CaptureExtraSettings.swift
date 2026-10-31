import Foundation

/// The capture options added after the first version, kept as plain preferences with safe defaults.
enum CaptureExtraSettings {
    static let formatKey = "capture.format"
    static let keepOriginalKey = "capture.keepOriginal"
    static let beautifyKey = "capture.beautify.v1"
    static let excludedAppsKey = "capture.excludedApps.v1"
    static let modesKey = "capture.modes.v1"

    /// How the capture modes behave: the selector, the self-timer, windows, displays, saved areas.
    static var modes: CaptureModeSettings {
        get { UserDefaults.standard.data(forKey: modesKey).flatMap { try? JSONDecoder().decode(CaptureModeSettings.self, from: $0) } ?? CaptureModeSettings() }
        set { if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: modesKey) } }
    }

    /// How pictures are saved. PNG unless changed.
    static var format: CaptureFormat {
        get { UserDefaults.standard.string(forKey: formatKey).flatMap(CaptureFormat.init(rawValue:)) ?? .png }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: formatKey) }
    }

    /// When a capture is edited, the untouched picture is saved too, beside the edited one.
    static var keepOriginal: Bool {
        get { UserDefaults.standard.bool(forKey: keepOriginalKey) }
        set { UserDefaults.standard.set(newValue, forKey: keepOriginalKey) }
    }

    /// The backdrop and corners put around every capture. Off (no backdrop) unless set.
    static var beautify: CaptureBeautify {
        get { UserDefaults.standard.data(forKey: beautifyKey).flatMap { try? JSONDecoder().decode(CaptureBeautify.self, from: $0) } ?? CaptureBeautify() }
        set { if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: beautifyKey) } }
    }

    /// What happens after a capture, for screenshots, recordings, GIFs, text and uploads, and how pictures are written.
    static var delivery: CaptureDeliveryPolicy {
        get { CaptureDeliveryStore().policy }
        set { CaptureDeliveryStore().policy = newValue }
    }

    /// Apps a capture refuses to photograph. Password managers to start with.
    static var excludedApps: [String] {
        get { UserDefaults.standard.stringArray(forKey: excludedAppsKey) ?? CaptureExclusions.defaults }
        set { UserDefaults.standard.set(Array(Set(newValue)).sorted(), forKey: excludedAppsKey) }
    }
}
