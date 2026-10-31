import Foundation

/// What a captured window is made into.
enum WindowShotStyle: String, Codable, CaseIterable, Identifiable {
    /// The window as macOS itself captures it: its own shadow, on a transparent background. Nothing is added.
    case system
    /// The window alone, without macOS's shadow, its rounded corners left transparent.
    case window
    /// The window with space around it: on a backdrop, or on a transparent canvas.
    case framed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "As macOS captures it"
        case .window: return "The window alone"
        case .framed: return "With space around it"
        }
    }
}

/// How windows are captured: the style, whether the space around is transparent or a backdrop, a shadow of Kriya's own, and which backdrop.
struct WindowShotOptions: Codable, Equatable {
    var style: WindowShotStyle = .system
    /// For "with space around it": leave the canvas transparent instead of putting a backdrop on it. Shift held while capturing a window
    /// does the opposite of this for that one capture.
    var transparentBackground = false
    /// A soft shadow drawn by Kriya, the same on every Mac. Not used for "as macOS captures it", which has macOS's own.
    var shadow = false
    var backdrop: CaptureBeautify.Background = .graphite

    init(style: WindowShotStyle = .system, transparentBackground: Bool = false, shadow: Bool = false, backdrop: CaptureBeautify.Background = .graphite) {
        self.style = style; self.transparentBackground = transparentBackground; self.shadow = shadow; self.backdrop = backdrop
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WindowShotOptions()
        style = c.value(.style, d.style); transparentBackground = c.value(.transparentBackground, d.transparentBackground)
        shadow = c.value(.shadow, d.shadow); backdrop = c.value(.backdrop, d.backdrop)
    }

    /// What the older four-way choice meant: the same picture as before.
    init(look: WindowLook) {
        switch look {
        case .system: self.init(style: .system)
        case .windowOnly: self.init(style: .window, shadow: false)
        case .kriyaShadow: self.init(style: .window, shadow: true)
        case .background: self.init(style: .framed, shadow: true)
        }
    }

    /// The older four-way choice this comes to, for the parts of Kriya that still ask by it.
    var look: WindowLook {
        switch style {
        case .system: return .system
        case .window: return shadow ? .kriyaShadow : .windowOnly
        case .framed: return .background
        }
    }

    /// The options for one capture: with Shift held, a framed window's background is the other of transparent and backdrop. For the
    /// other styles there is no background to change, so Shift does nothing.
    func effective(shiftHeld: Bool) -> WindowShotOptions {
        guard shiftHeld, style == .framed else { return self }
        var next = self
        next.transparentBackground.toggle()
        return next
    }

    /// Whether the system's own shadow is left out of the capture.
    var dropsSystemShadow: Bool { style != .system }

    /// What the settings say in a sentence.
    var detail: String {
        switch style {
        case .system: return "macOS's own shadow, on a transparent background."
        case .window: return shadow ? "The window with a soft shadow drawn by Kriya, on a transparent background." : "No shadow. The corners are transparent."
        case .framed:
            let around = transparentBackground ? "on a transparent canvas" : "on the \(backdrop.title.lowercased()) backdrop"
            return "The window with space around it, \(around)\(shadow ? ", with a soft shadow" : ""). Hold ⇧ while capturing for \(transparentBackground ? "the backdrop" : "a transparent background") instead."
        }
    }

    /// Everything back to how it was at first.
    mutating func resetToDefaults() { self = WindowShotOptions() }
}
