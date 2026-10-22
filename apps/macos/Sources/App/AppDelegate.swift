import AppKit
import Combine
import CoreServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var env: AppEnvironment?
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private var setupGuide: SetupGuideController?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The unit tests run inside this app. They build their own services with throwaway folders, so the real
        // services, menu-bar icon and saved data are never started under test.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        guard handOverToRunningCopy() else { return }

        let paths = AppPaths.live
        paths.createDirectories()
        Log.shared.configure(fileURL: paths.logFile, level: .info)
        CrashSignalHandler.reportPreviousCrash(noteFile: paths.crashSignalLog)
        CrashSignalHandler.install(noteFile: paths.crashSignalLog)
        Log.info("App", "Kriya \(SystemInfo.appVersion) (\(SystemInfo.build)) starting on macOS \(SystemInfo.osVersion), \(SystemInfo.architecture), core \(coreVersion())")

        let core: KriyaCore
        do {
            core = try KriyaCore.open(supportDir: paths.support.path, now: SystemInfo.nowSeconds)
        } catch {
            Log.error("App", "Could not open saved data: \(error.userMessage)")
            showFatal(error)
            return
        }
        let env = AppEnvironment(paths: paths, core: core)
        self.env = env

        env.crashGuard.beginSession()
        applyCrashFindings(env: env, core: core)
        env.config.apply(previous: nil)
        MainMenu.install(target: self)

        settingsWindow = SettingsWindowController(env: env)
        setupGuide = SetupGuideController(env: env, finish: { [weak self] in self?.showSettings(.features) })
        env.navigator.openSetupGuide = { [weak self] in self?.setupGuide?.show() }
        statusItem = StatusItemController(env: env, openSettings: { [weak self] pane in self?.showSettings(pane) })

        env.keyboard.palette.openSettings = { [weak self] pane in self?.showSettings(pane) }
        env.keyboard.palette.toggleFeature = { feature, on in env.services.setFeature(feature, enabled: on) }
        NSApp.servicesProvider = env.finder.services
        NSUpdateDynamicServices()
        for url in pendingURLs { route(url, in: env, source: nil) }
        pendingURLs.removeAll()

        AXWindow.startTrackingOutsideApp()
        env.permissions.startMonitoring()
        env.devices.start()
        env.profiles.start()
        env.mouse.start()
        env.services.start()
        env.backup.startICloud()
        // The installed apps, their leftovers and their updates are kept up to date from the start, not only while Apps is open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { env.inventory.startWatching() }

        if !env.config.settings.hasCompletedOnboarding {
            setupGuide?.show()
        }

        #if DEBUG
        DesignShots.runIfRequested(env: env, settings: settingsWindow) { [weak self] pane in self?.showSettings(pane) }
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(nil)
        return true
    }

    /// `kriya://finder/run?…` requests from the Finder extension.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let env else { pendingURLs += urls; return }
        let source = Self.senderBundleID()
        for url in urls { route(url, in: env, source: source) }
    }

    /// Web links go to the link router; Kriya's own `kriya://` requests go to the Finder handler.
    private func route(_ url: URL, in env: AppEnvironment, source: String?) {
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            env.links.open(url, sourceAppID: source)
        } else if url.scheme?.lowercased() == "kriya", url.host?.lowercased() == "browser" {
            env.bridge.handle(url)
        } else {
            env.finder.handle(url: url)
        }
    }

    /// The app that sent the open-address request, as the system reports it.
    private static func senderBundleID() -> String? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let descriptor = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr)) else { return nil }
        let pid = pid_t(descriptor.int32Value)
        return pid > 0 ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier : nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        guard let env else { return }
        env.mouse.flushPendingSaves()
        env.windows.flushPendingSaves()
        env.traffic.flushPendingSaves()
        env.backup.flushICloud()
        env.remap.stopAndWait()
        env.capture.stop()
        env.inventory.stopWatching()
        env.hotCorners.stop()
        env.fileShelf.stop()
        env.displayTools.stop()
        env.finder.deactivate()
        env.clipboard.stop()
        env.selection.stop()
        env.keyboard.stop(context: nil)
        env.services.stopAll()
        env.devices.stop()
        env.permissions.stopMonitoring()
        env.crashGuard.endSession()
        Log.info("App", "Kriya quit normally")
        Log.shared.flush()
    }

    // MARK: Actions

    @objc func openSettings(_ sender: Any?) { showSettings(nil) }
    @objc func openAbout(_ sender: Any?) { showSettings(.about) }

    @objc func goToPane(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let pane = SettingsPane(rawValue: raw) else { return }
        showSettings(pane)
    }

    @objc func nextPane(_ sender: Any?) { step(1) }
    @objc func previousPane(_ sender: Any?) { step(-1) }

    private func step(_ delta: Int) {
        guard let env else { return }
        let all = SettingsPane.allCases
        let index = all.firstIndex(of: env.navigator.pane) ?? 0
        showSettings(all[(index + delta + all.count) % all.count])
    }

    func showSettings(_ pane: SettingsPane?) {
        guard let env else { return }
        if let pane { env.navigator.pane = pane }
        settingsWindow?.show()
    }

    // MARK: Start-up helpers

    /// A second copy hands over to the one already running. A copy started by "Restart" waits for the old one to finish quitting.
    private func handOverToRunningCopy() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return true }
        func others() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0 != NSRunningApplication.current }
        }
        if CommandLine.arguments.contains("--relaunched") {
            for _ in 0..<30 where !others().isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        }
        if let existing = others().first {
            existing.activate()
            NSApp.terminate(nil)
            return false
        }
        return true
    }

    /// Reports what the core found about the last run: a damaged database, and a feature that crashed while starting.
    private func applyCrashFindings(env: AppEnvironment, core: KriyaCore) {
        var notes: [String] = []
        if core.recoveredFromCorruption() {
            notes.append("Kriya's saved data was damaged, so it started fresh. The damaged file was kept in the Kriya folder.")
        }
        if core.isEphemeral() {
            notes.append("Kriya could not open its saved data. Changes made in this session will not be kept.")
        }
        if let suspect = env.crashGuard.suspectFeature,
           env.config.settings.autoDisableCrashingFeature, env.config.isEnabled(suspect) {
            env.config.setEnabled(suspect, false)
            notes.append("Kriya quit unexpectedly while starting \(suspect.title), so it was turned off. You can turn it back on in Features.")
            Log.warning("Session", "Turned off \(suspect.title) after a crash while starting it")
        }
        if !notes.isEmpty { env.crashGuard.notice = notes.joined(separator: " ") }
    }

    private func showFatal(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Kriya cannot open its data"
        alert.informativeText = error.userMessage
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }
}
