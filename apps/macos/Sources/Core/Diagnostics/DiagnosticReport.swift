import Foundation

/// One block of text to paste into a bug report: build, permissions, features and conflicts, with personal details taken out.
enum BugReportText {
    struct Section: Equatable {
        let title: String
        let lines: [String]
    }

    static func assemble(_ sections: [Section], generated: Date, scrub: (String) -> String = { SupportScrubber.scrub($0) }) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var out = ["Kriya report, \(f.string(from: generated))"]
        for section in sections where !section.lines.isEmpty {
            out.append("")
            out.append("== \(section.title) ==")
            out += section.lines
        }
        return scrub(out.joined(separator: "\n"))
    }

    /// "Accessibility: allowed" lines.
    static func permissionLines(_ items: [(name: String, granted: Bool)]) -> [String] {
        items.map { "\($0.name): \($0.granted ? "allowed" : "not allowed")" }
    }

    /// Only the parts that are on and working, then the ones that are on but not, so a report starts with what is wrong.
    static func featureLines(_ items: [(name: String, enabled: Bool, state: String)]) -> [String] {
        let problems = items.filter { $0.enabled && $0.state != "Running" }.map { "\($0.name): on, \($0.state.lowercased())" }
        let ok = items.filter { $0.enabled && $0.state == "Running" }.map { "\($0.name): running" }
        let off = items.filter { !$0.enabled }.map(\.name)
        return problems + ok + (off.isEmpty ? [] : ["Off: " + off.joined(separator: ", ")])
    }
}
