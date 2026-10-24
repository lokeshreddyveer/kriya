import Foundation

/// Where "Open Page" for an update should go. An app's update feed is XML for machines, so it is never opened in a browser; the
/// page is the best human address the feed or the app gives, in this order: the new version's own page, its release notes, its
/// download, a page worked out from where the feed lives (GitHub releases, the developer's site), and last the App Store or nothing.
enum UpdateLinks {
    struct Item {
        var link: URL?
        var releaseNotes: URL?
        var download: URL?
    }

    /// The page to open for an app update found in a feed, or nil when nothing safe and useful can be worked out.
    static func page(for item: Item, feed: URL, appHomepage: URL? = nil) -> URL? {
        for candidate in [item.link, item.releaseNotes] {
            if let url = web(candidate), !looksLikeFeed(url) { return url }
        }
        if let github = githubReleases(from: feed) { return github }
        if let url = web(item.download), !looksLikeFeed(url) { return url }
        if let home = web(appHomepage) { return home }
        return siteRoot(of: feed)
    }

    /// Only http and https are ever opened (never a file, an app or a custom scheme from a feed).
    static func web(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host?.isEmpty == false else { return nil }
        return url
    }

    /// A machine-readable feed (`appcast.xml`, `.rss`, `.atom`, `.json`, `latest-mac.yml`) is not a page to show a person.
    static func looksLikeFeed(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return ["appcast", ".xml", ".rss", ".atom", ".json", ".yml", ".yaml", "feed"].contains { path.contains($0) }
    }

    /// `https://github.com/owner/repo/releases/latest` for a feed that lives on GitHub (raw files, releases, Pages), else nil.
    static func githubReleases(from feed: URL) -> URL? {
        let host = (feed.host ?? "").lowercased()
        let parts = feed.path.split(separator: "/").map(String.init)
        if host == "github.com" || host == "raw.githubusercontent.com", parts.count >= 2 {
            return URL(string: "https://github.com/\(parts[0])/\(parts[1])/releases/latest")
        }
        // owner.github.io/repo/appcast.xml
        if host.hasSuffix(".github.io"), let owner = host.split(separator: ".").first, let repo = parts.first, !repo.contains(".") {
            return URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")
        }
        return nil
    }

    /// The front page of the site the feed is on, as the last resort: `https://example.com/`.
    static func siteRoot(of feed: URL) -> URL? {
        guard let host = feed.host, web(feed) != nil else { return nil }
        // A feed served from a download or hosting service has no page of its own to send a person to.
        let hosts = ["s3.amazonaws.com", "amazonaws.com", "cloudfront.net", "githubusercontent.com", "storage.googleapis.com", "dl.dropboxusercontent.com"]
        if hosts.contains(where: { host.hasSuffix($0) }) { return nil }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = "/"
        return parts.url
    }

    /// An App Store address that opens the app's own page in the App Store (`macappstore://`), from the store's `https` address.
    static func appStoreURL(fromStorePage page: String) -> URL? {
        // Only the App Store's own hosts: not any address that merely ends in apple.com.
        guard var parts = URLComponents(string: page), parts.scheme == "https", let host = parts.host?.lowercased(),
              ["apps.apple.com", "itunes.apple.com"].contains(host) else { return nil }
        parts.scheme = "macappstore"
        parts.query = nil
        return parts.url
    }

    /// Reads an iTunes lookup answer: the store's version and page for the app.
    static func storeEntry(fromLookup data: Data) -> (version: String, page: String)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]], let first = results.first,
              let version = first["version"] as? String, let page = first["trackViewUrl"] as? String, !version.isEmpty else { return nil }
        return (version, page)
    }
}
