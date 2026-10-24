import Foundation

/// A short, honest summary of how the sound is doing: what is slowing it down and what has gone wrong. The delays are the ones the
/// devices report plus one buffer of Kriya's own processing; they are estimates, not a measurement of the whole path to the ear.
enum SoundHealth {
    struct Report: Equatable {
        enum Level: Equatable { case good, noticeable, problem }
        var level: Level
        var headline: String
    }

    /// Delay above this is something a person can hear against a picture or while playing along.
    static let noticeableMilliseconds = 60.0
    /// Above this it is clearly late.
    static let badMilliseconds = 150.0

    static func report(problems: Int, slowestMilliseconds: Double, slowestName: String?) -> Report {
        if problems > 0 {
            return Report(level: .problem, headline: problems == 1 ? "1 app could not be changed" : "\(problems) apps could not be changed")
        }
        if slowestMilliseconds >= badMilliseconds {
            return Report(level: .problem, headline: "\(slowestName ?? "A device") reports about \(Int(slowestMilliseconds.rounded())) ms of delay")
        }
        if slowestMilliseconds >= noticeableMilliseconds {
            return Report(level: .noticeable, headline: "\(slowestName ?? "A device") reports about \(Int(slowestMilliseconds.rounded())) ms of delay")
        }
        return Report(level: .good, headline: "Everything is running normally")
    }

    /// The delay Kriya's own processing adds for an app: one buffer, at the device's sample rate. Nil if either is unknown.
    static func processingMilliseconds(bufferFrames: Int, sampleRate: Double) -> Double? {
        guard bufferFrames > 0, sampleRate > 0 else { return nil }
        return Double(bufferFrames) / sampleRate * 1000
    }
}
