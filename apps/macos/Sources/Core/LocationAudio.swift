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

    /// The nearest enabled place the position is inside, or nil. A position with nonsense values matches nothing.
    static func place(at latitude: Double, _ longitude: Double, in rules: [PlaceRule]) -> PlaceRule? {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return rules.filter { $0.enabled && !$0.outputContains.isEmpty }
            .map { ($0, distance(latitude, longitude, $0.latitude, $0.longitude)) }
            .filter { $0.1 <= min(max($0.0.radius, radiusRange.lowerBound), radiusRange.upperBound) }
            .min { $0.1 < $1.1 }?.0
    }
}
