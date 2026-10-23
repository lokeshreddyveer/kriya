import AppKit

extension LauncherSources {
    /// "kill chrome", "port 3000", "wifi off", "quit all", "eject", "hidden files".
    func jobEntries(_ text: String) -> [PaletteEntry] {
        guard let request = SystemRequest.parse(text) else { return [] }
        func make(_ id: String, _ title: String, _ subtitle: String, _ symbol: String, destructive: Bool = false, run: @escaping () -> Void) -> PaletteEntry {
            var e = PaletteEntry(id: "job:\(id)", title: title, subtitle: subtitle, symbol: symbol, rememberable: false, run: run)
            e.queryScore = 750
            return e
        }
        switch request {
        case .kill(let name):
            let apps = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && ($0.localizedName ?? "").lowercased().contains(name)
            }
            return apps.prefix(4).map { app in
                make("kill:\(app.processIdentifier)", "Force quit \(app.localizedName ?? name)", "Ends it at once; unsaved work is lost", "xmark.octagon") {
                    if !app.forceTerminate() { Toast().show("\(app.localizedName ?? name) would not quit.", isError: true) }
                }
            }
        case .port(let number):
            return [make("port:\(number)", "What is using port \(number)?", "Shows the program and offers to end it", "network") { [weak self] in
                DispatchQueue.global().async {
                    let owners = PortOwner.parse(Self.output("/usr/sbin/lsof", ["-nP", "-iTCP:\(number)", "-sTCP:LISTEN", "-F", "pc"]))
                    DispatchQueue.main.async {
                        guard let owner = owners.first else { Toast().show("Nothing is listening on port \(number)."); return }
                        if LauncherSystemCommands.confirm("Port \(number) is used by \(owner.name)", detail: "Process \(owner.pid). End it?", button: "End It") { kill(owner.pid, SIGTERM) }
                    }
                }
                _ = self
            }]
        case .wifi(let state):
            let title = state == true ? "Turn Wi-Fi on" : state == false ? "Turn Wi-Fi off" : "Wi-Fi: show the network and turn it off or on"
            return [make("wifi", title, "Uses the Mac's own network tool", "wifi") {
                DispatchQueue.global().async {
                    let current = Self.output("/usr/sbin/networksetup", ["-getairportpower", "en0"]).lowercased().contains("on")
                    let target = state ?? !current
                    _ = Self.output("/usr/sbin/networksetup", ["-setairportpower", "en0", target ? "on" : "off"])
                    DispatchQueue.main.async { Toast().show(target ? "Wi-Fi on" : "Wi-Fi off") }
                }
            }]
        case .quitOthers:
            return [make("quit-others", "Quit every other app", "Asks each to close; apps with unsaved work will ask first", "power") {
                guard LauncherSystemCommands.confirm("Quit every other app?", detail: "Each app is asked to close and may ask to save first.", button: "Quit Them") else { return }
                let keep: Set<String> = ["com.apple.finder", Bundle.main.bundleIdentifier ?? ""]
                for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !keep.contains(app.bundleIdentifier ?? "") && !app.isActive { app.terminate() }
            }]
        case .eject:
            return [make("eject", "Eject all disks", "Every drive and disk image that can be removed", "eject") {
                let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey]
                let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []).filter {
                    let v = try? $0.resourceValues(forKeys: Set(keys)); return v?.volumeIsEjectable == true || v?.volumeIsRemovable == true
                }
                guard !volumes.isEmpty else { Toast().show("There is no disk to eject."); return }
                var failed = 0
                for volume in volumes { do { try NSWorkspace.shared.unmountAndEjectDevice(at: volume) } catch { failed += 1 } }
                Toast().show(failed == 0 ? "Ejected \(volumes.count) disk\(volumes.count == 1 ? "" : "s")" : "\(failed) disk\(failed == 1 ? " is" : "s are") still in use.", isError: failed > 0)
            }]
        case .hiddenFiles:
            return [make("hidden", "Show or hide hidden files in Finder", "Restarts Finder", "eye") {
                DispatchQueue.global().async {
                    let showing = Self.output("/usr/bin/defaults", ["read", "com.apple.finder", "AppleShowAllFiles"]).lowercased().contains("true") || Self.output("/usr/bin/defaults", ["read", "com.apple.finder", "AppleShowAllFiles"]).contains("1")
                    _ = Self.output("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", showing ? "false" : "true"])
                    _ = Self.output("/usr/bin/killall", ["Finder"])
                    DispatchQueue.main.async { Toast().show(showing ? "Hidden files are hidden" : "Hidden files are shown") }
                }
            }]
        }
    }

    /// "send clipboard" and, when something has arrived, "Paste from <Mac>".
    func sharedClipboardEntries(_ text: String) -> [PaletteEntry] {
        guard let shared = sharedClipboard, shared.enabled else { return [] }
        var found: [PaletteEntry] = []
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        if let p = shared.pending, lower.isEmpty || lower.contains("paste") || lower.contains("clipboard") || lower.contains("other mac") {
            var e = PaletteEntry(id: "job:shared-receive", title: "Paste from \(p.from)", subtitle: SharedClipboard.preview(p.text), symbol: "arrow.down.doc", rememberable: false) { DispatchQueue.main.async { shared.receive() } }
            e.queryScore = lower.isEmpty ? nil : 800
            found.append(e)
        }
        if lower.contains("send clipboard") || lower.contains("send to other") || lower == "send" {
            var e = PaletteEntry(id: "job:shared-send", title: "Send the clipboard to my other Macs", subtitle: "Encrypted with your passphrase, through iCloud Drive", symbol: "arrow.up.doc", rememberable: false) { DispatchQueue.main.async { shared.send() } }
            e.queryScore = 800
            found.append(e)
        }
        return found
    }

    /// "focus", "focus 45", "focus off": a timed session that hides distractions and puts everything back.
    func focusEntries(_ text: String) -> [PaletteEntry] {
        guard let focus, let request = FocusPlan.request(text) else { return [] }
        var e: PaletteEntry
        switch request {
        case .start(let minutes):
            if focus.isActive { return [] }
            let n = minutes ?? focus.config.minutes
            e = PaletteEntry(id: "job:focus", title: "Start a \(n)-minute focus session", subtitle: "Hides the Dock and desktop icons as set in Focus Sessions", symbol: "scope", rememberable: false) { DispatchQueue.main.async { focus.begin(minutes: minutes) } }
        case .stop:
            guard focus.isActive else { return [] }
            e = PaletteEntry(id: "job:focus-off", title: "End the focus session", subtitle: focus.remainingText, symbol: "scope", rememberable: false) { DispatchQueue.main.async { focus.finish(announce: true) } }
        }
        e.queryScore = 800
        return [e]
    }

    /// Shows the screen colour picker and copies the colour's hex code.
    func colorPickerEntries(_ text: String) -> [PaletteEntry] {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard ["pick color", "pick a color", "color picker", "pick colour", "eyedropper"].contains(t) else { return [] }
        var e = PaletteEntry(id: "job:colorpicker", title: "Pick a colour from the screen", subtitle: "Click any pixel; its hex code is copied", symbol: "eyedropper", rememberable: false) {
            DispatchQueue.main.async { ScreenColorPicker.pick() }
        }
        e.queryScore = 750
        return [e]
    }

    static func output(_ path: String, _ arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

enum ScreenColorPicker {
    private static var sampler: NSColorSampler?

    static func pick() {
        let s = NSColorSampler()
        sampler = s
        s.show { color in
            sampler = nil
            guard let color = color?.usingColorSpace(.sRGB) else { return }
            let hex = ColorTool.hex((Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded())))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            Toast().show("Copied \(hex)")
        }
    }
}
