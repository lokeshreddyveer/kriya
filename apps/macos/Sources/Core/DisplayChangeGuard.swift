import Foundation

/// A display change that is put back unless the person says to keep it. A resolution the display cannot show leaves a black screen
/// nobody can click on, so the answer has to be "keep", and silence means "put it back".
struct DisplayChangeGuard: Equatable {
    /// How long the person has to answer.
    static let seconds = 10

    let label: String
    let deadline: Date

    init(label: String, now: Date = Date(), seconds: Int = DisplayChangeGuard.seconds) {
        self.label = label
        deadline = now.addingTimeInterval(TimeInterval(seconds))
    }

    func secondsLeft(now: Date = Date()) -> Int { max(Int(deadline.timeIntervalSince(now).rounded(.up)), 0) }

    func isExpired(now: Date = Date()) -> Bool { now >= deadline }
}
