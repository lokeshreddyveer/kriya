import Foundation

/// A shadow under one mark. Offsets and blur are in points as the person sees them (positive vertical offset is down) and scale with
/// the size of the picture when it is drawn.
struct AnnotationShadow: Codable, Equatable {
    static let blurRange: ClosedRange<Double> = 0...40
    static let opacityRange: ClosedRange<Double> = 0...1
    static let offsetRange: ClosedRange<Double> = -40...40

    var enabled = false
    var blur = 6.0
    var opacity = 0.35
    var offset = CGSize(width: 0, height: 2)

    init(enabled: Bool = false, blur: Double = 6, opacity: Double = 0.35, offset: CGSize = CGSize(width: 0, height: 2)) {
        self.enabled = enabled; self.blur = blur; self.opacity = opacity; self.offset = offset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AnnotationShadow()
        enabled = c.value(.enabled, d.enabled); blur = c.value(.blur, d.blur); opacity = c.value(.opacity, d.opacity)
        offset = c.value(.offset, d.offset)
    }

    /// The values held to what can be drawn; damaged numbers become the usual ones.
    func sanitized() -> AnnotationShadow {
        func clamp(_ v: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double { v.isNaN ? fallback : min(max(v, range.lowerBound), range.upperBound) }
        var next = self
        next.blur = clamp(blur, Self.blurRange, 6)
        next.opacity = clamp(opacity, Self.opacityRange, 0.35)
        next.offset = CGSize(width: clamp(Double(offset.width), Self.offsetRange, 0), height: clamp(Double(offset.height), Self.offsetRange, 2))
        return next
    }

    /// Three softnesses to choose from, for the editor's menu.
    enum Softness: String, CaseIterable, Identifiable {
        case hard, medium, soft
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var blur: Double { self == .hard ? 2 : self == .medium ? 6 : 14 }
    }

    /// Which softness the blur is nearest to.
    var softness: Softness { Softness.allCases.min { abs($0.blur - blur) < abs($1.blur - blur) } ?? .medium }
}

/// The two ways the app can be shown to the system: with a Dock icon and menu bar (regular), or without (accessory).
enum AppActivation: Equatable {
    case regular, accessory, prohibited
}

/// How the editor's window and the app behave around it.
struct EditorWindowOptions: Codable, Equatable {
    /// The editor stays above other windows.
    var alwaysOnTop = false
    /// Kriya shows a Dock icon while the editor is open (and takes it away when it closes).
    var showDockIcon = false

    init(alwaysOnTop: Bool = false, showDockIcon: Bool = false) { self.alwaysOnTop = alwaysOnTop; self.showDockIcon = showDockIcon }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alwaysOnTop = c.value(.alwaysOnTop, false); showDockIcon = c.value(.showDockIcon, false)
    }
}

enum EditorWindowRules {
    /// The activation to change to for the editor, or nil to leave it alone. Only when a Dock icon is asked for and there is not one
    /// already, so the policy is changed only on request and only when it needs to be.
    static func activationToSet(current: AppActivation, showDockIcon: Bool) -> AppActivation? {
        showDockIcon && current != .regular ? .regular : nil
    }
}

/// What the editor does and remembers: preferences of the person, kept for every editing session. They are not part of any project
/// file, so opening a project on another Mac never changes how the editor behaves there.
struct EditorPreferences: Codable, Equatable {
    var window = EditorWindowOptions()
    /// Freehand strokes are smoothed when the stroke ends.
    var smoothPen = false
    /// Holding ⌥ while finishing an arrow points it the other way.
    var reverseArrowWithOption = false
    /// The name of the colour is shown beside the colours, not only spoken.
    var showColourNames = false
    /// The editor opens with the backdrop panel as it was left.
    var remembersBackdropPanel = false
    var lastBackdrop: CaptureBeautify?
    var backdropPanelWasShown = false
    /// The shadow new marks start with.
    var annotationShadow = AnnotationShadow()
    /// The canvas grows when a mark is drawn past the edge of the picture, so it is not cut off.
    var autoExpandCanvas = false
    /// Room added around the marks when the canvas grows, in pixels.
    var expandPadding = 16.0
    /// The editor shortcuts the person changed. Only the differences from the defaults.
    var shortcutOverrides: [EditorCommand: EditorKey] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EditorPreferences()
        window = c.value(.window, d.window); smoothPen = c.value(.smoothPen, d.smoothPen)
        reverseArrowWithOption = c.value(.reverseArrowWithOption, d.reverseArrowWithOption)
        showColourNames = c.value(.showColourNames, d.showColourNames); remembersBackdropPanel = c.value(.remembersBackdropPanel, d.remembersBackdropPanel)
        lastBackdrop = try? c.decodeIfPresent(CaptureBeautify.self, forKey: .lastBackdrop)
        backdropPanelWasShown = c.value(.backdropPanelWasShown, d.backdropPanelWasShown)
        annotationShadow = c.value(.annotationShadow, d.annotationShadow).sanitized()
        autoExpandCanvas = c.value(.autoExpandCanvas, d.autoExpandCanvas)
        let pad = c.value(.expandPadding, d.expandPadding)
        expandPadding = pad.isNaN ? d.expandPadding : min(max(pad, 0), 200)
        shortcutOverrides = c.value(.shortcutOverrides, d.shortcutOverrides)
    }

    /// The backdrop and panel state to open with: the last ones when remembering is on and there is something remembered.
    func startingBackdrop() -> (style: CaptureBeautify, shown: Bool)? {
        guard remembersBackdropPanel, let lastBackdrop else { return nil }
        return (lastBackdrop, backdropPanelWasShown)
    }

    /// Remembers how the backdrop panel was left (only while remembering is on).
    mutating func rememberBackdrop(_ style: CaptureBeautify, shown: Bool) {
        guard remembersBackdropPanel else { return }
        lastBackdrop = style
        backdropPanelWasShown = shown
    }
}

/// Reads and writes the editor preferences. Takes the preferences to use, so a check never touches the real ones.
struct EditorPreferencesStore {
    static let key = "capture.editorPrefs.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var preferences: EditorPreferences {
        get { defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(EditorPreferences.self, from: $0) } ?? EditorPreferences() }
        nonmutating set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.key) } }
    }
}

/// Smoothing a freehand stroke.
enum PenSmoothing {
    /// The stroke with its jitter taken out: each point moves toward the average of its neighbours, a few times. The first and last
    /// points stay where they were, so the stroke starts and ends where the hand did; the number of points is the same.
    static func smooth(_ points: [CGPoint], passes: Int = 3) -> [CGPoint] {
        guard points.count > 2, passes > 0 else { return points }
        var current = points
        for _ in 0..<passes {
            var next = current
            for i in 1..<(current.count - 1) {
                next[i] = CGPoint(x: (current[i - 1].x + 2 * current[i].x + current[i + 1].x) / 4, y: (current[i - 1].y + 2 * current[i].y + current[i + 1].y) / 4)
            }
            current = next
        }
        return current
    }
}

enum ArrowRules {
    /// The two ends of an arrow, swapped when ⌥ is held and the preference asks for it: the head goes to the other end.
    static func ends(start: CGPoint, end: CGPoint, optionHeld: Bool, preferences: EditorPreferences) -> (start: CGPoint, end: CGPoint) {
        preferences.reverseArrowWithOption && optionHeld ? (end, start) : (start, end)
    }
}
