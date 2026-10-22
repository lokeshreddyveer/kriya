import Foundation

/// Taking what identifies a person out of text before it is shared: their name, where their files are, email addresses,
/// network addresses and anything that looks like a key or token. Used on every support report.
enum SupportScrubber {
    static func scrub(_ text: String, home: String = NSHomeDirectory(), user: String = NSUserName(), computerName: String? = Host.current().localizedName) -> String {
        var out = text
        func replace(_ pattern: String, with template: String, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }

        // Where their files are, and what they call themselves.
        if home.count > 1 { out = out.replacingOccurrences(of: home, with: "~") }
        replace(#"/Users/[^/\s"']+"#, with: "/Users/<user>")
        if user.count >= 3 { out = out.replacingOccurrences(of: user, with: "<user>", options: .caseInsensitive) }
        if let computerName, computerName.count >= 3 { out = out.replacingOccurrences(of: computerName, with: "<this Mac>", options: .caseInsensitive) }

        // Who and where on the network.
        replace(#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, with: "<email>", options: .caseInsensitive)
        replace(#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, with: "<address>")
        replace(#"\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b"#, with: "<hardware address>")
        // Anything after a ? in a web address can carry a login.
        replace(#"(https?://[^\s?#"']+)\?[^\s"']*"#, with: "$1?<removed>")

        // Keys and tokens: a long run of letters and digits with both kinds in it.
        replace(#"\b(?=[A-Za-z0-9_\-]*\d)(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{28,}\b"#, with: "<token>")
        replace(#"\b(?:sk|pk|ghp|gho|ghs|xoxb|xoxp|AKIA|ASIA|AIza|glpat)[-_A-Za-z0-9]{8,}"#, with: "<token>")
        return out
    }
}
