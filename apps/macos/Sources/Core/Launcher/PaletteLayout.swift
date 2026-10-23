import CoreGraphics
import Foundation

/// How big the launcher window is for what it is showing: a bar alone, then growing as results appear, up to a limit.
enum PaletteLayout {
    static let width: CGFloat = 680
    /// The search pill, the gap, and the results panel under it (a row of kinds, then the results).
    static let searchHeight: CGFloat = 58
    static let gap: CGFloat = 10
    static let chipsHeight: CGFloat = 46
    static let rowHeight: CGFloat = 54
    static let headerHeight: CGFloat = 26
    static let panelPadding: CGFloat = 8
    static let maxRows = 8
    /// Room around the glass so its shadows are not cut off by the window's edge.
    static let shadowInset: CGFloat = 28
    /// The panel with only a line of help in it, or "nothing matches".
    static let helpPanelHeight: CGFloat = 96
    static let nothingPanelHeight: CGFloat = 64
    static var emptyHeight: CGFloat { searchHeight + gap + helpPanelHeight + shadowInset * 2 }

    /// The height of the window for rows that sit under these headings (one per row, in order). Headings show only while
    /// nothing is typed.
    static func height(sections: [String], typed: Bool) -> CGFloat {
        guard !sections.isEmpty else { return searchHeight + gap + (typed ? nothingPanelHeight : helpPanelHeight) + shadowInset * 2 }
        var total: CGFloat = 0
        var previous: String?
        for heading in sections.prefix(maxRows) {
            if !typed, heading != previous { total += headerHeight }
            total += rowHeight
            previous = heading
        }
        return searchHeight + gap + chipsHeight + total + panelPadding * 2 + shadowInset * 2
    }

    /// Where the launcher opens.
    enum Placement: String, CaseIterable, Identifiable {
        case top, center, pointer, remembered
        var id: String { rawValue }
        var title: String {
            switch self {
            case .top: return "Near the top"
            case .center: return "In the middle"
            case .pointer: return "At the pointer"
            case .remembered: return "Where I left it"
            }
        }

        private static let key = "launcherPlacement"
        static var current: Placement {
            get { UserDefaults.standard.string(forKey: key).flatMap(Placement.init(rawValue:)) ?? .top }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
        }
    }

    /// The tallest the window gets, used to centre it so it does not jump as it grows.
    static var tallest: CGFloat { searchHeight + gap + chipsHeight + CGFloat(maxRows) * rowHeight + headerHeight * 2 + panelPadding * 2 + shadowInset * 2 }

    /// The top-centre point the person dragged the window to, kept between uses.
    enum Remembered {
        private static let key = "launcherTopCenter"
        static var saved: CGPoint? {
            get {
                guard let text = UserDefaults.standard.string(forKey: key) else { return nil }
                let p = text.split(separator: ",").compactMap { Double($0) }
                return p.count == 2 ? CGPoint(x: p[0], y: p[1]) : nil
            }
            set { UserDefaults.standard.set(newValue.map { "\($0.x),\($0.y)" }, forKey: key) }
        }
    }

    /// Where the window goes for a placement. Always completely inside the usable area of the screen it lands on; the window
    /// grows downward from its top edge.
    static func frame(height: CGFloat, in visible: CGRect, placement: Placement, pointer: CGPoint, saved: CGPoint?) -> CGRect {
        let w = min(width + shadowInset * 2, visible.width - 24)
        let h = min(height, visible.height - 24)
        var centerX = visible.midX
        var top: CGFloat
        switch placement {
        case .top:
            return frame(height: height, in: visible)
        case .center:
            top = visible.midY + min(tallest, visible.height - 24) / 2
        case .pointer:
            centerX = pointer.x
            top = pointer.y + 24
        case .remembered:
            guard let saved else { return frame(height: height, in: visible) }
            centerX = saved.x
            top = saved.y
        }
        let x = min(max(centerX - w / 2, visible.minX + 12), visible.maxX - w - 12)
        top = min(top, visible.maxY - 8)
        let y = max(top - h, visible.minY + 12)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Where the window goes: its top a fixed way down from the top of the usable area, centered across it, and always
    /// completely inside it. The window grows downward from there.
    static func frame(height: CGFloat, in visible: CGRect) -> CGRect {
        let w = min(width + shadowInset * 2, visible.width - 24)
        let top = visible.maxY - visible.height * 0.17
        var y = top - height
        y = max(y, visible.minY + 12)
        return CGRect(x: visible.midX - w / 2, y: y, width: w, height: min(height, visible.height - 24))
    }

    /// The same window after its height changed: the top edge stays put.
    static func resized(_ current: CGRect, toHeight height: CGFloat, in visible: CGRect) -> CGRect {
        var y = current.maxY - height
        y = max(y, visible.minY + 12)
        return CGRect(x: current.minX, y: y, width: current.width, height: min(height, visible.height - 24))
    }
}
