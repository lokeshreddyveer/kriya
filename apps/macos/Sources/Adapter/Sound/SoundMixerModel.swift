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

    private let audio = AudioControl.shared
    private var timer: Timer?
    private var viewers = 0

    func viewerAppeared() {
        viewers += 1
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func viewerGone() {
        viewers = max(viewers - 1, 0)
        if viewers == 0 { timer?.invalidate(); timer = nil }
    }

    func refresh() {
        let devices = audio.devices()
        outputs = devices.filter(\.isOutput)
        inputs = devices.filter(\.isInput)
        if let out = audio.defaultDevice(input: false) {
            outputID = out
            let v = audio.volume(of: out)
            hasVolume = v != nil
            volume = v ?? 0
            muted = audio.isMuted(out) ?? false
            let rates = audio.sampleRates(of: out)
            sampleRates = rates
            sampleRate = audio.sampleRate(of: out) ?? 0
            let b = audio.balance(of: out)
            hasBalance = b != nil
            balance = b ?? 0.5
        }
        if let input = audio.defaultDevice(input: true) {
            inputID = input
            let v = audio.volume(of: input, input: true)
            hasInputVolume = v != nil
            inputVolume = v ?? 0
            micMuted = audio.isMuted(input, input: true) ?? false
        }
    }

    func setVolume(_ v: Double) {
        guard audio.setVolume(v, of: outputID) else { return }
        volume = v
        if muted { _ = audio.setMuted(false, device: outputID); muted = false }
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

    func setInputVolume(_ v: Double) { if audio.setVolume(v, of: inputID, input: true) { inputVolume = v } }
    func toggleMicMute() { if audio.setMuted(!micMuted, device: inputID, input: true) { micMuted.toggle() } }
    func setSampleRate(_ r: Double) { if audio.setSampleRate(r, of: outputID) { sampleRate = r } }
    func setBalance(_ b: Double) { if audio.setBalance(b, of: outputID) { balance = b } }
}
