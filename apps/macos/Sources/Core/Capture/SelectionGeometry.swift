import CoreGraphics
import Foundation

/// The arithmetic of choosing an area on the screen: dragging it out (from a corner or from the centre, free or in a fixed shape),
/// snapping its edges to screen and window edges, nudging and resizing it with the keyboard. Plain numbers in, plain numbers out, so
/// every rule can be tested without a screen. Coordinates are points in one display's own space, y growing in either direction as the
/// caller uses it; nothing here cares which.
enum SelectionGeometry {
    /// How close an edge must come to something before it snaps to it.
    static let snapDistance: CGFloat = 6
    /// The smallest an area may be, so a stray click is not a capture.
    static let minimumSide: CGFloat = 8

    // MARK: Fixed shapes

    struct Shape: Equatable, Identifiable {
        let id: String
        let name: String
        /// Width divided by height; nil is free.
        let ratio: CGFloat?
    }

    static let shapes: [Shape] = [
        Shape(id: "free", name: "Free", ratio: nil),
        Shape(id: "1:1", name: "1:1", ratio: 1),
        Shape(id: "16:9", name: "16:9", ratio: 16.0 / 9.0),
        Shape(id: "9:16", name: "9:16", ratio: 9.0 / 16.0),
        Shape(id: "4:3", name: "4:3", ratio: 4.0 / 3.0),
        Shape(id: "3:2", name: "3:2", ratio: 3.0 / 2.0),
    ]

    /// The shape after this one, going round (free comes after the last).
    static func nextShape(after current: Shape) -> Shape {
        guard let index = shapes.firstIndex(of: current) else { return shapes[0] }
        return shapes[(index + 1) % shapes.count]
    }

    // MARK: Dragging

    /// The area for a drag from `anchor` to `point`.
    /// - `fromCenter`: the anchor is the middle and the area grows outwards from it (holding Option).
    /// - `ratio`: width ÷ height to keep (holding Shift gives 1, or a chosen shape); the larger of the two movements decides the size.
    static func rect(from anchor: CGPoint, to point: CGPoint, fromCenter: Bool = false, ratio: CGFloat? = nil) -> CGRect {
        var dx = point.x - anchor.x
        var dy = point.y - anchor.y
        if let ratio, ratio > 0 {
            // Work out the size from the bigger pull, keep each direction's sign.
            let w = max(abs(dx), abs(dy) * ratio)
            let h = w / ratio
            dx = (dx < 0 ? -1 : 1) * w
            dy = (dy < 0 ? -1 : 1) * h
        }
        if fromCenter {
            return CGRect(x: anchor.x - abs(dx), y: anchor.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
        }
        return CGRect(x: min(anchor.x, anchor.x + dx), y: min(anchor.y, anchor.y + dy), width: abs(dx), height: abs(dy))
    }

    /// The area kept inside `bounds`: shifted back in if it hangs out, and shrunk only if it is bigger than the bounds.
    static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        var r = rect
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    // MARK: Snapping

    /// The area with each edge moved onto the nearest edge in `xs` / `ys` that is within `distance`. Left and right (top and bottom)
    /// snap separately, so snapping both ends of a drag changes the size, not only the place.
    static func snapped(_ rect: CGRect, xs: [CGFloat], ys: [CGFloat], distance: CGFloat = snapDistance) -> CGRect {
        func nearest(_ value: CGFloat, in list: [CGFloat]) -> CGFloat? {
            list.filter { abs($0 - value) <= distance }.min { abs($0 - value) < abs($1 - value) }
        }
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if let x = nearest(minX, in: xs) { minX = x }
        if let x = nearest(maxX, in: xs) { maxX = x }
        if let y = nearest(minY, in: ys) { minY = y }
        if let y = nearest(maxY, in: ys) { maxY = y }
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 0), height: max(maxY - minY, 0))
    }

    /// The edges worth snapping to: the display's own edges and the edges of the windows on it.
    static func edges(display: CGRect, windows: [CGRect]) -> (xs: [CGFloat], ys: [CGFloat]) {
        var xs = [display.minX, display.maxX], ys = [display.minY, display.maxY]
        for window in windows {
            xs += [window.minX, window.maxX]
            ys += [window.minY, window.maxY]
        }
        return (Array(Set(xs)).sorted(), Array(Set(ys)).sorted())
    }

    /// Sizes people capture to. An area whose width and height are both close to one of these becomes exactly that size.
    static let commonSizes: [CGSize] = [
        CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 720), CGSize(width: 1440, height: 900), CGSize(width: 1024, height: 768),
        CGSize(width: 800, height: 600), CGSize(width: 640, height: 480), CGSize(width: 1200, height: 630), CGSize(width: 1080, height: 1080),
        CGSize(width: 1080, height: 1920), CGSize(width: 390, height: 844), CGSize(width: 375, height: 667), CGSize(width: 768, height: 1024),
        CGSize(width: 512, height: 512), CGSize(width: 256, height: 256),
    ]

    /// The size to show instead if the area is within `tolerance` of a common size in both directions, else nil. The origin stays put.
    static func commonSize(for rect: CGRect, tolerance: CGFloat = 5) -> CGSize? {
        commonSizes.first { abs($0.width - rect.width) <= tolerance && abs($0.height - rect.height) <= tolerance }
    }

    // MARK: Keyboard

    /// The area moved by `dx`, `dy` points and kept inside `bounds`.
    static func moved(_ rect: CGRect, dx: CGFloat, dy: CGFloat, within bounds: CGRect) -> CGRect {
        clamped(rect.offsetBy(dx: dx, dy: dy), to: bounds)
    }

    /// The area made `dw` wider and `dh` taller from its top-left corner (negative shrinks it), kept inside `bounds` and not smaller
    /// than the minimum. With a `ratio` the shape is kept: the change in width decides.
    static func resized(_ rect: CGRect, dw: CGFloat, dh: CGFloat, within bounds: CGRect, ratio: CGFloat? = nil) -> CGRect {
        var w = rect.width + dw
        var h = rect.height + dh
        if let ratio, ratio > 0 {
            if dw != 0 { h = w / ratio } else { w = h * ratio }
        }
        w = min(max(w, minimumSide), bounds.maxX - rect.minX)
        h = min(max(h, minimumSide), bounds.maxY - rect.minY)
        if let ratio, ratio > 0 {
            // A limit hit on one side must not break the shape.
            if w / h > ratio { w = h * ratio } else { h = w / ratio }
        }
        return CGRect(x: rect.minX, y: rect.minY, width: w, height: h)
    }

    /// Whether the area is big enough to capture.
    static func isUsable(_ rect: CGRect) -> Bool { rect.width >= minimumSide && rect.height >= minimumSide }

    // MARK: Between pictures and screens

    /// The part of a picture to keep for an area given in points. `scale` is pixels per point; `topLeft` says whether the area's y
    /// counts from the top (as `CGImage.cropping` does) or from the bottom (as AppKit views do, when `displayHeight` is needed).
    static func cropRect(for area: CGRect, scale: CGFloat, displayHeight: CGFloat, topLeft: Bool) -> CGRect {
        let y = topLeft ? area.minY : displayHeight - area.maxY
        return CGRect(x: (area.minX * scale).rounded(), y: (y * scale).rounded(), width: (area.width * scale).rounded(), height: (area.height * scale).rounded())
    }

    /// The text shown beside a selection: its size in points, and in pixels when they differ.
    static func sizeLabel(_ rect: CGRect, scale: CGFloat) -> String {
        let w = Int(rect.width.rounded()), h = Int(rect.height.rounded())
        guard scale > 1.01 else { return "\(w) × \(h)" }
        return "\(w) × \(h)  (\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded())) px)"
    }
}
