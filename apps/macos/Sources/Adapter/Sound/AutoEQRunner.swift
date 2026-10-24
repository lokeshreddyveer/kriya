import CoreAudio
import Foundation

/// Headphone correction that follows the output. A correction is fitted once from an AutoEq file (or a curve) and saved against the
/// device; whenever that device becomes the output it is put on "All sound", and it comes off again when the output moves to a device
/// that has none, putting back exactly what "All sound" had before. Nothing is sent anywhere: files are read from this Mac.
/// What the runner changes: the settings of "All sound". The audio engine in the app; a stand-in in tests.
protocol SystemSoundTarget: AnyObject {
    func systemSettings() -> AppAudioSettings
    func updateSystem(_ change: (inout AppAudioSettings) -> Void)
}

extension AppAudioEngine: SystemSoundTarget {
    func systemSettings() -> AppAudioSettings { current(Self.systemKey) }
    func updateSystem(_ change: (inout AppAudioSettings) -> Void) { update(Self.systemKey, change) }
}

final class AutoEQRunner: ObservableObject {
    static let shared = AutoEQRunner()
    private static let key = "soundAutoEQ.v1"
    private static let appliedKey = "soundAutoEQ.applied.v1"

    typealias Stored = AutoEQ.Saved

    /// Corrections by device unique name.
    @Published private(set) var stored: [String: Stored]
    /// The device whose correction is on now, and what "All sound" had before it. Kept across launches, so a correction that was on when
    /// Kriya quit is still taken off properly.
    @Published private(set) var applied: AutoEQ.Applied?
    weak var target: SystemSoundTarget?
    private var started = false
    private let defaults: UserDefaults
    private let currentOutput: () -> String?
    private let watchesDevices: Bool
    private var listener: (AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)?

    var appliedTo: String? { applied?.uid }

    /// `currentOutput` says which device is the output now; `watchesDevices` is off in tests, which change the output by hand.
    init(defaults: UserDefaults = .standard, currentOutput: @escaping () -> String? = { AudioControl.shared.defaultOutputUID() }, watchesDevices: Bool = true) {
        self.defaults = defaults
        self.currentOutput = currentOutput
        self.watchesDevices = watchesDevices
        stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Stored].self, from: $0) } ?? [:]
        applied = defaults.data(forKey: Self.appliedKey).flatMap { try? JSONDecoder().decode(AutoEQ.Applied.self, from: $0) }
    }

    var isActive: Bool { started }

    func start() {
        guard !started else { return }
        started = true
        if watchesDevices {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.follow() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block) == noErr { listener = (address, block) }
        }
        follow()
    }

    func stop() {
        guard started else { return }
        started = false
        if var (address, block) = listener { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block) }
        listener = nil
        clear()
    }

    func set(_ correction: AutoEQ.Correction, name: String, for uid: String) {
        stored[uid] = Stored(name: name, correction: correction)
        persist()
        follow(force: appliedTo == uid)
    }

    func remove(_ uid: String) {
        stored[uid] = nil
        persist()
        follow()
    }

    /// Puts a whole set of corrections in place (a Quick Config being applied) and brings the equaliser in line with the output.
    func replaceAll(_ next: [String: Stored]) {
        stored = next
        persist()
        follow(force: true)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
    }

    private func saveApplied() {
        if let applied, let data = try? JSONEncoder().encode(applied) { defaults.set(data, forKey: Self.appliedKey) }
        else { defaults.removeObject(forKey: Self.appliedKey) }
    }

    /// Looks at the current output and puts the matching correction on, or takes ours off. `force` puts the correction on again with its
    /// current numbers even if it is already on.
    func follow(force: Bool = false) {
        guard started, let target else { return }
        let current = currentOutput()
        var plan = AutoEQ.plan(applied: force ? nil : appliedTo, current: current, corrections: stored.mapValues(\.correction))
        if plan == nil, force, appliedTo != nil { plan = .clear }   // forced, and this output has no correction (any more)
        switch plan {
        case .apply(let uid, let correction)?:
            // What "All sound" had is kept once, when the first correction goes on; going from one corrected device to another keeps it.
            let before = applied?.previous ?? Self.snapshot(target.systemSettings())
            target.updateSystem { $0.eq = correction.gains; $0.preamp = correction.preampDB; $0.effectsBypassed = false }
            applied = AutoEQ.Applied(uid: uid, previous: before)
            saveApplied()
            FeatureActivity.shared.changed("soundDevices", "Headphone correction on for \(stored[uid]?.name ?? "this device")")
        case .clear?: clear()
        case nil: break
        }
    }

    static func snapshot(_ s: AppAudioSettings) -> AutoEQ.Previous { AutoEQ.Previous(eq: s.eq, preamp: s.preamp, effectsBypassed: s.effectsBypassed) }

    private func clear() {
        guard let applied, let target else { self.applied = nil; saveApplied(); return }
        let before = applied.previous
        target.updateSystem { $0.eq = before.eq; $0.preamp = before.preamp; $0.effectsBypassed = before.effectsBypassed }
        self.applied = nil
        saveApplied()
    }

    // MARK: Reading a file

    enum Failure: LocalizedError {
        case unreadable, notRecognised
        var errorDescription: String? {
            switch self {
            case .unreadable: return "That file could not be read."
            case .notRecognised: return "That does not look like an AutoEq ParametricEQ or GraphicEQ file."
            }
        }
    }

    /// Fits a correction from the text of an AutoEq file: a ParametricEQ.txt, or a GraphicEQ.txt.
    static func correction(fromFileText text: String) throws -> AutoEQ.Correction {
        if let profile = AutoEQ.parseParametric(text) { return AutoEQ.correction(for: profile) }
        if let curve = AutoEQ.parseGraphic(text) { return AutoEQ.correction(forCurve: curve) }
        throw Failure.notRecognised
    }
}
