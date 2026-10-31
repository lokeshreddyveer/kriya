import Foundation

/// Which displays to darken while recording. Only the displays that are not being recorded: darkening the one being recorded would
/// darken the video, and with a single display there is nothing else to darken.
enum RecordingDim {
    /// `all` are the displays connected; `recorded` is the one being recorded, or nil when that is not known (then nothing is dimmed:
    /// a guess could darken the recording).
    static func displaysToDim(all: [UInt32], recorded: UInt32?) -> [UInt32] {
        guard let recorded, all.contains(recorded), all.count > 1 else { return [] }
        return all.filter { $0 != recorded }
    }
}
