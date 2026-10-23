import AppKit
import AppIntents
import Foundation

/// Receives `kriya://run`, `action`, `workflow` and `launcher` addresses, from the command-line tool, a script or the
/// Shortcuts app, checks the secret, and does what was asked through the same paths a shortcut would.
final class RemoteCommands {
    /// The one running copy, which the Shortcuts actions reach.
    static weak var shared: RemoteCommands?

    private let token: String
    private(set) var handled = 0
    private(set) var refused = 0
    var runCommand: (String) -> Void = { _ in }
    var runAction: (String) -> Void = { _ in }
    var runWorkflow: (String) -> Void = { _ in }
    var showLauncher: (String?) -> Void = { _ in }

    init(support: URL) {
        token = BridgeToken.loadOrCreate(in: support)
        Self.shared = self
    }

    @discardableResult
    func handle(_ url: URL) -> Bool {
        switch RemoteCommand.parse(url, token: token) {
        case .failure(let failure):
            if failure != .notOurs { refused += 1; Log.warning("Remote", "A request was refused") }
            return false
        case .success(let command):
            perform(command)
            return true
        }
    }

    func perform(_ command: RemoteCommand) {
        handled += 1
        // Command names are logged; what a launcher request typed is not.
        switch command {
        case .command(let id): Log.info("Remote", "Running command \(id.prefix(60))"); DispatchQueue.main.async { self.runCommand(id) }
        case .action(let id): Log.info("Remote", "Running a saved action"); DispatchQueue.main.async { self.runAction(id) }
        case .workflow(let id): Log.info("Remote", "Running a workflow"); DispatchQueue.main.async { self.runWorkflow(id) }
        case .launcher(let text): DispatchQueue.main.async { self.showLauncher(text) }
        }
    }
}

// MARK: - Shortcuts, Siri and Spotlight

struct OpenKriyaLauncherIntent: AppIntent {
    static var title: LocalizedStringResource = "Open the Kriya Launcher"
    static var description = IntentDescription("Opens Kriya's launcher, with some text typed if you give it.")
    static var openAppWhenRun = false

    @Parameter(title: "Text to search for") var text: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        RemoteCommands.shared?.perform(.launcher(text))
        return .result()
    }
}

struct RunKriyaCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Run a Kriya Command"
    static var description = IntentDescription("Runs a Kriya command by its name, such as window.left_half or pointer.spotlight.")
    static var openAppWhenRun = false

    @Parameter(title: "Command") var command: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard RemoteCommand.isValidID(command) else { throw IntentError.badCommand }
        RemoteCommands.shared?.perform(.command(command))
        return .result()
    }
}

struct RunKriyaActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Run a Saved Kriya Action"
    static var description = IntentDescription("Runs one of your saved actions by its id.")
    static var openAppWhenRun = false

    @Parameter(title: "Action id") var actionID: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard RemoteCommand.isValidID(actionID) else { throw IntentError.badCommand }
        RemoteCommands.shared?.perform(.action(actionID))
        return .result()
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case badCommand
    var localizedStringResource: LocalizedStringResource { "That is not a name Kriya can run." }
}

struct KriyaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenKriyaLauncherIntent(), phrases: ["Open the launcher in \(.applicationName)", "Search with \(.applicationName)"], shortTitle: "Open Launcher", systemImageName: "magnifyingglass")
        AppShortcut(intent: SetAppVolumeIntent(), phrases: ["Set an app's volume in \(.applicationName)"], shortTitle: "Set App Volume", systemImageName: "speaker.wave.2")
        AppShortcut(intent: SetSoundOutputIntent(), phrases: ["Play sound on a device with \(.applicationName)"], shortTitle: "Play Sound On", systemImageName: "hifispeaker")
    }
}
