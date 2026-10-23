import Foundation

/// One key press as it was recorded.
struct RecordedKey: Equatable {
    var keyCode: UInt16
    var modifiers: UInt64
    /// Seconds since the recording began.
    var time: TimeInterval
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

    static func action(from recorded: [RecordedKey]) -> Action? {
        let keys = cleaned(recorded)
        guard !keys.isEmpty else { return nil }
        if keys.count == 1 { return .keyPress(keyCode: keys[0].keyCode, modifiers: keys[0].modifiers) }
        return .sequence(steps: keys.map { .keyPress(keyCode: $0.keyCode, modifiers: $0.modifiers) }, delayMs: delay(for: keys))
    }

    /// "3 keys: ⌘C, ⇥, ⌘V" for the recorder's list.
    static func summary(_ recorded: [RecordedKey]) -> String {
        let keys = cleaned(recorded)
        let names = keys.prefix(6).map { KeyNames.describe(keyCode: $0.keyCode, modifiers: $0.modifiers) }.joined(separator: ", ")
        return "\(keys.count) key\(keys.count == 1 ? "" : "s")" + (keys.isEmpty ? "" : ": " + names + (keys.count > 6 ? ", …" : ""))
    }
}
