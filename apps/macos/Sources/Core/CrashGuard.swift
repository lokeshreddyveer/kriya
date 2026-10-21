import AppKit
import Combine

/// Crash recovery and safe mode. The decisions are made in the core; this class reports the app's lifecycle to it
/// and shows the result. In safe mode no feature starts, so a feature that keeps crashing cannot lock the person out.
final class CrashGuard: ObservableObject {
    @Published private(set) var isSafeMode = false
    @Published private(set) var safeModeReason: String?
    /// A one-time message for the person, such as which feature was switched off after a crash.
    @Published var notice: String?
    private(set) var suspectFeature: FeatureId?

    private let core: KriyaCore

    init(core: KriyaCore) {
        self.core = core
    }

    /// Call once at launch, before any feature starts. Holding Option while launching, or `--safe-mode`, forces safe mode.
    func beginSession(forceSafeMode: Bool = false) {
        let forced = forceSafeMode || CommandLine.arguments.contains("--safe-mode") || NSEvent.modifierFlags.contains(.option)
        let outcome = core.beginSession(
            now: SystemInfo.nowSeconds,
            debuggerAttached: SystemInfo.isDebuggerAttached(),
            forceSafeMode: forced
        )
        isSafeMode = outcome.safeMode
        safeModeReason = outcome.safeModeReason
        suspectFeature = outcome.suspectFeature
        if outcome.previousSessionCrashed {
            Log.warning("Session", "The previous run ended unexpectedly" + (outcome.suspectFeature.map { " while starting \($0.title)" } ?? ""))
        }
        if outcome.safeMode { Log.warning("Session", "Safe mode: \(outcome.safeModeReason ?? "")") }
    }

    func markStarting(_ feature: FeatureId) { core.markFeatureStarting(feature: feature) }
    func markStarted() { core.markFeatureStarted() }
    func endSession() { core.endSession() }

    func leaveSafeMode() {
        core.leaveSafeMode()
        isSafeMode = false
        safeModeReason = nil
        Log.info("Session", "Left safe mode")
    }

    /// Restarts the app with every feature held off.
    func restartInSafeMode() {
        SystemInfo.relaunch(arguments: ["--safe-mode"])
    }
}
