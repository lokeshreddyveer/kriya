import CoreGraphics
import Foundation

/// A ring of arcs, one per item, each as wide as the item is big: the round alternative to the treemap.
enum Sunburst {
    struct Arc: Equatable {
        let id: String
        /// Radians, 0 at the top, growing clockwise.
        let start: Double
        let end: Double
    }

    /// Arcs filling the circle for items with a size, biggest first. Items too thin to see (under `minimum` radians) are not drawn.
    static func arcs(_ items: [(id: String, size: Double)], minimum: Double = 0.012) -> [Arc] {
        let sorted = items.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        let total = sorted.reduce(0) { $0 + $1.size }
        guard total > 0 else { return [] }
        var angle = 0.0
        var out: [Arc] = []
        for item in sorted {
            let span = item.size / total * 2 * .pi
            defer { angle += span }
            if span >= minimum { out.append(Arc(id: item.id, start: angle, end: angle + span)) }
        }
        return out
    }

    /// The arc under `point` for a ring between `inner` and `outer` around `center`, if any.
    static func hit(_ point: CGPoint, center: CGPoint, inner: CGFloat, outer: CGFloat, in arcs: [Arc]) -> Arc? {
        let dx = Double(point.x - center.x), dy = Double(point.y - center.y)
        let radius = (dx * dx + dy * dy).squareRoot()
        guard radius >= Double(inner), radius <= Double(outer) else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        return arcs.first { angle >= $0.start && angle < $0.end }
    }
}
