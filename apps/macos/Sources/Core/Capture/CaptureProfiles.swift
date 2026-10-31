import Foundation

/// A named way of capturing: where the picture goes, what happens to it, the backdrop and how recordings are made. Shortcuts, the
/// words to hide, and everything that is a permission or belongs to the whole app (pins, the web link, the history length) are not
/// part of it. A choice left empty (nil) leaves the current one alone when the profile is used.
struct CaptureProfile: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var copyImage: Bool
    var saveToFolder: Bool
    var folderPath: String
    var openEditor: Bool
    var redactAutomatically: Bool
    var delaySeconds: Int
    var playSound: Bool
    var namePattern: String?
    var includeCursor: Bool
    /// What happens after a screenshot, a recording and a GIF, each on its own.
    var screenshotSteps: DeliverySteps?
    var recordingSteps: DeliverySteps?
    var gifSteps: DeliverySteps?
    var ocrSteps: DeliverySteps?
    /// The backdrop for screenshots. A style with no backdrop means none on purpose.
    var background: CaptureBeautify?
    var recordingOptions: RecordingOptions?

    static func from(_ settings: CaptureSettings, named name: String) -> CaptureProfile {
        CaptureProfile(
            name: name, copyImage: settings.copyImage, saveToFolder: settings.saveToFolder, folderPath: settings.folderPath, openEditor: settings.openEditor,
            redactAutomatically: settings.redactAutomatically, delaySeconds: settings.delaySeconds, playSound: settings.playSound,
            namePattern: settings.namePattern, includeCursor: settings.includeCursor ?? false
        )
    }

    /// Everything the profile can carry, as it is now.
    static func from(_ settings: CaptureSettings, policy: CaptureDeliveryPolicy, legacyBackdrop: CaptureBeautify, named name: String) -> CaptureProfile {
        var profile = from(settings, named: name)
        profile.screenshotSteps = policy.steps(for: .screenshot, settings: settings)
        profile.recordingSteps = policy.steps(for: .recording, settings: settings)
        profile.gifSteps = policy.steps(for: .gif, settings: settings)
        profile.ocrSteps = policy.steps(for: .ocr, settings: settings)
        profile.background = policy.background.resolve(kind: .screenshot, legacy: legacyBackdrop, modifiers: []) ?? CaptureBeautify()
        profile.recordingOptions = settings.recording
        return profile
    }

    /// The settings with this profile's choices put in; everything else (shortcuts, words to hide) is kept.
    func applied(to settings: CaptureSettings) -> CaptureSettings {
        var s = settings
        s.copyImage = copyImage; s.saveToFolder = saveToFolder; s.folderPath = folderPath; s.openEditor = openEditor
        s.redactAutomatically = redactAutomatically; s.delaySeconds = min(max(delaySeconds, 0), 30); s.playSound = playSound
        s.namePattern = namePattern; s.includeCursor = includeCursor
        if let recordingOptions { s.recording = recordingOptions }
        // A profile that neither copies nor saves would throw the picture away.
        if !s.copyImage && !s.saveToFolder { s.copyImage = true }
        return s
    }

    /// The delivery policy with this profile's steps and backdrop put in. Only what the profile holds is changed.
    func applied(to policy: CaptureDeliveryPolicy) -> CaptureDeliveryPolicy {
        var next = policy
        if let screenshotSteps { next.screenshot = screenshotSteps }
        if let recordingSteps { next.recording = recordingSteps }
        if let gifSteps { next.gif = gifSteps }
        if let ocrSteps { next.ocr = ocrSteps }
        if let background {
            let presetID = BackgroundPolicy.profilePrefix + id
            next.background.presets.removeAll { $0.id == presetID }
            if background.isOn {
                next.background.presets.append(BackgroundPreset(id: presetID, name: name, style: background))
                next.background.screenshotPreset = presetID
            } else {
                next.background.screenshotPreset = BackgroundPolicy.noneID
            }
        }
        return next.sanitized()
    }

    static let starters: [CaptureProfile] = [
        CaptureProfile(name: "Quick copy", copyImage: true, saveToFolder: false, folderPath: "", openEditor: false, redactAutomatically: false, delaySeconds: 0, playSound: false, namePattern: nil, includeCursor: false),
        CaptureProfile(name: "Documentation", copyImage: true, saveToFolder: true, folderPath: "", openEditor: true, redactAutomatically: true, delaySeconds: 0, playSound: false, namePattern: nil, includeCursor: false),
        CaptureProfile(name: "Tutorial", copyImage: false, saveToFolder: true, folderPath: "", openEditor: false, redactAutomatically: false, delaySeconds: 3, playSound: false, namePattern: nil, includeCursor: true),
    ]
}

final class CaptureProfileStore: ObservableObject {
    private static let key = "captureProfiles.v1"
    @Published var profiles: [CaptureProfile] { didSet { if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Self.key) } } }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        profiles = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([CaptureProfile].self, from: $0) } ?? CaptureProfile.starters
    }
}
