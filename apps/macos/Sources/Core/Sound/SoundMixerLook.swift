import Foundation

/// How roomy the mixer's rows are.
enum SoundDensity: String, CaseIterable, Identifiable {
    case compact, comfortable, spacious
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Space above and below a row's content.
    var rowPadding: Double {
        switch self {
        case .compact: return 6
        case .comfortable: return 10
        case .spacious: return 15
        }
    }

    /// Whether a row shows its chips (output, boost, effects) or leaves them to the row's menu.
    var showsChips: Bool { self != .compact }

    /// What was saved, or the older compact switch if the density was never chosen.
    static func resolve(stored: String?, legacyCompact: Bool) -> SoundDensity {
        if let stored, let density = SoundDensity(rawValue: stored) { return density }
        return legacyCompact ? .compact : .comfortable
    }
}

/// Light, dark, or whatever the Mac is set to.
enum SoundAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    static func resolve(_ stored: String?) -> SoundAppearance { stored.flatMap(SoundAppearance.init(rawValue:)) ?? .dark }
}

/// Finding apps and devices by typing a few letters of their names.
enum SoundSearch {
    /// True when every word typed appears somewhere in `text`, ignoring case, accents and spacing.
    static func matches(_ query: String, in text: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        guard !words.isEmpty else { return true }
        let haystack = fold(text)
        return words.allSatisfy { haystack.contains($0) }
    }

    static func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
}

/// How far one key press, one scroll or one held key moves a volume.
enum VolumeStep {
    static let choices: [Double] = [0.01, 0.02, 0.05, 0.10]
    static let standard = 0.05

    /// The step to use: with hold-to-ramp on, a key held down moves faster the longer it is held (twice as fast after eight repeats,
    /// three times after sixteen, and never more than four times).
    static func step(base: Double, repeats: Int, ramp: Bool) -> Double {
        guard ramp else { return base }
        return base * min(1 + Double(max(repeats, 0) / 8), 4)
    }

    /// The volume after one step up or down, kept inside `range` and on a whole percent.
    static func next(_ value: Double, up: Bool, step: Double, range: ClosedRange<Double> = 0...1) -> Double {
        let moved = value + (up ? step : -step)
        return min(max((moved * 100).rounded() / 100, range.lowerBound), range.upperBound)
    }

    /// The change in volume for one scroll event. A trackpad sends many small deltas and a wheel a few big ones; Option makes it finer.
    static func scrollChange(delta: Double, precise: Bool, fine: Bool, inverted: Bool) -> Double {
        let change = delta * (precise ? 0.0025 : 0.02) * (fine ? 0.25 : 1)
        return inverted ? -change : change
    }
}
