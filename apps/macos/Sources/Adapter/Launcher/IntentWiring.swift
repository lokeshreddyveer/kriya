import AppKit

private extension WorkflowStep {
    /// Whether this step, or any step inside it, runs code, controls other apps or the system.
    var isRisky: Bool { kind.risk != .safe || kind.children.contains { $0.isRisky } }
}

extension AppEnvironment {
    /// Connects the natural-language layer to what already exists: the apps, devices, workflows and commands it reads names from, and the
    /// features it hands a finished request to. It adds one query source to the launcher and nothing that can act by itself.
    func configureIntents(sources: LauncherSources) {
        let palette = keyboard.palette
        let toast = Toast()
        let launcher = IntentLauncher()
        launcher.prefs = { [weak palette] in palette?.prefs.data ?? LauncherPrefsData() }
        launcher.world = { [weak self] in self?.currentIntentWorld() ?? IntentWorld() }

        var hooks = IntentLauncher.Hooks()
        hooks.message = { text, isError in toast.show(text, isError: isError) }
        hooks.prefill = { [weak palette] text in palette?.show(prefill: text) }
        hooks.startTimer = { [weak sources] seconds, _ in sources?.timers.start(seconds: seconds) }
        hooks.startFocus = { [weak self] minutes in DispatchQueue.main.async { self?.focusSession.begin(minutes: minutes) } }
        hooks.runCommand = { [weak self] name in DispatchQueue.main.async { self?.keyboard.run(.command(command: name)) } }
        hooks.runWorkflow = { [weak self] id in self?.automation.fire(id, source: "Launcher request") }
        hooks.moveWindow = { [weak self] command in _ = self?.windowController.run(command: command) }
        hooks.addToShelf = { [weak self] urls in for url in urls { self?.fileShelf.add(file: url) } }
        hooks.excludedFolders = { [weak palette] in palette?.prefs.data.fileSearchExcluded ?? [] }
        hooks.browserTabsOn = { [weak palette] in palette?.prefs.data.searchBrowserTabs == true }
        hooks.openSettings = { [weak self] pane, tab in
            self?.launcherSources?.openSettings(pane)
            if let tab { DispatchQueue.main.async { self?.navigator.go(pane, tab: tab) } }
        }
        let fade = { UserDefaults.standard.object(forKey: "soundTimedFadeSeconds") as? Double ?? 2 }
        func key(_ id: String) -> String { id == IntentWorld.systemApp ? AppAudioEngine.systemKey : AudioProcessList.groupKey(forBundleID: id) }
        hooks.setVolume = { [weak self] id, value in DispatchQueue.main.async { self?.appAudio.update(key(id)) { $0.volume = value } } }
        hooks.mute = { [weak self] id, seconds in
            DispatchQueue.main.async {
                guard let engine = self?.appAudio else { return }
                if let seconds { engine.startTimed(key(id), level: 0, duration: seconds, fadeOut: fade(), fadeIn: fade()) }
                else { engine.update(key(id)) { $0.muted = true } }
            }
        }
        hooks.unmute = { [weak self] id in DispatchQueue.main.async { self?.appAudio.update(key(id)) { $0.muted = false } } }
        hooks.muteAllExcept = { [weak self] keep in
            DispatchQueue.main.async {
                guard let engine = self?.appAudio else { return }
                let keepKey = key(keep)
                let others = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier).map { key($0) }
                for other in Set(others) where other != keepKey { engine.update(other) { $0.muted = true } }
                engine.update(keepKey) { $0.muted = false }
            }
        }
        hooks.chooseOutput = { [weak self] uid in
            guard let audio = self?.audio, let device = audio.devices().first(where: { $0.uid == uid && $0.isOutput }) else { return false }
            return audio.setDefault(device)
        }
        launcher.hooks = hooks
        intentLauncher = launcher
        palette.addQueryProvider(name: "Requests") { [weak launcher] text in launcher?.entries(for: text) ?? [] }
    }

    /// Everything a request can name, read fresh each time so it is never out of date.
    func currentIntentWorld() -> IntentWorld {
        var world = IntentWorld()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let aliases = keyboard.palette.prefs.data.aliases
        world.apps = inventory.apps.map { app in
            IntentApp(bundleID: app.bundleID, name: app.name, aliases: aliases.filter { $0.value == "app:\(app.bundleID)" }.map(\.key),
                      isRunning: running.contains(app.bundleID), lastUsed: app.lastUsed)
        }
        let nicknames = UserDefaults.standard.data(forKey: "soundDeviceNames.v1").flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        world.devices = audio.devices().filter(\.isOutput).map { IntentDevice(uid: $0.uid, name: $0.name, nicknames: nicknames[$0.uid].map { [$0] } ?? []) }
        world.workflows = automation.store.workflows.filter(\.enabled).map { IntentWorkflow(id: $0.id, name: $0.name, isRisky: $0.steps.contains { $0.isRisky }) }
        world.commands = Set(executor.registeredCommands)
        let fm = FileManager.default
        var folders: [String: URL] = ["home": fm.homeDirectoryForCurrentUser]
        for (name, directory) in [("downloads", FileManager.SearchPathDirectory.downloadsDirectory), ("desktop", .desktopDirectory), ("documents", .documentDirectory)] {
            if let url = fm.urls(for: directory, in: .userDomainMask).first { folders[name] = url }
        }
        world.folders = folders
        world.recentFile = { kind in
            let folder = kind == "download" ? folders["downloads"] : ((CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? folders["desktop"])
            guard let folder, let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else { return nil }
            let files = urls.filter { url in kind == "download" ? true : url.lastPathComponent.hasPrefix("Screenshot") || url.lastPathComponent.hasPrefix("Screen Shot") }
            return files.max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
        }
        world.defaultEngine = keyboard.palette.prefs.data.webEngine ?? WebSearch.defaultEngineID
        world.frontAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        world.localOnly = LocalOnly.isOn
        return world
    }
}
