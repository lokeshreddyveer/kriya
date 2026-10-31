import AppKit

/// Running the capture commands that were added after the first ones. Each is checked against what is true now first; when it cannot
/// run, the person is told why in one sentence, and nothing else happens.
extension ScreenCaptureService {
    /// Runs one command. Call it on the main thread.
    func perform(_ command: CaptureCommand) {
        if case .disabled(let reason) = command.availability(in: commandState()) {
            toast.show(reason, isError: true)
            return
        }
        // A capture that starts from an area: Kriya's selector, and then what the command says instead of the settings.
        if let forced = command.forced {
            capture(.region, action: .normal, forced: forced)
            return
        }
        switch command.id {
        case CaptureCommandID.selfTimer:
            // The timer set under Settings, or five seconds when none is set, for this one capture.
            oneShotTimer = max(CaptureExtraSettings.modes.timer.seconds, 5)
            capture(.region, action: .normal)
            // Refused before it began (an app that is never captured, say): the timer is not kept for the next capture.
            if !isCapturing { oneShotTimer = nil }
        case CaptureCommandID.historyOpen:
            CaptureOverlay.shared.actions.openHistory()
        case CaptureCommandID.restoreLast:
            CaptureOverlay.shared.restoreLast()
        case CaptureCommandID.desktopIcons:
            toggleDesktopIcons()
        case CaptureCommandID.cardsToggle:
            CaptureOverlay.shared.toggleHidden()
        case CaptureCommandID.cardsSaveAll:
            CaptureOverlay.shared.saveAll()
        case CaptureCommandID.cardsCloseAll:
            CaptureOverlay.shared.dismissAll()
        case CaptureCommandID.scrollStart:
            capture(.window, action: .scroll)
        case CaptureCommandID.scrollStop:
            if let session = scrollSession { Task { @MainActor in session.stop() } }
        case CaptureCommandID.recordingRestart:
            recording.startOver()
        case CaptureCommandID.cameraFullscreen:
            recording.toggleCameraFullscreen()
        case CaptureCommandID.pinsToggle:
            PinnedShots.shared.toggleVisibility()
        case CaptureCommandID.pinsCloseAll:
            PinnedShots.shared.closeAll()
        case CaptureCommandID.pinsChoose:
            PinnedShots.shared.chooseAndPin()
        default:
            toast.show("Kriya does not know how to run “\(command.title)”.", isError: true)
        }
    }

    /// Hides the desktop icons or shows them again. Finder restarts, which takes a moment, so it is done off the main thread.
    private func toggleDesktopIcons() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let shown = FocusSessionController.toggleDesktopIcons()
            DispatchQueue.main.async { self?.toast.show(shown ? "Desktop icons are showing again." : "Desktop icons are hidden. Run the command again to bring them back.") }
        }
    }
}
