import Foundation

/// What is listening on a port, from `lsof -F pc` output ("p123" then "cnode").
struct PortOwner: Equatable {
    let pid: Int32
    let name: String

    static func parse(_ output: String) -> [PortOwner] {
        var found: [PortOwner] = []
        var pid: Int32?
        for line in output.split(separator: "\n") {
            guard let first = line.first else { continue }
            let rest = String(line.dropFirst())
            if first == "p" { pid = Int32(rest) }
            else if first == "c", let pid, !found.contains(where: { $0.pid == pid }) { found.append(PortOwner(pid: pid, name: rest)) }
        }
        return found
    }
}

/// Words typed in the launcher that ask for a system job.
enum SystemRequest: Equatable {
    case kill(String)
    case port(Int)
    case wifi(Bool?)
    case quitOthers
    case eject
    case hiddenFiles

    static func parse(_ text: String) -> SystemRequest? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        let words = t.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        let rest = words.dropFirst().joined(separator: " ")
        switch first {
        case "kill", "killall":
            return rest.isEmpty ? nil : .kill(rest)
        case "port", "whatsonport", "lsof":
            guard let n = Int(rest), (1...65_535).contains(n) else { return nil }
            return .port(n)
        case "wifi", "wi-fi":
            switch rest { case "on": return .wifi(true); case "off": return .wifi(false); case "": return .wifi(nil); default: return nil }
        case "quit", "close":
            return ["all", "all apps", "others", "all others", "all other apps", "everything"].contains(rest) ? .quitOthers : nil
        case "eject":
            return rest.isEmpty || rest == "all" || rest == "disks" ? .eject : nil
        case "hidden", "dotfiles":
            return rest.isEmpty || rest == "files" ? .hiddenFiles : nil
        default: return nil
        }
    }
}

/// Warns once when a mouse, keyboard or trackpad runs low, and again only after it has been charged.
enum LowBattery {
    static let warnAt = 15
    static let rearmAt = 30

    /// Names to warn about now, and the new set of names already warned about.
    static func check(_ readings: [BatteryReading], warned: Set<String>) -> (warn: [String], warned: Set<String>) {
        var next = warned, warn: [String] = []
        for reading in readings {
            if reading.percent <= warnAt, !reading.charging {
                if next.insert(reading.name).inserted { warn.append(reading.name) }
            } else if reading.percent >= rearmAt || reading.charging {
                next.remove(reading.name)
            }
        }
        return (warn, next)
    }
}
