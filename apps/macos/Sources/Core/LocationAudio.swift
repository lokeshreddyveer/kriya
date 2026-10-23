import Foundation

/// A place, and the sound output to use when the Mac is there.
struct PlaceRule: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var latitude: Double
    var longitude: Double
    /// Metres.
    var radius: Double = 150
    /// Part of the output's name, such as "Studio Display" or "Speakers".
    var outputContains: String
    var enabled = true
    /// Tried in order when the first output is not connected.
    var fallbacks: [String]?
    /// How long the Mac must stay in the place before the output changes. Nil means the usual 60 seconds.
    var dwellSeconds: Double?

    /// The outputs to try, first choice first.
    var outputs: [String] { ([outputContains] + (fallbacks ?? [])).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
}

/// What the place automation has done so far, so it switches once on arrival, waits out a short pass-through, rests after a
/// switch, and leaves the output alone once the person has chosen another by hand.
struct PlaceSwitchState: Equatable {
    var candidateID: String?
    var candidateSince: Date?
    var appliedID: String?
    var lastSwitch: Date?
    var overriddenID: String?
}

enum PlaceSwitcher {
    static let defaultDwell: TimeInterval = 60
    static let cooldown: TimeInterval = 300

    /// The place to switch the output for now, or nil. `outputIsOurs` says whether the output in use is still the one the last
    /// switch chose.
    static func decide(_ state: inout PlaceSwitchState, place: PlaceRule?, now: Date, outputIsOurs: Bool) -> PlaceRule? {
        if place?.id != state.candidateID {
            state.candidateID = place?.id
            state.candidateSince = place == nil ? nil : now
            if place == nil { state.appliedID = nil; state.overriddenID = nil }
            return nil
        }
        guard let place, let since = state.candidateSince else { return nil }
        if state.overriddenID == place.id { return nil }
        if state.appliedID == place.id {
            if !outputIsOurs { state.overriddenID = place.id }
            return nil
        }
        guard now.timeIntervalSince(since) >= (place.dwellSeconds ?? defaultDwell) else { return nil }
        if let last = state.lastSwitch, now.timeIntervalSince(last) < cooldown { return nil }
        state.appliedID = place.id
        state.lastSwitch = now
        return place
    }
}

enum PlaceRules {
    static let limit = 20
    static let radiusRange: ClosedRange<Double> = 50...2000

    /// Metres between two points on the Earth (haversine).
    static func distance(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
        let r = 6_371_000.0
        let p1 = aLat * .pi / 180, p2 = bLat * .pi / 180
        let dp = (bLat - aLat) * .pi / 180, dl = (bLon - aLon) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// How far past its radius the Mac may drift from the place it is in before that place is given up. Stops the output flipping
    /// back and forth when the position wobbles at the edge.
    static let leaveMargin = 1.3
    /// A reading older than this, or less exact than this many metres, is not used.
    static let maxAge: TimeInterval = 120
    static let maxUncertainty = 500.0

    static func isUsable(accuracy: Double, age: TimeInterval) -> Bool {
        accuracy >= 0 && accuracy <= maxUncertainty && age >= -5 && age <= maxAge
    }

    /// Like `place(at:_:in:)`, but the place the Mac is already in is kept until it is clearly outside it.
    static func place(at latitude: Double, _ longitude: Double, in rules: [PlaceRule], current: PlaceRule?) -> PlaceRule? {
        if let current, let still = rules.first(where: { $0.id == current.id && $0.enabled }),
           distance(latitude, longitude, still.latitude, still.longitude) <= min(max(still.radius, radiusRange.lowerBound), radiusRange.upperBound) * leaveMargin {
            return still
        }
        return place(at: latitude, longitude, in: rules)
    }

    /// The nearest enabled place the position is inside, or nil. A position with nonsense values matches nothing.
    static func place(at latitude: Double, _ longitude: Double, in rules: [PlaceRule]) -> PlaceRule? {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return rules.filter { $0.enabled && !$0.outputContains.isEmpty }
            .map { ($0, distance(latitude, longitude, $0.latitude, $0.longitude)) }
            .filter { $0.1 <= min(max($0.0.radius, radiusRange.lowerBound), radiusRange.upperBound) }
            .min { $0.1 < $1.1 }?.0
    }
}
