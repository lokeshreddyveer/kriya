import Foundation

/// What the system says about an app's signature and whether Apple has checked it, read from `codesign` and `spctl` output.
struct AppTrust: Equatable {
    enum Level: Equatable { case appStore, notarized, developerID, adhoc, unsigned, rejected, unknown }

    let level: Level
    let signer: String?
    let teamID: String?

    var title: String {
        switch level {
        case .appStore: return "Mac App Store"
        case .notarized: return "Signed and notarized"
        case .developerID: return "Signed by a developer"
        case .adhoc: return "Signed only on the developer's own Mac"
        case .unsigned: return "Not signed"
        case .rejected: return "macOS would refuse to open it"
        case .unknown: return "Could not tell"
        }
    }

    var isConcerning: Bool { [.unsigned, .rejected, .adhoc].contains(level) }

    static func parse(codesign: String, spctl: String) -> AppTrust {
        let signer = value(after: "Authority=", in: codesign, firstOnly: true)
        let team = value(after: "TeamIdentifier=", in: codesign, firstOnly: true).flatMap { $0 == "not set" ? nil : $0 }
        let lower = spctl.lowercased()
        if codesign.contains("not signed at all") { return AppTrust(level: .unsigned, signer: nil, teamID: nil) }
        if lower.contains("rejected") { return AppTrust(level: .rejected, signer: signer, teamID: team) }
        if lower.contains("source=mac app store") { return AppTrust(level: .appStore, signer: signer, teamID: team) }
        if lower.contains("source=notarized developer id") { return AppTrust(level: .notarized, signer: signer, teamID: team) }
        if lower.contains("source=developer id") { return AppTrust(level: .developerID, signer: signer, teamID: team) }
        if codesign.contains("Signature=adhoc") || team == nil && signer == nil && codesign.contains("flags=") { return AppTrust(level: .adhoc, signer: nil, teamID: nil) }
        if lower.contains("accepted") { return AppTrust(level: .developerID, signer: signer, teamID: team) }
        return AppTrust(level: .unknown, signer: signer, teamID: team)
    }

    private static func value(after key: String, in text: String, firstOnly: Bool) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix(key) { return String(line.dropFirst(key.count)) }
        return nil
    }
}

/// Why Homebrew might not be found or might misbehave, from facts about this Mac.
enum HomebrewDiagnosis {
    static func lines(appleSilicon: Bool, foundAt: String?, optHomebrewExists: Bool, usrLocalExists: Bool, pathVariable: String) -> [String] {
        var out: [String] = []
        let expected = appleSilicon ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"
        if let foundAt {
            out.append("Homebrew found at \(foundAt).")
            if foundAt != expected { out.append("On this \(appleSilicon ? "Apple silicon" : "Intel") Mac Homebrew normally lives at \(expected); this one is somewhere else, which can mean it was installed for the other kind of Mac.") }
        } else {
            out.append("Homebrew was not found in the places Kriya looks.")
            if optHomebrewExists && !appleSilicon { out.append("/opt/homebrew exists, which is where Homebrew installs on Apple silicon, but this is an Intel Mac.") }
            if usrLocalExists && appleSilicon { out.append("/usr/local exists but Homebrew is not in it; an Apple silicon Mac uses /opt/homebrew.") }
            out.append("Install it from brew.sh, then open this tab again.")
        }
        if let foundAt {
            let bin = (foundAt as NSString).deletingLastPathComponent
            if !pathVariable.split(separator: ":").contains(Substring(bin)) { out.append("\(bin) is not on the PATH that apps start with. Kriya runs Homebrew by its full path, so it still works, but Terminal may need a line added to its shell profile.") }
        }
        return out
    }
}
