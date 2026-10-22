import CoreGraphics
import Foundation

/// One box in a layout being drawn: where it sits on a display (as fractions, 0 to 1, from the top left) and which app's
/// window goes there.
struct DesignRegion: Identifiable, Equatable {
    var id = UUID()
    var rect: CGRect
    var appID = ""
    /// Only a window with this title goes here. Empty means any window of the app.
    var title = ""
}

/// The rules for drawing a layout, kept apart from the screen so they can be tested.
enum LayoutDesign {
    static let minimumSize: CGFloat = 0.05

    /// Rounds a fraction to the nearest step of a grid. A grid of 0 means no snapping.
    static func snap(_ value: CGFloat, grid: Int) -> CGFloat {
        guard grid > 0 else { return value }
        let step = 1 / CGFloat(grid)
        return (value / step).rounded() * step
    }

    static func clamp(_ rect: CGRect) -> CGRect {
        let width = min(max(rect.width, minimumSize), 1)
        let height = min(max(rect.height, minimumSize), 1)
        return CGRect(x: min(max(rect.minX, 0), 1 - width), y: min(max(rect.minY, 0), 1 - height), width: width, height: height)
    }

    /// The box made by dragging from one point to another over a canvas, as fractions of it.
    static func rect(from start: CGPoint, to end: CGPoint, in size: CGSize, grid: Int) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        func unit(_ p: CGPoint) -> CGPoint { CGPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1)) }
        let a = unit(start), b = unit(end)
        let x0 = snap(min(a.x, b.x), grid: grid), x1 = snap(max(a.x, b.x), grid: grid)
        let y0 = snap(min(a.y, b.y), grid: grid), y1 = snap(max(a.y, b.y), grid: grid)
        return clamp(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
    }

    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    /// A box with one corner dragged to a new place. The opposite corner stays put.
    static func resized(_ rect: CGRect, corner: Corner, to point: CGPoint, grid: Int) -> CGRect {
        let p = CGPoint(x: snap(min(max(point.x, 0), 1), grid: grid), y: snap(min(max(point.y, 0), 1), grid: grid))
        let anchor: CGPoint
        switch corner {
        case .topLeft: anchor = CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight: anchor = CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: anchor = CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight: anchor = CGPoint(x: rect.minX, y: rect.minY)
        }
        var box = CGRect(x: min(p.x, anchor.x), y: min(p.y, anchor.y), width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
        // Never smaller than the minimum, growing away from the fixed corner.
        if box.width < minimumSize { box.size.width = minimumSize; if p.x < anchor.x { box.origin.x = anchor.x - minimumSize } else { box.origin.x = anchor.x } }
        if box.height < minimumSize { box.size.height = minimumSize; if p.y < anchor.y { box.origin.y = anchor.y - minimumSize } else { box.origin.y = anchor.y } }
        return clamp(box)
    }

    /// A box moved by a drag, kept on the display.
    static func moved(_ rect: CGRect, by delta: CGSize, grid: Int) -> CGRect {
        var origin = CGPoint(x: snap(rect.minX + delta.width, grid: grid), y: snap(rect.minY + delta.height, grid: grid))
        origin.x = min(max(origin.x, 0), 1 - rect.width)
        origin.y = min(max(origin.y, 0), 1 - rect.height)
        return CGRect(origin: origin, size: rect.size)
    }

    // MARK: Starting points

    enum Template: String, CaseIterable, Identifiable {
        case halves = "Two halves", thirds = "Three columns", quarters = "Four quarters", sidebar = "Main and sidebar"
        case focus = "Centered focus", grid = "Grid of six"
        var id: String { rawValue }

        var rects: [CGRect] {
            switch self {
            case .halves: return [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
            case .thirds: return (0..<3).map { CGRect(x: CGFloat($0) / 3, y: 0, width: 1.0 / 3, height: 1) }
            case .quarters: return [(0, 0), (0.5, 0), (0, 0.5), (0.5, 0.5)].map { CGRect(x: $0.0, y: $0.1, width: 0.5, height: 0.5) }
            case .sidebar: return [CGRect(x: 0, y: 0, width: 0.7, height: 1), CGRect(x: 0.7, y: 0, width: 0.3, height: 1)]
            case .focus: return [CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)]
            case .grid: return (0..<6).map { CGRect(x: CGFloat($0 % 3) / 3, y: CGFloat($0 / 3) / 2, width: 1.0 / 3, height: 0.5) }
            }
        }
    }

    // MARK: Checks

    /// Pairs of boxes that cover each other by more than a sliver. Allowed, but worth pointing out.
    static func overlaps(_ regions: [DesignRegion]) -> [(DesignRegion, DesignRegion)] {
        var found: [(DesignRegion, DesignRegion)] = []
        for (i, a) in regions.enumerated() {
            for b in regions.dropFirst(i + 1) {
                let both = a.rect.intersection(b.rect)
                if !both.isNull, both.width * both.height > 0.01 { found.append((a, b)) }
            }
        }
        return found
    }

    /// Why a layout cannot be saved yet, or nil when it can.
    static func problem(name: String, regions: [DesignRegion]) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the layout a name." }
        if regions.isEmpty { return "Draw at least one box on the display." }
        if regions.contains(where: { $0.appID.isEmpty }) { return "Choose an app for every box." }
        if regions.count > 60 { return "That is more boxes than a layout can hold." }
        return nil
    }

    // MARK: To and from a saved layout

    static func entries(from regions: [DesignRegion], displayID: String) -> [LayoutEntry] {
        regions.map {
            LayoutEntry(
                appId: $0.appID, title: $0.title, displayId: displayID,
                frame: Rect(x: Double($0.rect.minX), y: Double($0.rect.minY), width: Double($0.rect.width), height: Double($0.rect.height))
            )
        }
    }

    /// The boxes of a saved layout that sit on one display.
    static func regions(from entries: [LayoutEntry], displayID: String) -> [DesignRegion] {
        entries.filter { $0.displayId == displayID }.map {
            DesignRegion(rect: clamp(CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height)), appID: $0.appId, title: $0.title)
        }
    }
}
