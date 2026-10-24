import Foundation

/// How "All sound" and a single app's own settings share the work. An app that has its own tap is left out of the all-sound tap, so its
/// sound is processed once; "All sound" volume and mute then reach it as a master level inside its own processing.
enum SoundMaster {
    /// The gain an app's processing uses: its own volume times the master volume, never more than the most Kriya allows.
    static func gain(app: Double, master: Double, maxVolume: Double) -> Double {
        min(max(app, 0) * max(master, 0), maxVolume)
    }

    static func isMuted(app: Bool, master: Bool) -> Bool { app || master }

    /// The processes the all-sound tap must leave alone: Kriya's own, and every process an app's own tap already handles. Each once,
    /// in a fixed order, so the same set always gives the same answer and an unchanged set is recognised as unchanged.
    static func excludedFromAllSound(own: [UInt32], handledByApps: [[UInt32]]) -> [UInt32] {
        Array(Set(own).union(handledByApps.flatMap { $0 })).sorted()
    }

    /// The timed change on "All sound" (a mute for a while, say) reaches every app's processing as a factor, times the app's own.
    static func temporary(app: Float, master: Float) -> Float { min(max(app, 0), 1) * min(max(master, 0), 1) }
}
