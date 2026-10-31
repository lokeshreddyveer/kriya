import Foundation

// MARK: - Do Not Disturb while recording

/// Whether Do Not Disturb (a Focus) is on.
enum DNDState: String, Codable, Equatable {
    case on, off
    /// It could not be told (macOS only shows it to apps with Full Disk Access).
    case unknown
}

/// Turning Do Not Disturb on and off. The real one runs two Shortcuts the person made; a check supplies its own.
protocol FocusControlling: AnyObject {
    func currentState() -> DNDState
    /// Turns it on or off. False if that could not be done.
    @discardableResult func set(_ state: DNDState) -> Bool
}

/// One turn-on of Do Not Disturb for a recording, and how to put things back. It is kept on disk from the moment it begins, so if Kriya
/// is quit or crashes in the middle, it can be put back the next time Kriya starts.
struct FocusTransaction: Codable, Equatable {
    /// What Do Not Disturb was before the recording. When that could not be told it is treated as off.
    var previousState: DNDState
    var startedAt: Date

    /// What to put it back to: on only if it was known to be on.
    var restoreTarget: DNDState { previousState == .on ? .on : .off }

    /// Turns Do Not Disturb on. Nil, and nothing changed, if that could not be done.
    static func begin(using controller: FocusControlling, now: Date = Date()) -> FocusTransaction? {
        let before = controller.currentState()
        // Already on: nothing is changed, so there is nothing to put back.
        if before == .on { return FocusTransaction(previousState: .on, startedAt: now) }
        guard controller.set(.on) else { return nil }
        return FocusTransaction(previousState: before, startedAt: now)
    }

    /// Puts Do Not Disturb back to how it was. Returns whether it is now as it was.
    @discardableResult
    func restore(using controller: FocusControlling) -> Bool {
        // Left on by the recording and on before: nothing to do.
        guard restoreTarget == .off || controller.currentState() != .on else { return true }
        return controller.set(restoreTarget)
    }
}

/// Keeps the transaction on disk while it lasts. Takes the preferences to use, so a check never touches the real ones.
struct FocusTransactionStore {
    static let key = "recording.focusTransaction.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var pending: FocusTransaction? {
        get { defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(FocusTransaction.self, from: $0) } }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) }
        }
    }

    /// Puts Do Not Disturb back if a transaction was left behind (Kriya was quit, or crashed, during a recording), and forgets it.
    /// Returns whether there was one.
    @discardableResult
    func recover(using controller: FocusControlling) -> Bool {
        guard let left = pending else { return false }
        left.restore(using: controller)
        pending = nil
        return true
    }
}

// MARK: - Showing clicks

enum MouseButton: String, Codable, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
}

/// How clicks are shown on screen while recording.
struct ClickHighlightOptions: Codable, Equatable {
    var enabled = false
    /// A ring that stays while the button is held, and fades when it is let go.
    var showHold = true
    /// Left and right clicks in different colours.
    var distinguishButtons = true
    /// A soft glow around the pointer, always.
    var cursorHalo = false
    /// A window-only recording does not include the overlays, since they are not part of the window, unless this is on.
    var includeInWindowRecording = false
    var leftColour = CodableColor(red: 1.0, green: 0.78, blue: 0.2, alpha: 0.9)
    var rightColour = CodableColor(red: 0.35, green: 0.65, blue: 1.0, alpha: 0.9)

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClickHighlightOptions()
        enabled = c.value(.enabled, d.enabled); showHold = c.value(.showHold, d.showHold); distinguishButtons = c.value(.distinguishButtons, d.distinguishButtons)
        cursorHalo = c.value(.cursorHalo, d.cursorHalo); includeInWindowRecording = c.value(.includeInWindowRecording, d.includeInWindowRecording)
        leftColour = c.value(.leftColour, d.leftColour); rightColour = c.value(.rightColour, d.rightColour)
    }

    /// The colour of a click: by button when they are told apart, otherwise the left one's.
    func colour(for button: MouseButton) -> CodableColor { distinguishButtons && button == .right ? rightColour : leftColour }

    /// Whether overlays are shown at all for this kind of recording: always, except a window-only recording that did not ask for them
    /// (they would be on the screen but not in the video, which only confuses).
    func shows(for source: RecordingSource) -> Bool { enabled && (source != .window || includeInWindowRecording) }
}

// MARK: - Showing keys

struct KeystrokeOptions: Codable, Equatable {
    enum Position: String, Codable, CaseIterable, Identifiable {
        case bottomCenter, bottomLeft, bottomRight, topCenter
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bottomCenter: return "Bottom center"
            case .bottomLeft: return "Bottom left"
            case .bottomRight: return "Bottom right"
            case .topCenter: return "Top center"
            }
        }
    }

    enum Theme: String, Codable, CaseIterable, Identifiable {
        case dark, light, accent
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum Size: String, Codable, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var fontSize: Double { self == .small ? 18 : self == .medium ? 26 : 38 }
    }

    /// ⌘⇧ or "Cmd Shift".
    enum ModifierLabels: String, Codable, CaseIterable, Identifiable {
        case symbols, words
        var id: String { rawValue }
        var title: String { self == .symbols ? "Symbols (⌘⇧)" : "Words (Cmd Shift)" }
    }

    static let fadeRange: ClosedRange<Double> = 0.5...6

    var position: Position = .bottomCenter
    var theme: Theme = .dark
    var size: Size = .medium
    var modifierLabels: ModifierLabels = .symbols
    /// Seconds a key stays on screen before it fades.
    var fadeSeconds = 1.6
    /// Nothing is shown while a password field has the keyboard.
    var hidePasswordFields = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = KeystrokeOptions()
        position = c.value(.position, d.position); theme = c.value(.theme, d.theme); size = c.value(.size, d.size)
        modifierLabels = c.value(.modifierLabels, d.modifierLabels); fadeSeconds = c.value(.fadeSeconds, d.fadeSeconds)
        hidePasswordFields = c.value(.hidePasswordFields, d.hidePasswordFields)
    }

    /// The fade time held to what can be set.
    var fade: Double { fadeSeconds.isNaN ? 1.6 : min(max(fadeSeconds, Self.fadeRange.lowerBound), Self.fadeRange.upperBound) }

    /// The words for each modifier, in the order they are written.
    static func words(for modifiers: KeystrokeLabel.Modifiers) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Opt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Cmd") }
        return parts.isEmpty ? "" : parts.joined(separator: " ") + " "
    }

    /// The text of a key press in the style chosen, or nil when it should not be shown (a bare modifier, or a password field).
    func label(keyCode: UInt16, characters: String?, modifiers: KeystrokeLabel.Modifiers, secureInput: Bool) -> String? {
        guard let symbols = KeystrokeLabel.label(keyCode: keyCode, characters: characters, modifiers: modifiers, secureInput: hidePasswordFields && secureInput) else { return nil }
        guard modifierLabels == .words, !modifiers.isEmpty else { return symbols }
        return Self.words(for: modifiers) + symbols.dropFirst(modifiers.symbols.count)
    }
}

// MARK: - Audio tracks

/// How the Mac's sound and the microphone are written to the movie.
enum AudioTrackMode: String, Codable, CaseIterable, Identifiable {
    /// Each in a track of its own, so they can be edited apart. What Kriya has always written.
    case separate
    /// One track with both mixed together.
    case mixed

    var id: String { rawValue }
    var title: String { self == .separate ? "Separate tracks" : "One mixed track" }
}

// MARK: - Remembering what was recorded

/// What the last recording was of, so the next can start on the same thing. Checked again before it is used.
struct RecordingSelection: Codable, Equatable {
    /// A region of a display, in points from that display's top left, with the display's identifier.
    var displayUUID: String?
    var region: [Double]?
    var window: RememberedWindow?

    /// What is still true: a display that is not connected, a region that no longer fits on its display, or a window that is not open is
    /// dropped. `windows` is nil when what is open cannot be known (then a window is kept, not guessed away). `displaySizes` maps each
    /// connected display's identifier to its size in points.
    func validated(displaySizes: [String: CGSize], windows: [RememberedWindow]?) -> RecordingSelection {
        var next = self
        if let uuid = displayUUID {
            guard let size = displaySizes[uuid] else { next.displayUUID = nil; next.region = nil; return stripWindow(next, windows) }
            if let r = region {
                let ok = r.count == 4 && r.allSatisfy { $0.isFinite } && r[0] >= 0 && r[1] >= 0 && r[2] >= 8 && r[3] >= 8 && r[0] + r[2] <= Double(size.width) + 0.5 && r[1] + r[3] <= Double(size.height) + 0.5
                if !ok { next.region = nil }
            }
        } else {
            next.region = nil
        }
        return stripWindow(next, windows)
    }

    private func stripWindow(_ selection: RecordingSelection, _ windows: [RememberedWindow]?) -> RecordingSelection {
        var next = selection
        if let window = next.window, let windows, !windows.contains(window) { next.window = nil }
        return next
    }

    var isEmpty: Bool { displayUUID == nil && window == nil }
}
