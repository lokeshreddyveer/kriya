import Foundation

/// How large the text in Kriya's settings window is. The window also grows its text by itself when it is made very wide; the
/// larger of the two is used.
enum TextSize: String, CaseIterable, Identifiable, Codable {
    case standard, large, larger, largest

    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "Standard"
        case .large: return "Large"
        case .larger: return "Larger"
        case .largest: return "Largest"
        }
    }

    /// The body text size in points. Standard leaves the system's own size alone.
    var points: Double? {
        switch self {
        case .standard: return nil
        case .large: return 15
        case .larger: return 17
        case .largest: return 20
        }
    }

    /// 0 to 3, so it can be compared with what the window width asks for.
    var level: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    static func larger(of a: TextSize, _ b: TextSize) -> TextSize { a.level >= b.level ? a : b }

    /// What a window of this width asks for by itself.
    static func forWidth(_ width: Double) -> TextSize {
        switch width {
        case ..<1300: return .standard
        case ..<1800: return .large
        default: return .larger
        }
    }
}

/// Colours adjusted for people who asked macOS for more contrast (System Settings › Accessibility › Display).
enum ContrastBoost {
    /// Darker on a light background, lighter on a dark one, so a colour that carried meaning still reads on its own.
    static func adjust(_ rgb: (CGFloat, CGFloat, CGFloat), dark: Bool) -> (CGFloat, CGFloat, CGFloat) {
        func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
        if dark { return (clamp(rgb.0 + (1 - rgb.0) * 0.3), clamp(rgb.1 + (1 - rgb.1) * 0.3), clamp(rgb.2 + (1 - rgb.2) * 0.3)) }
        return (clamp(rgb.0 * 0.65), clamp(rgb.1 * 0.65), clamp(rgb.2 * 0.65))
    }

    /// The contrast ratio between two colours (WCAG), 1 to 21.
    static func ratio(_ a: (CGFloat, CGFloat, CGFloat), _ b: (CGFloat, CGFloat, CGFloat)) -> Double {
        func channel(_ c: CGFloat) -> Double { let v = Double(c); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func luminance(_ c: (CGFloat, CGFloat, CGFloat)) -> Double { 0.2126 * channel(c.0) + 0.7152 * channel(c.1) + 0.0722 * channel(c.2) }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
