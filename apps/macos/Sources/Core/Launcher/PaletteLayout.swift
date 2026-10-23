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
        case topLeft, top, topRight, center, bottomLeft, bottom, bottomRight, pointer, remembered
        var id: String { rawValue }
        var title: String {
            switch self {
            case .topLeft: return "Top left"
            case .top: return "Near the top"
            case .topRight: return "Top right"
            case .center: return "In the middle"
            case .bottomLeft: return "Bottom left"
            case .bottom: return "Near the bottom"
            case .bottomRight: return "Bottom right"
            case .pointer: return "At the pointer"
            case .remembered: return "Where I left it"
            }
        }

        /// Placements along the bottom keep the search bar's bottom edge still and grow upward, with results above the bar.
        var growsUp: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }

        static let key = "launcherPlacement"
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

    /// Where the window goes for a placement. Always completely inside the usable area of the screen it lands on. Most
    /// placements grow downward from their top edge; the bottom ones grow upward from their bottom edge.
    static func frame(height: CGFloat, in visible: CGRect, placement: Placement, pointer: CGPoint, saved: CGPoint?) -> CGRect {
        let w = min(width + shadowInset * 2, visible.width - 24)
        let h = min(height, visible.height - 24)
        let left = visible.minX + 12
        let right = visible.maxX - w - 12
        var x = visible.midX - w / 2
        var top: CGFloat
        switch placement {
        case .top:
            return frame(height: height, in: visible)
        case .topLeft, .topRight:
            x = placement == .topLeft ? left : right
            top = visible.maxY - 12
        case .center:
            // The search bar itself sits in the middle of the screen; results open below it.
            top = visible.midY + searchHeight / 2 + shadowInset
        case .bottomLeft, .bottom, .bottomRight:
            x = placement == .bottomLeft ? left : placement == .bottomRight ? right : x
            let bottom = placement == .bottom ? visible.minY + visible.height * 0.12 : visible.minY + 12
            let y = min(max(bottom, visible.minY + 12), visible.maxY - h - 8)
            return CGRect(x: min(max(x, left), right), y: y, width: w, height: h)
        case .pointer:
            x = pointer.x - w / 2
            top = pointer.y + 24
        case .remembered:
            guard let saved else { return frame(height: height, in: visible) }
            x = saved.x - w / 2
            top = saved.y
        }
        x = min(max(x, left), right)
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

    /// The same window after its height changed: the top edge stays put, or the bottom edge when it grows upward.
    static func resized(_ current: CGRect, toHeight height: CGFloat, in visible: CGRect, growsUp: Bool = false) -> CGRect {
        let h = min(height, visible.height - 24)
        if growsUp {
            let y = min(current.minY, visible.maxY - h - 8)
            return CGRect(x: current.minX, y: y, width: current.width, height: h)
        }
        var y = current.maxY - height
        y = max(y, visible.minY + 12)
        return CGRect(x: current.minX, y: y, width: current.width, height: h)
    }
}
