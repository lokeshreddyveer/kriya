import AppKit

/// ⌘C twice in quick succession adds the new copy under the one before, instead of replacing it. Off until turned on in the
/// Clipboard settings. It only looks at when ⌘C was pressed, never at what was typed, and it works on text only.
final class ClipboardMerger {
    static let enabledKey = "clipboardMergeCopies"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private let events: EventMonitor
    private let monitor: ClipboardMonitor
    private var token: EventMonitor.Token?
    private let toast = Toast()
    /// What was on the clipboard when the first ⌘C was pressed, and when it was.
    private var before: String?
    private var firstAt: Date?
    private var watching = false

    init(events: EventMonitor, monitor: ClipboardMonitor) {
        self.events = events
        self.monitor = monitor
    }

    func start() {
        guard token == nil else { return }
        token = events.subscribe(owner: "clipboard.merge", events: [.keyDown], mode: .listenOnly) { [weak self] _, event in
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let mods = KeyModifiers.bits(from: event.flags) & ~KeyModifiers.function
            guard code == 8, mods == KeyModifiers.command, event.getIntegerValueField(.keyboardEventAutorepeat) == 0, ClipboardMerger.isEnabled else { return .passThrough }
            DispatchQueue.main.async { self?.copyPressed() }
            return .passThrough
        }
    }

    func stop() {
        if let token { events.unsubscribe(token) }
        token = nil
    }

    private func copyPressed() {
        let now = Date()
        if ClipboardMerge.isDoubleTap(first: firstAt, second: now), let before {
            firstAt = nil
            mergeWhenCopied(previous: before)
            return
        }
        firstAt = now
        before = NSPasteboard.general.string(forType: .string)
    }

    /// Waits a moment for the second copy to land, then replaces it with both.
    private func mergeWhenCopied(previous: String) {
        guard !watching else { return }
        watching = true
        let start = NSPasteboard.general.changeCount
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] timer in
            tries += 1
            guard let self else { timer.invalidate(); return }
            let board = NSPasteboard.general
            if board.changeCount != start, let new = board.string(forType: .string) {
                timer.invalidate()
                self.watching = false
                if let merged = ClipboardMerge.merge(previous: previous, new: new) {
                    board.clearContents()
                    board.setString(merged, forType: .string)
                    self.monitor.ignore(changeCount: board.changeCount)
                    self.toast.show("Added to the earlier copy")
                }
            } else if tries > 12 {
                timer.invalidate()
                self.watching = false
            }
        }
    }
}
