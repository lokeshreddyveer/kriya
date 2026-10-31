import AppKit
import AppIntents
import Foundation

/// Receives `kriya://run`, `action`, `workflow` and `launcher` addresses, from the command-line tool, a script or the
/// Shortcuts app, checks the secret, and does what was asked through the same paths a shortcut would.
final class RemoteCommands {
    /// The one running copy, which the Shortcuts actions reach.
    static weak var shared: RemoteCommands?

    let tokens: RemoteTokenStore
    private let defaults: UserDefaults
    private(set) var handled = 0
    private(set) var refused = 0
    var runCommand: (String) -> Void = { _ in }
    var runAction: (String) -> Void = { _ in }
    var runWorkflow: (String) -> Void = { _ in }
    var showLauncher: (String?) -> Void = { _ in }
    /// Says why something was turned away, to the person at the Mac. Replaced in tests.
    var tell: (String) -> Void = { message in
        DispatchQueue.main.async { Toast().show(message, isError: true) }
    }

    init(support: URL, defaults: UserDefaults = .standard) {
        tokens = RemoteTokenStore(support: support)
        self.defaults = defaults
        // The token is made (or taken over from the one links carried before) now, and the command-line tool is told whether this is on.
        tokens.tokenForUse()
        tokens.writeState(enabled: RemoteAccess.isEnabled(defaults))
        Self.shared = self
    }

    /// Whether remote commands are on.
    var isEnabled: Bool { RemoteAccess.isEnabled(defaults) }

    /// Turns remote commands on or off. Off, a request is turned away with a message and nothing is run; the token stays stored but
    /// nothing that carries it is accepted.
    func setEnabled(_ on: Bool) {
        RemoteAccess.setEnabled(on, defaults: defaults)
        tokens.writeState(enabled: on)
    }

    /// A new token. Everything that carried the old one stops working. Returns it, or nil if it could not be saved.
    @discardableResult
    func rotateToken() -> String? { tokens.rotate() }

    /// Takes the token back. Nothing works until a new one is created.
    @discardableResult
    func revokeToken() -> Bool { tokens.revoke() }

    @discardableResult
    func handle(_ url: URL) -> Bool {
        switch RemoteCommand.authorize(url, enabled: isEnabled, token: tokens.current) {
        case .failure(let refusal):
            guard let message = refusal.message else { return false }
            refused += 1
            Log.warning("Remote", refusal == .disabled ? "A request was refused: remote commands are off" : "A request was refused")
            tell(message)
            return false
        case .success(let command):
            return perform(command) == nil
        }
    }

    /// Runs a command, unless remote commands are off. Returns why not, or nil when it was run. The Shortcuts actions and the local web
    /// address come through here too, so one switch covers them all.
    @discardableResult
    func perform(_ command: RemoteCommand) -> RemoteRefusal? {
        guard isEnabled else {
            refused += 1
            Log.warning("Remote", "A request was refused: remote commands are off")
            tell(RemoteAccess.disabledMessage)
            return .disabled
        }
        handled += 1
        // Command names are logged; what a launcher request typed is not.
        switch command {
        case .command(let id): Log.info("Remote", "Running command \(id.prefix(60))"); DispatchQueue.main.async { self.runCommand(id) }
        case .action(let id): Log.info("Remote", "Running a saved action"); DispatchQueue.main.async { self.runAction(id) }
        case .workflow(let id): Log.info("Remote", "Running a workflow"); DispatchQueue.main.async { self.runWorkflow(id) }
        case .launcher(let text): DispatchQueue.main.async { self.showLauncher(text) }
        }
        return nil
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
        if RemoteCommands.shared?.perform(.launcher(text)) == .disabled { throw IntentError.remoteCommandsOff }
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
        if RemoteCommands.shared?.perform(.command(command)) == .disabled { throw IntentError.remoteCommandsOff }
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
        if RemoteCommands.shared?.perform(.action(actionID)) == .disabled { throw IntentError.remoteCommandsOff }
        return .result()
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case badCommand
    case remoteCommandsOff
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .badCommand: return "That is not a name Kriya can run."
        case .remoteCommandsOff: return "Remote commands are turned off in Kriya, so this was not run. Turn them on in Kriya's settings, under Control from outside."
        }
    }
}

struct KriyaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenKriyaLauncherIntent(), phrases: ["Open the launcher in \(.applicationName)", "Search with \(.applicationName)"], shortTitle: "Open Launcher", systemImageName: "magnifyingglass")
        AppShortcut(intent: SetAppVolumeIntent(), phrases: ["Set an app's volume in \(.applicationName)"], shortTitle: "Set App Volume", systemImageName: "speaker.wave.2")
        AppShortcut(intent: SetSoundOutputIntent(), phrases: ["Play sound on a device with \(.applicationName)"], shortTitle: "Play Sound On", systemImageName: "hifispeaker")
    }
}
