import AppIntents
import Foundation

/// Where the sound actions for Shortcuts find the mixer. Set by the app.
enum SoundIntentBridge {
    @MainActor static var engine: AppAudioEngine?
    @MainActor static var mixer: SoundMixerModel?
}

enum SoundIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady, noApp(String), noDevice(String)
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: return "Kriya is not ready yet."
        case .noApp(let n): return "No app named “\(n)” is making sound or has settings."
        case .noDevice(let n): return "No sound output named “\(n)” was found."
        }
    }
}

struct SetAppVolumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set an App's Volume"
    static var description = IntentDescription("Changes how loud one app is, from 0 to 400 percent. Use the name “All sound” for everything.")
    static var openAppWhenRun = false

    @Parameter(title: "App name") var app: String
    @Parameter(title: "Volume (percent)", default: 100) var percent: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let engine = SoundIntentBridge.engine else { throw SoundIntentError.notReady }
        let key = try SoundIntentLookup.key(for: app, engine: engine)
        engine.update(key) { $0.volume = Double(min(max(percent, 0), 400)) / 100 }
        return .result()
    }
}

struct MuteAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Mute or Unmute an App"
    static var description = IntentDescription("Silences one app, or brings its sound back. Use “All sound” for everything.")
    static var openAppWhenRun = false

    @Parameter(title: "App name") var app: String
    @Parameter(title: "Muted", default: true) var muted: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let engine = SoundIntentBridge.engine else { throw SoundIntentError.notReady }
        let key = try SoundIntentLookup.key(for: app, engine: engine)
        engine.update(key) { $0.muted = muted }
        return .result()
    }
}

struct SetSoundOutputIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Sound On"
    static var description = IntentDescription("Switches the Mac's sound output to the device whose name contains the words you give.")
    static var openAppWhenRun = false

    @Parameter(title: "Device name") var device: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let mixer = SoundIntentBridge.mixer else { throw SoundIntentError.notReady }
        mixer.refresh()
        guard let match = mixer.outputs.first(where: { $0.name.lowercased().contains(device.lowercased()) }) else { throw SoundIntentError.noDevice(device) }
        mixer.chooseOutput(match.id)
        return .result()
    }
}

struct SetSystemVolumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set the Mac's Volume"
    static var description = IntentDescription("Sets the sound output's own volume, from 0 to 100 percent.")
    static var openAppWhenRun = false

    @Parameter(title: "Volume (percent)", default: 50) var percent: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let mixer = SoundIntentBridge.mixer else { throw SoundIntentError.notReady }
        mixer.refresh()
        mixer.setVolume(Double(min(max(percent, 0), 100)) / 100)
        return .result()
    }
}

enum SoundIntentLookup {
    /// The mixer key for an app named in a shortcut: "All sound", or an app whose name or bundle identifier contains the words.
    @MainActor
    static func key(for name: String, engine: AppAudioEngine) throws -> String {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        if ["all", "all sound", "everything", "system"].contains(wanted) { return AppAudioEngine.systemKey }
        engine.refresh()
        if let app = engine.apps.first(where: { $0.name.lowercased() == wanted }) ?? engine.apps.first(where: { $0.name.lowercased().contains(wanted) || $0.bundleID.lowercased().contains(wanted) }) { return app.id }
        throw SoundIntentError.noApp(name)
    }
}
