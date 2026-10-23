import Foundation

enum DisplayInsight {
    /// What macOS reports about a screen's high dynamic range. Both numbers are the largest brightness multiple the screen can show.
    static func hdr(potential: Double, current: Double) -> String {
        if potential <= 1.0 { return "No HDR support" }
        return current > 1.0 ? "HDR content is showing now" : "HDR capable; showing standard content now"
    }

    /// What a monitor answered when asked, in words, for the DDC test.
    static func ddcReport(name: String, brightness: DDC.Reading?, input: DDC.Reading?) -> String {
        var parts: [String] = []
        if let b = brightness { parts.append("brightness works (now \(DDC.percent(fromRaw: b.current, maximum: b.maximum))%)") } else { parts.append("brightness did not answer") }
        if let i = input { parts.append("input switching works (input \(i.current))") } else { parts.append("input switching did not answer") }
        return "\(name): " + parts.joined(separator: "; ") + "."
    }

    /// Brightness to put back after wake: only monitors still present, and never 0 (a monitor that wakes dark is not helped by that).
    static func brightnessToRestore(saved: [String: Int], connected: Set<String>) -> [String: Int] {
        saved.filter { connected.contains($0.key) && $0.value > 0 }.mapValues { min($0, 100) }
    }

    /// Displays that appeared or went since the last look, as (name, connected) in a stable order.
    static func changes(before: [String: String], after: [String: String]) -> [(name: String, connected: Bool)] {
        let added = after.filter { before[$0.key] == nil }.map { (name: $0.value, connected: true) }
        let removed = before.filter { after[$0.key] == nil }.map { (name: $0.value, connected: false) }
        return (added + removed).sorted { ($0.name, $0.connected ? 0 : 1) < ($1.name, $1.connected ? 0 : 1) }
    }
}
