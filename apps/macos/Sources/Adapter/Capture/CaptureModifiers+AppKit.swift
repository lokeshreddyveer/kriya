import AppKit

extension CaptureModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var m: CaptureModifiers = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.control) { m.insert(.control) }
        self = m
    }

    /// The keys held right now.
    static var current: CaptureModifiers { CaptureModifiers(NSEvent.modifierFlags) }
}
