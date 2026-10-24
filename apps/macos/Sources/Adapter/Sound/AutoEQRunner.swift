import CoreAudio
import Foundation

/// Headphone correction that follows the output. A correction is fitted once from an AutoEq file (or a curve) and saved against the
/// device; whenever that device becomes the output it is put on "All sound", and it comes off again when the output moves to a device
/// that has none. Nothing is sent anywhere: files are read from this Mac, or fetched only when the person asks and Local-only is off.
final class AutoEQRunner: ObservableObject {
    static let shared = AutoEQRunner()
    private static let key = "soundAutoEQ.v1"

    struct Stored: Codable, Equatable {
        var name: String
        var correction: AutoEQ.Correction
    }

    /// Corrections by device unique name.
    @Published private(set) var stored: [String: Stored]
    @Published private(set) var appliedTo: String?
    weak var engine: AppAudioEngine?
    private var started = false
    private var listener: (AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)?

    private init() {
        stored = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Stored].self, from: $0) } ?? [:]
    }

    var isActive: Bool { started }

    func start() {
        guard !started else { return }
        started = true
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.follow() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block) == noErr { listener = (address, block) }
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
        if appliedTo == uid { appliedTo = nil }   // re-applied below with the new numbers
        follow()
    }

    func remove(_ uid: String) {
        stored[uid] = nil
        persist()
        follow()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Looks at the current output and puts the matching correction on, or takes ours off.
    func follow() {
        guard started, let engine else { return }
        let current = AudioControl.shared.defaultOutputUID()
        switch AutoEQ.plan(applied: appliedTo, current: current, corrections: stored.mapValues(\.correction)) {
        case .apply(let uid, let correction)?:
            engine.update(AppAudioEngine.systemKey) { $0.eq = correction.gains; $0.preamp = correction.preampDB; $0.effectsBypassed = false }
            appliedTo = uid
            FeatureActivity.shared.changed("soundDevices", "Headphone correction on for \(stored[uid]?.name ?? "this device")")
        case .clear?: clear()
        case nil: break
        }
    }

    private func clear() {
        guard appliedTo != nil, let engine else { appliedTo = nil; return }
        engine.update(AppAudioEngine.systemKey) { $0.eq = EQPreset.flat.gains; $0.preamp = 0 }
        appliedTo = nil
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
