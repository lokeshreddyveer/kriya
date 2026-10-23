import Foundation

/// What `spctl` and `codesign` say about the installed app, in words.
struct CodeSignInfo: Equatable {
    enum Verdict: Equatable { case notarized, developerID, signedOnly, unsigned, unknown }
    var verdict: Verdict
    var team: String?
    var authority: String?

    var title: String {
        switch verdict {
        case .notarized: return "Signed and notarized by Apple"
        case .developerID: return "Signed with a Developer ID (not notarized)"
        case .signedOnly: return "Signed for development only"
        case .unsigned: return "Not signed"
        case .unknown: return "Could not be checked"
        }
    }

    static func parse(spctl: String, codesign: String) -> CodeSignInfo {
        let lower = spctl.lowercased()
        var verdict = Verdict.unknown
        if lower.contains("source=notarized developer id") { verdict = .notarized }
        else if lower.contains("source=developer id") { verdict = .developerID }
        else if lower.contains("rejected") || lower.contains("no usable signature") { verdict = codesign.contains("Authority=") ? .signedOnly : .unsigned }
        else if lower.contains("accepted") { verdict = .developerID }
        if codesign.contains("code object is not signed at all") { verdict = .unsigned }
        func value(_ key: String) -> String? {
            codesign.split(separator: "\n").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
        }
        let team = value("TeamIdentifier").flatMap { $0 == "not set" ? nil : $0 }
        return CodeSignInfo(verdict: verdict, team: team, authority: value("Authority"))
    }
}

/// The version facts shown in About and put in a report, so a bug report says exactly which build it came from.
struct BuildFacts: Equatable {
    var version: String
    var build: String
    var commit: String
    var architecture: String
    var macOS: String

    var lines: [String] {
        ["Kriya \(version) (build \(build))", "Commit \(commit)", "\(architecture), macOS \(macOS)"]
    }
}
