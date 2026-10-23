import Foundation

/// What `pmset -g assertions` says is holding the Mac awake, read into a list a person can follow.
enum PowerAssertions {
    struct Assertion: Equatable, Identifiable {
        let pid: Int
        let process: String
        /// For example PreventUserIdleSystemSleep.
        let kind: String
        let name: String
        let heldFor: String
        var id: String { "\(pid)|\(kind)|\(name)" }

        /// In plain words.
        var effect: String {
            switch kind {
            case "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion": return "Keeps the Mac awake"
            case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion": return "Keeps the screen on"
            case "PreventDiskIdle", "NoDiskIdleAssertion": return "Keeps the disk spinning"
            case "NetworkClientActive": return "Network in use"
            case "BackgroundTask", "ApplePushServiceTask": return "Background work"
            default: return kind
            }
        }

        var holdsMacAwake: Bool {
            ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion", "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"].contains(kind)
        }
    }

    static func parse(_ output: String) -> [Assertion] {
        guard let regex = try? NSRegularExpression(pattern: #"pid (\d+)\((.*?)\): \[0x[0-9a-fA-F]+\] (\d+:\d+:\d+) (\w+) named: "(.*)""#) else { return [] }
        var list: [Assertion] = []
        for line in output.split(separator: "\n") {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges == 6 else { continue }
            func part(_ i: Int) -> String { Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
            guard let pid = Int(part(1)) else { continue }
            list.append(Assertion(pid: pid, process: part(2), kind: part(4), name: part(5), heldFor: part(3)))
        }
        return list
    }

    /// Only the ones that stop the Mac or its screen sleeping, without repeats.
    static func awakeHolders(_ list: [Assertion]) -> [Assertion] {
        var seen = Set<String>()
        return list.filter { $0.holdsMacAwake && seen.insert($0.id).inserted }
    }

    /// One line a person can read: "caffeinate and Zoom are keeping this Mac awake."
    static func summary(_ list: [Assertion]) -> String {
        let names = Array(Set(awakeHolders(list).map(\.process))).sorted()
        switch names.count {
        case 0: return "Nothing is keeping this Mac awake."
        case 1: return "\(names[0]) is keeping this Mac awake."
        case 2: return "\(names[0]) and \(names[1]) are keeping this Mac awake."
        default: return "\(names.prefix(2).joined(separator: ", ")) and \(names.count - 2) more are keeping this Mac awake."
        }
    }
}
