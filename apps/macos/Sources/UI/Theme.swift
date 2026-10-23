import AppKit
import SwiftUI

/// Kriya's palette. Surfaces and text use the system's own colours, so light and dark mode and Reduce Transparency
/// work without extra code. The only custom colours are a muted accent and three quiet status colours, each tuned
/// separately for light and dark.
enum Theme {
    /// Selected items and the main action. A desaturated slate blue, not the system's bright blue.
    static let accent = dynamic(dark: (0.44, 0.58, 0.72), light: (0.29, 0.42, 0.54))
    /// Healthy and finished.
    static let ok = dynamic(dark: (0.50, 0.66, 0.56), light: (0.31, 0.50, 0.39))
    /// Needs attention: a missing permission, a paused feature.
    static let warn = dynamic(dark: (0.83, 0.66, 0.37), light: (0.60, 0.44, 0.12))
    /// Failed or destructive.
    static let danger = dynamic(dark: (0.82, 0.47, 0.42), light: (0.69, 0.29, 0.24))

    private static func dynamic(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            var c = isDark ? dark : light
            if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { c = ContrastBoost.adjust(c, dark: isDark) }
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

/// A row's icon: one quiet colour, not a coloured tile.
struct RowIcon: View {
    let symbol: String
    var active = false

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(active ? Theme.accent : Color.secondary)
            .frame(width: 24, height: 24)
    }
}
