import AppKit
import Combine
import CoreAudio

/// What the sound mixer shows about this Mac's own output and input, kept fresh while a window shows it.
final class SoundMixerModel: ObservableObject {
    @Published private(set) var volume = 0.0
    @Published private(set) var muted = false
    @Published private(set) var hasVolume = false
    @Published private(set) var outputs: [AudioDevice] = []
    @Published private(set) var inputs: [AudioDevice] = []
    @Published private(set) var outputID = AudioDeviceID(0)
    @Published private(set) var inputID = AudioDeviceID(0)
    @Published private(set) var inputVolume = 0.0
    @Published private(set) var hasInputVolume = false
    @Published private(set) var micMuted = false
    @Published private(set) var sampleRates: [Double]?
    @Published private(set) var sampleRate = 0.0
    @Published private(set) var balance = 0.5
    @Published private(set) var hasBalance = false
    /// Where alerts and other sound effects play, and how loud.
    @Published private(set) var effectsID = AudioDeviceID(0)
    @Published private(set) var effectsVolume = 1.0

    private let audio = AudioControl.shared
    private var timer: Timer?
    private var viewers = 0

    func viewerAppeared() {
        viewers += 1
        refresh()
        refreshEffectsVolume()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func viewerGone() {
        viewers = max(viewers - 1, 0)
        if viewers == 0 { timer?.invalidate(); timer = nil }
    }

    /// Everything `refresh` reads from Core Audio, gathered away from the main thread: listing devices and reading each one's settings
    /// takes tens of milliseconds on some outputs (Bluetooth, HDMI), which on the main thread stalled a slider being dragged.
    private struct Snapshot {
        var outputs: [AudioDevice] = [], inputs: [AudioDevice] = []
        var output: (id: AudioDeviceID, volume: Double?, muted: Bool, rates: [Double]?, rate: Double, balance: Double?)?
        var effectsID: AudioDeviceID?
        var input: (id: AudioDeviceID, volume: Double?, muted: Bool)?
    }

    private func gather() -> Snapshot {
        var s = Snapshot()
        let devices = audio.devices()
        s.outputs = devices.filter(\.isOutput)
        s.inputs = devices.filter(\.isInput)
        if let out = audio.defaultDevice(input: false) {
            s.output = (out, audio.volume(of: out), audio.isMuted(out) ?? false, audio.sampleRates(of: out), audio.sampleRate(of: out) ?? 0, audio.balance(of: out))
        }
        s.effectsID = audio.defaultSystemOutputDevice()
        if let input = audio.defaultDevice(input: true) { s.input = (input, audio.volume(of: input, input: true), audio.isMuted(input, input: true) ?? false) }
        return s
    }

    /// While a slider is being dragged, what the device says is not copied back over what the slider shows, so the thumb does not jump.
    private var adjustingUntil = Date.distantPast
    private var adjusting: Bool { Date() < adjustingUntil }

    private func apply(_ s: Snapshot) {
        if s.outputs != outputs { outputs = s.outputs }
        if s.inputs != inputs { inputs = s.inputs }
        if let out = s.output {
            if out.id != outputID { outputID = out.id }
            if hasVolume != (out.volume != nil) { hasVolume = out.volume != nil }
            if !adjusting {
                if volume != (out.volume ?? 0) { volume = out.volume ?? 0 }
                if muted != out.muted { muted = out.muted }
            }
            if sampleRates != out.rates { sampleRates = out.rates }
            if sampleRate != out.rate { sampleRate = out.rate }
            if hasBalance != (out.balance != nil) { hasBalance = out.balance != nil }
            if balance != (out.balance ?? 0.5) { balance = out.balance ?? 0.5 }
        }
        if let effects = s.effectsID, effects != effectsID { effectsID = effects }
        if let input = s.input {
            if input.id != inputID { inputID = input.id }
            if hasInputVolume != (input.volume != nil) { hasInputVolume = input.volume != nil }
            if !adjusting, inputVolume != (input.volume ?? 0) { inputVolume = input.volume ?? 0 }
            if micMuted != input.muted { micMuted = input.muted }
        }
    }

    private let readQueue = DispatchQueue(label: "app.kriya.sound.read", qos: .userInitiated)
    private var refreshing = false

    /// Reads the devices in the background and shows the answer when it arrives. A read already under way is not started again.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        readQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.gather()
            DispatchQueue.main.async { self.apply(snapshot); self.refreshing = false }
        }
    }

    /// The same, now, on this thread: for a window that is drawn straight afterwards.
    func refreshNow() { apply(gather()) }

    private var lastTick = Date.distantPast

    /// A quiet tick as the volume moves, if the person asked for one (like the Mac's own volume feedback).
    private func tick() {
        guard UserDefaults.standard.bool(forKey: "soundVolumeFeedback"), Date().timeIntervalSince(lastTick) > 0.12 else { return }
        lastTick = Date()
        NSSound(named: "Tink")?.play()
    }

    // MARK: Volume writes
    // A slider produces many values a second and a device can take a while to accept each. The slider shows its own value at once, the
    // newest value is the only one that waits to be written, and the writing happens off the main thread.

    private let writeQueue = DispatchQueue(label: "app.kriya.sound.write", qos: .userInteractive)
    private let pendingLock = NSLock()
    private var pendingOutput: (device: AudioDeviceID, level: Double)?
    private var pendingInput: (device: AudioDeviceID, level: Double)?

    private func write(output: Bool, device: AudioDeviceID, level: Double) {
        adjustingUntil = Date().addingTimeInterval(0.6)
        pendingLock.lock()
        if output { pendingOutput = (device, level) } else { pendingInput = (device, level) }
        pendingLock.unlock()
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            let job = output ? self.pendingOutput : self.pendingInput
            if output { self.pendingOutput = nil } else { self.pendingInput = nil }
            self.pendingLock.unlock()
            guard let job else { return }   // a newer write already took it
            let ok = self.audio.setVolume(job.level, of: job.device, input: !output)
            if output, ok, self.mutedOnWrite { _ = self.audio.setMuted(false, device: job.device) }
            if !ok { DispatchQueue.main.async { self.adjustingUntil = .distantPast; self.refresh() } }
        }
    }

    /// Whether the output was muted when the person started moving the slider; moving it unmutes.
    private var mutedOnWrite = false

    func setVolume(_ v: Double) {
        volume = v
        mutedOnWrite = muted
        if muted { muted = false }
        tick()
        write(output: true, device: outputID, level: v)
    }

    func toggleMute() { if audio.setMuted(!muted, device: outputID) { muted.toggle() } }

    func chooseOutput(_ id: AudioDeviceID) {
        guard let device = outputs.first(where: { $0.id == id }), audio.setDefault(device) else { return }
        refresh()
    }

    func chooseInput(_ id: AudioDeviceID) {
        guard let device = inputs.first(where: { $0.id == id }), audio.setDefault(device) else { return }
        refresh()
    }

    /// Reading the alert volume runs a small script, so it is read when a window opens, not every second.
    func refreshEffectsVolume() {
        DispatchQueue.global(qos: .utility).async { [audio] in
            let v = audio.alertVolume()
            DispatchQueue.main.async { if let v { self.effectsVolume = v } }
        }
    }

    func setEffectsVolume(_ v: Double) {
        effectsVolume = v
        DispatchQueue.global(qos: .utility).async { [audio] in _ = audio.setAlertVolume(v) }
    }

    func chooseEffectsOutput(_ id: AudioDeviceID) {
        guard let device = outputs.first(where: { $0.id == id }), audio.setDefaultSystemOutput(device) else { return }
        refresh()
    }

    func setInputVolume(_ v: Double) {
        inputVolume = v
        write(output: false, device: inputID, level: v)
    }
    func toggleMicMute() { if audio.setMuted(!micMuted, device: inputID, input: true) { micMuted.toggle() } }
    func setSampleRate(_ r: Double) { if audio.setSampleRate(r, of: outputID) { sampleRate = r } }
    func setBalance(_ b: Double) { if audio.setBalance(b, of: outputID) { balance = b } }
}
