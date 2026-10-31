import AppKit

/// Sends gestures the only ways macOS allows an app: phased scroll events, the system's scroll-to-zoom, and its own shortcut keys.
/// It does not forge the private gesture events a real trackpad produces, so three-finger and four-finger gestures are their system
/// shortcuts (Spaces, Mission Control, App Exposé), which must be on in System Settings › Keyboard › Shortcuts and Trackpad.
final class SystemTrackpadEmitter: TrackpadEventEmitter {
    private let scroller = PhasedScrollPoster()
    private var carry = ScrollCarry()
    private let lock = NSLock()

    func emit(_ intent: GestureIntent, at point: CGPoint) {
        switch intent.kind {
        case .twoFingerSwipe:
            swipe(intent, at: point)
        case .fourFingerPinch(let zoomIn):
            guard intent.phase == .changed || intent.phase == .began else { return }
            // A pinch is a zoom while it is held; its size is the drag's.
            let amount = zoomIn ? max(abs(intent.dx), abs(intent.dy)) : -max(abs(intent.dx), abs(intent.dy))
            if amount != 0 { scroller.zoom(amount * 0.2, flags: [], location: point) }
        case .threeFingerSwipe(let direction):
            guard intent.phase == .began else { return }
            switch direction {
            case .left: key(123, .maskControl)
            case .right: key(124, .maskControl)
            case .up: open("/System/Applications/Mission Control.app")
            case .down: key(125, .maskControl)
            }
        case .commandTab:
            if intent.phase == .began { key(48, .maskCommand) }
        case .missionControl:
            if intent.phase == .began { open("/System/Applications/Mission Control.app") }
        case .appExpose:
            if intent.phase == .began { key(125, .maskControl) }
        case .rotate:
            break
        }
    }

    private func swipe(_ intent: GestureIntent, at point: CGPoint) {
        let phase: ScrollPhase
        switch intent.phase {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        }
        let ends = phase == .ended || phase == .cancelled
        lock.lock()
        let (ix, iy) = intent.phase == .began ? (0, 0) : carry.take(dx: intent.dx, dy: intent.dy, flush: ends)
        lock.unlock()
        scroller.post(dx: ix, dy: iy, frame: ScrollFrame(dx: Double(ix), dy: Double(iy), phase: phase, momentum: .none), flags: [], location: point)
    }

    private func open(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

    private func key(_ code: CGKeyCode, _ flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }
}
