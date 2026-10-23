import Foundation

/// Reading pixels off a picture of the screen, for the pixel ruler. Pure: the caller supplies the bytes.
struct PixelGrid {
    let width: Int
    let height: Int
    /// Four bytes per pixel (red, green, blue, alpha), the top row first.
    let bytes: [UInt8]

    func color(x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    func hex(x: Int, y: Int) -> String? {
        color(x: x, y: y).map { String(format: "#%02X%02X%02X", $0.r, $0.g, $0.b) }
    }

    /// How many pixels you can move from (x, y) in a direction before the colour changes by more than `tolerance`
    /// (the sum of the red, green and blue differences). This is how the ruler finds the edges of a button or a window.
    func run(fromX x: Int, y: Int, dx: Int, dy: Int, tolerance: Int = 24) -> Int {
        guard let start = color(x: x, y: y), dx != 0 || dy != 0 else { return 0 }
        var steps = 0
        var cx = x + dx, cy = y + dy
        while let c = color(x: cx, y: cy) {
            if abs(c.r - start.r) + abs(c.g - start.g) + abs(c.b - start.b) > tolerance { break }
            steps += 1
            cx += dx; cy += dy
        }
        return steps
    }

    /// The box of like-coloured pixels around a point, as left, top, width and height in pixels.
    func region(around x: Int, y: Int, tolerance: Int = 24) -> (x: Int, y: Int, width: Int, height: Int)? {
        guard color(x: x, y: y) != nil else { return nil }
        let left = run(fromX: x, y: y, dx: -1, dy: 0, tolerance: tolerance)
        let right = run(fromX: x, y: y, dx: 1, dy: 0, tolerance: tolerance)
        let up = run(fromX: x, y: y, dx: 0, dy: -1, tolerance: tolerance)
        let down = run(fromX: x, y: y, dx: 0, dy: 1, tolerance: tolerance)
        return (x - left, y - up, left + right + 1, up + down + 1)
    }
}

enum PixelMeasure {
    /// A rectangle from two corners, whichever way it was dragged.
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// "240 × 120 px", and in points when the screen has more than one pixel to the point.
    static func label(widthPixels: Int, heightPixels: Int, scale: Double) -> String {
        guard scale > 1 else { return "\(widthPixels) × \(heightPixels) px" }
        func pt(_ v: Int) -> String { let p = Double(v) / scale; return p == p.rounded() ? "\(Int(p))" : String(format: "%.1f", p) }
        return "\(widthPixels) × \(heightPixels) px  (\(pt(widthPixels)) × \(pt(heightPixels)) pt)"
    }
}
