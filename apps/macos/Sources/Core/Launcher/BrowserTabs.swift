import Foundation

/// An open tab in a browser, found by asking the browser (AppleScript). Only the title and address are read.
struct BrowserTab: Equatable, Identifiable {
    enum Browser: String, CaseIterable {
        case safari = "Safari"
        case chrome = "Google Chrome"
        case brave = "Brave Browser"
        case edge = "Microsoft Edge"
        case arc = "Arc"

        var bundleID: String {
            switch self {
            case .safari: return "com.apple.Safari"
            case .chrome: return "com.google.Chrome"
            case .brave: return "com.brave.Browser"
            case .edge: return "com.microsoft.edgemac"
            case .arc: return "company.thebrowser.Browser"
            }
        }

        var isSafari: Bool { self == .safari }
    }

    let browser: Browser
    let window: Int
    let tab: Int
    let title: String
    let url: String
    var id: String { "\(browser.rawValue):\(window):\(tab)" }
}

enum BrowserTabs {
    private static let separator = "\u{1F}"

    /// The AppleScript that lists a browser's tabs as lines of `window ␟ tab ␟ title ␟ address`.
    static func listScript(for browser: BrowserTab.Browser) -> String {
        let titleProperty = browser.isSafari ? "name of t" : "title of t"
        return """
        set out to ""
        tell application "\(browser.rawValue)"
            set windowCount to count of windows
            repeat with w from 1 to windowCount
                set tabCount to count of tabs of window w
                repeat with i from 1 to tabCount
                    set t to tab i of window w
                    set out to out & w & "\(separator)" & i & "\(separator)" & (\(titleProperty)) & "\(separator)" & (URL of t) & linefeed
                end repeat
            end repeat
        end tell
        return out
        """
    }

    /// The AppleScript that brings a tab to the front.
    static func activateScript(for tab: BrowserTab) -> String {
        let name = tab.browser.rawValue
        if tab.browser.isSafari {
            return """
            tell application "\(name)"
                activate
                set current tab of window \(tab.window) to tab \(tab.tab) of window \(tab.window)
                set index of window \(tab.window) to 1
            end tell
            """
        }
        return """
        tell application "\(name)"
            activate
            set active tab index of window \(tab.window) to \(tab.tab)
            set index of window \(tab.window) to 1
        end tell
        """
    }

    /// The tabs in a browser's answer. Lines that are not in the expected shape are ignored.
    static func parse(_ output: String, browser: BrowserTab.Browser) -> [BrowserTab] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.components(separatedBy: separator)
            guard parts.count >= 4, let window = Int(parts[0]), let tab = Int(parts[1]), window > 0, tab > 0 else { return nil }
            let address = parts[3...].joined(separator: separator).trimmingCharacters(in: .whitespaces)
            // Only pages: not the browser's own start page or a blank tab with no address.
            guard address.hasPrefix("http://") || address.hasPrefix("https://") || address.hasPrefix("file://") else { return nil }
            return BrowserTab(browser: browser, window: window, tab: tab, title: parts[2].trimmingCharacters(in: .whitespaces), url: address)
        }
    }

    /// The tabs whose title or address contains every word typed.
    static func matching(_ tabs: [BrowserTab], query: String, limit: Int = 8) -> [BrowserTab] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let found = tabs.filter { tab in
            let haystack = (tab.title + " " + tab.url).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        return Array(found.prefix(limit))
    }
}
