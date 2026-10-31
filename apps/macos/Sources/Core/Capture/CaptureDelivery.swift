import Foundation

extension KeyedDecodingContainer {
    /// The saved value, or `fallback` when the key is missing or holds something this version cannot read. Settings saved by any earlier
    /// version therefore always load, and a field added later starts at its usual value.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T { (try? decodeIfPresent(T.self, forKey: key)) ?? fallback }
}

/// Modifier keys held when a capture is asked for or finished. Plain values, so the logic that reads them can be checked without a keyboard.
struct CaptureModifiers: OptionSet, Codable, Equatable {
    let rawValue: Int
    static let shift = CaptureModifiers(rawValue: 1 << 0)
    static let option = CaptureModifiers(rawValue: 1 << 1)
    static let command = CaptureModifiers(rawValue: 1 << 2)
    static let control = CaptureModifiers(rawValue: 1 << 3)
}

/// What a capture produces, which decides what can happen to it afterwards.
enum CaptureKind: String, Codable, CaseIterable, Identifiable {
    case screenshot, recording, gif
    /// The text read from a picture.
    case ocr
    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshot: return "Screenshot"
        case .recording: return "Recording"
        case .gif: return "GIF"
        case .ocr: return "Text from a picture"
        }
    }

    static func of(_ action: CaptureAction) -> CaptureKind {
        switch action {
        case .record, .recordScreen, .recordWindow, .recordApp, .pauseRecording, .stopRecording, .trimRecording: return .recording
        case .recordGIF: return .gif
        case .text, .textJoined, .textMarkdown, .textTable: return .ocr
        default: return .screenshot
        }
    }
}

/// What happens to a capture once it is taken: the "After Capture" choices, for one kind of capture. They run in a fixed order (see
/// `DeliveryPipeline`) however they are chosen.
struct DeliverySteps: Codable, Equatable {
    var showQuickAccessCard = true
    var copy = true
    var save = true
    var upload = false
    /// A link to it is put on the clipboard: to the uploaded copy, or to the saved file when it was not uploaded.
    var copyLink = false
    /// A screenshot opens in the editor.
    var annotate = false
    /// A screenshot is pinned on the screen.
    var pin = false
    /// A recording or GIF opens in the trimmer.
    var trim = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DeliverySteps()
        showQuickAccessCard = c.value(.showQuickAccessCard, d.showQuickAccessCard); copy = c.value(.copy, d.copy); save = c.value(.save, d.save)
        upload = c.value(.upload, d.upload); copyLink = c.value(.copyLink, d.copyLink)
        annotate = c.value(.annotate, d.annotate); pin = c.value(.pin, d.pin); trim = c.value(.trim, d.trim)
    }

    /// What the settings did before this choice existed: a screenshot copies, saves and opens the editor as the options said; a
    /// recording or GIF is saved, never copied; text read from a picture is copied and nothing else.
    static func legacy(_ settings: CaptureSettings, kind: CaptureKind) -> DeliverySteps {
        var s = DeliverySteps()
        switch kind {
        case .screenshot: s.copy = settings.copyImage; s.save = settings.saveToFolder; s.annotate = settings.openEditor
        case .recording, .gif: s.copy = false; s.save = true
        case .ocr: s.copy = true; s.save = false; s.showQuickAccessCard = false
        }
        return s
    }

    /// The same steps with the ones that make no sense for this kind removed, and never a result that throws the capture away.
    /// - A screenshot has no trimming. A recording or GIF has no editor and no pin, and is always kept in the capture folder (the
    ///   recorder writes it there). Text read from a picture has none of editor, pin, trimming or a card.
    func normalized(for kind: CaptureKind, keepsSomething: Bool = true) -> DeliverySteps {
        var s = self
        switch kind {
        case .screenshot: s.trim = false
        case .recording, .gif: s.annotate = false; s.pin = false; s.save = true
        case .ocr: s.annotate = false; s.pin = false; s.trim = false; s.showQuickAccessCard = false
        }
        if keepsSomething, !s.copy && !s.save && !s.upload {
            if kind == .recording || kind == .gif { s.save = true } else { s.copy = true }
        }
        return s
    }
}

/// A named backdrop, so one choice can be reused for every capture.
struct BackgroundPreset: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var style: CaptureBeautify

    static let starters: [BackgroundPreset] = CaptureBeautify.Background.allCases.filter { $0 != .none }.map { background in
        var style = CaptureBeautify()
        style.background = background
        return BackgroundPreset(id: "starter.\(background.rawValue)", name: background.title, style: style)
    }
}

/// Which backdrop goes behind captures, when it is put there, and how to leave it out for one capture.
struct BackgroundPolicy: Codable, Equatable {
    /// Put on the picture before the editor opens, so it can be adjusted there (the original is kept), or only when the picture is
    /// delivered.
    enum Timing: String, Codable, CaseIterable, Identifiable {
        case beforeEditor, atExport
        var id: String { rawValue }
        var title: String { self == .beforeEditor ? "Before the editor opens" : "When the picture is saved" }
    }

    /// The preset id that means "no backdrop", chosen on purpose (as opposed to nothing chosen, which keeps the older global backdrop).
    static let noneID = "none"
    /// A profile's own backdrop is kept as a preset whose id starts with this, so a list of presets can leave it out.
    static let profilePrefix = "profile."

    var presets: [BackgroundPreset] = BackgroundPreset.starters
    /// For screenshots. Nil keeps the older global backdrop if one was set.
    var screenshotPreset: String?
    /// For recordings and GIFs. Kept so the choice is not lost; a backdrop behind a video needs every frame composed.
    var recordingPreset: String?
    var skipWithShift = true
    var timing: Timing = .atExport
    /// The backdrop is put only on what leaves Kriya: the saved file, the copy and the upload. The card, the pin and the picture in the
    /// editor stay plain, and so does the untouched original kept beside an edit.
    var exportOnly = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BackgroundPolicy()
        presets = c.value(.presets, d.presets)
        screenshotPreset = c.value(.screenshotPreset, d.screenshotPreset)
        recordingPreset = c.value(.recordingPreset, d.recordingPreset)
        skipWithShift = c.value(.skipWithShift, d.skipWithShift)
        timing = c.value(.timing, d.timing)
        exportOnly = c.value(.exportOnly, d.exportOnly)
    }

    /// The backdrop put on the thumbnail of a recording (the picture on its card). Never on the recording itself.
    func recordingThumbnail(modifiers: CaptureModifiers) -> CaptureBeautify? {
        resolve(kind: .recording, legacy: CaptureBeautify(), modifiers: modifiers)
    }

    func preset(id: String?) -> BackgroundPreset? { id.flatMap { id in presets.first { $0.id == id } } }

    /// The backdrop for one capture, or nil for none. `legacy` is the single global backdrop older versions had; it applies to
    /// screenshots when no preset has been chosen. Holding Shift (when allowed) leaves the backdrop out.
    func resolve(kind: CaptureKind, legacy: CaptureBeautify, modifiers: CaptureModifiers) -> CaptureBeautify? {
        if skipWithShift && modifiers.contains(.shift) { return nil }
        // Text read from a picture has no backdrop.
        guard kind != .ocr else { return nil }
        let chosen = kind == .screenshot ? screenshotPreset : recordingPreset
        if chosen == Self.noneID { return nil }
        if let style = preset(id: chosen)?.style { return style.isOn ? style : nil }
        return kind == .screenshot && legacy.isOn ? legacy : nil
    }

    /// Ids that point at nothing become "not chosen"; ids are unique and every preset keeps a name.
    func sanitized() -> BackgroundPolicy {
        var next = self
        var seen = Set<String>()
        next.presets = presets.filter { !$0.id.isEmpty && $0.id != Self.noneID && seen.insert($0.id).inserted }.map { preset in
            var p = preset
            if p.name.trimmingCharacters(in: .whitespaces).isEmpty { p.name = "Backdrop" }
            return p
        }
        func valid(_ id: String?) -> String? { id == Self.noneID || next.preset(id: id) != nil ? id : nil }
        next.screenshotPreset = valid(screenshotPreset)
        next.recordingPreset = valid(recordingPreset)
        return next
    }
}

/// How the picture itself is written: colour profile, size, outline, clipboard contents, file name and how long history is kept.
struct OutputPolicy: Codable, Equatable {
    var convertToSRGB = false
    var scale: OutputScale = .native
    /// An outline around every screenshot that has no backdrop of its own with one.
    var border = CaptureBorder()
    /// "@2x" at the end of the file name of a Retina screenshot that is kept at its full size.
    var includeRetinaSuffix = false
    /// What a copied screenshot puts on the clipboard.
    var clipboard: ClipboardOutput = .image
    var askForName = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OutputPolicy()
        convertToSRGB = c.value(.convertToSRGB, d.convertToSRGB); scale = c.value(.scale, d.scale)
        border = c.value(.border, d.border); includeRetinaSuffix = c.value(.includeRetinaSuffix, d.includeRetinaSuffix); clipboard = c.value(.clipboard, d.clipboard)
        askForName = c.value(.askForName, d.askForName)
    }

    /// The pixel size to write for a picture taken on a screen with this scale. At `.oneX` on a Retina screen it is the size in points:
    /// the longer side is the pixels divided by the scale, and the other side follows the exact shape of the picture, so rounding can
    /// never bend it. Anything else is written at the size it was taken.
    func outputSize(pixels: CGSize, backingScale: CGFloat) -> CGSize {
        guard scale == .oneX, backingScale > 1, pixels.width > 0, pixels.height > 0 else { return pixels }
        if pixels.width >= pixels.height {
            let width = max((pixels.width / backingScale).rounded(), 1)
            return CGSize(width: width, height: max((width * pixels.height / pixels.width).rounded(), 1))
        }
        let height = max((pixels.height / backingScale).rounded(), 1)
        return CGSize(width: max((height * pixels.width / pixels.height).rounded(), 1), height: height)
    }

    /// The scale of the picture as it is written: 1 once it was brought down to points, otherwise the screen's own. `untouched` is the
    /// original kept beside an edit, which is never resized.
    func writtenScale(backingScale: CGFloat, untouched: Bool = false) -> CGFloat {
        scale == .oneX && !untouched ? 1 : max(backingScale, 1)
    }

    /// The "@2x" to put on the end of a file name, before its extension, or "" for none. Only when the setting is on, the picture is
    /// written at native Retina size (its scale is above 1), and the name has no "@2x" (or other "@3x") in it already.
    func retinaSuffix(for stem: String, backingScale: CGFloat, untouched: Bool = false) -> String {
        let imageScale = writtenScale(backingScale: backingScale, untouched: untouched)
        guard includeRetinaSuffix, imageScale > 1, stem.range(of: #"@[0-9]+x"#, options: .regularExpression) == nil else { return "" }
        return "@\(Int(imageScale.rounded()))x"
    }

    /// Nothing is asked of the picture: no profile change, no resizing, no border.
    var isIdentity: Bool { !convertToSRGB && scale == .native && !border.enabled }
}

/// Whether a Retina screenshot keeps all its pixels or is brought down to its size in points.
enum OutputScale: String, Codable, CaseIterable, Identifiable {
    /// The pixels the screen has: a screenshot of 1440 × 900 points on a Retina screen is 2880 × 1800.
    case native
    /// One pixel to a point: 1440 × 900. Half the size in each direction on a Retina screen; nothing changes on a 1x screen.
    case oneX

    var id: String { rawValue }
    var title: String { self == .native ? "Native (Retina)" : "Scaled to 1x" }
}

/// How text read from a picture is handled.
struct TextPolicy: Codable, Equatable {
    var detectLinks = true
    var keepLineBreaks = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        detectLinks = c.value(.detectLinks, true); keepLineBreaks = c.value(.keepLineBreaks, false)
    }
}

/// What happens around an upload.
struct UploadPolicy: Codable, Equatable {
    var copyLinkAfterUpload = true
    var closeCardAfterUpload = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        copyLinkAfterUpload = c.value(.copyLinkAfterUpload, true); closeCardAfterUpload = c.value(.closeCardAfterUpload, true)
    }
}

/// How pinned pictures look: appearance only. Where a pin sits on the screen and how big it is belong to the pin itself (the person drags
/// and resizes each one) and are never part of this, so changing the style never moves or resizes a pin.
struct PinPolicy: Codable, Equatable {
    /// How see-through a pin can be set: never fully invisible.
    static let opacityRange: ClosedRange<Double> = 0.2...1

    var roundedCorners = true
    var shadow = true
    var border = true
    /// How see-through a pin is to start with, 1 being solid.
    var opacity = 1.0
    /// A colour behind the picture, seen through any transparent parts of it. Nil for none.
    var background: CodableColor?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roundedCorners = c.value(.roundedCorners, true); shadow = c.value(.shadow, true); border = c.value(.border, true)
        opacity = c.value(.opacity, 1.0)
        background = try? c.decodeIfPresent(CodableColor.self, forKey: .background)
    }

    var cornerRadius: CGFloat { roundedCorners ? 8 : 0 }
    var borderWidth: CGFloat { border ? 1 : 0 }

    /// The opacity held to what can be set (a damaged value is solid, so a pin is never lost to a bad number).
    var alpha: CGFloat {
        guard !opacity.isNaN else { return 1 }
        return CGFloat(min(max(opacity, Self.opacityRange.lowerBound), Self.opacityRange.upperBound))
    }

    func sanitized() -> PinPolicy {
        var next = self
        next.opacity = Double(alpha)
        return next
    }
}

/// Everything that decides what happens to a capture after it is taken, for every kind: screenshots, recordings, GIFs, text, uploads,
/// pins. One value, saved under one key, so a backup, a reset and diagnostics treat it as a whole. A kind with no steps of its own
/// follows the older copy/save/editor options, so nothing changes until something here is chosen.
struct CaptureDeliveryPolicy: Codable, Equatable {
    var screenshot: DeliverySteps?
    var recording: DeliverySteps?
    var gif: DeliverySteps?
    /// What happens to text read from a picture.
    var ocr: DeliverySteps?
    var background = BackgroundPolicy()
    var output = OutputPolicy()
    /// How long the history lists reach, and when old files are offered for cleanup.
    var retention = CaptureRetention()
    /// Which sound plays when a capture is taken (whether one plays at all is the "Play the camera sound" switch).
    var sound = SoundPolicy()
    var text = TextPolicy()
    var upload = UploadPolicy()
    var pin = PinPolicy()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptureDeliveryPolicy()
        screenshot = c.value(.screenshot, d.screenshot); recording = c.value(.recording, d.recording); gif = c.value(.gif, d.gif); ocr = c.value(.ocr, d.ocr)
        background = c.value(.background, d.background).sanitized(); output = c.value(.output, d.output)
        retention = c.value(.retention, d.retention).sanitized(); sound = c.value(.sound, d.sound)
        text = c.value(.text, d.text); upload = c.value(.upload, d.upload); pin = c.value(.pin, d.pin).sanitized()
    }

    func steps(for kind: CaptureKind, settings: CaptureSettings) -> DeliverySteps {
        let own: DeliverySteps?
        switch kind {
        case .screenshot: own = screenshot
        case .recording: own = recording
        case .gif: own = gif
        case .ocr: own = ocr
        }
        // Steps chosen here never throw a capture away. The older options did allow copy and save both off, and still do.
        if let own { return own.normalized(for: kind) }
        return DeliverySteps.legacy(settings, kind: kind).normalized(for: kind, keepsSomething: false)
    }

    func sanitized() -> CaptureDeliveryPolicy {
        var next = self
        next.background = background.sanitized()
        next.retention = retention.sanitized()
        next.pin = pin.sanitized()
        return next
    }
}

/// Reads and writes the delivery policy. Takes the preferences to use, so a check never touches the real ones.
struct CaptureDeliveryStore {
    static let key = "capture.delivery.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var policy: CaptureDeliveryPolicy {
        get { (defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(CaptureDeliveryPolicy.self, from: $0) } ?? CaptureDeliveryPolicy()).sanitized() }
        nonmutating set { if let data = try? JSONEncoder().encode(newValue.sanitized()) { defaults.set(data, forKey: Self.key) } }
    }
}

/// One capture, asked for once and carried to the end: what to take, what to do with it, which keys were held, and a snapshot of the
/// delivery policy as it was when the capture began, so a change made while it runs cannot change what happens to it.
struct CaptureRequest: Equatable {
    var mode: CaptureMode
    var action: CaptureAction
    var kind: CaptureKind
    var steps: DeliverySteps
    var delivery: CaptureDeliveryPolicy
    /// Held when the capture was asked for.
    var modifiers: CaptureModifiers
    /// The scale of the screen the person was on when asking, used only to keep Retina screenshots at 1x.
    var backingScale: CGFloat
    /// What a command that starts from a chosen area does with the picture instead of what the settings say.
    var forced: ForcedDelivery?

    static func make(mode: CaptureMode, action: CaptureAction, settings: CaptureSettings, policy: CaptureDeliveryPolicy,
                     modifiers: CaptureModifiers = [], backingScale: CGFloat = 2, forced: ForcedDelivery? = nil) -> CaptureRequest {
        let kind = CaptureKind.of(action)
        return CaptureRequest(mode: mode, action: action, kind: kind, steps: policy.steps(for: kind, settings: settings), delivery: policy,
                              modifiers: modifiers, backingScale: max(backingScale, 1), forced: forced)
    }

    /// The backdrop for this capture. The keys are read when the picture is delivered, because Shift may also be part of the shortcut
    /// that started the capture, and only a Shift still held at the end means "leave the backdrop out".
    func background(legacy: CaptureBeautify, modifiersNow: CaptureModifiers) -> CaptureBeautify? {
        delivery.background.resolve(kind: kind, legacy: legacy, modifiers: modifiersNow)
    }
}
