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

/// How the camera looks on screen while recording.
struct CameraStyle: Codable, Equatable {
    enum Shape: String, CaseIterable, Identifiable, Codable {
        case circle, rounded, square
        var id: String { rawValue }
        var title: String { self == .circle ? "Circle" : self == .rounded ? "Rounded square" : "Square" }
    }
    enum Size: String, CaseIterable, Identifiable, Codable {
        case small, medium, large
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        /// The width and height of the window in points.
        var side: Double { self == .small ? 140 : self == .medium ? 220 : 320 }
    }
    enum Corner: String, CaseIterable, Identifiable, Codable {
        case bottomRight, bottomLeft, topRight, topLeft
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bottomRight: return "Bottom right"
            case .bottomLeft: return "Bottom left"
            case .topRight: return "Top right"
            case .topLeft: return "Top left"
            }
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CameraStyle()
        shape = try c.decodeIfPresent(Shape.self, forKey: .shape) ?? d.shape
        size = try c.decodeIfPresent(Size.self, forKey: .size) ?? d.size
        corner = try c.decodeIfPresent(Corner.self, forKey: .corner) ?? d.corner
        border = try c.decodeIfPresent(Bool.self, forKey: .border) ?? d.border
        mirrored = try c.decodeIfPresent(Bool.self, forKey: .mirrored) ?? d.mirrored
    }

    var shape: Shape = .circle
    var size: Size = .medium
    var corner: Corner = .bottomRight
    var border = true
    /// Flips the picture left to right, like a mirror, as a camera preview usually is.
    var mirrored = true

    /// The corner radius for a window `side` points across.
    func cornerRadius(side: Double) -> Double {
        switch shape {
        case .circle: return side / 2
        case .rounded: return side * 0.18
        case .square: return 0
        }
    }

    /// Where the window's bottom-left corner goes inside `area` (AppKit coordinates), `margin` points from the chosen corner.
    func origin(in area: CGRect, margin: Double = 30) -> CGPoint {
        let s = size.side
        let x = (corner == .bottomLeft || corner == .topLeft) ? area.minX + margin : area.maxX - s - margin
        let y = (corner == .bottomLeft || corner == .bottomRight) ? area.minY + margin : area.maxY - s - margin
        return CGPoint(x: x, y: y)
    }
}

/// The largest a recording may be, by its shorter side: "1080p" is 1080 pixels high for a landscape screen.
enum ResolutionLimit: String, Codable, CaseIterable, Identifiable {
    case original, p2160, p1440, p1080, p720, p480
    var id: String { rawValue }

    var title: String { self == .original ? "Original" : "\(shorterSide ?? 0)p" }

    var shorterSide: Int? {
        switch self {
        case .original: return nil
        case .p2160: return 2160
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        }
    }

    /// The size shrunk to fit, keeping its shape; never enlarged.
    func fit(_ size: CGSize) -> CGSize {
        guard let limit = shorterSide.map(CGFloat.init), size.width > 0, size.height > 0 else { return size }
        let shorter = min(size.width, size.height)
        guard shorter > limit else { return size }
        let factor = limit / shorter
        return CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
    }
}

/// What no video encoder Kriya can use will go beyond: H.264 stops at 4096 pixels on a side, HEVC (used for HDR) at 8192.
enum EncoderLimit {
    static func largestSide(hevc: Bool) -> CGFloat { hevc ? 8192 : 4096 }

    /// The size shrunk to fit the encoder, keeping its shape. Never enlarged.
    static func fit(_ size: CGSize, hevc: Bool) -> CGSize {
        let limit = largestSide(hevc: hevc)
        let longest = max(size.width, size.height)
        guard longest > limit, longest > 0 else { return size }
        let factor = limit / longest
        return CGSize(width: (size.width * factor).rounded(.down), height: (size.height * factor).rounded(.down))
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
    var cameraStyle = CameraStyle()
    /// Darkens the displays that are not being recorded (when there is more than one), so attention stays on the one that is.
    var dimScreen = false
    /// A countdown before the recording starts.
    var showCountdown = false
    /// Silences notifications while recording.
    var doNotDisturb = false
    /// One audio channel instead of two.
    var monoAudio = false
    /// The largest the video may be, by its shorter side. Never larger than the display, and never past what the encoder can do.
    var maximumResolution: ResolutionLimit = .original
    /// `.oneX` records a Retina screen at its size in points: half the pixels in each direction.
    var outputScale: OutputScale = .native
    /// The Mac's sound and the microphone in tracks of their own (what Kriya has always written), or mixed into one.
    var audioTrackMode: AudioTrackMode = .separate
    /// Starts the next recording on the display and window chosen last time, when they are still there.
    var remembersLastSelection = false
    var lastSelection: RecordingSelection?
    var clickHighlight = ClickHighlightOptions()
    var keystrokeOptions = KeystrokeOptions()
    var gif = GIFOptions()

    init() {}

    /// Reads options saved by any earlier version: a key that is not there keeps its usual value, so an old file never fails to load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecordingOptions()
        source = try c.decodeIfPresent(RecordingSource.self, forKey: .source) ?? d.source
        systemAudio = try c.decodeIfPresent(Bool.self, forKey: .systemAudio) ?? d.systemAudio
        microphone = try c.decodeIfPresent(Bool.self, forKey: .microphone) ?? d.microphone
        hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr) ?? d.hdr
        framesPerSecond = try c.decodeIfPresent(Int.self, forKey: .framesPerSecond) ?? d.framesPerSecond
        showCursor = try c.decodeIfPresent(Bool.self, forKey: .showCursor) ?? d.showCursor
        showKeystrokes = try c.decodeIfPresent(Bool.self, forKey: .showKeystrokes) ?? d.showKeystrokes
        webcam = try c.decodeIfPresent(Bool.self, forKey: .webcam) ?? d.webcam
        cameraID = try c.decodeIfPresent(String.self, forKey: .cameraID) ?? d.cameraID
        cameraStyle = try c.decodeIfPresent(CameraStyle.self, forKey: .cameraStyle) ?? d.cameraStyle
        dimScreen = c.value(.dimScreen, d.dimScreen); showCountdown = c.value(.showCountdown, d.showCountdown)
        doNotDisturb = c.value(.doNotDisturb, d.doNotDisturb); monoAudio = c.value(.monoAudio, d.monoAudio)
        maximumResolution = c.value(.maximumResolution, d.maximumResolution); outputScale = c.value(.outputScale, d.outputScale)
        audioTrackMode = c.value(.audioTrackMode, d.audioTrackMode)
        remembersLastSelection = c.value(.remembersLastSelection, d.remembersLastSelection)
        lastSelection = try? c.decodeIfPresent(RecordingSelection.self, forKey: .lastSelection)
        clickHighlight = c.value(.clickHighlight, d.clickHighlight); keystrokeOptions = c.value(.keystrokeOptions, d.keystrokeOptions)
        gif = c.value(.gif, d.gif).sanitized()
    }

    static let allowedFrameRates = [15, 24, 30, 60]

    /// The size to record a screen of `pixels` at. In order: brought down to points on a Retina screen when 1x is asked for, no larger
    /// than the chosen resolution, and no larger than the encoder can write. Never larger than the display itself. Both sides stay even
    /// (video needs it) and within the encoder's limit.
    func recordedSize(pixels: CGSize, backingScale: CGFloat) -> CGSize {
        guard pixels.width > 0, pixels.height > 0 else { return CGSize(width: 2, height: 2) }
        var size = pixels
        if outputScale == .oneX, backingScale > 1 { size = CGSize(width: size.width / backingScale, height: size.height / backingScale) }
        size = maximumResolution.fit(size)
        let hevc = hdr
        size = EncoderLimit.fit(size, hevc: hevc)
        let limit = EncoderLimit.largestSide(hevc: hevc)
        func even(_ v: CGFloat) -> CGFloat { min(max((v / 2).rounded() * 2, 2), limit) }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    /// Channels in the Mac's sound: one when it is mixed down to mono, otherwise two. (The microphone is one channel either way.)
    var systemAudioChannels: Int { monoAudio ? 1 : 2 }

    /// How many seconds to count down before the recording starts: the self-timer's, or at least 3 when the countdown is asked for.
    static let countdownSeconds = 3
    func countdown(selfTimer seconds: Int) -> Int { showCountdown ? max(seconds, Self.countdownSeconds) : seconds }

    /// The same options with anything unusable put right, given what this Mac can do.
    func sanitized(hdrAvailable: Bool) -> RecordingOptions {
        var next = self
        if !Self.allowedFrameRates.contains(next.framesPerSecond) {
            next.framesPerSecond = Self.allowedFrameRates.min { abs($0 - framesPerSecond) < abs($1 - framesPerSecond) } ?? 30
        }
        if !hdrAvailable { next.hdr = false }
        next.gif = gif.sanitized()
        return next
    }

    /// Whether two audio tracks are written (the Mac's sound and the microphone), which matters for the file's layout.
    var audioTrackCount: Int { audioTrackMode == .mixed ? ((systemAudio || microphone) ? 1 : 0) : (systemAudio ? 1 : 0) + (microphone ? 1 : 0) }
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
