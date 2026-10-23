import AppKit
import Combine

/// Starts, pauses and stops a screen recording, and shows the things that go with it: the control strip, the keys and the
/// camera. The capture service hands it the person's choices.
final class RecordingController: ObservableObject {
    let recorder = ScreenRecorder()
    let mirror = LiveMirror()

    private let keystrokes = KeystrokeOverlay()
    private let camera = WebcamBubble()
    private var hud: RecordingHUD?
    private var pausedSub: AnyCancellable?
    private let toast = Toast()

    /// Called on the main thread once a recording has ended, either way. The capture service uses it to allow the next capture.
    var onEnd: () -> Void = {}

    var isRecording: Bool { recorder.isActive }

    init() {
        recorder.onFinish = { [weak self] result in self?.finished(result) }
    }

    func start(_ options: RecordingOptions, into folder: URL) {
        guard !recorder.isActive else { return }
        let hud = RecordingHUD(recorder: recorder, onPause: { [weak self] in self?.recorder.togglePause() }, onStop: { [weak self] in self?.recorder.stop() })
        self.hud = hud
        hud.show()
        if options.showKeystrokes { keystrokes.show() }
        let begin = {
            self.recorder.start(options: options, into: folder, excluding: [hud.windowNumber]) { [weak self] error in
                guard let self, let error else { return }
                self.tearDown()
                self.toast.show(error.localizedDescription, isError: true)
                self.onEnd()
            }
        }
        if options.webcam {
            camera.show(cameraID: options.cameraID) { [weak self] problem in
                if let problem { self?.toast.show(problem, isError: true) }
                // The recording goes ahead without the camera rather than not at all.
                begin()
            }
        } else {
            begin()
        }
    }

    func togglePause() { recorder.togglePause() }
    func stop() { recorder.stop() }

    private func finished(_ result: Result<URL, Error>) {
        tearDown()
        switch result {
        case .success(let url):
            toast.show("Recording saved as \(url.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .failure(let error):
            toast.show(error.localizedDescription, isError: true)
        }
        onEnd()
    }

    private func tearDown() {
        hud?.hide()
        hud = nil
        keystrokes.hide()
        camera.hide()
    }

    func showMirror() {
        if mirror.isShowing { mirror.close(); return }
        mirror.show { [weak self] problem in
            if let problem { self?.toast.show(problem, isError: true) }
        }
    }
}
