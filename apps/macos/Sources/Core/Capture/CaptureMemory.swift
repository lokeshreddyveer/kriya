import Foundation

/// Which kind of recording was started last.
enum RecordingChoice: String, Codable, CaseIterable, Identifiable {
    case screen, window, app, gif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: return "Screen"
        case .window: return "Window"
        case .app: return "App"
        case .gif: return "GIF"
        }
    }

    /// The command that starts it, as the rest of Kriya names it.
    var command: String {
        switch self {
        case .screen: return "capture.rec.screen"
        case .window: return "capture.rec.window"
        case .app: return "capture.rec.app"
        case .gif: return "capture.gif"
        }
    }

    /// The recording an action starts, or nil if the action is not a recording.
    static func of(_ action: CaptureAction) -> RecordingChoice? {
        switch action {
        case .record, .recordScreen: return .screen
        case .recordWindow: return .window
        case .recordApp: return .app
        case .recordGIF: return .gif
        default: return nil
        }
    }
}

/// A window picked last time, by something that survives a restart: the app it belonged to and its title. (A window's own number does
/// not.)
struct RememberedWindow: Codable, Equatable {
    var bundleID: String
    var title: String
}

/// What the capture chooser and the selector remember between uses, and for how long it is still true.
struct CaptureMemory: Codable, Equatable {
    /// Remember at all. Off, the chooser opens on "Area", and no display or window is offered first.
    var remembers = true
    /// The kind of recording started last. (The kind of capture chosen last is `CaptureModeSettings.lastChoice`, and the scrolling mode
    /// chosen last is `CaptureModeSettings.scrollMode`.)
    var recording: RecordingChoice = .screen
    /// The display chosen last, by the identifier a display keeps across restarts and being unplugged.
    var displayUUID: String?
    var window: RememberedWindow?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        remembers = c.value(.remembers, true)
        recording = c.value(.recording, RecordingChoice.screen)
        displayUUID = try? c.decodeIfPresent(String.self, forKey: .displayUUID)
        window = try? c.decodeIfPresent(RememberedWindow.self, forKey: .window)
    }

    /// The same memory with what no longer exists taken out: a display that is not connected, a window that is not open. `windows` is
    /// nil when what is open cannot be known (Screen Recording is off, so titles are hidden); a window is then left as it is, not
    /// thrown away on a guess.
    func validated(displays: Set<String>, windows: [RememberedWindow]?) -> CaptureMemory {
        var next = self
        if let uuid = displayUUID, !displays.contains(uuid) { next.displayUUID = nil }
        if let window, let windows, !windows.contains(window) { next.window = nil }
        return next
    }

    mutating func rememberDisplay(_ uuid: String?) { if remembers, let uuid { displayUUID = uuid } }
    mutating func rememberWindow(bundleID: String?, title: String) {
        guard remembers, let bundleID, !bundleID.isEmpty, !title.isEmpty else { return }
        window = RememberedWindow(bundleID: bundleID, title: title)
    }
    mutating func rememberRecording(_ action: CaptureAction) {
        if remembers, let choice = RecordingChoice.of(action) { recording = choice }
    }
}

/// What the selector shows to help aim: the crosshair pointer and the magnifier. Each can be on or off by itself. The pixel ruler has
/// its own and does not read these.
struct SelectorAids: Codable, Equatable {
    var showCrosshair = true
    var showMagnifier = true

    enum Pointer: Equatable { case crosshair, arrow }

    static let both = SelectorAids(showCrosshair: true, showMagnifier: true)
    static let crosshairOnly = SelectorAids(showCrosshair: true, showMagnifier: false)
    static let magnifierOnly = SelectorAids(showCrosshair: false, showMagnifier: true)
    static let neither = SelectorAids(showCrosshair: false, showMagnifier: false)

    /// The pointer over the frozen screen. The crosshair is only for choosing an area; windows and displays are clicked, with an arrow.
    func pointer(choosingArea: Bool) -> Pointer { showCrosshair && choosingArea ? .crosshair : .arrow }

    /// Whether the magnifier is drawn: it is on, the area is not being adjusted, and the pointer is on this display.
    func magnifier(adjusting: Bool, pointerOnThisDisplay: Bool) -> Bool { showMagnifier && !adjusting && pointerOnThisDisplay }
}
