import Foundation

/// Sound levels as the person thinks of them (0 to 100) and as the system keeps them (0 to 1), and the steps between.
enum AudioMath {
    static let step = 0.0625   // one tap of the volume keys on a Mac: sixteen steps

    static func clamp(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 0 }

    /// The level after pressing volume up or down, snapped to the sixteen steps a Mac's own keys use.
    static func stepped(_ level: Double, up: Bool) -> Double {
        let current = clamp(level)
        let index = (current / step).rounded()
        let next = up ? (index * step > current + 1e-9 ? index : index + 1) : (index * step < current - 1e-9 ? index : index - 1)
        return clamp(next * step)
    }

    static func percent(_ level: Double) -> Int { Int((clamp(level) * 100).rounded()) }
    static func level(percent: Int) -> Double { clamp(Double(min(max(percent, 0), 100)) / 100) }

    /// "volume 40", "vol 40%", "volume up": what was asked, or nil.
    enum Request: Equatable { case set(Int), up, down, mute }

    static func request(in text: String) -> Request? {
        let parts = text.trimmingCharacters(in: .whitespaces).lowercased().split(separator: " ").map(String.init)
        guard parts.count == 2, ["volume", "vol"].contains(parts[0]) else { return nil }
        switch parts[1] {
        case "up", "louder": return .up
        case "down", "quieter", "softer": return .down
        case "mute", "off": return .mute
        default:
            let digits = parts[1].hasSuffix("%") ? String(parts[1].dropLast()) : parts[1]
            guard let value = Int(digits), (0...100).contains(value) else { return nil }
            return .set(value)
        }
    }
}
