import AppKit
import SwiftUI

/// What the tester shows for an event. Kept apart from the view so it can be checked.
enum InputTesterFormat {
    /// An event line with the device it seems to come from, when that is known.
    static func attributed(_ line: String, device: String?) -> String {
        guard let device, !device.isEmpty else { return line }
        return "\(line)  ·  \(device)"
    }

    static func button(_ number: Int, down: Bool) -> String {
        "\(MouseButtons.name(UInt32(max(number, 0)))) \(down ? "pressed" : "released")"
    }

    static func scroll(deltaX: Double, deltaY: Double, smooth: Bool) -> String {
        let kind = smooth ? "Smooth scroll" : "Wheel"
        func part(_ value: Double, _ positive: String, _ negative: String) -> String? {
            guard abs(value) > 0.001 else { return nil }
            return "\(value > 0 ? positive : negative) \(String(format: "%.1f", abs(value)))"
        }
        let parts = [part(deltaY, "up", "down"), part(deltaX, "left", "right")].compactMap { $0 }
        return "\(kind): " + (parts.isEmpty ? "no movement" : parts.joined(separator: ", "))
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> String {
        var bits: UInt64 = 0
        if flags.contains(.shift) { bits |= KeyModifiers.shift }
        if flags.contains(.control) { bits |= KeyModifiers.control }
        if flags.contains(.option) { bits |= KeyModifiers.option }
        if flags.contains(.command) { bits |= KeyModifiers.command }
        if flags.contains(.function) { bits |= KeyModifiers.function }
        let held = KeyModifiers.glyphs(for: bits)
        return held.isEmpty ? "No modifier keys held" : "Held: \(held)" + (flags.contains(.capsLock) ? " and Caps Lock" : "")
    }

    static func key(_ code: UInt16, flags: NSEvent.ModifierFlags) -> String {
        var bits: UInt64 = 0
        if flags.contains(.shift) { bits |= KeyModifiers.shift }
        if flags.contains(.control) { bits |= KeyModifiers.control }
        if flags.contains(.option) { bits |= KeyModifiers.option }
        if flags.contains(.command) { bits |= KeyModifiers.command }
        return "Key: " + KeyNames.describe(keyCode: code, modifiers: bits) + "  (code \(code))"
    }
}

/// A square that reports what the mouse and keyboard do over it. It sees only what happens inside it while it has focus,
/// shows the latest few events, and keeps nothing.
struct InputTester: NSViewRepresentable {
    let onEvent: (String) -> Void

    func makeNSView(context: Context) -> TesterView {
        let view = TesterView()
        view.onEvent = onEvent
        return view
    }

    func updateNSView(_ view: TesterView, context: Context) { view.onEvent = onEvent }

    final class TesterView: NSView {
        var onEvent: (String) -> Void = { _ in }
        private var tracking: NSTrackingArea?

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onEvent(InputTesterFormat.button(0, down: true)) }
        override func mouseUp(with event: NSEvent) { onEvent(InputTesterFormat.button(0, down: false)) }
        override func rightMouseDown(with event: NSEvent) { onEvent(InputTesterFormat.button(1, down: true)) }
        override func rightMouseUp(with event: NSEvent) { onEvent(InputTesterFormat.button(1, down: false)) }
        override func otherMouseDown(with event: NSEvent) { onEvent(InputTesterFormat.button(event.buttonNumber, down: true)) }
        override func otherMouseUp(with event: NSEvent) { onEvent(InputTesterFormat.button(event.buttonNumber, down: false)) }
        override func scrollWheel(with event: NSEvent) {
            onEvent(InputTesterFormat.scroll(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY), smooth: event.hasPreciseScrollingDeltas))
        }
        override func flagsChanged(with event: NSEvent) { onEvent(InputTesterFormat.modifiers(event.modifierFlags)) }
        override func keyDown(with event: NSEvent) { onEvent(InputTesterFormat.key(event.keyCode, flags: event.modifierFlags)) }
    }
}
