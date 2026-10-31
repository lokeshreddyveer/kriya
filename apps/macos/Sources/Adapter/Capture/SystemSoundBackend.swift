import AppKit

extension CaptureSoundPlayer {
    /// The player the app uses, with the Mac's own sound.
    static let shared = CaptureSoundPlayer(backend: SystemSoundBackend())
}

/// Makes the capture sound with the Mac's own sound playback.
final class SystemSoundBackend: CaptureSoundBackend {
    /// macOS's own screenshot sound, which Kriya plays itself so it works with Kriya's own selector too.
    static let systemShutter = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif")

    /// Held while it plays, or it would stop at once.
    private var current: NSSound?

    func play(_ step: CaptureSoundPlan.Step) -> Bool {
        switch step {
        case .custom(let url): return start(file: url)
        case .system: return start(file: Self.systemShutter)
        case .camera: return start(NSSound(data: ShutterSynth.wav()))
        case .beep:
            NSSound.beep()
            return true
        }
    }

    private func start(file url: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return false }
        return start(NSSound(contentsOf: url, byReference: true))
    }

    private func start(_ sound: NSSound?) -> Bool {
        guard let sound else { return false }
        current = sound
        guard sound.play() else { return false }
        // A long file is cut off after a few seconds: a capture sound is a click, not a song.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak sound] in
            if let sound, self?.current === sound { sound.stop() }
        }
        return true
    }
}
