import Foundation

/// A colour that can be saved: red, green, blue and opacity, each from 0 to 1, in the sRGB colour space.
struct CodableColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red); self.green = Self.clamp(green); self.blue = Self.clamp(blue); self.alpha = Self.clamp(alpha)
    }

    /// A damaged or partial colour loads as the usual border colour rather than failing, and every part is kept in range.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CodableColor.border
        self.init(red: c.value(.red, d.red), green: c.value(.green, d.green), blue: c.value(.blue, d.blue), alpha: c.value(.alpha, d.alpha))
    }

    private static func clamp(_ v: Double) -> Double { v.isNaN ? 0 : min(max(v, 0), 1) }

    static let black = CodableColor(red: 0, green: 0, blue: 0)
    static let white = CodableColor(red: 1, green: 1, blue: 1)
    /// The soft dark line used when no colour was chosen.
    static let border = CodableColor(red: 0, green: 0, blue: 0, alpha: 0.28)
}

/// An outline around a screenshot. It is drawn in the ring just outside the picture, on a canvas that is made large enough to hold it,
/// so no part of it is ever cut off and none of the picture is covered.
struct CaptureBorder: Codable, Equatable {
    /// Widths that can be chosen, in pixels.
    static let widthRange: ClosedRange<Double> = 0.5...64

    var enabled = false
    var width = 1.0
    var color = CodableColor.border

    init(enabled: Bool = false, width: Double = 1, color: CodableColor = .border) {
        self.enabled = enabled; self.width = width; self.color = color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: c.value(.enabled, false), width: c.value(.width, 1.0), color: c.value(.color, CodableColor.border))
    }

    /// The width held to what can be drawn.
    var drawnWidth: Double { width.isNaN ? Self.widthRange.lowerBound : min(max(width, Self.widthRange.lowerBound), Self.widthRange.upperBound) }

    /// The whole pixels the canvas must have on every side to hold the border (0 when it is off).
    var reserved: Int { enabled ? Int(drawnWidth.rounded(.up)) : 0 }
}
