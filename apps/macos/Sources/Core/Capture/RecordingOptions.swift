import Foundation

/// What a screen recording captures.
enum RecordingSource: String, CaseIterable, Identifiable, Codable {
    /// The whole display the pointer is on.
    case screen
    /// The window in front.
    case window
    /// Everything one app shows, on the display the pointer is on.
    case app
    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: return "Whole screen"
        case .window: return "Window in front"
        case .app: return "The front app"
        }
    }
}

/// How a recording is made. Kept apart from the recorder so the choices can be checked without a screen.
struct RecordingOptions: Codable, Equatable {
    var source: RecordingSource = .screen
    var systemAudio = true
    var microphone = false
    /// Records in a wider range of brightness and colour, on screens that have it. Needs macOS 15.
    var hdr = false
    var framesPerSecond = 30
    var showCursor = true
    /// Shows the keys being pressed on screen while recording, so they are in the video.
    var showKeystrokes = false
    /// Shows the camera in a small round window while recording, so it is in the video.
    var webcam = false
    /// The camera's own id. Empty means the Mac's default one.
    var cameraID = ""

    static let allowedFrameRates = [15, 24, 30, 60]

    /// The same options with anything unusable put right, given what this Mac can do.
    func sanitized(hdrAvailable: Bool) -> RecordingOptions {
        var next = self
        if !Self.allowedFrameRates.contains(next.framesPerSecond) {
            next.framesPerSecond = Self.allowedFrameRates.min { abs($0 - framesPerSecond) < abs($1 - framesPerSecond) } ?? 30
        }
        if !hdrAvailable { next.hdr = false }
        return next
    }

    /// Whether two audio tracks are written (the Mac's sound and the microphone), which matters for the file's layout.
    var audioTrackCount: Int { (systemAudio ? 1 : 0) + (microphone ? 1 : 0) }
}

/// Keeps time for a recording that can be paused: the paused stretch is cut out, so what follows picks up straight after what
/// came before, and no gap or freeze is written. Times are seconds on the capture's own clock.
struct PauseClock {
    private(set) var isPaused = false
    private var offset: Double = 0
    private var last: Double?
    private var resumePending = false
    /// The time one frame lasts, used to place the first frame after a pause one frame after the last before it.
    var frameDuration: Double

    init(frameDuration: Double = 1.0 / 30.0) { self.frameDuration = frameDuration }

    /// The time to write for a video frame captured at `time`, or nil if it is dropped (paused).
    mutating func video(at time: Double) -> Double? {
        if isPaused { return nil }
        if resumePending {
            // The first frame after a pause follows the last one written by a single frame.
            let written = (last ?? time) - offset
            offset = time - (written + frameDuration)
            resumePending = false
        }
        last = time
        return time - offset
    }

    /// The time to write for audio captured at `time`, or nil if it is dropped. Audio waits for the first frame after a pause,
    /// since that frame decides how far the clock moved.
    func audio(at time: Double) -> Double? {
        if isPaused || resumePending { return nil }
        let written = time - offset
        return written < 0 ? nil : written
    }

    mutating func pause() { isPaused = true }

    mutating func resume() {
        guard isPaused else { return }
        isPaused = false
        resumePending = true
    }
}

/// Turns key presses into the short labels shown on screen while recording: "⌘⇧4", "Return", "A".
enum KeystrokeLabel {
    private static let names: [UInt16: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 71: "Clear", 76: "Enter", 117: "Fwd Delete",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    struct Modifiers: OptionSet {
        let rawValue: UInt
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)

        var symbols: String {
            (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
        }
    }

    /// The label for a key press, or nil for one that should not be shown (a bare modifier, or a character in a field that hides
    /// what is typed). `characters` is what the key types without any modifier, upper-cased for display.
    static func label(keyCode: UInt16, characters: String?, modifiers: Modifiers, secureInput: Bool = false) -> String? {
        if secureInput { return nil }
        let name = names[keyCode] ?? characters?.trimmingCharacters(in: .controlCharacters).uppercased()
        guard let name, !name.isEmpty else { return nil }
        // A plain letter with no modifier (or only Shift) is ordinary typing; it is shown too, but without the modifier symbol.
        return modifiers.symbols + name
    }
}

/// The last few key labels shown on screen. A new one extends the line; old ones fade after a moment.
struct KeystrokeStrip: Equatable {
    struct Item: Equatable {
        var text: String
        var time: Double
    }

    private(set) var items: [Item] = []
    var lifetime: Double = 1.6
    var capacity = 6

    /// Adds a label. Repeated presses of the same key within a moment are counted ("A ×3") instead of filling the line.
    mutating func add(_ text: String, at time: Double) {
        prune(at: time)
        if let lastIndex = items.indices.last {
            let base = Self.base(of: items[lastIndex].text)
            if base == text, time - items[lastIndex].time < 0.8 {
                items[lastIndex] = Item(text: Self.counted(base, count: Self.count(of: items[lastIndex].text) + 1), time: time)
                return
            }
        }
        items.append(Item(text: text, time: time))
        if items.count > capacity { items.removeFirst(items.count - capacity) }
    }

    mutating func prune(at time: Double) {
        items.removeAll { time - $0.time > lifetime }
    }

    func text(at time: Double) -> String {
        items.filter { time - $0.time <= lifetime }.map(\.text).joined(separator: "  ")
    }

    private static func counted(_ base: String, count: Int) -> String { "\(base) ×\(count)" }

    private static func base(of text: String) -> String {
        guard let range = text.range(of: " ×", options: .backwards), Int(text[range.upperBound...]) != nil else { return text }
        return String(text[..<range.lowerBound])
    }

    private static func count(of text: String) -> Int {
        guard let range = text.range(of: " ×", options: .backwards), let n = Int(text[range.upperBound...]) else { return 1 }
        return n
    }
}

/// Names for recording files: "Kriya Recording 2026-10-22 14.05.09.mov".
enum RecordingFileName {
    static func make(for date: Date, existing: (String) -> Bool = { _ in false }) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "Kriya Recording \(formatter.string(from: date))"
        var name = "\(base).mov"
        var counter = 2
        while existing(name) {
            name = "\(base) \(counter).mov"
            counter += 1
        }
        return name
    }
}
