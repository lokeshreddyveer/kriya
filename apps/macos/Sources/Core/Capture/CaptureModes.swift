import Foundation

/// How a captured window is shown. The four are different pictures of the same window.
enum WindowLook: String, Codable, CaseIterable, Identifiable {
    /// The window alone: no shadow, and the rounded corners left transparent.
    case windowOnly
    /// The window with a soft shadow drawn by Kriya, the same on every macOS version.
    case kriyaShadow
    /// The window on a backdrop with space around it (the backdrop chosen under Style).
    case background
    /// The window as macOS itself would capture it: its own shadow, on a transparent background.
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .windowOnly: return "Window only"
        case .kriyaShadow: return "Window with a shadow"
        case .background: return "Window on a background"
        case .system: return "Window as macOS captures it"
        }
    }

    var detail: String {
        switch self {
        case .windowOnly: return "No shadow. The corners are transparent."
        case .kriyaShadow: return "A soft shadow drawn by Kriya, the same on every Mac."
        case .background: return "On the backdrop chosen under Style, with space around it."
        case .system: return "macOS's own shadow, on a transparent background."
        }
    }

    /// Whether macOS should leave its own shadow out of the capture.
    var dropsSystemShadow: Bool { self != .system }
}

/// The display a full-screen capture takes.
enum DisplayChoice: String, Codable, CaseIterable, Identifiable {
    /// Choose on screen: every display is shown and the one clicked is captured.
    case ask
    /// The display the pointer is on.
    case pointer
    /// The display with the menu bar.
    case main
    /// Every display, side by side in one picture.
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return "Ask me which"
        case .pointer: return "The display with the pointer"
        case .main: return "The main display"
        case .all: return "All displays in one picture"
        }
    }
}

/// How long to wait before a capture, for all of them: area, window, full screen, menu and recording.
struct SelfTimer: Codable, Equatable {
    static let presets = [3, 5, 10]
    static let longest = 60

    var seconds = 0
    var hideCursor = false

    var isOn: Bool { seconds > 0 }

    /// A timer length kept to what is allowed.
    static func clamped(_ seconds: Int) -> Int { min(max(seconds, 0), longest) }
}

/// The ways of starting a capture, as shown by the one chooser. The order is the order shown.
enum CaptureChoice: String, CaseIterable, Identifiable, Codable {
    case area, window, screen, scrolling, recordScreen, recordGIF, text, menu, previousArea

    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: return "Area"
        case .window: return "Window"
        case .screen: return "Full screen"
        case .scrolling: return "Scrolling"
        case .recordScreen: return "Record"
        case .recordGIF: return "GIF"
        case .text: return "Text"
        case .menu: return "Menu"
        case .previousArea: return "Previous"
        }
    }

    var symbol: String {
        switch self {
        case .area: return "viewfinder"
        case .window: return "macwindow"
        case .screen: return "display"
        case .scrolling: return "arrow.up.and.down.text.horizontal"
        case .recordScreen: return "record.circle"
        case .recordGIF: return "photo.on.rectangle"
        case .text: return "text.viewfinder"
        case .menu: return "filemenu.and.cursorarrow"
        case .previousArea: return "arrow.counterclockwise"
        }
    }

    /// The command that does it, as the rest of Kriya names it.
    var command: String {
        switch self {
        case .area: return "capture.region"
        case .window: return "capture.window"
        case .screen: return "capture.screen"
        case .scrolling: return "capture.scroll"
        case .recordScreen: return "capture.rec.screen"
        case .recordGIF: return "capture.gif"
        case .text: return "capture.text"
        case .menu: return "capture.menu"
        case .previousArea: return "capture.again"
        }
    }

    /// The key that picks it in the chooser: 1 to 9 in order.
    var key: Character { Character(String(Self.allCases.firstIndex(of: self).map { $0 + 1 } ?? 0)) }
}

/// An area the person named, to capture again by name: on one display, or in one app.
struct NamedArea: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    /// Points, with the origin at the top left of the main display (what `PreviousArea` keeps).
    var x: Double, y: Double, width: Double, height: Double
    /// The display layout it was taken on; it only applies to that layout.
    var layout: String
    /// The app it belongs to, if it should be offered only while that app is in front.
    var appBundleID: String?

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init?(name: String, rect: CGRect, layout: String, appBundleID: String? = nil) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 60, rect.width >= PreviousArea.minimumSide, rect.height >= PreviousArea.minimumSide,
              rect.width.isFinite, rect.height.isFinite, rect.origin.x.isFinite, rect.origin.y.isFinite else { return nil }
        self.name = clean
        x = Double(rect.origin.x.rounded()); y = Double(rect.origin.y.rounded())
        width = Double(rect.width.rounded()); height = Double(rect.height.rounded())
        self.layout = layout
        self.appBundleID = appBundleID
    }

    /// The area if the displays are as they were, else nil.
    func valid(for currentLayout: String) -> CGRect? { layout == currentLayout ? rect : nil }

    /// Whether to offer it now: it has no app, or that app is the one in front.
    func applies(frontApp: String?) -> Bool { appBundleID == nil || appBundleID == frontApp }

    var command: String { "capture.area.\(id)" }
}

/// Which way a scrolling capture goes.
enum CaptureScrollAxis: String, Codable, CaseIterable, Identifiable {
    case vertical, horizontal, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .vertical: return "Down"
        case .horizontal: return "Across"
        case .both: return "Down and across"
        }
    }
}

/// Whether Kriya scrolls for you or you scroll yourself while Kriya watches.
enum ScrollMode: String, Codable, CaseIterable, Identifiable {
    case automatic, manual
    var id: String { rawValue }
    var title: String { self == .automatic ? "Kriya scrolls" : "I scroll" }
}

/// How the capture modes behave, kept together. Every field has a safe default, and a setting saved by an older version (with fewer
/// fields) still loads.
struct CaptureModeSettings: Codable, Equatable {
    /// Use macOS's own selection tool (`screencapture -i`) instead of Kriya's selector.
    var useMacOSSelector = false
    var timer = SelfTimer()
    var windowLook: WindowLook = .system
    var display: DisplayChoice = .ask
    var hideDesktopIcons = false
    var cropNotch = false
    var lastChoice: CaptureChoice = .area
    /// The fixed shape in force for area capture (`SelectionGeometry.Shape.id`).
    var shapeID = "free"
    var namedAreas: [NamedArea] = []
    /// When the capture icon shows in the menu bar, besides its own setting: also while recording.
    var showRecordingTimer = true
    var scrollAxis: CaptureScrollAxis = .vertical
    var scrollMode: ScrollMode = .automatic

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        useMacOSSelector = try c.decodeIfPresent(Bool.self, forKey: .useMacOSSelector) ?? false
        timer = try c.decodeIfPresent(SelfTimer.self, forKey: .timer) ?? SelfTimer()
        windowLook = try c.decodeIfPresent(WindowLook.self, forKey: .windowLook) ?? .system
        display = try c.decodeIfPresent(DisplayChoice.self, forKey: .display) ?? .ask
        hideDesktopIcons = try c.decodeIfPresent(Bool.self, forKey: .hideDesktopIcons) ?? false
        cropNotch = try c.decodeIfPresent(Bool.self, forKey: .cropNotch) ?? false
        lastChoice = try c.decodeIfPresent(CaptureChoice.self, forKey: .lastChoice) ?? .area
        shapeID = try c.decodeIfPresent(String.self, forKey: .shapeID) ?? "free"
        namedAreas = try c.decodeIfPresent([NamedArea].self, forKey: .namedAreas) ?? []
        showRecordingTimer = try c.decodeIfPresent(Bool.self, forKey: .showRecordingTimer) ?? true
        scrollAxis = try c.decodeIfPresent(CaptureScrollAxis.self, forKey: .scrollAxis) ?? .vertical
        scrollMode = try c.decodeIfPresent(ScrollMode.self, forKey: .scrollMode) ?? .automatic
    }

    var shape: SelectionGeometry.Shape { SelectionGeometry.shapes.first { $0.id == shapeID } ?? SelectionGeometry.shapes[0] }

    /// Adds or replaces (by name) a saved area, keeping the list to a sensible size.
    mutating func save(_ area: NamedArea) {
        namedAreas.removeAll { $0.name.caseInsensitiveCompare(area.name) == .orderedSame }
        namedAreas.append(area)
        if namedAreas.count > 30 { namedAreas.removeFirst(namedAreas.count - 30) }
    }

    /// The saved areas to offer now: on the displays as they are, and for the app in front (or for any app).
    func areas(layout: String, frontApp: String?) -> [NamedArea] {
        namedAreas.filter { $0.valid(for: layout) != nil && $0.applies(frontApp: frontApp) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// A running time written as it is beside a recording: 01:23, or 1:02:03 once it passes an hour.
enum RecordingTime {
    static func text(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.down)), 0)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
