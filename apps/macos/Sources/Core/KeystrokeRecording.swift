import Foundation

/// One key press as it was recorded.
struct RecordedKey: Equatable {
    var keyCode: UInt16
    var modifiers: UInt64
    /// Seconds since the recording began.
    var time: TimeInterval
}

/// One mouse click as it was recorded. `inWindow` says the point is measured from the top-left of the window that was in
/// front, so replaying it still hits the same control after the window has moved.
struct RecordedClick: Equatable {
    var x: Int32
    var y: Int32
    var right: Bool
    var count: UInt8
    var inWindow: Bool
    var time: TimeInterval

    /// Turns a screen point into what is saved, given the front window's frame (top-left origin) if there was one.
    static func make(point: CGPoint, window: CGRect?, right: Bool, count: Int, time: TimeInterval) -> RecordedClick {
        if let window, window.contains(point) {
            return RecordedClick(x: Int32((point.x - window.minX).rounded()), y: Int32((point.y - window.minY).rounded()), right: right,
                                 count: UInt8(min(max(count, 1), 3)), inWindow: true, time: time)
        }
        return RecordedClick(x: Int32(point.x.rounded()), y: Int32(point.y.rounded()), right: right, count: UInt8(min(max(count, 1), 3)), inWindow: false, time: time)
    }

    var action: Action { .click(x: x, y: y, button: right ? 1 : 0, count: count, inWindow: inWindow) }
}

/// Turns recorded key presses into a saved action: one key press, or a sequence of them with the pauses kept roughly as they
/// were. Mouse movement, clicks and what was typed as text are not recorded, only keys.
enum KeystrokeRecording {
    static let maxSteps = 50

    /// Key codes that make no sense as steps: the modifier keys themselves.
    private static let modifierCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// The recorded keys, without modifier-only presses and cut to what a sequence can hold.
    static func cleaned(_ keys: [RecordedKey]) -> [RecordedKey] {
        Array(keys.filter { !modifierCodes.contains($0.keyCode) }.prefix(maxSteps))
    }

    /// The pause between steps: the middle of the gaps that were recorded, kept between 30 ms and 1.5 s, so a slow typist and
    /// a fast one both replay at about their own pace.
    static func delay(for keys: [RecordedKey]) -> UInt32 {
        let gaps = zip(keys.dropFirst(), keys).map { max(0, $0.time - $1.time) }.sorted()
        guard !gaps.isEmpty else { return 80 }
        let middle = gaps[gaps.count / 2]
        return UInt32(min(max(middle * 1000, 30), 1500).rounded())
    }

    static func action(from recorded: [RecordedKey]) -> Action? { action(keys: recorded, clicks: []) }

    /// Keys and clicks together, in the order they happened.
    static func action(keys recorded: [RecordedKey], clicks: [RecordedClick]) -> Action? {
        let keys = cleaned(recorded)
        var timed: [(time: TimeInterval, action: Action)] = keys.map { ($0.time, .keyPress(keyCode: $0.keyCode, modifiers: $0.modifiers)) }
        timed += clicks.map { ($0.time, $0.action) }
        timed.sort { $0.time < $1.time }
        timed = Array(timed.prefix(maxSteps))
        guard !timed.isEmpty else { return nil }
        if timed.count == 1 { return timed[0].action }
        let gaps = zip(timed.dropFirst(), timed).map { max(0, $0.time - $1.time) }.sorted()
        let middle = gaps.isEmpty ? 0.08 : gaps[gaps.count / 2]
        return .sequence(steps: timed.map(\.action), delayMs: UInt32(min(max(middle * 1000, 30), 1500).rounded()))
    }

    /// "3 keys: ⌘C, ⇥, ⌘V" for the recorder's list.
    static func summary(_ recorded: [RecordedKey], clicks: [RecordedClick] = []) -> String {
        let keys = cleaned(recorded)
        if !clicks.isEmpty {
            let k = keys.count
            return "\(k) key\(k == 1 ? "" : "s") and \(clicks.count) click\(clicks.count == 1 ? "" : "s")"
        }
        let names = keys.prefix(6).map { KeyNames.describe(keyCode: $0.keyCode, modifiers: $0.modifiers) }.joined(separator: ", ")
        return "\(keys.count) key\(keys.count == 1 ? "" : "s")" + (keys.isEmpty ? "" : ": " + names + (keys.count > 6 ? ", …" : ""))
    }
}
