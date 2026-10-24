import Foundation

struct IntentApp: Equatable {
    var bundleID: String
    var name: String
    /// Short names the person gave it ("ff" for Firefox).
    var aliases: [String] = []
    var isRunning = false
    var lastUsed: Date?
}

struct IntentDevice: Equatable {
    var uid: String
    var name: String
    /// Names the person gave it ("desk", "headphones").
    var nicknames: [String] = []
}

struct IntentWorkflow: Equatable {
    var id: String
    var name: String
    /// Whether it does something that should be confirmed first (runs a script, changes files, sends something).
    var isRisky: Bool
}

/// Everything a request can refer to, handed in as plain values so reading a request touches nothing and can be tested exactly.
/// The app fills it from the real apps, devices, workflows and command registry each time.
struct IntentWorld {
    /// Stands for all sound, not one app.
    static let systemApp = "system"

    var apps: [IntentApp] = []
    var devices: [IntentDevice] = []
    var workflows: [IntentWorkflow] = []
    /// Every command in the command registry. A command not listed here is never run from a request.
    var commands: Set<String> = []
    /// "downloads", "desktop", "documents", "home".
    var folders: [String: URL] = [:]
    /// The newest file of a kind: "screenshot" or "download".
    var recentFile: (String) -> URL? = { _ in nil }
    var fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    var defaultEngine = "google"
    var now = Date()
    var calendar = Calendar.current
    /// The app in front, for "this app" and "it".
    var frontAppBundleID: String?
    /// Whether Local-only mode is on: nothing may leave this Mac, so nothing is sent to an AI provider.
    var localOnly = false

    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser

    // MARK: Matching names

    enum Match<T: Equatable>: Equatable {
        case none
        case one(T, confidence: Double)
        case many([T])
    }

    /// Words that carry no meaning in an app's name when a person says it.
    private static let nameNoise: Set<String> = ["the", "app", "application", "my", "a"]

    static func cleanName(_ text: String) -> String {
        text.lowercased().split(separator: " ").map(String.init).filter { !nameNoise.contains($0) }.joined(separator: " ")
    }

    /// Picks the one app a name means, or says that it means several, or none. A name that fits two apps is never guessed between.
    func resolveApp(_ spoken: String) -> Match<IntentApp> {
        let name = Self.cleanName(spoken)
        guard !name.isEmpty else { return .none }
        if ["this", "it", "this app", "current", "current app", "front", "front app", "frontmost", "frontmost app", "that"].contains(name) {
            if let id = frontAppBundleID, let app = apps.first(where: { $0.bundleID == id }) { return .one(app, confidence: 1) }
            return .none
        }
        func labels(_ app: IntentApp) -> [String] { ([app.name] + app.aliases + [app.bundleID]).map { $0.lowercased() } }
        let exact = apps.filter { labels($0).contains(name) }
        if exact.count == 1 { return .one(exact[0], confidence: 1) }
        if exact.count > 1 { return .many(exact) }
        let starts = apps.filter { app in labels(app).contains { $0.hasPrefix(name) || $0.split(separator: " ").contains { $0.hasPrefix(name) } } }
        if starts.count == 1 { return .one(starts[0], confidence: 0.85) }
        if starts.count > 1 { return .many(starts) }
        let inside = apps.filter { app in labels(app).contains { $0.contains(name) } }
        if inside.count == 1 { return .one(inside[0], confidence: 0.7) }
        if inside.count > 1 { return .many(inside) }
        return .none
    }

    func resolveDevice(_ spoken: String) -> Match<IntentDevice> {
        let name = Self.cleanName(spoken)
        guard !name.isEmpty else { return .none }
        func labels(_ d: IntentDevice) -> [String] { ([d.name] + d.nicknames).map { $0.lowercased() } }
        let exact = devices.filter { labels($0).contains(name) }
        if exact.count == 1 { return .one(exact[0], confidence: 1) }
        if exact.count > 1 { return .many(exact) }
        let partial = devices.filter { labels($0).contains { $0.contains(name) || name.contains($0) } }
        if partial.count == 1 { return .one(partial[0], confidence: 0.8) }
        if partial.count > 1 { return .many(partial) }
        return .none
    }

    func resolveWorkflow(_ spoken: String) -> Match<IntentWorkflow> {
        let name = Self.cleanName(spoken)
        guard !name.isEmpty else { return .none }
        let exact = workflows.filter { $0.name.lowercased() == name || $0.id.lowercased() == name }
        if exact.count == 1 { return .one(exact[0], confidence: 1) }
        if exact.count > 1 { return .many(exact) }
        let partial = workflows.filter { $0.name.lowercased().contains(name) || name.contains($0.name.lowercased()) }
        if partial.count == 1 { return .one(partial[0], confidence: 0.8) }
        if partial.count > 1 { return .many(partial) }
        return .none
    }
}

/// A quick, side-effect-free test of whether text reads as a request, for the places that must not keep one (the search history).
enum IntentGate {
    static func isRequest(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("?") { return true }
        // An empty world is enough: a request that names an app Kriya does not know still reads as a request.
        return IntentParser.parse(trimmed, world: IntentWorld()).isRequest
    }
}
