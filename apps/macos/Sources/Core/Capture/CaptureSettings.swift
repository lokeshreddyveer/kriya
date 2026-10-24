import Foundation

/// How a capture is taken.
enum CaptureMode: String, CaseIterable, Identifiable, Codable {
    case region, window, screen
    var id: String { rawValue }

    var title: String {
        switch self {
        case .region: return "Region"
        case .window: return "Window"
        case .screen: return "Full screen"
        }
    }

    var symbol: String {
        switch self {
        case .region: return "viewfinder"
        case .window: return "macwindow"
        case .screen: return "display"
        }
    }
}

/// What to do with a capture once it is taken.
enum CaptureAction: String, CaseIterable, Identifiable, Codable {
    /// Deliver the picture as the settings say.
    case normal
    /// Read the text in it and copy only the text.
    case text
    /// Hide private-looking text first, then deliver.
    case redacted
    /// Read a QR code in it and copy what it holds.
    case qr
    /// Lift the main subject off its background and copy it as a picture with a clear background.
    case cutout
    /// Cut a saved recording down to part of it.
    case trimRecording
    /// Drag out an area to capture, and remember it. And capture the same area again without asking.
    case area, previousArea
    /// Record the screen as a movie, or as a GIF.
    case record, recordGIF
    /// Scroll the window in front and join the pages into one tall picture.
    case scroll
    /// A frozen screen to measure on, with a magnifier and colour readout.
    case ruler
    /// Keep the picture on top of everything.
    case pin
    /// Record with Kriya's own recorder: sound, microphone, pause, keys and camera. The source is the screen, the window in
    /// front or the front app.
    case recordScreen, recordWindow, recordApp
    /// Pause or resume, and stop, the recording in progress.
    case pauseRecording, stopRecording
    /// A floating live copy of the window in front.
    case mirror
    /// A capture of the whole screen after a countdown, so a menu can be opened first. It opens in the editor to be cropped.
    case menu
    /// Opens the panel that offers every kind of capture.
    case chooser
    /// Read the text and copy it as one paragraph (no line breaks), as Markdown paragraphs, or a table as CSV.
    case textJoined, textMarkdown, textTable
    var id: String { rawValue }
}

struct CaptureShortcut: Codable, Equatable, Identifiable {
    var command: String
    var keyCode: UInt16
    var modifiers: UInt64
    var id: String { command }
}

struct CaptureSettings: Codable, Equatable {
    var copyImage = true
    var saveToFolder = true
    /// Empty means the default folder in Pictures.
    var folderPath = ""
    var openEditor = false
    var redactAutomatically = false
    var delaySeconds = 0
    var playSound = false
    /// Names or words to hide wherever they appear when private text is hidden, on top of emails, numbers and keys.
    var redactWords: [String] = []
    var shortcuts: [CaptureShortcut] = []
    /// How files are named: "{app} {date} {time}". Nil is the original "Kriya Capture date time".
    var namePattern: String?
    /// Draw the pointer in the picture. Optional so settings saved before it existed still load.
    var includeCursor: Bool?
    /// How Kriya's own recorder records. Optional so settings saved before it existed still load.
    var recordingOptions: RecordingOptions?
    var recording: RecordingOptions {
        get { recordingOptions ?? RecordingOptions() }
        set { recordingOptions = newValue }
    }

    /// The commands that start a capture, by name. The same names work from mouse rules, workflows and the launcher.
    static let commands: [(command: String, title: String, mode: CaptureMode, action: CaptureAction)] = [
        ("capture.region", "Capture a region", .region, .normal),
        ("capture.window", "Capture a window", .window, .normal),
        ("capture.screen", "Capture the whole screen", .screen, .normal),
        ("capture.text", "Copy text from a region (OCR)", .region, .text),
        ("capture.text.joined", "Copy text from a region as one paragraph (OCR)", .region, .textJoined),
        ("capture.text.markdown", "Copy text from a region as Markdown paragraphs (OCR)", .region, .textMarkdown),
        ("capture.table", "Copy a table from a region as CSV (OCR)", .region, .textTable),
        ("capture.redacted", "Capture a region and hide private text", .region, .redacted),
        ("capture.qr", "Read a QR code from a region", .region, .qr),
        ("capture.area", "Capture an area (and remember it)", .region, .area),
        ("capture.again", "Capture the previous area again", .region, .previousArea),
        ("capture.trim", "Trim a recording to part of it", .screen, .trimRecording),
        ("capture.cutout", "Cut out the subject of a region (clear background)", .region, .cutout),
        ("capture.record", "Record the screen", .region, .record),
        ("capture.gif", "Record the screen as a GIF", .region, .recordGIF),
        ("capture.scroll", "Capture the whole page of the front window (scrolling)", .window, .scroll),
        ("capture.ruler", "Measure pixels on the screen (ruler)", .screen, .ruler),
        ("capture.pin", "Pin the clipboard picture or the latest capture on screen", .screen, .pin),
        ("capture.rec.screen", "Record the whole screen (sound, camera, keys)", .screen, .recordScreen),
        ("capture.rec.window", "Record the window in front", .window, .recordWindow),
        ("capture.rec.app", "Record the front app", .window, .recordApp),
        ("capture.rec.pause", "Pause or resume the recording", .screen, .pauseRecording),
        ("capture.rec.stop", "Stop and save the recording", .screen, .stopRecording),
        ("capture.mirror", "Float a live copy of the window in front", .window, .mirror),
        ("capture.menu", "Capture a menu (5 seconds to open it, then crop)", .screen, .menu),
        ("capture.all", "Open the capture chooser (every kind of capture in one panel)", .region, .chooser),
    ]

    static var defaultFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Kriya Captures", isDirectory: true)
    }

    var folder: URL { folderPath.isEmpty ? Self.defaultFolder : URL(fileURLWithPath: folderPath, isDirectory: true) }
}

/// The capture settings, kept in the app's preferences.
final class CaptureSettingsStore: ObservableObject {
    @Published private(set) var settings: CaptureSettings

    private let defaults: UserDefaults
    private let key = "captureSettings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(CaptureSettings.self, from: data) {
            settings = decoded
        } else {
            settings = CaptureSettings()
        }
        sanitize()
    }

    func update(_ change: (inout CaptureSettings) -> Void) {
        var next = settings
        change(&next)
        next.delaySeconds = min(max(next.delaySeconds, 0), 30)
        next.redactWords = Array(Set(next.redactWords.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 && $0.count <= 60 })).sorted().prefix(100).map { $0 }
        guard next != settings else { return }
        settings = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: key) }
    }

    /// A shortcut with no modifier keys would take over normal typing, and two commands cannot share keys.
    private func sanitize() {
        var seen = Set<String>()
        settings.shortcuts = settings.shortcuts.filter { shortcut in
            guard shortcut.modifiers != 0, CaptureSettings.commands.contains(where: { $0.command == shortcut.command }) else { return false }
            return seen.insert("\(shortcut.keyCode):\(shortcut.modifiers)").inserted
        }
    }

    func shortcut(for command: String) -> CaptureShortcut? { settings.shortcuts.first { $0.command == command } }

    func setShortcut(_ command: String, keyCode: UInt16?, modifiers: UInt64) {
        update { settings in
            settings.shortcuts.removeAll { $0.command == command }
            if let keyCode, modifiers != 0 {
                settings.shortcuts.removeAll { $0.keyCode == keyCode && $0.modifiers == modifiers }
                settings.shortcuts.append(CaptureShortcut(command: command, keyCode: keyCode, modifiers: modifiers))
            }
        }
    }
}

/// The arguments for the system's own screenshot tool, kept apart so they can be checked.
enum ScreenCaptureArguments {
    static func make(mode: CaptureMode, delay: Int, sound: Bool, output: URL, cursor: Bool = false) -> [String] {
        var arguments: [String] = []
        switch mode {
        case .region: arguments += ["-i", "-s"]
        case .window: arguments += ["-i", "-w"]
        case .screen: break
        }
        if !sound { arguments.append("-x") }
        if cursor { arguments.append("-C") }
        if delay > 0 { arguments += ["-T", String(min(delay, 30))] }
        arguments += ["-t", "png", output.path]
        return arguments
    }

    /// A file name that sorts by time and cannot clash: "Kriya Capture 2026-10-22 14.05.09.png".
    static func fileName(for date: Date, existing: (String) -> Bool = { _ in false }) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "Kriya Capture \(formatter.string(from: date))"
        var name = "\(base).png"
        var counter = 2
        while existing(name) {
            name = "\(base) \(counter).png"
            counter += 1
        }
        return name
    }
}
