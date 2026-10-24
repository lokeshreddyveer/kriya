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
    case visible, hidden, automatic
    var id: String { rawValue }
    var title: String { switch self { case .visible: return "Always visible"; case .hidden: return "Hidden"; case .automatic: return "Only while there is something to show" } }
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
    static func line(width: Int?, height: Int?, bytes: Int?, format: String, date: Date, now: Date = Date()) -> String {
        var parts: [String] = []
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
