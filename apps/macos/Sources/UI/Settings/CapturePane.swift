import AppKit
import SwiftUI

/// Screenshots, reading text from the screen, hiding private text, and marking pictures up.
struct CapturePane: View {
    @EnvironmentObject private var capture: ScreenCaptureService
    @ObservedObject var store: CaptureSettingsStore
    @State private var screenAllowed = CGPreflightScreenCaptureAccess()
    @State private var newWord = ""
    @StateObject private var profiles = CaptureProfileStore()
    @State private var profileName = ""
    @AppStorage(OCRLanguages.defaultsKey) private var ocrLanguages = ""
    @ObservedObject private var registry = ShortcutRegistry.shared
    private let systemEditor = SystemShortcutEditor()
    @State private var systemStates = SystemShortcutEditor().states()
    @State private var keysNote: String?

    private var settings: CaptureSettings { store.settings }

    var body: some View {
        Form {
            if !screenAllowed {
                Section {
                    Banner(symbol: "rectangle.dashed.badge.record", tint: Theme.warn, title: "Screen Recording is off for Kriya", message: "macOS asks for this before any app may capture the screen. Kriya only captures when you ask it to. After you allow it, macOS may ask you to quit and reopen Kriya; this notice goes away once it has taken effect.") {
                        Button("Allow…") {
                            CGRequestScreenCaptureAccess()
                            screenAllowed = CGPreflightScreenCaptureAccess()
                        }.controlSize(.small)
                    }
                }
            }

            Section {
                HStack(spacing: 8) {
                    ForEach(CaptureMode.allCases) { mode in
                        Button { capture.capture(mode) } label: { Label(mode.title, systemImage: mode.symbol) }
                    }
                    Button { capture.capture(.region, action: .text) } label: { Label("Copy Text", systemImage: "text.viewfinder") }
                    Button { capture.capture(.region, action: .chooser) } label: { Label("All-in-One", systemImage: "square.grid.3x3") }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button { capture.capture(.window, action: .scroll) } label: { Label("Scrolling", systemImage: "arrow.down.to.line") }
                    Button { capture.capture(.screen, action: .menu) } label: { Label("Menu", systemImage: "filemenu.and.cursorarrow") }
                    Button { capture.capture(.region, action: .record) } label: { Label("Record", systemImage: "record.circle") }
                    Button { capture.capture(.region, action: .recordGIF) } label: { Label("Record GIF", systemImage: "photo.stack") }
                    Button { capture.capture(.region, action: .qr) } label: { Label("Read QR Code", systemImage: "qrcode.viewfinder") }
                    Button { capture.capture(.screen, action: .ruler) } label: { Label("Pixel Ruler", systemImage: "ruler") }
                    Button { capture.capture(.screen, action: .pin) } label: { Label("Pin", systemImage: "pin") }
                    Spacer()
                }
                .disabled(capture.isCapturing)
                RecordingControls(capture: capture)
            } header: { Text("Capture now") } footer: {
                Text("Region, window and screen captures use Kriya's selector (see “How capturing works” below): drag, or click a window or display, and press Escape to cancel. “Copy Text” reads the words in the region you pick and copies only the text. “Scrolling” asks for the area that scrolls, then takes it a screen at a time and joins the pictures, even when a few pixels change between them (a toolbar that does not scroll is kept once, and a picture that cannot be joined is kept below a red line, never dropped). A PDF open in a viewer is taken whole from its file. “Record” and “Record GIF” use the system recorder: choose the area, then click its stop button in the menu bar. “Read QR Code” copies what the code says. “Pixel Ruler” freezes the screen: move for a magnifier and the colour under the pointer, drag to measure a box, click to measure the box of one colour, hold ⌥ for distances to the edges, C copies the colour and Return copies the size.")
            }

            CaptureModesSection(capture: capture)

            RecordingSection(store: store)

            CaptureHistorySection()
            CaptureRetentionSection()
            AfterCaptureSection()
            BackgroundsSection()
            PinStyleSection()
            EditorPreferencesSection()

            Section {
                let supported = TextRecognizer.supportedLanguages
                let chosen = OCRLanguages.parse(ocrLanguages)
                Text(OCRLanguages.summary(chosen: chosen)).font(.callout).foregroundStyle(.secondary)
                Menu("Choose Languages") {
                    Button("Automatic") { ocrLanguages = "" }
                    Divider()
                    ForEach(supported, id: \.self) { code in
                        Button { ocrLanguages = OCRLanguages.join(chosen.contains(code) ? chosen.filter { $0 != code } : chosen + [code]) } label: {
                            Label(OCRLanguages.name(of: code), systemImage: chosen.contains(code) ? "checkmark" : "")
                        }
                    }
                }.fixedSize()
            } header: { Text("Text in pictures (OCR)") } footer: { Text("Pick up to five languages if the automatic choice misreads. Reading happens on this Mac.") }

            Section {
                ForEach(profiles.profiles) { profile in
                    HStack {
                        Text(profile.name)
                        Spacer()
                        Button("Use") {
                            store.update { $0 = profile.applied(to: $0) }
                            CaptureExtraSettings.delivery = profile.applied(to: CaptureExtraSettings.delivery)
                        }.controlSize(.small)
                        Button(role: .destructive) { profiles.profiles.removeAll { $0.id == profile.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Delete \(profile.name)")
                    }
                }
                HStack {
                    TextField("Name for the current settings", text: $profileName)
                    Button("Save") { profiles.profiles.append(CaptureProfile.from(settings, policy: CaptureExtraSettings.delivery, legacyBackdrop: CaptureExtraSettings.beautify, named: profileName.trimmingCharacters(in: .whitespaces))); profileName = "" }
                        .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { Text("Capture profiles") } footer: { Text("A profile sets where the picture goes and what happens to it. Your shortcuts, hidden words and recording options stay as they are.") }

            Section {
                Toggle("Copy the picture to the clipboard", isOn: bind(\.copyImage))
                Toggle("Save it in a folder", isOn: bind(\.saveToFolder))
                if settings.saveToFolder {
                    LabeledContent("Folder") {
                        HStack {
                            Text(settings.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { chooseFolder() }.controlSize(.small)
                            if !settings.folderPath.isEmpty { Button("Reset") { store.update { $0.folderPath = "" } }.controlSize(.small) }
                        }
                    }
                }
                Toggle("Open the editor to mark it up first", isOn: bind(\.openEditor))
                Toggle("Hide private text automatically", isOn: bind(\.redactAutomatically))
                Picker("Wait before capturing", selection: Binding(get: { settings.delaySeconds }, set: { v in store.update { $0.delaySeconds = v } })) {
                    Text("No wait").tag(0); Text("3 seconds").tag(3); Text("5 seconds").tag(5); Text("10 seconds").tag(10)
                }
                Toggle("Play a sound when a capture is taken", isOn: bind(\.playSound))
                CaptureSoundRows(enabled: settings.playSound)
                Toggle("Include the pointer in screenshots", isOn: Binding(get: { settings.includeCursor ?? false }, set: { v in store.update { $0.includeCursor = v } }))
                VStack(alignment: .leading, spacing: 4) {
                    TextField("File name", text: Binding(get: { settings.namePattern ?? CaptureNaming.defaultPattern }, set: { value in store.update { $0.namePattern = value == CaptureNaming.defaultPattern ? nil : value } }))
                    if let problem = CaptureNaming.problem(settings.namePattern ?? CaptureNaming.defaultPattern) { Text(problem).font(.caption).foregroundStyle(Theme.danger) }
                    else {
                        Text("Example: " + CaptureNaming.fileName(pattern: settings.namePattern, date: Date(), app: NSWorkspace.shared.frontmostApplication?.localizedName ?? "Safari", mode: "capture", ext: "png")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("After a capture") } footer: {
                Text("In the file name, {date}, {time}, {app} (the app in front), {mode} and {n} are filled in; recordings use the same pattern with “Recording” in place of “Capture”. Pictures are made and kept on this Mac. Reading text and hiding private text use the Mac's own text recognition, with no internet.")
            }

            CaptureOutputSection()
            CaptureUploadSection()

            Section {
                if settings.redactWords.isEmpty { Text("None.").font(.callout).foregroundStyle(.secondary) }
                ForEach(settings.redactWords, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button(role: .destructive) { store.update { $0.redactWords.removeAll { $0 == word } } } label: { Image(systemName: "trash") }.accessibilityLabel("Stop hiding “\(word)”").buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("A name or word to hide", text: $newWord).onSubmit(addWord)
                    Button("Add", action: addWord).disabled(newWord.trimmingCharacters(in: .whitespaces).count < 2)
                }
            } header: { Text("Always hide") } footer: {
                Text("When private text is hidden, these words are covered too, on top of email addresses, phone numbers, card numbers, IP addresses and keys or tokens. Check the result before you share it: text the recognizer cannot read is not covered.")
            }

            Section {
                macOSKeysBanner
                ForEach(CaptureSettings.commands, id: \.command) { entry in
                    LabeledContent(entry.title) {
                        VStack(alignment: .trailing, spacing: 3) {
                            ShortcutRecorder(shortcut: Binding(
                                get: { store.shortcut(for: entry.command).map { RecordedShortcut(keyCode: $0.keyCode, modifiers: $0.modifiers) } },
                                set: { new in store.setShortcut(entry.command, keyCode: new?.keyCode, modifiers: new?.modifiers ?? 0) }
                            ), needsModifier: true)
                            .frame(width: 180, height: 26)
                            if let problem = problem(for: entry.command) {
                                Text(problem).font(.caption).foregroundStyle(Theme.warn).multilineTextAlignment(.trailing).frame(maxWidth: 300, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            } header: { Text("Shortcuts") } footer: {
                Text("The same commands (capture.region, capture.window, capture.screen, capture.text, capture.redacted, capture.qr, capture.record, capture.gif, capture.scroll, capture.ruler, capture.pin) can be used from a mouse button, a hot corner, a workflow, the selection bar or the launcher.")
            }
        }
        .formStyle(.grouped)
        .onAppear { screenAllowed = CGPreflightScreenCaptureAccess() }
        // The answer to the permission prompt arrives later, so the notice is checked again until it is gone (and the pane is left).
        .task {
            while !Task.isCancelled && !screenAllowed {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                screenAllowed = CGPreflightScreenCaptureAccess()
            }
        }
    }

    // MARK: Shortcuts and macOS's own screenshot keys

    /// Said when a saved shortcut was refused, with the reason: macOS's own screenshot keys are the usual one.
    private func problem(for command: String) -> String? {
        guard let saved = store.shortcut(for: command) else { return CaptureCommandCatalog.setupProblem(of: command, in: capture.commandState()) }
        // The same keys held by another part of Kriya: said first, with whose they are.
        if let other = CaptureCommandCatalog.clashes(command: command, keyCode: saved.keyCode, modifiers: saved.modifiers, among: registry.entries).first {
            return "These keys are also used by “\(other.title)” (\(other.owner)). Choose other keys."
        }
        let entry = registry.entries.first { $0.owner == CaptureCommandCatalog.owner && $0.command == command }
        guard entry?.status == .refused else { return CaptureCommandCatalog.setupProblem(of: command, in: capture.commandState()) }
        if let known = SystemScreenshotKeys.occupant(keyCode: saved.keyCode, modifiers: saved.modifiers, states: systemStates) {
            return "macOS uses these keys for “\(known.name)”. Use “Let Kriya use ⌘⇧3, ⌘⇧4 and ⌘⇧5” above, or choose other keys."
        }
        return "These keys did not work: another app, or macOS itself, already uses them. Choose other keys."
    }

    private var macOSKeysBanner: some View {
        let still = SystemScreenshotKeys.enabled(states: systemStates, among: SystemScreenshotKeys.usual)
        let released = systemEditor.released
        return VStack(alignment: .leading, spacing: 8) {
            if !still.isEmpty {
                Banner(symbol: "keyboard", tint: Theme.warn, title: "macOS is still using ⌘⇧3, ⌘⇧4 and ⌘⇧5", message: "macOS takes these keys before any app sees them, so pressing them here (to record them, or to capture) takes a macOS screenshot instead. Kriya can turn macOS's off and use them for its own capture. You can give them back here at any time.") {
                    Button("Let Kriya use ⌘⇧3, ⌘⇧4 and ⌘⇧5…") { useUsualKeys() }.controlSize(.small)
                }
            }
            if !released.isEmpty {
                Banner(symbol: "checkmark.circle", tint: Theme.ok, title: "macOS's screenshot keys are off", message: "Kriya turned them off so it can use them. Turn them back on to go back to how macOS was.") {
                    Button("Give Them Back to macOS") { giveBack() }.controlSize(.small)
                }
            }
            if let note = keysNote { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func useUsualKeys() {
        let alert = NSAlert()
        alert.messageText = "Let Kriya use ⌘⇧3, ⌘⇧4 and ⌘⇧5?"
        alert.informativeText = "macOS's own screenshot shortcuts on those keys are turned off, and Kriya's are set: ⌘⇧3 captures the whole screen, ⌘⇧4 an area, ⌘⇧5 records the screen. You can change each below, and give the keys back to macOS here at any time. If the keys still do the macOS thing afterwards, sign out and back in once."
        alert.addButton(withTitle: "Use These Keys")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard systemEditor.release(SystemScreenshotKeys.usual) else {
            keysNote = "macOS did not let Kriya change its shortcuts. Turn them off yourself in System Settings › Keyboard › Keyboard Shortcuts › Screenshots."
            return
        }
        let cmdShift = KeyModifiers.command | KeyModifiers.shift
        store.setShortcut("capture.screen", keyCode: 20, modifiers: cmdShift)
        store.setShortcut("capture.region", keyCode: 21, modifiers: cmdShift)
        store.setShortcut("capture.rec.screen", keyCode: 23, modifiers: cmdShift)
        keysNote = "Done. Kriya's capture now answers ⌘⇧3, ⌘⇧4 and ⌘⇧5."
        reloadAfterSystemChange()
    }

    private func giveBack() {
        keysNote = systemEditor.giveBack() ? "macOS's screenshot keys are on again. Kriya's shortcuts on the same keys will stop working until you choose other keys." : "macOS did not let Kriya change its shortcuts."
        reloadAfterSystemChange()
    }

    /// The system takes a moment to apply a change; once it has, Kriya asks for its shortcuts again so ones refused earlier are tried anew.
    private func reloadAfterSystemChange() {
        systemStates = systemEditor.states()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            systemStates = systemEditor.states()
            capture.reregisterShortcuts()
        }
    }

    private func bind(_ path: WritableKeyPath<CaptureSettings, Bool>) -> Binding<Bool> {
        Binding(get: { store.settings[keyPath: path] }, set: { value in store.update { $0[keyPath: path] = value } })
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard word.count >= 2 else { return }
        store.update { $0.redactWords.append(word) }
        newWord = ""
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Where should captures be saved?"
        if panel.runModal() == .OK, let url = panel.url { store.update { $0.folderPath = url.path } }
    }
}

/// How long captures are kept: how far back the history reaches, and when old pictures and recordings are offered for the Trash.
/// Nothing is deleted without asking, and nothing is deleted outright.
struct CaptureRetentionSection: View {
    @EnvironmentObject private var capture: ScreenCaptureService
    @State private var retention = CaptureExtraSettings.delivery.retention
    @State private var expired: [CaptureCleanup.File] = []
    @State private var message: String?

    private func length(_ days: Int, none: String) -> String { days == 0 ? none : days == 1 ? "1 day" : "\(days) days" }

    var body: some View {
        Section {
            Picker("Show in the history", selection: $retention.captureHistoryDays) {
                ForEach(CaptureRetention.choices, id: \.self) { Text(length($0, none: "Everything")).tag($0) }
            }
            Picker("Offer to clean up pictures older than", selection: $retention.screenshotFileDays) {
                ForEach(CaptureRetention.choices, id: \.self) { Text(length($0, none: "Never")).tag($0) }
            }
            Picker("Offer to clean up recordings older than", selection: $retention.recordingFileDays) {
                ForEach(CaptureRetention.choices, id: \.self) { Text(length($0, none: "Never")).tag($0) }
            }
            if !expired.isEmpty {
                LabeledContent {
                    Button("Move to the Trash…") { cleanUp() }.controlSize(.small)
                } label: {
                    Text(CaptureCleanup.summary(expired)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        } header: { Text("How long captures are kept") } footer: {
            Text("The history list and the closed cards Kriya remembers drop entries older than the first limit by themselves; the files stay where they are. The other two limits only say which files are old: Kriya never moves one to the Trash without showing you how many and asking first, and it never deletes outright. GIFs count as recordings.")
        }
        .onChange(of: retention) { _, value in
            var policy = CaptureExtraSettings.delivery
            policy.retention = value.sanitized()
            CaptureExtraSettings.delivery = policy
            message = nil
            scan()
        }
        .onAppear(perform: scan)
    }

    /// Looks at the capture folder off the main thread, so a big folder does not hold the window up.
    private func scan() {
        let folder = capture.settings.settings.folder
        let limits = retention.sanitized()
        DispatchQueue.global(qos: .utility).async {
            let found = CaptureCleanup.expired(CaptureCleanup.files(in: folder), retention: limits)
            DispatchQueue.main.async { expired = found }
        }
    }

    private func cleanUp() {
        let result = CaptureCleanup.run(expired, confirm: { files in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Move \(files.count) old capture\(files.count == 1 ? "" : "s") to the Trash?"
            alert.informativeText = CaptureCleanup.summary(files) + " They stay in the Trash until you empty it."
            // Cancel is the default, so a stray Return never moves files.
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Move to Trash")
            return alert.runModal() == .alertSecondButtonReturn
        }, trash: { path in
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        })
        message = result.message
        scan()
    }
}

/// The last pictures and recordings in the capture folder, to pin, copy or find again.
struct CaptureHistorySection: View {
    @EnvironmentObject private var capture: ScreenCaptureService
    @State private var entries: [CaptureHistory.Entry] = []

    var body: some View {
        Section {
            if entries.isEmpty { Text("Nothing in the capture folder yet.").foregroundStyle(.secondary) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(entries) { entry in
                        VStack(spacing: 4) {
                            thumbnail(entry).frame(width: 120, height: 80).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                if !entry.isMovie { Button { if let image = NSImage(contentsOfFile: entry.path) { PinnedShots.shared.pin(image) } } label: { Image(systemName: "pin") }.help("Pin on screen").accessibilityLabel("Pin on screen") }
                                if !entry.isMovie { Button { if let image = NSImage(contentsOfFile: entry.path) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) } } label: { Image(systemName: "doc.on.doc") }.help("Copy").accessibilityLabel("Copy") }
                                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) } label: { Image(systemName: "magnifyingglass") }.help("Show in Finder").accessibilityLabel("Show in Finder")
                            }.buttonStyle(.borderless).controlSize(.small)
                        }
                    }
                }
            }
        } header: {
            HStack { Text("Recent captures"); Spacer(); Button { reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh").buttonStyle(.borderless) }
        } footer: {
            Text("Pin keeps a picture on top of everything: drag it, scroll to resize it, ⌥-scroll to make it see-through, double-click to close.")
        }
        .onAppear(perform: reload)
    }

    @ViewBuilder
    private func thumbnail(_ entry: CaptureHistory.Entry) -> some View {
        if entry.isMovie { ZStack { Color.black.opacity(0.7); Image(systemName: "play.fill").foregroundStyle(.white) } }
        else if let image = NSImage(contentsOfFile: entry.path) { Image(nsImage: image).resizable().scaledToFill() }
        else { Color.gray.opacity(0.2) }
    }

    private func reload() { entries = CaptureHistory.read(folder: capture.settings.settings.folder, limit: 12) }
}

/// Buttons for Kriya's own recorder, which turn into Pause and Stop while it runs.
private struct RecordingControls: View {
    @ObservedObject var capture: ScreenCaptureService
    @ObservedObject private var recorder: ScreenRecorder

    init(capture: ScreenCaptureService) {
        self.capture = capture
        _recorder = ObservedObject(wrappedValue: capture.recording.recorder)
    }

    var body: some View {
        HStack(spacing: 8) {
            if recorder.state == .recording || recorder.state == .paused {
                Button { capture.capture(.screen, action: .pauseRecording) } label: {
                    Label(recorder.state == .paused ? "Resume" : "Pause", systemImage: recorder.state == .paused ? "play.fill" : "pause.fill")
                }
                Button { capture.capture(.screen, action: .stopRecording) } label: { Label("Stop and Save", systemImage: "stop.fill") }
            } else {
                Button { capture.capture(.screen, action: .recordScreen) } label: { Label("Record Screen", systemImage: "record.circle.fill") }
                Button { capture.capture(.window, action: .recordWindow) } label: { Label("Record Window", systemImage: "macwindow") }
                Button { capture.capture(.window, action: .recordApp) } label: { Label("Record App", systemImage: "app.dashed") }
                Button { capture.capture(.window, action: .mirror) } label: { Label("Float a Window", systemImage: "rectangle.on.rectangle") }
                    .help("A live, view-only copy of the window in front that stays on top")
            }
            Spacer()
        }
        .disabled(recorder.state == .starting || recorder.state == .stopping)
    }
}

/// How Kriya's own recorder records.
private struct RecordingSection: View {
    @ObservedObject var store: CaptureSettingsStore

    private var options: RecordingOptions { store.settings.recording }
    /// Whether the two Do Not Disturb Shortcuts exist, found off the main thread because asking Shortcuts takes a moment.
    @State private var shortcutsReady: Bool?

    private func bind<T>(_ path: WritableKeyPath<RecordingOptions, T>) -> Binding<T> {
        Binding(get: { store.settings.recording[keyPath: path] }, set: { value in store.update { $0.recording[keyPath: path] = value } })
    }

    /// How a recording becomes a GIF: size, speed, colours, merging and length.
    @ViewBuilder private var gifSection: some View {
        let gif = options.gif
        Section {
            Picker("Size", selection: bind(\.gif.resolution)) { ForEach(GIFResolution.allCases) { Text($0.title).tag($0) } }
            Picker("Frame rate", selection: bind(\.gif.frameRate)) { ForEach(GIFOptions.frameRates, id: \.self) { Text("\($0) per second").tag($0) } }
            LabeledContent("Quality") {
                HStack(spacing: 8) {
                    Text("Smaller").font(.caption).foregroundStyle(.secondary)
                    Slider(value: bind(\.gif.quality), in: GIFOptions.qualityRange).frame(width: 140)
                    Text("Best").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Merge pictures that repeat the one before", isOn: bind(\.gif.optimize))
            Toggle("Use only the first part of the recording", isOn: Binding(
                get: { gif.maximumDuration != nil },
                set: { on in store.update { $0.recording.gif.maximumDuration = on ? 30 : nil } }
            ))
            if let seconds = gif.maximumDuration {
                Stepper("Length: \(Int(seconds)) seconds", value: Binding(
                    get: { Int(seconds) },
                    set: { value in store.update { $0.recording.gif.maximumDuration = Double(value) } }
                ), in: Int(GIFOptions.durationRange.lowerBound)...Int(GIFOptions.durationRange.upperBound))
            }
            HStack {
                Button("Reset GIF Settings") { store.update { $0.recording.gif = GIFOptions() } }.controlSize(.small)
                Spacer()
            }
        } header: { Text("GIFs") } footer: {
            Text("“Record GIF” records with the system recorder and then turns the movie into a GIF on this Mac, with a progress window you can cancel. Lower quality uses fewer colours for a smaller file; merging joins pictures that repeat so a still screen costs nothing. Kriya checks there is room first, and stops and removes the GIF if the disk is nearly full. A GIF holds every picture in memory, so a large size or a high frame rate is limited to a shorter length; the message says so. The recording is kept if the GIF is cancelled or fails.")
        }
    }

    private func colour(_ path: WritableKeyPath<RecordingOptions, CodableColor>) -> Binding<Color> {
        Binding(get: { store.settings.recording[keyPath: path].swiftUIColor }, set: { value in store.update { $0.recording[keyPath: path] = CodableColor(value) } })
    }

    /// Clicks drawn on the screen while recording, so they are in the movie.
    @ViewBuilder private var clickSection: some View {
        Section {
            Toggle("Show clicks", isOn: bind(\.clickHighlight.enabled))
            if options.clickHighlight.enabled {
                Toggle("Keep a ring while the button is held", isOn: bind(\.clickHighlight.showHold))
                Toggle("Left and right clicks in different colours", isOn: bind(\.clickHighlight.distinguishButtons))
                ColorPicker(options.clickHighlight.distinguishButtons ? "Left click" : "Click", selection: colour(\.clickHighlight.leftColour), supportsOpacity: true)
                if options.clickHighlight.distinguishButtons {
                    ColorPicker("Right click", selection: colour(\.clickHighlight.rightColour), supportsOpacity: true)
                }
                Toggle("A soft glow around the pointer", isOn: bind(\.clickHighlight.cursorHalo))
                Toggle("Include in window recordings", isOn: bind(\.clickHighlight.includeInWindowRecording))
                HStack {
                    Button("Reset Click Settings") { store.update { $0.recording.clickHighlight = ClickHighlightOptions() } }.controlSize(.small)
                    Spacer()
                }
            }
        } header: { Text("Clicks") } footer: {
            Text("A ring appears where you click. It is drawn on the screen, so it is in a screen or app recording; a window recording leaves it out unless “Include in window recordings” is on, since the ring is not part of the window.")
        }
    }

    /// The keys pressed, shown on the screen while recording.
    @ViewBuilder private var keystrokeSection: some View {
        if options.showKeystrokes {
            Section {
                Picker("Position", selection: bind(\.keystrokeOptions.position)) { ForEach(KeystrokeOptions.Position.allCases) { Text($0.title).tag($0) } }
                Picker("Style", selection: bind(\.keystrokeOptions.theme)) { ForEach(KeystrokeOptions.Theme.allCases) { Text($0.title).tag($0) } }
                Picker("Size", selection: bind(\.keystrokeOptions.size)) { ForEach(KeystrokeOptions.Size.allCases) { Text($0.title).tag($0) } }
                Picker("Modifier keys", selection: bind(\.keystrokeOptions.modifierLabels)) { ForEach(KeystrokeOptions.ModifierLabels.allCases) { Text($0.title).tag($0) } }
                LabeledContent("Stays on screen") {
                    HStack(spacing: 8) {
                        Slider(value: bind(\.keystrokeOptions.fadeSeconds), in: KeystrokeOptions.fadeRange).frame(width: 140)
                        Text(String(format: "%.1f s", options.keystrokeOptions.fade)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                Toggle("Never show keys typed in a password field", isOn: bind(\.keystrokeOptions.hidePasswordFields))
                HStack {
                    Button("Reset Key Settings") { store.update { $0.recording.keystrokeOptions = KeystrokeOptions() } }.controlSize(.small)
                    Spacer()
                }
            } header: { Text("Keys on screen") } footer: {
                Text("These apply when “Show the keys I press” is on. A bare modifier key is not shown by itself.")
            }
        }
    }

    /// What happens around a recording: notifications, sound tracks and where the next one starts.
    @ViewBuilder private var aroundSection: some View {
        Section {
            Toggle("Turn on Do Not Disturb while recording", isOn: bind(\.doNotDisturb))
            if options.doNotDisturb {
                if shortcutsReady == nil {
                    Text("Looking for the two Shortcuts…").foregroundStyle(.secondary).font(.callout)
                } else if shortcutsReady == true {
                    Label("The two Shortcuts were found.", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary).font(.callout)
                } else {
                    Label("Make two Shortcuts named “\(ShortcutsFocusController.onName)” and “\(ShortcutsFocusController.offName)” that turn Do Not Disturb on and off. macOS gives apps no other way.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
            }
            Picker("Sound and microphone", selection: bind(\.audioTrackMode)) { ForEach(AudioTrackMode.allCases) { Text($0.title).tag($0) } }
                .disabled(!(options.systemAudio && options.microphone))
            Toggle("Start on the same screen and window as last time", isOn: bind(\.remembersLastSelection))
                .onChange(of: options.remembersLastSelection) { _, on in if !on { store.update { $0.recording.lastSelection = nil } } }
        } header: { Text("Around a recording") } footer: {
            Text("Do Not Disturb is turned on when recording starts and put back however it ends, including if Kriya quits or is restarted. Separate tracks keep the Mac's sound and the microphone apart so they can be edited apart; one mixed track joins them, and applies only when both are recorded. Remembering starts the next recording on the screen, and for a window recording the window, used last time, if they are still there; otherwise it uses the screen the pointer is on and the window in front.")
        }
        .task(id: options.doNotDisturb) {
            guard options.doNotDisturb else { return }
            shortcutsReady = await Task.detached { ShortcutsFocusController.isSetUp() }.value
        }
    }

    var body: some View {
        gifSection
        Section {
            Toggle("Record the Mac's sound", isOn: bind(\.systemAudio))
            Toggle("Record the microphone", isOn: bind(\.microphone))
            if options.microphone { MediaPermissionNote(permission: .microphone) }
            Toggle("Show the keys I press", isOn: bind(\.showKeystrokes))
            Toggle("Show the camera in a small window", isOn: bind(\.webcam))
            if options.webcam {
                MediaPermissionNote(permission: .camera)
                Picker("Camera shape", selection: bind(\.cameraStyle.shape)) { ForEach(CameraStyle.Shape.allCases) { Text($0.title).tag($0) } }
                Picker("Camera size", selection: bind(\.cameraStyle.size)) { ForEach(CameraStyle.Size.allCases) { Text($0.title).tag($0) } }
                Picker("Camera corner", selection: bind(\.cameraStyle.corner)) { ForEach(CameraStyle.Corner.allCases) { Text($0.title).tag($0) } }
                Toggle("A white border around the camera", isOn: bind(\.cameraStyle.border))
                Toggle("Mirror the camera, like a mirror", isOn: bind(\.cameraStyle.mirrored))
            }
            Toggle("Show the pointer", isOn: bind(\.showCursor))
            Toggle("Record in HDR", isOn: bind(\.hdr)).disabled(!ScreenRecorder.hdrAvailable)
            Picker("Frame rate", selection: bind(\.framesPerSecond)) {
                ForEach(RecordingOptions.allowedFrameRates, id: \.self) { Text("\($0) per second").tag($0) }
            }
            Picker("Largest size", selection: bind(\.maximumResolution)) { ForEach(ResolutionLimit.allCases) { Text($0.title).tag($0) } }
            Picker("Retina screens", selection: bind(\.outputScale)) { ForEach(OutputScale.allCases) { Text($0.title).tag($0) } }
            Toggle("Mix the Mac's sound down to mono", isOn: bind(\.monoAudio))
            Toggle("Count down before recording", isOn: bind(\.showCountdown))
            Toggle("Darken the displays that are not being recorded", isOn: bind(\.dimScreen))
        } header: { Text("Recording") } footer: {
            Text("Record Screen, Record Window and Record App use Kriya's own recorder, which saves a movie in the capture folder. The Mac's sound and the microphone go on separate audio tracks. Pause cuts the paused time out, so the movie has no gap. The keys and the camera are shown in windows on screen, so they are in a screen or app recording but not a window recording. A password field never shows its keys. HDR needs macOS 15 and a screen that supports it, and is untested on some displays. The first time Screen Recording is allowed, quit and open Kriya again.")
        }
        clickSection
        keystrokeSection
        aroundSection
    }
}
