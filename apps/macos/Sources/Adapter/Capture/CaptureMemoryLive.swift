import AppKit

/// Telling displays apart in a way that survives a restart: the display's own identifier, not the number macOS gives it for one session.
enum DisplayIdentity {
    static func uuid(of id: CGDirectDisplayID) -> String? {
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        let uuid = unmanaged.takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// The identifiers of the displays connected now.
    static func connectedUUIDs() -> Set<String> {
        Set(NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).flatMap(uuid(of:))
        })
    }

    /// The display with this identifier, if it is connected.
    static func id(forUUID uuid: String) -> CGDirectDisplayID? {
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID, Self.uuid(of: id) == uuid else { continue }
            return id
        }
        return nil
    }
}

/// The windows open now, as what can be remembered about them.
enum LiveWindows {
    /// Nil when it cannot be told: with Screen Recording off, macOS hides window titles, so a window cannot be matched.
    static func current() -> [RememberedWindow]? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0, let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let title = info[kCGWindowName as String] as? String, !title.isEmpty,
                  let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return nil }
            return RememberedWindow(bundleID: bundleID, title: title)
        }
    }
}

extension ScreenCaptureService {
    /// Takes out of the memory what no longer exists: a display that is not connected, a window that is not open. Done when Kriya starts
    /// and again when the chooser or the selector is about to use it.
    @discardableResult
    func validateRemembered() -> CaptureModeSettings {
        var modes = CaptureExtraSettings.modes
        let valid = modes.memory.validated(displays: DisplayIdentity.connectedUUIDs(), windows: LiveWindows.current())
        if valid != modes.memory {
            modes.memory = valid
            CaptureExtraSettings.modes = modes
        }
        return modes
    }

    /// Remembers what was just chosen (when remembering is on): the display, and for a window, the window.
    func rememberSelection(displayID: CGDirectDisplayID, windowBundleID: String?, windowTitle: String?) {
        var modes = CaptureExtraSettings.modes
        guard modes.memory.remembers else { return }
        let before = modes.memory
        modes.memory.rememberDisplay(DisplayIdentity.uuid(of: displayID))
        if let windowTitle { modes.memory.rememberWindow(bundleID: windowBundleID, title: windowTitle) }
        if modes.memory != before { CaptureExtraSettings.modes = modes }
    }

    /// Remembers the kind of recording that was started.
    func rememberRecording(_ action: CaptureAction) {
        guard RecordingChoice.of(action) != nil else { return }
        var modes = CaptureExtraSettings.modes
        let before = modes.memory
        modes.memory.rememberRecording(action)
        if modes.memory != before { CaptureExtraSettings.modes = modes }
    }

    /// The display chosen last time, if remembering is on and it is still connected.
    func preferredDisplayID() -> CGDirectDisplayID? {
        let modes = validateRemembered()
        guard modes.memory.remembers, let uuid = modes.memory.displayUUID else { return nil }
        return DisplayIdentity.id(forUUID: uuid)
    }

    /// The window chosen last time, if remembering is on and it is still open.
    func preferredWindow() -> RememberedWindow? {
        let modes = validateRemembered()
        return modes.memory.remembers ? modes.memory.window : nil
    }
}

extension ScreenCaptureService {
    /// Remembers what a recording was of: its display and, for a window recording, the window. Only while remembering is on.
    func rememberRecordingSelection(_ options: RecordingOptions, display: CGDirectDisplayID?, window: RememberedWindow?) -> RecordingOptions {
        guard options.remembersLastSelection else { return options }
        var next = options
        var selection = options.lastSelection ?? RecordingSelection()
        if let display, let uuid = DisplayIdentity.uuid(of: display) { selection.displayUUID = uuid }
        if let window { selection.window = window }
        next.lastSelection = selection
        return next
    }

    /// The remembered selection with whatever no longer exists taken out, checked now, just before it is used.
    func validRecordingSelection(_ options: RecordingOptions) -> RecordingSelection? {
        guard options.remembersLastSelection, let selection = options.lastSelection else { return nil }
        var sizes: [String: CGSize] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID, let uuid = DisplayIdentity.uuid(of: id) else { continue }
            sizes[uuid] = screen.frame.size
        }
        let valid = selection.validated(displaySizes: sizes, windows: LiveWindows.current())
        return valid.isEmpty ? nil : valid
    }
}
