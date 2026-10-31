import Foundation

/// What a command that starts from a chosen area does with the picture, instead of what the settings say.
enum ForcedDelivery: String, Codable, CaseIterable {
    case copy, save, upload, annotate, pin
}

/// Something that has to be true before a command can run. Each one has the sentence shown when it is not.
enum CaptureNeed: String, CaseIterable, Hashable {
    case screenPermission, notBusy, kriyaSelector, uploadReady
    case scrollRunning, kriyaRecorderRunning, cameraShown
    case pinsOpen, cardsShown, closedCard

    /// What to tell the person when this is not so. A whole sentence that says what to do.
    var problem: String {
        switch self {
        case .screenPermission: return "Screen Recording is off for Kriya. Allow it in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
        case .notBusy: return "A capture is already in progress. Finish it or press Escape, then try again."
        case .kriyaSelector: return "This command needs Kriya's own selector. Turn off “Use macOS's own selection tool instead of Kriya's” in Settings › Screen Capture."
        case .uploadReady: return "Uploading is not set up. Add a bucket under Settings › Screen Capture › Upload to your own bucket."
        case .scrollRunning: return "No scrolling capture is running."
        case .kriyaRecorderRunning: return "Kriya's recorder is not recording, so there is nothing to start over. Start one with “Record Screen”."
        case .cameraShown: return "The camera is not showing. Turn on “Show the camera in a small window” under Settings › Screen Capture › Recording, then start a recording."
        case .pinsOpen: return "No pinned pictures are on the screen."
        case .cardsShown: return "No capture cards are on the screen."
        case .closedCard: return "There is no closed capture to bring back."
        }
    }
}

/// What is true right now, gathered by the capture service. Plain values, so every rule can be checked without a screen.
struct CaptureCommandState: Equatable {
    var hasScreenPermission = true
    var isCapturing = false
    var isScrolling = false
    var kriyaRecording = false
    var macOSRecording = false
    var pinCount = 0
    /// Cards on the screen, hidden or not.
    var cardCount = 0
    var closedCardCount = 0
    var uploadReady = false
    var cameraShown = false
    /// Kriya's own selector is in use (not macOS's).
    var kriyaSelector = true

    func isMet(_ need: CaptureNeed) -> Bool {
        switch need {
        case .screenPermission: return hasScreenPermission
        case .notBusy: return !isCapturing
        case .kriyaSelector: return kriyaSelector
        case .uploadReady: return uploadReady
        case .scrollRunning: return isScrolling
        case .kriyaRecorderRunning: return kriyaRecording
        case .cameraShown: return cameraShown
        case .pinsOpen: return pinCount > 0
        case .cardsShown: return cardCount > 0
        case .closedCard: return closedCardCount > 0
        }
    }
}

/// Whether a command can run now, and if not, why.
enum CommandAvailability: Equatable {
    case available
    case disabled(String)

    var isAvailable: Bool { self == .available }
    /// The message to show when it was asked for anyway.
    var error: String? { if case .disabled(let reason) = self { return reason } else { return nil } }
}

enum CaptureCommandGroup: String, CaseIterable {
    case screenshots, history, recording, scrolling, cards, pins, desktop

    var title: String {
        switch self {
        case .screenshots: return "Screenshots"
        case .history: return "History"
        case .recording: return "Recording"
        case .scrolling: return "Scrolling capture"
        case .cards: return "Quick access cards"
        case .pins: return "Pins"
        case .desktop: return "Desktop"
        }
    }
}

/// One command of the capture feature: a name that never changes, who owns it, what it is called, what it needs, and what it does
/// differently from the settings (for the commands that start from a chosen area).
struct CaptureCommand: Identifiable, Equatable {
    let id: String
    let title: String
    let group: CaptureCommandGroup
    let needs: [CaptureNeed]
    var forced: ForcedDelivery?

    /// The shortcut owner these commands are registered under, and the feature that owns them.
    var owner: String { CaptureCommandCatalog.owner }
    var feature: String { CaptureCommandCatalog.featureID }

    func availability(in state: CaptureCommandState) -> CommandAvailability {
        for need in needs where !state.isMet(need) { return .disabled(need.problem) }
        return .available
    }
}

/// What to say after saving several cards at once.
enum CardBatch {
    static func summary(saved: Int, alreadySaved: Int, failed: Int) -> String {
        func pictures(_ n: Int) -> String { "\(n) capture\(n == 1 ? "" : "s")" }
        var parts: [String] = []
        if saved > 0 { parts.append("Saved \(pictures(saved))") }
        if alreadySaved > 0 { parts.append(saved > 0 ? "\(alreadySaved) already saved" : "\(pictures(alreadySaved).capitalizedFirst) already saved") }
        if failed > 0 { parts.append("\(pictures(failed)) could not be saved") }
        return parts.isEmpty ? "There was nothing to save." : parts.joined(separator: ", ") + "."
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

enum CaptureCommandID {
    static let regionCopy = "capture.region.copy"
    static let regionSave = "capture.region.save"
    static let regionUpload = "capture.region.upload"
    static let regionAnnotate = "capture.region.annotate"
    static let regionPin = "capture.region.pin"
    static let historyOpen = "capture.history.open"
    static let restoreLast = "capture.restore"
    static let desktopIcons = "capture.desktopicons.toggle"
    static let cardsToggle = "capture.cards.toggle"
    static let cardsSaveAll = "capture.cards.saveall"
    static let cardsCloseAll = "capture.cards.closeall"
    static let scrollStart = "capture.scroll.start"
    static let scrollStop = "capture.scroll.stop"
    static let selfTimer = "capture.timer"
    static let recordingRestart = "capture.rec.restart"
    static let cameraFullscreen = "capture.camera.fullscreen"
    static let pinsToggle = "capture.pins.toggle"
    static let pinsCloseAll = "capture.pins.closeall"
    static let pinsChoose = "capture.pins.choose"
}

/// The capture commands added to the older ones. Each can be given a shortcut, run from a mouse rule, a workflow or the launcher
/// by its name, and is checked against the rest of Kriya's shortcuts for clashes.
enum CaptureCommandCatalog {
    /// The name the capture shortcuts are registered under in the shortcut registry.
    static let owner = "Screen capture"
    /// The feature in the feature list that these belong to.
    static let featureID = "capture"

    private static let area: [CaptureNeed] = [.screenPermission, .notBusy, .kriyaSelector]

    static let added: [CaptureCommand] = [
        CaptureCommand(id: CaptureCommandID.regionCopy, title: "Capture an area and copy it", group: .screenshots, needs: area, forced: .copy),
        CaptureCommand(id: CaptureCommandID.regionSave, title: "Capture an area and save it", group: .screenshots, needs: area, forced: .save),
        CaptureCommand(id: CaptureCommandID.regionUpload, title: "Capture an area and upload it", group: .screenshots, needs: area + [.uploadReady], forced: .upload),
        CaptureCommand(id: CaptureCommandID.regionAnnotate, title: "Capture an area and mark it up", group: .screenshots, needs: area, forced: .annotate),
        CaptureCommand(id: CaptureCommandID.regionPin, title: "Capture an area and pin it to the screen", group: .screenshots, needs: area, forced: .pin),
        CaptureCommand(id: CaptureCommandID.selfTimer, title: "Capture an area with the self-timer", group: .screenshots, needs: [.screenPermission, .notBusy]),
        CaptureCommand(id: CaptureCommandID.historyOpen, title: "Open the capture history", group: .history, needs: []),
        CaptureCommand(id: CaptureCommandID.restoreLast, title: "Bring back the last closed capture", group: .history, needs: [.closedCard]),
        CaptureCommand(id: CaptureCommandID.desktopIcons, title: "Show or hide the desktop icons", group: .desktop, needs: []),
        CaptureCommand(id: CaptureCommandID.cardsToggle, title: "Hide or show the capture cards", group: .cards, needs: [.cardsShown]),
        CaptureCommand(id: CaptureCommandID.cardsSaveAll, title: "Save every capture card", group: .cards, needs: [.cardsShown]),
        CaptureCommand(id: CaptureCommandID.cardsCloseAll, title: "Close every capture card", group: .cards, needs: [.cardsShown]),
        CaptureCommand(id: CaptureCommandID.scrollStart, title: "Start a scrolling capture", group: .scrolling, needs: [.screenPermission, .notBusy]),
        CaptureCommand(id: CaptureCommandID.scrollStop, title: "Stop the scrolling capture and keep it", group: .scrolling, needs: [.scrollRunning]),
        CaptureCommand(id: CaptureCommandID.recordingRestart, title: "Start the recording over", group: .recording, needs: [.kriyaRecorderRunning]),
        CaptureCommand(id: CaptureCommandID.cameraFullscreen, title: "Show the camera full screen, or back", group: .recording, needs: [.cameraShown]),
        CaptureCommand(id: CaptureCommandID.pinsToggle, title: "Hide or show the pinned pictures", group: .pins, needs: [.pinsOpen]),
        CaptureCommand(id: CaptureCommandID.pinsCloseAll, title: "Close every pinned picture", group: .pins, needs: [.pinsOpen]),
        CaptureCommand(id: CaptureCommandID.pinsChoose, title: "Choose a picture and pin it", group: .pins, needs: []),
    ]

    static func command(_ id: String) -> CaptureCommand? { added.first { $0.id == id } }

    /// Whether the command can run now. Nil if `id` is not one of the added commands.
    static func availability(of id: String, in state: CaptureCommandState) -> CommandAvailability? { command(id)?.availability(in: state) }

    /// What has to be set up before this command can ever work (Screen Recording, Kriya's selector, an upload bucket), or nil. Things
    /// that change from moment to moment (a recording running, pins on the screen) are not setup, so Settings does not mention them.
    static func setupProblem(of id: String, in state: CaptureCommandState) -> String? {
        guard let command = command(id) else { return nil }
        let setup: Set<CaptureNeed> = [.screenPermission, .kriyaSelector, .uploadReady]
        return command.needs.first { setup.contains($0) && !state.isMet($0) }?.problem
    }

    /// Other shortcuts, from any part of Kriya, that already use these keys, so a clash is shown before the shortcut is saved. The
    /// command's own current shortcut is not a clash with itself.
    static func clashes(command: String, keyCode: UInt16, modifiers: UInt64, among entries: [ShortcutEntry]) -> [ShortcutEntry] {
        entries.filter { $0.keyCode == keyCode && $0.modifiers == modifiers && !($0.owner == owner && $0.command == command) }
    }

    /// Commands that were given the same keys within the capture shortcuts (the store prevents it, but a restored backup may not).
    static func duplicateKeys(in shortcuts: [CaptureShortcut]) -> [[String]] {
        let grouped = Dictionary(grouping: shortcuts) { "\($0.keyCode):\($0.modifiers)" }
        return grouped.values.filter { $0.count > 1 }.map { $0.map(\.command).sorted() }.sorted { $0.first ?? "" < $1.first ?? "" }
    }
}
