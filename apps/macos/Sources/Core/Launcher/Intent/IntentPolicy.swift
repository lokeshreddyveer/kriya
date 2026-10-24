import Foundation

/// Whether an understood request may run at once or must be confirmed first. A request is judged by what it would do, not by how it
/// was found: the same intent asks first whether a pattern or a model produced it.
enum IntentPolicy {
    /// Commands whose names show they delete, install, change permissions or run scripts. A request for one is confirmed even though it is a
    /// real command in the registry.
    private static let sensitiveCommandWords = [
        "delete", "trash", "remove", "uninstall", "install", "erase", "wipe", "format", "script", "applescript", "shell", "terminal", "shortcut",
        "permission", "export", "send", "upload", "reset", "restore", "clear", "quit_all", "force", "kill", "empty",
    ]

    /// File types that start something when opened. Opening one from a typed request is confirmed.
    static let launchableExtensions: Set<String> = [
        "app", "command", "sh", "zsh", "bash", "scpt", "scptd", "applescript", "workflow", "action", "pkg", "mpkg", "dmg", "jar", "py", "rb", "pl", "js",
        "terminal", "tool", "webloc", "inetloc", "url", "exe", "msi", "bat", "wflow", "shortcut", "service", "prefpane",
    ]

    static func risk(of intent: LauncherIntent, world: IntentWorld) -> IntentRisk {
        switch intent {
        case .search, .openApp, .searchFiles, .searchNotes, .searchClipboard, .searchBrowserTabs, .webSearch, .startTimer, .startFocusSession,
             .setVolume, .muteApp, .unmuteApp, .moveWindow, .capture, .openSettings:
            return .safe
        case .askAI:
            // A plain question goes to the provider the person chose, with secrets hidden first. Nothing from the clipboard or the screen is
            // attached to a request, so it is safe; text that still holds a secret after hiding is not sent (see IntentAI).
            return .safe
        case .muteAllExcept:
            return .confirm(reason: "This silences every other app until you turn them back on.")
        case .chooseAudioOutput:
            return .confirm(reason: "This changes where all sound from this Mac plays.")
        case .openFile(let url):
            return launchableExtensions.contains(url.pathExtension.lowercased()) || isApplicationBundle(url)
                ? .confirm(reason: "Opening this file starts a program or script.") : .safe
        case .addToShelf(let urls):
            return urls.count > 10 ? .confirm(reason: "This puts \(urls.count) files on the shelf.") : .safe
        case .runWorkflow(let id):
            if let workflow = world.workflows.first(where: { $0.id == id }), workflow.isRisky {
                return .confirm(reason: "“\(workflow.name)” runs a script, changes files or sends something.")
            }
            return .safe
        case .runCommand(let name, _):
            let lower = name.lowercased()
            if let word = sensitiveCommandWords.first(where: { lower.contains($0) }) {
                return .confirm(reason: "“\(name)” can change or remove things (it is a “\(word)” command).")
            }
            return .safe
        case .sequence(let steps):
            for step in steps { if case .confirm(let reason) = risk(of: step, world: world) { return .confirm(reason: reason) } }
            return .safe
        }
    }

    private static func isApplicationBundle(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isApplicationKey]))?.isApplication == true
    }
}

/// Checks that an intent's arguments are real and in range, whoever produced it. Nothing is run until this passes.
enum IntentValidator {
    static let queryLimit = 500
    static let focusMinutes = 1...480

    /// The problem with an intent in plain words, or nil if it is sound.
    static func validate(_ intent: LauncherIntent, world: IntentWorld) -> String? {
        switch intent {
        case .search(let text), .searchNotes(let text), .searchClipboard(let text), .searchBrowserTabs(let text):
            return text.count > queryLimit ? "That search is too long." : textProblem(text, allowEmpty: true)
        case .askAI(let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "There is nothing to ask." : (text.count > 2000 ? "That question is too long." : nil)
        case .webSearch(let engine, let query):
            guard WebSearch.engines.contains(where: { $0.id == engine }) else { return "“\(engine)” is not a search site Kriya knows." }
            return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "There is nothing to search for." : (query.count > queryLimit ? "That search is too long." : nil)
        case .searchFiles(let query, let range):
            if query.isEmpty && range == nil { return "There is nothing to search for." }
            if case .lastDays(let n)? = range, !(1...3650).contains(n) { return "“the last \(n) days” is not a range I can use." }
            return query.count > queryLimit ? "That search is too long." : textProblem(query, allowEmpty: true)
        case .openApp(let id):
            return world.apps.contains { $0.bundleID == id } ? nil : "That app is not installed."
        case .openFile(let url):
            return pathProblem(url, world: world, mustExist: true)
        case .addToShelf(let urls):
            if urls.isEmpty { return "There is nothing to add." }
            if urls.count > 50 { return "That is too many files for the shelf at once." }
            return urls.lazy.compactMap { pathProblem($0, world: world, mustExist: true) }.first
        case .startTimer(let seconds, let label):
            guard seconds >= IntentText.shortest, seconds <= IntentText.longest else { return "A timer can be from 1 second to 24 hours." }
            return label.flatMap { textProblem($0, allowEmpty: true) }
        case .startFocusSession(let minutes):
            return focusMinutes.contains(minutes) ? nil : "A focus session can be from 1 to 480 minutes."
        case .runWorkflow(let id):
            return world.workflows.contains { $0.id == id } ? nil : "The requested workflow does not exist."
        case .runCommand(let name, let arguments):
            guard world.commands.contains(name) else { return "“\(name)” is not a Kriya command." }
            if arguments.count > 8 { return "That command was given too many arguments." }
            for (key, value) in arguments {
                if key.isEmpty || key.count > 40 || value.count > 200 { return "A command argument is too long." }
                if let problem = textProblem(key + value, allowEmpty: true) { return problem }
            }
            return nil
        case .setVolume(let id, let value):
            if let problem = appProblem(id, world: world) { return problem }
            return value >= 0 && value <= AppAudioSettings.maxVolume ? nil : "A volume can be from 0% to \(Int(AppAudioSettings.maxVolume * 100))%."
        case .muteApp(let id, let seconds):
            if let problem = appProblem(id, world: world) { return problem }
            if let seconds, !(IntentText.shortest...IntentText.longest).contains(seconds) { return "Muting can be for 1 second to 24 hours." }
            return nil
        case .unmuteApp(let id), .muteAllExcept(let id):
            return appProblem(id, world: world, allowSystem: false)
        case .chooseAudioOutput(let uid):
            guard let uid else { return nil }
            return world.devices.contains { $0.uid == uid } ? nil : "That sound output is not connected."
        case .moveWindow:
            return nil
        case .capture:
            return nil
        case .openSettings(_, let tab):
            return tab.flatMap { textProblem($0, allowEmpty: false) }
        case .sequence(let steps):
            if steps.isEmpty || steps.count > 3 { return "I can do up to three things at once." }
            return steps.lazy.compactMap { validate($0, world: world) }.first
        }
    }

    private static func appProblem(_ id: String, world: IntentWorld, allowSystem: Bool = true) -> String? {
        if id == IntentWorld.systemApp { return allowSystem ? nil : "Choose an app." }
        return world.apps.contains { $0.bundleID == id } ? nil : "That app is not installed."
    }

    /// No control characters, and nothing that reads as shell text.
    private static func textProblem(_ text: String, allowEmpty: Bool) -> String? {
        if !allowEmpty && text.isEmpty { return "A value is missing." }
        if text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return "That contains characters I will not use." }
        return nil
    }

    /// A path must be absolute, inside the home folder, /Applications or a mounted volume, and free of "..". It never reaches a shell.
    static func pathProblem(_ url: URL, world: IntentWorld, mustExist: Bool) -> String? {
        guard url.isFileURL else { return "That is not a file on this Mac." }
        let path = url.standardizedFileURL.path
        if url.path.contains("/../") || url.path.hasSuffix("/..") || url.pathComponents.contains("..") { return "That path goes up out of its folder." }
        if path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return "That path contains characters I will not use." }
        let home = world.homeDirectory.standardizedFileURL.path
        let allowedRoots = [home, "/Applications", "/Volumes", "/System/Applications", "/Users/Shared"]
        guard allowedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return "I only open files in your home folder, Applications and drives." }
        if mustExist && !world.fileExists(url) { return "That file does not exist." }
        return nil
    }
}
