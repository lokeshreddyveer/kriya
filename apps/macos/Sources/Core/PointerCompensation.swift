import Foundation

// MARK: - Where a polling rate came from

/// How sure a polling rate is. Anything but `declared` is shown as an estimate.
enum PollingRateSource: String, Equatable {
    /// The device said so.
    case declared
    /// Timed on request, by watching its movement reports.
    case measured
    /// Neither: a cautious guess from how it connects.
    case assumed

    var isEstimated: Bool { self != .declared }
    var title: String {
        switch self {
        case .declared: return "from the device"
        case .measured: return "measured"
        case .assumed: return "estimated"
        }
    }
}

struct PollingRateInfo: Equatable {
    var hz: Int
    var source: PollingRateSource

    var isEstimated: Bool { source.isEstimated }

    /// Shown for information only: the rate affects how finely and how often movement is reported, and so latency and how acceleration
    /// behaves, but not how far the pointer travels in total. Nothing here is changed by it.
    var text: String { "\(hz) Hz (\(source.title))" }

    /// The best rate known: one measured now, else the device's own, else a cautious guess. Always some rate; never invented without
    /// being marked as an estimate. A wired mouse is assumed to report at the plain USB rate and a wireless one a little lower, the
    /// lowest common values, so the guess is never higher than the truth.
    static func resolve(declaredHz: Int?, measuredHz: Int?, connection: ConnectionKind) -> PollingRateInfo {
        if let measuredHz, measuredHz > 0 { return PollingRateInfo(hz: measuredHz, source: .measured) }
        if let declaredHz, declaredHz > 0 { return PollingRateInfo(hz: declaredHz, source: .declared) }
        switch connection {
        case .wireless: return PollingRateInfo(hz: 90, source: .assumed)
        default: return PollingRateInfo(hz: 125, source: .assumed)
        }
    }
}

// MARK: - Settings

/// What the person has told Kriya about one mouse. Kriya never reads or changes the mouse's own resolution; this is only what it was
/// told. Off unless switched on, and with no reference chosen it does nothing.
struct DeviceCompensation: Codable, Equatable {
    var enabled = false
    /// This mouse's resolution in counts per inch, as its maker or its own software states it.
    var cpi: Int?
    /// The resolution to bring it towards, chosen by the person. There is no default: no reference, no adjustment.
    var referenceCPI: Int?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, false)
        cpi = (try? c.decodeIfPresent(Int.self, forKey: .cpi)) ?? nil
        referenceCPI = (try? c.decodeIfPresent(Int.self, forKey: .referenceCPI)) ?? nil
    }

    private enum CodingKeys: String, CodingKey { case enabled, cpi, referenceCPI }
}

struct PointerCompensationSettings: Codable, Equatable {
    var devices: [String: DeviceCompensation] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        devices = c.value(.devices, [:])
    }

    private enum CodingKeys: String, CodingKey { case devices }

    subscript(id: String) -> DeviceCompensation {
        get { devices[id] ?? DeviceCompensation() }
        set { devices[id] = newValue == DeviceCompensation() ? nil : newValue }
    }
}

struct PointerCompensationStore {
    static let key = "mouse.pointerCompensation.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var settings: PointerCompensationSettings {
        get { defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(PointerCompensationSettings.self, from: $0) } ?? PointerCompensationSettings() }
        nonmutating set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.key) } }
    }
}

// MARK: - The adjustment

/// A heuristic, not a measurement: it scales the tracking speed Kriya sets for a mouse by the square root of the ratio of two resolutions
/// the person typed in. It does not change the mouse's CPI, and it may not match every sensor or acceleration curve.
enum PointerCompensation {
    static let cpiRange = 100...32_000
    /// The multiplier is never more than this much either way.
    static let multiplierRange = 0.25...2.0
    /// macOS's tracking-speed scale.
    static let trackingRange = 0.0...3.0

    static let label = "Estimated pointer-speed compensation. This does not change the mouse’s CPI and may not match every sensor or acceleration curve."

    enum Cap: Equatable { case none, atLeast, atMost }

    struct Result: Equatable {
        /// The square root of reference ÷ CPI, before the cap.
        var raw: Double
        /// What is used: the raw value held to the allowed range.
        var multiplier: Double
        var cap: Cap
        var cpi: Int
        var reference: Int
        /// The sum, written out with the numbers in it.
        var formula: String {
            String(format: "multiplier = √(reference ÷ mouse) = √(%ld ÷ %ld) = %.3f", reference, cpi, raw)
        }
    }

    /// The working for a mouse, or nil when it cannot be worked out: switched off, either resolution missing, or one out of range.
    static func result(for compensation: DeviceCompensation) -> Result? {
        guard compensation.enabled, let cpi = compensation.cpi, let reference = compensation.referenceCPI,
              cpiRange.contains(cpi), cpiRange.contains(reference) else { return nil }
        let raw = (Double(reference) / Double(cpi)).squareRoot()
        let clamped = min(max(raw, multiplierRange.lowerBound), multiplierRange.upperBound)
        let cap: Cap = raw < multiplierRange.lowerBound ? .atLeast : raw > multiplierRange.upperBound ? .atMost : .none
        return Result(raw: raw, multiplier: clamped, cap: cap, cpi: cpi, reference: reference)
    }

    /// The tracking speed after compensation. Acceleration off (-1) and a speed that is not set by Kriya are left alone, and the result
    /// stays on the system's scale. Without a worked-out multiplier nothing changes.
    static func adjusted(_ tracking: Double, for compensation: DeviceCompensation) -> Double {
        guard tracking >= 0, tracking.isFinite, let result = result(for: compensation) else { return tracking }
        return min(max(tracking * result.multiplier, trackingRange.lowerBound), trackingRange.upperBound)
    }

    /// What to tell the person about the state of the settings, in words.
    static func explanation(_ compensation: DeviceCompensation) -> String {
        guard compensation.enabled else { return "Off. The tracking speed is used as set." }
        guard compensation.cpi != nil else { return "Enter this mouse’s resolution." }
        guard compensation.referenceCPI != nil else { return "Choose the resolution to match." }
        guard let result = result(for: compensation) else { return "Resolutions from \(cpiRange.lowerBound) to \(cpiRange.upperBound) are expected." }
        var text = result.formula + String(format: ", used as ×%.3f", result.multiplier)
        switch result.cap {
        case .atLeast: text += " (held at the lowest allowed, ×\(multiplierRange.lowerBound))"
        case .atMost: text += " (held at the highest allowed, ×\(multiplierRange.upperBound))"
        case .none: break
        }
        return text
    }
}
