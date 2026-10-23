import Foundation

/// A named way of capturing: where the picture goes and what happens to it. The shortcuts and recording options are not part of it.
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

    static func from(_ settings: CaptureSettings, named name: String) -> CaptureProfile {
        CaptureProfile(
            name: name, copyImage: settings.copyImage, saveToFolder: settings.saveToFolder, folderPath: settings.folderPath, openEditor: settings.openEditor,
            redactAutomatically: settings.redactAutomatically, delaySeconds: settings.delaySeconds, playSound: settings.playSound,
            namePattern: settings.namePattern, includeCursor: settings.includeCursor ?? false
        )
    }

    /// The settings with this profile's choices put in; everything else (shortcuts, words to hide, recording) is kept.
    func applied(to settings: CaptureSettings) -> CaptureSettings {
        var s = settings
        s.copyImage = copyImage; s.saveToFolder = saveToFolder; s.folderPath = folderPath; s.openEditor = openEditor
        s.redactAutomatically = redactAutomatically; s.delaySeconds = min(max(delaySeconds, 0), 30); s.playSound = playSound
        s.namePattern = namePattern; s.includeCursor = includeCursor
        // A profile that neither copies nor saves would throw the picture away.
        if !s.copyImage && !s.saveToFolder { s.copyImage = true }
        return s
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
