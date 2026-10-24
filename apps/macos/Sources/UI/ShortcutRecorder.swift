import AppKit
import SwiftUI

struct RecordedShortcut: Equatable {
    var keyCode: UInt16
    var modifiers: UInt64

    var title: String { KeyNames.describe(keyCode: keyCode, modifiers: modifiers) }
}

/// A box that records a key combination: click it, press the keys. Escape cancels, Delete clears.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: RecordedShortcut?
    /// For a shortcut that works anywhere: a key alone (or with only ⇧) is refused with a hint instead of being dropped without a word.
    /// Function keys are fine on their own.
    var needsModifier = false

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        field.onChange = { shortcut = $0 }
        field.needsModifier = needsModifier
        return field
    }

    func updateNSView(_ field: RecorderField, context: Context) {
        field.onChange = { shortcut = $0 }
        field.shortcut = shortcut
        field.needsModifier = needsModifier
    }
}

final class RecorderField: NSView {
    var onChange: ((RecordedShortcut?) -> Void)?
    var shortcut: RecordedShortcut? { didSet { needsDisplay = true } }
    var needsModifier = false
    private var recording = false { didSet { needsDisplay = true } }
    /// Why the last key was not taken, shown in the field for a moment.
    private var hint: String? { didSet { needsDisplay = true } }

    /// F1–F20, which are fine as a shortcut on their own.
    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 200, height: 28) }
    // Without a baseline, a row that lines its label and field up by baseline drops the field below the label. This
    // puts the field's text on the same line as the label beside it.
    override var firstBaselineOffsetFromTop: CGFloat { 19 }
    override var lastBaselineOffsetFromBottom: CGFloat { 9 }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    // Command combinations arrive as key equivalents; while recording they belong to the recorder.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        capture(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if recording { capture(event) } else { super.keyDown(with: event) }
    }

    private func capture(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isEmpty {
            if event.keyCode == 53 {            // Escape: cancel
                finish()
                return
            }
            if event.keyCode == 51 {            // Delete: clear
                shortcut = nil
                onChange?(nil)
                finish()
                return
            }
        }
        let hasPrimary = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
        if needsModifier, !hasPrimary, !Self.functionKeys.contains(event.keyCode) {
            hint = "Hold ⌘, ⌃ or ⌥ with the key"
            NSSound.beep()
            let shown = hint
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in if self?.hint == shown { self?.hint = nil } }
            return   // still recording
        }
        hint = nil
        let recorded = RecordedShortcut(keyCode: event.keyCode, modifiers: KeyModifiers.bits(from: flags))
        shortcut = recorded
        onChange?(recorded)
        finish()
    }

    private func finish() {
        recording = false
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 2 : 1
        path.stroke()

        let text: String
        let color: NSColor
        if recording, let hint {
            text = hint
            color = .systemRed
        } else if recording {
            text = "Press the keys…"
            color = .controlAccentColor
        } else if let shortcut {
            text = shortcut.title
            color = .labelColor
        } else {
            text = "Click to record"
            color = .secondaryLabelColor
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}
