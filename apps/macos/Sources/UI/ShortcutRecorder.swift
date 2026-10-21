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

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        field.onChange = { shortcut = $0 }
        return field
    }

    func updateNSView(_ field: RecorderField, context: Context) {
        field.onChange = { shortcut = $0 }
        field.shortcut = shortcut
    }
}

final class RecorderField: NSView {
    var onChange: ((RecordedShortcut?) -> Void)?
    var shortcut: RecordedShortcut? { didSet { needsDisplay = true } }
    private var recording = false { didSet { needsDisplay = true } }

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
        if recording {
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
