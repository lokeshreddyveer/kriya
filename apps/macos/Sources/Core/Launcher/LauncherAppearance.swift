import Foundation

/// How the launcher looks: one of a few ready-made themes, and an accent colour for the highlight.
enum LauncherTheme: String, CaseIterable, Identifiable {
    case glass, darkGlass, lightGlass, midnight, paper, graphite
    var id: String { rawValue }

    enum Appearance { case system, dark, light }
    enum Background: Equatable {
        case glass
        /// A flat colour, as red, green and blue from 0 to 1.
        case solid(r: Double, g: Double, b: Double)
    }

    var title: String {
        switch self {
        case .glass: return "Glass (follows the system)"
        case .darkGlass: return "Dark Glass"
        case .lightGlass: return "Light Glass"
        case .midnight: return "Midnight"
        case .paper: return "Paper"
        case .graphite: return "Graphite"
        }
    }

    var appearance: Appearance {
        switch self {
        case .glass: return .system
        case .darkGlass, .midnight, .graphite: return .dark
        case .lightGlass, .paper: return .light
        }
    }

    var background: Background {
        switch self {
        case .glass, .darkGlass, .lightGlass: return .glass
        case .midnight: return .solid(r: 0.06, g: 0.08, b: 0.16)
        case .paper: return .solid(r: 0.98, g: 0.96, b: 0.93)
        case .graphite: return .solid(r: 0.15, g: 0.15, b: 0.16)
        }
    }

    private static let key = "launcherTheme"
    static var current: LauncherTheme {
        get { UserDefaults.standard.string(forKey: key).flatMap(LauncherTheme.init(rawValue:)) ?? .glass }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// The colour of the highlighted row. Neutral keeps the soft grey-white of the system's own search.
enum LauncherAccent: String, CaseIterable, Identifiable {
    case neutral, blue, purple, pink, orange, green
    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    /// Red, green and blue from 0 to 1, or nil for neutral.
    var rgb: (r: Double, g: Double, b: Double)? {
        switch self {
        case .neutral: return nil
        case .blue: return (0.20, 0.50, 1.00)
        case .purple: return (0.62, 0.38, 0.95)
        case .pink: return (0.96, 0.32, 0.58)
        case .orange: return (1.00, 0.58, 0.16)
        case .green: return (0.20, 0.74, 0.46)
        }
    }

    private static let key = "launcherAccent"
    static var current: LauncherAccent {
        get { UserDefaults.standard.string(forKey: key).flatMap(LauncherAccent.init(rawValue:)) ?? .neutral }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
