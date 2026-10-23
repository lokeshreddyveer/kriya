import SwiftUI

/// One tile in the menu-bar window's quick actions.
struct PopoverTile: Identifiable, Hashable {
    let id: String
    let symbol: String
    let title: String
    let command: String
    /// The menu-bar window closes after this one, because the thing it opens needs the screen to itself.
    var closes = false
}

/// What can be shown in the menu-bar window, and the choices offered for how it looks.
enum PopoverCatalog {
    static let tiles: [PopoverTile] = [
        PopoverTile(id: "awake", symbol: "cup.and.saucer", title: "Keep Awake", command: "power.keep_awake"),
        PopoverTile(id: "awake30", symbol: "timer", title: "Awake 30 min", command: "power.keep_awake.30"),
        PopoverTile(id: "awake60", symbol: "clock", title: "Awake 1 hour", command: "power.keep_awake.60"),
        PopoverTile(id: "stack", symbol: "square.stack.3d.down.right", title: "Paste Stack", command: "clipboard.stack"),
        PopoverTile(id: "clip", symbol: "doc.on.clipboard", title: "Clipboard", command: "clipboard.quick", closes: true),
        PopoverTile(id: "shelf", symbol: "tray", title: "Shelf", command: "shelf.toggle", closes: true),
        PopoverTile(id: "find", symbol: "scope", title: "Find Pointer", command: "pointer.locate", closes: true),
        PopoverTile(id: "mag", symbol: "plus.magnifyingglass", title: "Magnifier", command: "pointer.magnifier", closes: true),
        PopoverTile(id: "present", symbol: "rectangle.on.rectangle.angled", title: "Presenting", command: "pointer.presentation"),
        PopoverTile(id: "switch", symbol: "macwindow.on.rectangle", title: "Switcher", command: "window.switcher", closes: true),
        PopoverTile(id: "radial", symbol: "circle.hexagongrid", title: "Radial", command: "window.radial", closes: true),
        PopoverTile(id: "grid", symbol: "square.grid.3x3", title: "Window Grid", command: "window.grid", closes: true),
        PopoverTile(id: "todo", symbol: "sidebar.left", title: "Todo Column", command: "window.todo_toggle"),
        PopoverTile(id: "stash", symbol: "arrow.right.to.line", title: "Stash Window", command: "window.stash"),
        PopoverTile(id: "pointercenter", symbol: "dot.circle.and.hand.point.up.left.fill", title: "Pointer to Window", command: "window.pointer_to_window"),
        PopoverTile(id: "nextdisplay", symbol: "rectangle.2.swap", title: "Next Display", command: "window.next_display"),
        PopoverTile(id: "profile", symbol: "display", title: "Display Profile", command: "display.next_profile"),
        PopoverTile(id: "dim", symbol: "moon", title: "Dim", command: "display.dim_more"),
        PopoverTile(id: "bright", symbol: "sun.max", title: "Brighten", command: "display.dim_less"),
        PopoverTile(id: "focus", symbol: "scope", title: "Focus Mode", command: "focus.toggle"),
        PopoverTile(id: "hideothers", symbol: "eye.slash", title: "Hide Others", command: "app.hide_others"),
        PopoverTile(id: "restoremin", symbol: "arrow.up.forward.square", title: "Restore Window", command: "window.restore_minimized"),
        PopoverTile(id: "speak", symbol: "speaker.wave.2", title: "Read Aloud", command: "text.speak"),
        PopoverTile(id: "notes", symbol: "note.text", title: "Notes", command: "notes.open", closes: true),
        PopoverTile(id: "mute", symbol: "speaker.slash", title: "Mute", command: "audio.mute"),
        PopoverTile(id: "micmute", symbol: "mic.slash", title: "Mute Mic", command: "audio.mic_mute"),
        PopoverTile(id: "nextout", symbol: "hifispeaker", title: "Next Output", command: "audio.next_output"),
        PopoverTile(id: "colour", symbol: "eyedropper", title: "Pick Colour", command: "color.pick", closes: true),
        PopoverTile(id: "scrollcap", symbol: "arrow.down.to.line", title: "Whole Page", command: "capture.scroll", closes: true),
        PopoverTile(id: "record", symbol: "record.circle", title: "Record Screen", command: "capture.record", closes: true),
        PopoverTile(id: "focussession", symbol: "scope", title: "Focus Session", command: "focus.session"),
        PopoverTile(id: "dictate", symbol: "mic", title: "Dictate", command: "dictation.toggle", closes: true),
        PopoverTile(id: "dialogfolders", symbol: "folder.badge.gearshape", title: "Dialog Folders", command: "dialog.folders"),
        PopoverTile(id: "pinshot", symbol: "pin", title: "Pin Picture", command: "capture.pin", closes: true),
        PopoverTile(id: "ruler", symbol: "ruler", title: "Pixel Ruler", command: "capture.ruler", closes: true),
        PopoverTile(id: "qr", symbol: "qrcode.viewfinder", title: "Read QR", command: "capture.qr", closes: true),
        PopoverTile(id: "pointermenu", symbol: "contextualmenu.and.cursorarrow", title: "Pointer Menu", command: "menu.pointer", closes: true),
    ]

    static func tile(_ id: String) -> PopoverTile? { tiles.first { $0.id == id } }

    static let defaultTiles = ["awake", "stack", "clip", "shelf", "find", "mag", "present", "switch", "radial", "dim", "bright", "speak"]
    static let defaultLayouts = [
        "window.left_half", "window.right_half", "window.top_half", "window.bottom_half", "window.maximize", "window.center",
        "window.top_left", "window.top_right", "window.bottom_left", "window.bottom_right", "window.first_third", "window.last_third",
    ]

    static let sections: [(id: String, title: String)] = [
        ("quick", "Quick actions"), ("window", "Window"), ("features", "Features"), ("more", "More"),
    ]

    static let extras: [(id: String, title: String, symbol: String)] = [
        ("remap", "Key remapping", "keyboard"), ("pointer", "Pointer effects", "cursorarrow.rays"), ("corners", "Hot corners", "square.dashed"),
        ("shelf", "File shelf", "tray"), ("links", "Link routing", "arrow.triangle.branch"), ("dragscroll", "Drag to scroll", "hand.draw"),
    ]

    /// Muted colours the window can be tinted with. The first is Kriya's own accent.
    static let tints: [(id: String, name: String, color: Color)] = [
        ("slate", "Slate", Theme.accent),
        ("sage", "Sage", Color(.sRGB, red: 0.56, green: 0.66, blue: 0.55)),
        ("amber", "Amber", Color(.sRGB, red: 0.77, green: 0.65, blue: 0.42)),
        ("rose", "Rose", Color(.sRGB, red: 0.73, green: 0.54, blue: 0.56)),
        ("violet", "Violet", Color(.sRGB, red: 0.62, green: 0.56, blue: 0.72)),
        ("graphite", "Graphite", Color(.sRGB, red: 0.62, green: 0.64, blue: 0.67)),
    ]

    static func tint(_ id: String) -> Color { tints.first { $0.id == id }?.color ?? Theme.accent }

    /// Short names, so two switches fit side by side.
    static func shortTitle(_ feature: FeatureId) -> String {
        switch feature {
        case .mouse: return "Mouse"
        case .windowManagement: return "Windows"
        case .trafficLights: return "Buttons"
        case .contextMenu: return "Right-Click"
        case .selectionBar: return "Selection Bar"
        case .clipboard: return "Clipboard"
        case .keyboard: return "Keyboard"
        case .automation: return "Automation"
        }
    }
}

/// How the menu-bar window looks and what it holds. Saved in the person's defaults, and shared by the window and the
/// pane where it is changed.
final class PopoverPrefs: ObservableObject {
    private let defaults = UserDefaults.standard
    private func key(_ name: String) -> String { "popover.\(name)" }

    @Published var tiles: [String] { didSet { defaults.set(tiles, forKey: key("tiles")) } }
    @Published var layouts: [String] { didSet { defaults.set(layouts, forKey: key("layouts")) } }
    @Published var sectionOrder: [String] { didSet { defaults.set(sectionOrder, forKey: key("sectionOrder")) } }
    @Published var hiddenSections: Set<String> { didSet { defaults.set(Array(hiddenSections), forKey: key("hiddenSections")) } }
    @Published var extras: [String] { didSet { defaults.set(extras, forKey: key("extras")) } }
    @Published var columns: Int { didSet { defaults.set(columns, forKey: key("columns")) } }
    @Published var compact: Bool { didSet { defaults.set(compact, forKey: key("compact")) } }
    @Published var showLabels: Bool { didSet { defaults.set(showLabels, forKey: key("showLabels")) } }
    @Published var showSearch: Bool { didSet { defaults.set(showSearch, forKey: key("showSearch")) } }
    @Published var featuresAsGrid: Bool { didSet { defaults.set(featuresAsGrid, forKey: key("featuresAsGrid")) } }
    @Published var theme: String { didSet { defaults.set(theme, forKey: key("theme")) } }
    @Published var tint: String { didSet { defaults.set(tint, forKey: key("tint")) } }
    @Published var maxHeight: Double { didSet { defaults.set(maxHeight, forKey: key("maxHeight")) } }

    init() {
        let d = UserDefaults.standard
        func list(_ name: String, _ fallback: [String]) -> [String] { d.stringArray(forKey: "popover.\(name)") ?? fallback }
        tiles = list("tiles", PopoverCatalog.defaultTiles).filter { PopoverCatalog.tile($0) != nil }
        layouts = list("layouts", PopoverCatalog.defaultLayouts)
        let order = list("sectionOrder", PopoverCatalog.sections.map(\.id))
        // A section added in a later version still appears.
        sectionOrder = order + PopoverCatalog.sections.map(\.id).filter { !order.contains($0) }
        hiddenSections = Set(d.stringArray(forKey: "popover.hiddenSections") ?? [])
        extras = list("extras", PopoverCatalog.extras.map(\.id))
        columns = d.object(forKey: "popover.columns") as? Int ?? 4
        compact = d.bool(forKey: "popover.compact")
        showLabels = d.object(forKey: "popover.showLabels") as? Bool ?? true
        showSearch = d.object(forKey: "popover.showSearch") as? Bool ?? true
        featuresAsGrid = d.object(forKey: "popover.featuresAsGrid") as? Bool ?? true
        theme = d.string(forKey: "popover.theme") ?? "system"
        tint = d.string(forKey: "popover.tint") ?? "slate"
        maxHeight = d.object(forKey: "popover.maxHeight") as? Double ?? 580
    }

    var colorScheme: ColorScheme? {
        switch theme {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    func reset() {
        for name in ["tiles", "layouts", "sectionOrder", "hiddenSections", "extras", "columns", "compact", "showLabels", "showSearch", "featuresAsGrid", "theme", "tint", "maxHeight"] {
            defaults.removeObject(forKey: key(name))
        }
        let fresh = PopoverPrefs()
        tiles = fresh.tiles; layouts = fresh.layouts; sectionOrder = fresh.sectionOrder; hiddenSections = fresh.hiddenSections
        extras = fresh.extras; columns = fresh.columns; compact = fresh.compact; showLabels = fresh.showLabels
        showSearch = fresh.showSearch; featuresAsGrid = fresh.featuresAsGrid; theme = fresh.theme; tint = fresh.tint; maxHeight = fresh.maxHeight
    }
}

private struct PopoverTintKey: EnvironmentKey {
    static let defaultValue: Color = Theme.accent
}

extension EnvironmentValues {
    /// The colour the menu-bar window uses for what is on.
    var popoverTint: Color {
        get { self[PopoverTintKey.self] }
        set { self[PopoverTintKey.self] = newValue }
    }
}
