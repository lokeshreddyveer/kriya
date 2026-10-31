import CoreGraphics
import Foundation

/// Where the quick access cards appear, how big they are, how long they stay, and which captures get one.
enum QuickAccessPosition: String, Codable, CaseIterable, Identifiable {
    case topLeft, topCenter, topRight, middleLeft, center, middleRight, bottomLeft, bottomCenter, bottomRight, nearPointer
    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .topCenter: return "Top center"
        case .topRight: return "Top right"
        case .middleLeft: return "Middle left"
        case .center: return "Center"
        case .middleRight: return "Middle right"
        case .bottomLeft: return "Bottom left"
        case .bottomCenter: return "Bottom center"
        case .bottomRight: return "Bottom right"
        case .nearPointer: return "Near the pointer"
        }
    }
}

enum QuickAccessScope: String, Codable, CaseIterable, Identifiable {
    case both, screenshots, recordings, off
    var id: String { rawValue }
    var title: String { switch self { case .both: return "Screenshots and recordings"; case .screenshots: return "Screenshots only"; case .recordings: return "Recordings only"; case .off: return "Never" } }
}

enum QuickAccessIcon: String, Codable, CaseIterable, Identifiable {
    case visible, hidden, automatic, whileRecording
    var id: String { rawValue }
    var title: String {
        switch self {
        case .visible: return "Always visible"
        case .hidden: return "Hidden"
        case .automatic: return "Only while there is something to show"
        case .whileRecording: return "Only while recording"
        }
    }
}

enum QuickAccessDisplay: String, Codable, CaseIterable, Identifiable {
    /// The display the pointer is on (where the capture was made).
    case pointer
    /// The main display (the one with the menu bar).
    case main
    var id: String { rawValue }
    var title: String { self == .pointer ? "Where the capture was made" : "The main display" }
}

enum QuickAccessSize: String, Codable, CaseIterable, Identifiable {
    case small, regular, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var thumbnailWidth: CGFloat { switch self { case .small: return 190; case .regular: return 260; case .large: return 340 } }
}

struct QuickAccessSettings: Codable, Equatable {
    var icon: QuickAccessIcon = .visible
    var scope: QuickAccessScope = .both
    var position: QuickAccessPosition = .bottomLeft
    var display: QuickAccessDisplay = .pointer
    var size: QuickAccessSize = .regular
    /// Distance from the screen edge, in points.
    var margin: Double = 20
    /// Seconds before a card goes away by itself; 0 keeps it until dismissed.
    var autoCloseSeconds: Int = 9
    /// How many recent cards are stacked on screen at once.
    var stackLimit: Int = 4
    /// Do not show a card for a screenshot while a recording is running.
    var holdWhileRecording = true
    /// The card goes away once its picture has been dragged somewhere. ⌥ held while dragging keeps it, when `optionDragKeepsOpen`.
    var closeAfterDragging = false
    var optionDragKeepsOpen = true
    /// The card goes away once its picture has been uploaded.
    var closeAfterUpload = false
    /// Where Save puts a picture, and where it goes when ⌥ is held while pressing it.
    var defaultSaveDestination = SaveDestination(kind: .captureFolder)
    var alternateSaveDestination = SaveDestination(kind: .ask)

    init() {}

    /// Reads settings saved by any earlier version: a key that is not there keeps its usual value, so nothing set before is lost.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QuickAccessSettings()
        icon = c.value(.icon, d.icon); scope = c.value(.scope, d.scope); position = c.value(.position, d.position)
        display = c.value(.display, d.display); size = c.value(.size, d.size); margin = c.value(.margin, d.margin)
        autoCloseSeconds = c.value(.autoCloseSeconds, d.autoCloseSeconds); stackLimit = c.value(.stackLimit, d.stackLimit)
        holdWhileRecording = c.value(.holdWhileRecording, d.holdWhileRecording)
        closeAfterDragging = c.value(.closeAfterDragging, d.closeAfterDragging); optionDragKeepsOpen = c.value(.optionDragKeepsOpen, d.optionDragKeepsOpen)
        closeAfterUpload = c.value(.closeAfterUpload, d.closeAfterUpload)
        defaultSaveDestination = c.value(.defaultSaveDestination, d.defaultSaveDestination)
        alternateSaveDestination = c.value(.alternateSaveDestination, d.alternateSaveDestination)
    }

    func shows(recording: Bool) -> Bool {
        switch scope {
        case .both: return true
        case .screenshots: return !recording
        case .recordings: return recording
        case .off: return false
        }
    }

    /// The values brought into range, so a hand-edited preference cannot break the layout.
    var clamped: QuickAccessSettings {
        var s = self
        s.margin = min(max(margin, 0), 120)
        s.autoCloseSeconds = min(max(autoCloseSeconds, 0), 120)
        s.stackLimit = min(max(stackLimit, 1), 6)
        return s
    }
}

/// Where a card's Save puts a picture.
struct SaveDestination: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case captureFolder, desktop, downloads, ask, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .captureFolder: return "The capture folder"
            case .desktop: return "The Desktop"
            case .downloads: return "Downloads"
            case .ask: return "Ask each time"
            case .custom: return "A folder I choose…"
            }
        }
    }

    var kind: Kind = .captureFolder
    /// The folder for `.custom`.
    var path = ""

    init(kind: Kind = .captureFolder, path: String = "") { self.kind = kind; self.path = path }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.value(.kind, Kind.captureFolder); path = c.value(.path, "")
    }

    /// Somewhere to save, or a question to ask.
    enum Place: Equatable {
        case folder(URL)
        case ask
    }

    /// Where this puts a picture. A custom folder that was never chosen falls back to the capture folder rather than failing.
    func place(captureFolder: URL, home: URL) -> Place {
        switch kind {
        case .captureFolder: return .folder(captureFolder)
        case .desktop: return .folder(home.appendingPathComponent("Desktop", isDirectory: true))
        case .downloads: return .folder(home.appendingPathComponent("Downloads", isDirectory: true))
        case .ask: return .ask
        case .custom: return path.isEmpty ? .folder(captureFolder) : .folder(URL(fileURLWithPath: path, isDirectory: true))
        }
    }
}

/// The rules for what a Quick Access card does with its picture, in one place. Every way of dragging, uploading or saving (a button, a
/// key, a menu) asks here, so a card behaves the same whichever way it is used.
enum QuickAccessCard {
    enum After: Equatable { case close, keepOpen }

    /// What happens to the card after its picture was dragged out. ⌥ held keeps it open when that is allowed.
    static func afterDrag(_ settings: QuickAccessSettings, optionHeld: Bool) -> After {
        guard settings.closeAfterDragging else { return .keepOpen }
        return optionHeld && settings.optionDragKeepsOpen ? .keepOpen : .close
    }

    static func afterUpload(_ settings: QuickAccessSettings) -> After { settings.closeAfterUpload ? .close : .keepOpen }

    /// The destination for a Save: the default one, or the alternate one when ⌥ is held.
    static func destination(_ settings: QuickAccessSettings, optionHeld: Bool) -> SaveDestination {
        optionHeld ? settings.alternateSaveDestination : settings.defaultSaveDestination
    }
}

enum QuickAccessStore {
    static let key = "capture.quickAccess.v1"

    static var settings: QuickAccessSettings {
        get { (UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(QuickAccessSettings.self, from: $0) } ?? QuickAccessSettings()).clamped }
        set { if let data = try? JSONEncoder().encode(newValue.clamped) { UserDefaults.standard.set(data, forKey: key) } }
    }
}

enum QuickAccessLayout {
    /// Where a card's lower-left corner goes (AppKit coordinates, origin at the bottom left of the screen). Cards stack: downwards from a
    /// top position, upwards from every other, one `gap` apart. The result is kept fully on the screen.
    static func origin(position: QuickAccessPosition, panel: CGSize, screen: CGRect, margin: CGFloat, pointer: CGPoint? = nil, stackIndex: Int = 0, gap: CGFloat = 10) -> CGPoint {
        let step = (panel.height + gap) * CGFloat(stackIndex)
        var x: CGFloat, y: CGFloat
        switch position {
        case .topLeft, .middleLeft, .bottomLeft: x = screen.minX + margin
        case .topCenter, .center, .bottomCenter: x = screen.midX - panel.width / 2
        case .topRight, .middleRight, .bottomRight: x = screen.maxX - panel.width - margin
        case .nearPointer: x = (pointer?.x ?? screen.midX) + 18
        }
        switch position {
        case .topLeft, .topCenter, .topRight: y = screen.maxY - panel.height - margin - step
        case .middleLeft, .center, .middleRight: y = screen.midY - panel.height / 2 + step
        case .bottomLeft, .bottomCenter, .bottomRight: y = screen.minY + margin + step
        case .nearPointer: y = (pointer?.y ?? screen.midY) - panel.height - 18 + step
        }
        x = min(max(x, screen.minX), max(screen.maxX - panel.width, screen.minX))
        y = min(max(y, screen.minY), max(screen.maxY - panel.height, screen.minY))
        return CGPoint(x: x, y: y)
    }
}

/// The line under a card's picture: what it is and when it was made.
enum QuickAccessInfo {
    /// "1:05" or "0:07": a recording's length.
    static func duration(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }

    static func line(width: Int?, height: Int?, bytes: Int?, format: String, date: Date, now: Date = Date(), seconds: Double? = nil) -> String {
        var parts: [String] = []
        if let seconds, seconds > 0 { parts.append(duration(seconds)) }
        if let width, let height, width > 0, height > 0 { parts.append("\(width) × \(height)") }
        if !format.isEmpty { parts.append(format.uppercased()) }
        if let bytes { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "d MMM HH:mm"
        parts.append(f.string(from: date))
        return parts.joined(separator: " · ")
    }
}

/// The keys that work while the pointer is over a card.
enum QuickAccessKey: String, CaseIterable {
    case copy, save, annotate, text, pin, shelf, share, delete, history, dismiss

    var key: String {
        switch self {
        case .copy: return "c"
        case .save: return "s"
        case .annotate: return "e"
        case .text: return "o"
        case .pin: return "p"
        case .shelf: return "h"
        case .share: return "x"
        case .delete: return "⌫"
        case .history: return "y"
        case .dismiss: return "⎋"
        }
    }

    var title: String {
        switch self {
        case .copy: return "Copy"
        case .save: return "Save"
        case .annotate: return "Annotate"
        case .text: return "Copy text (OCR)"
        case .pin: return "Pin on screen"
        case .shelf: return "Send to the shelf"
        case .share: return "Share"
        case .delete: return "Move to the Trash"
        case .history: return "Open history"
        case .dismiss: return "Close"
        }
    }

    /// The action for a key press: a letter (without Command, Control or Option), Delete or Escape.
    static func action(characters: String, keyCode: UInt16, hasCommandLikeModifier: Bool) -> QuickAccessKey? {
        if keyCode == 53 { return .dismiss }
        if keyCode == 51 || keyCode == 117 { return .delete }
        guard !hasCommandLikeModifier else { return nil }
        return allCases.first { $0.key == characters.lowercased() }
    }
}
