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
    /// Called with the movie once it has been saved, so it can get a quick access card.
    var onSaved: (URL) -> Void = { _ in }

    var isRecording: Bool { recorder.isActive }

    init() {
        recorder.onFinish = { [weak self] result in self?.finished(result) }
    }

    /// What the recording running now was started with, so it can be started over.
    private struct Started {
        var options: RecordingOptions
        var folder: URL
        var namePattern: String?
        var app: String?
        var mode: String
        var target: NSRunningApplication?
    }

    private var last: Started?
    /// A cancel or a start-over is under way: the movie that results is thrown away.
    private var discarding = false
    private var restart: Started?
    private var diskTimer: Timer?
    private let status = RecordingStatusBox()

    func start(_ options: RecordingOptions, into folder: URL, namePattern: String? = nil, app: String? = nil, mode: String = "recording", target: NSRunningApplication? = nil) {
        guard !recorder.isActive else { return }
        let started = Started(options: options, folder: folder, namePattern: namePattern, app: app, mode: mode, target: target)
        last = started
        discarding = false
        let info = RecordingStatus(options: options)
        status.value = info
        let hud = RecordingHUD(recorder: recorder, status: info, onPause: { [weak self] in self?.recorder.togglePause() }, onStop: { [weak self] in self?.recorder.stop() },
                               onRestart: { [weak self] in self?.startOver() }, onCancel: { [weak self] in self?.cancel() })
        self.hud = hud
        hud.show()
        if options.showKeystrokes { keystrokes.show() }
        watchDisk(folder: folder, status: info)
        let begin = {
            let fileName = CaptureNaming.fileName(pattern: namePattern.map { $0.replacingOccurrences(of: "Capture", with: "Recording") } ?? "Kriya Recording {date} {time}", date: Date(), app: app, mode: mode, ext: "mov") {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
            self.recorder.start(options: options, into: folder, excluding: [hud.windowNumber], fileName: fileName, target: target) { [weak self] error in
                guard let self, let error else { return }
                self.tearDown()
                if error is ScreenRecorder.Cancelled {
                    // Stop or cancel pressed during the start is not a failure; a start-over begins again.
                    if let again = self.restart {
                        self.restart = nil
                        self.start(again.options, into: again.folder, namePattern: again.namePattern, app: again.app, mode: again.mode, target: again.target)
                        return
                    }
                    self.toast.show("Recording cancelled.")
                } else {
                    self.toast.show(error.localizedDescription, isError: true)
                }
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

    /// Ends the recording and throws it away.
    func cancel() {
        discarding = true
        restart = nil
        recorder.stop()
    }

    /// Throws this recording away and starts another with the same choices.
    func startOver() {
        guard let last else { return }
        discarding = true
        restart = last
        recorder.stop()
    }

    /// Checks the room on the disk every couple of seconds: a warning in the strip when it is getting short, and the recording is
    /// stopped and saved while there is still room to save it when it is nearly gone.
    private func watchDisk(folder: URL, status info: RecordingStatus) {
        diskTimer?.invalidate()
        diskTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self, weak info] _ in
            guard let self, let info, let free = RecordingDisk.freeBytes(at: folder) else { return }
            switch RecordingDisk.level(freeBytes: free) {
            case .fine: if info.diskWarning != nil { info.diskWarning = nil }
            case .low: info.diskWarning = "Disk space is low: \(RecordingDisk.describe(freeBytes: free)) left"
            case .critical:
                info.diskWarning = "Disk is nearly full: saving now"
                self.toast.show("The disk is nearly full, so the recording was stopped and saved.", isError: true)
                self.recorder.stop()
                self.diskTimer?.invalidate()
            }
        }
    }

    func togglePause() { recorder.togglePause() }
    func stop() { recorder.stop() }

    private func finished(_ result: Result<URL, Error>) {
        tearDown()
        if discarding {
            discarding = false
            if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
            if let again = restart {
                restart = nil
                toast.show("Starting over…")
                start(again.options, into: again.folder, namePattern: again.namePattern, app: again.app, mode: again.mode, target: again.target)
                return
            }
            toast.show("Recording cancelled.")
            onEnd()
            return
        }
        switch result {
        case .success(let url):
            toast.show("Recording saved as \(url.lastPathComponent)")
            // With the card turned off for recordings, the file is shown in Finder instead.
            if QuickAccessStore.settings.shows(recording: true) { onSaved(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .failure(let error):
            toast.show(error.localizedDescription, isError: true)
        }
        onEnd()
    }

    private func tearDown() {
        diskTimer?.invalidate()
        diskTimer = nil
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

/// Holds the strip's status between the start of a recording and its end.
final class RecordingStatusBox {
    var value: RecordingStatus?
}
