import AppKit

/// Capturing with Kriya's own selector: the area, window or display is chosen on a frozen picture of the screen, a self-timer can
/// count down first (with a number on screen and a Cancel), and the picture comes from ScreenCaptureKit. It ends in the same place as
/// every other capture: `process`, then the quick card, the history and the editor.
extension ScreenCaptureService {
    /// Whether Kriya's selector takes region, window and screen captures (it does, unless macOS's own tool is chosen under Settings).
    var usesNativeSelector: Bool { nativeSelectorEnabled && !CaptureExtraSettings.modes.useMacOSSelector }

    /// The seconds to wait before this capture: the longest of the delay setting, the self-timer, and a timer chosen in the chooser.
    func timerSeconds(for settings: CaptureSettings) -> Int {
        // A timer chosen in the chooser stands for this one capture, even if it is "none".
        if let one = oneShotTimer { oneShotTimer = nil; return SelfTimer.clamped(one) }
        return SelfTimer.clamped(max(settings.delaySeconds, CaptureExtraSettings.modes.timer.seconds))
    }

    private struct Target {
        var kind: SelectorResult.Kind
        var rect: CGRect
        var displayID: CGDirectDisplayID
        var windowID: CGWindowID?
        var image: CGImage?
        var action: SelectorResult.Action = .capture
        var all = false
        /// For a chosen window: what it belongs to and is called, so it can be offered first next time.
        var windowBundleID: String?
        var windowTitle: String?
    }

    func nativeCapture(_ mode: CaptureMode, action: CaptureAction, settings current: CaptureSettings) {
        let seconds = timerSeconds(for: current)
        Task { @MainActor in await self.runNative(mode, action: action, settings: current, seconds: seconds) }
    }

    @MainActor
    private func runNative(_ mode: CaptureMode, action: CaptureAction, settings current: CaptureSettings, seconds: Int) async {
        let modes = CaptureExtraSettings.modes
        guard let target = await choose(mode, modes: modes) else { return finishCapture() }
        await deliverNative(target, action: action, settings: current, modes: modes, seconds: seconds)
    }

    // MARK: Choosing

    @MainActor
    private func choose(_ mode: CaptureMode, modes: CaptureModeSettings) async -> Target? {
        switch mode {
        case .region:
            let outcome = await selector.select(.area, shape: modes.shape, hint: "Drag to choose an area   ·   ⏎ capture   ·   ⎋ cancel   ·   R changes the shape")
            return unpack(outcome)
        case .window:
            // The window chosen last time is marked first, if it is still open.
            let outcome = await selector.select(.window, hint: "Click the window to capture   ·   ⎋ cancel", preferredWindow: preferredWindow())
            return unpack(outcome)
        case .screen:
            switch modes.display {
            case .ask:
                if NSScreen.screens.count > 1 {
                    return unpack(await selector.select(.display, hint: "Click the display to capture   ·   ⎋ cancel", preferredDisplay: preferredDisplayID()))
                }
                return displayTarget(CGMainDisplayID())
            case .pointer:
                let point = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
                return displayTarget(screen.flatMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID } ?? CGMainDisplayID())
            case .main:
                return displayTarget(CGMainDisplayID())
            case .all:
                var target = displayTarget(CGMainDisplayID())
                target.all = true
                return target
            }
        }
    }

    private func displayTarget(_ id: CGDirectDisplayID) -> Target { Target(kind: .display, rect: CGDisplayBounds(id), displayID: id) }

    @MainActor
    private func unpack(_ outcome: (result: SelectorResult?, problem: String?)) -> Target? {
        if let problem = outcome.problem { toast.show(problem, isError: true); return nil }
        guard let r = outcome.result else { return nil }
        return Target(kind: r.kind, rect: r.rect, displayID: r.displayID, windowID: r.windowID, image: r.image, action: r.action,
                      windowBundleID: r.windowBundleID, windowTitle: r.windowTitle)
    }

    // MARK: Taking the picture

    @MainActor
    private func deliverNative(_ target: Target, action: CaptureAction, settings current: CaptureSettings, modes: CaptureModeSettings, seconds: Int) async {
        var settings = current
        var action = action
        var pin = false
        // A command that starts from an area (capture and copy, save, upload, mark up, pin) decides for itself what happens.
        var chosen = target.action
        let forcedDelivery = consumeForcedDelivery()
        if chosen == .capture, let forced = forcedDelivery {
            switch forced {
            case .copy: chosen = .copy
            case .save: chosen = .save
            case .upload: chosen = .upload
            case .annotate: chosen = .annotate
            case .pin: chosen = .pin
            }
        }
        switch chosen {
        case .capture, .scrollAuto, .scrollManual: break
        case .copy:
            settings.saveToFolder = false; settings.copyImage = true
            deliveryAdjustment = { $0.copy = true; $0.save = false; $0.upload = false; $0.copyLink = false }
        case .save:
            settings.copyImage = false; settings.saveToFolder = true
            deliveryAdjustment = { $0.copy = false; $0.save = true; $0.upload = false; $0.copyLink = false }
        case .upload:
            settings.copyImage = false; settings.saveToFolder = true
            deliveryAdjustment = { $0.copy = false; $0.save = true; $0.upload = true; $0.copyLink = true }
        case .annotate: settings.openEditor = true
        case .pin: pin = true
        case .text: action = .text
        case .redact: action = .redacted
        }
        if target.kind == .area, let area = PreviousArea(rect: target.rect, layout: AreaPicker.currentLayout) { previousArea = area }
        // The display (and window) just chosen are offered first next time, if remembering is on.
        rememberSelection(displayID: target.displayID, windowBundleID: target.windowBundleID, windowTitle: target.kind == .window ? target.windowTitle : nil)

        if seconds > 0 {
            let title = target.kind == .window ? "Capturing the window in" : "Capturing in"
            guard await CaptureCountdown().run(seconds: seconds, title: title, on: screen(for: target.displayID)) else {
                toast.show("Capture cancelled.")
                return finishCapture()
            }
        }
        let options = ScreenGrabber.Options(includeCursor: current.includeCursor ?? false, hideDesktopIcons: modes.hideDesktopIcons, excludeKriya: true, cropNotch: modes.cropNotch)
        do {
            var image: CGImage
            switch target.kind {
            case .area:
                // What was seen is what is captured, unless time has passed or the pointer is wanted in the picture.
                if seconds == 0, !(current.includeCursor ?? false), let frozen = target.image { image = frozen }
                else { image = try await ScreenGrabber.areaImage(target.rect, options: options) }
            case .window:
                guard let id = target.windowID else { return finishCapture() }
                image = try await ScreenGrabber.windowImage(id, look: modes.windowLook, options: options)
                // Shift held when the window was clicked turns the transparent background on or off for this capture.
                image = CaptureLooks.apply(modes.windowShot, shiftHeld: CaptureModifiers.current.contains(.shift), to: image)
            case .display:
                image = target.all ? try await ScreenGrabber.allDisplaysImage(options: options) : try await ScreenGrabber.displayImage(target.displayID, options: options)
            }
            // Which display it came from says whether this is a Retina picture, for keeping it at 1x and for an "@2x" name.
            noteBackingScale(of: target.displayID)
            // The sound, now the picture is taken (Kriya's own selector makes none by itself).
            playCaptureSound(current)
            if pin {
                PinnedShots.shared.pin(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
                return finishCapture()
            }
            processInBackground(image, action: action, settings: settings)
        } catch {
            toast.show(error.localizedDescription, isError: true)
            finishCapture()
        }
    }

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id } ?? NSScreen.main
    }

    // MARK: The chooser

    @MainActor
    func showChooser() {
        let modes = CaptureExtraSettings.modes
        chooser.show(last: modes.chooserStart, timerSeconds: modes.timer.seconds, previousAvailable: previousArea?.valid(for: AreaPicker.currentLayout) != nil) { [weak self] choice, timer in
            guard let self else { return }
            var remembered = CaptureExtraSettings.modes
            remembered.rememberChoice(choice)
            CaptureExtraSettings.modes = remembered
            self.oneShotTimer = timer
            // "Record" starts the kind of recording started last, when remembering is on.
            if !self.run(command: remembered.command(for: choice)) { self.oneShotTimer = nil }
        }
    }

    // MARK: Previous and saved areas

    /// The previous area again, exactly, on the same display. If the displays changed, it says so and lets the person choose again.
    func nativePreviousArea(settings current: CaptureSettings) {
        let seconds = timerSeconds(for: current)
        Task { @MainActor in
            if let saved = previousArea {
                guard saved.valid(for: AreaPicker.currentLayout) != nil else {
                    previousArea = nil
                    toast.show("The previous area is no longer valid. Select a new area.")
                    await runNative(.region, action: .normal, settings: current, seconds: seconds)
                    return
                }
                await captureSaved(saved.rect, settings: current, seconds: seconds)
            } else {
                toast.show("No area has been captured yet. Drag one out.")
                await runNative(.region, action: .normal, settings: current, seconds: seconds)
            }
        }
    }

    /// A saved area by its command (`capture.area.<id>`).
    func captureNamedArea(id: String) -> Bool {
        guard let area = CaptureExtraSettings.modes.namedAreas.first(where: { $0.id == id }) else { return false }
        guard !isCapturing else { return true }
        guard hasPermission() else { handleMissingPermission(); return true }
        guard let rect = area.valid(for: AreaPicker.currentLayout) else {
            toast.show("“\(area.name)” is no longer valid: the displays changed. Save it again.", isError: true)
            return true
        }
        let current = settings.settings
        let seconds = timerSeconds(for: current)
        beginCapture()
        Task { @MainActor in await self.captureSaved(rect, settings: current, seconds: seconds) }
        return true
    }

    /// Saves the previous area under a name, for one app or for any.
    @discardableResult
    func saveNamedArea(_ name: String, appBundleID: String? = nil) -> Bool {
        guard let rect = previousArea?.rect, let area = NamedArea(name: name, rect: rect, layout: AreaPicker.currentLayout, appBundleID: appBundleID) else { return false }
        var modes = CaptureExtraSettings.modes
        modes.save(area)
        CaptureExtraSettings.modes = modes
        onSavedAreasChanged()
        return true
    }

    /// Forgets a saved area.
    func deleteNamedArea(id: String) {
        var modes = CaptureExtraSettings.modes
        modes.namedAreas.removeAll { $0.id == id }
        CaptureExtraSettings.modes = modes
        onSavedAreasChanged()
    }

    @MainActor
    private func captureSaved(_ rect: CGRect, settings current: CaptureSettings, seconds: Int) async {
        let target = Target(kind: .area, rect: rect, displayID: CGMainDisplayID())
        await deliverNative(target, action: .normal, settings: current, modes: CaptureExtraSettings.modes, seconds: max(seconds, 0))
    }

    // MARK: Menus

    /// A menu closes when you click, so nothing can be chosen on a frozen picture: a countdown gives time to open it, then the whole
    /// display is captured and opened in the editor to be cropped to the menu.
    func nativeMenuCapture(settings current: CaptureSettings) {
        let seconds = max(timerSeconds(for: current), 5)
        hasMenuCapture = true
        Task { @MainActor in
            let point = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
            guard await CaptureCountdown().run(seconds: seconds, title: "Open the menu now. Capturing in", on: screen) else {
                toast.show("Menu capture cancelled.")
                return finishCapture()
            }
            // The display the pointer is on at the end, which is where the menu is.
            let end = NSEvent.mouseLocation
            let shown = NSScreen.screens.first { NSMouseInRect(end, $0.frame, false) } ?? screen
            let id = shown?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
            var settings = current
            settings.openEditor = true
            do {
                let image = try await ScreenGrabber.displayImage(id, options: .init(includeCursor: true, hideDesktopIcons: false, excludeKriya: true, cropNotch: false))
                processInBackground(image, action: .normal, settings: settings)
            } catch {
                toast.show(error.localizedDescription, isError: true)
                finishCapture()
            }
        }
    }

    // MARK: Scrolling

    func startScrollingCapture(settings current: CaptureSettings) {
        let modes = CaptureExtraSettings.modes
        let seconds = timerSeconds(for: current)
        Task { @MainActor in
            let outcome = await selector.select(.area, toolbar: false, hint: "Select the area that scrolls   ·   ↕ button: Kriya scrolls   ·   ✋ button: you scroll   ·   ⏎ the way you scrolled last   ·   ⎋ cancel")
            guard let target = unpack(outcome) else { return finishCapture() }
            if seconds > 0, !(await CaptureCountdown().run(seconds: seconds, title: "Scrolling capture in", on: screen(for: target.displayID))) {
                toast.show("Capture cancelled.")
                return finishCapture()
            }
            var mode = modes.scrollMode
            // The buttons under the area choose for this capture, and the choice is remembered; ⏎ uses the one used last.
            if target.action == .scrollAuto { mode = .automatic } else if target.action == .scrollManual { mode = .manual }
            if target.action == .scrollAuto || target.action == .scrollManual {
                var remembered = CaptureExtraSettings.modes
                remembered.rememberScrollMode(mode)
                if remembered != CaptureExtraSettings.modes { CaptureExtraSettings.modes = remembered }
            }
            if mode == .automatic, !AXIsProcessTrusted() {
                // Scrolling for you needs Accessibility. Without it, you scroll and Kriya watches.
                mode = .manual
                toast.show("Accessibility is off, so Kriya cannot scroll for you. Scroll the page yourself; Kriya takes the pictures.")
            }
            let options = ScreenGrabber.Options(includeCursor: false, hideDesktopIcons: false, excludeKriya: true, cropNotch: false)
            let session = ScrollCaptureSession(rect: target.rect, axis: modes.scrollAxis, mode: mode, options: options, stepFraction: modes.scrollStep, useDocument: modes.scrollUsesDocument)
            scrollSession = session
            let (image, summary) = await session.run()
            scrollSession = nil
            guard let image else {
                toast.show(summary, isError: !summary.contains("cancelled"))
                return finishCapture()
            }
            toast.show(summary)
            processInBackground(image, action: .normal, settings: current)
        }
    }

    // MARK: Recordings that did not finish

    /// A recording left behind by a crash or a power cut is found at the next start. Its movie was written in pieces, so everything up
    /// to the last few seconds is there: it is shown in Finder, and Kriya says so.
    func recoverUnfinishedRecordings() {
        let folder = settings.settings.folder
        let found = RecordingRecovery.unfinished(in: folder).filter { url in
            // One being recorded right now is not unfinished.
            !recording.isRecording
        }
        guard !found.isEmpty else { return }
        for movie in found { RecordingRecovery.acknowledge(movie) }
        DispatchQueue.main.async {
            self.toast.show(found.count == 1 ? "A recording was cut off last time: \(found[0].lastPathComponent). What was recorded is saved." : "\(found.count) recordings were cut off last time. What was recorded is saved.", isError: false)
            NSWorkspace.shared.activateFileViewerSelecting(found)
        }
    }

    // MARK: Recording with a timer

    /// Starts Kriya's recorder after the self-timer, with the app that was in front when it was asked for.
    func startRecordingAfterTimer(_ requested: RecordingOptions, settings current: CaptureSettings, seconds: Int, target: NSRunningApplication?) {
        // Starting on the display and window used last time: what is gone by now is dropped, and what this recording is of is remembered.
        var chosen = requested
        chosen.lastSelection = validRecordingSelection(requested)
        if chosen.remembersLastSelection {
            let pointerScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            let pointerDisplay = (pointerScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let shownDisplay = chosen.lastSelection?.displayUUID.flatMap { DisplayIdentity.id(forUUID: $0) } ?? pointerDisplay
            let bundle = target?.bundleIdentifier
            let window = chosen.source == .window ? LiveWindows.current()?.first { $0.bundleID == bundle } : nil
            let remembered = rememberRecordingSelection(chosen, display: shownDisplay, window: window)
            chosen.lastSelection = remembered.lastSelection
            let selection = remembered.lastSelection
            settings.update { $0.recording.lastSelection = selection }
        }
        let options = chosen
        // A countdown asked for in the recording options counts at least 3 seconds, or the self-timer's longer time.
        let wait = options.countdown(selfTimer: seconds)
        Task { @MainActor in
            if wait > 0 {
                let point = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
                // Cancelling here ends it before anything has changed on the screen: the dimming starts only once recording has.
                guard await CaptureCountdown().run(seconds: wait, title: "Recording in", on: screen) else {
                    toast.show("Recording cancelled.")
                    return finishCapture()
                }
            }
            recording.start(options, into: current.folder, namePattern: current.namePattern, app: frontApp, mode: options.source.rawValue, target: target)
        }
    }
}

// MARK: - The look of a captured window

enum CaptureLooks {
    /// The captured window made to look the way chosen. `system` and `windowOnly` are as captured; the shadow and the backdrop are put on.
    static func apply(_ look: WindowLook, to image: CGImage) -> CGImage {
        apply(WindowShotOptions(look: look), shiftHeld: false, to: image)
    }

    /// The captured window made into what the options say. `shiftHeld` flips transparent and backdrop for this one picture of a framed
    /// window. `globalBackdropOn` is whether a backdrop is already set for every capture, in which case delivery adds it and a framed
    /// window gets none here (so there are never two).
    static func apply(_ options: WindowShotOptions, shiftHeld: Bool, globalBackdropOn: Bool = CaptureExtraSettings.beautify.isOn, to image: CGImage) -> CGImage {
        let shot = options.effective(shiftHeld: shiftHeld)
        switch shot.style {
        case .system:
            return image
        case .window:
            return shot.shadow ? (withShadow(image) ?? image) : image
        case .framed:
            // On a transparent canvas the space around is only the shadow's; on a backdrop it is the backdrop's padding.
            if shot.transparentBackground { return shot.shadow ? (withShadow(image) ?? image) : image }
            guard !globalBackdropOn else { return image }
            var style = CaptureBeautify()
            style.background = shot.backdrop == .none ? .graphite : shot.backdrop
            style.shadow = shot.shadow
            return CaptureRenderer.beautified(image, style) ?? image
        }
    }

    /// The picture on a transparent canvas with a soft shadow below it.
    static func withShadow(_ image: CGImage) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let blur = max(16, min(w, h) * 0.04)
        let pad = blur * 2
        let offset = blur * 0.45
        guard let context = CGContext(data: nil, width: Int(w + pad * 2), height: Int(h + pad * 2 + offset), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setShadow(offset: CGSize(width: 0, height: -offset), blur: blur, color: NSColor.black.withAlphaComponent(0.42).cgColor)
        context.draw(image, in: CGRect(x: pad, y: pad + offset, width: w, height: h))
        return context.makeImage()
    }
}

/// Keeps one command in the command list for each saved area (`capture.area.<id>`), so a saved area can go on a shortcut, a mouse
/// button, a hot corner or into a workflow like any other command.
final class AreaCommandRegistry {
    private let executor: ActionExecutor
    private var registered = Set<String>()

    init(executor: ActionExecutor) { self.executor = executor }

    func sync(run: @escaping (String) -> Void) {
        let wanted = Set(CaptureExtraSettings.modes.namedAreas.map(\.command))
        for gone in registered.subtracting(wanted) { executor.unregisterCommand(gone) }
        for command in wanted.subtracting(registered) { executor.registerCommand(command) { DispatchQueue.main.async { run(command) } } }
        registered = wanted
    }
}
