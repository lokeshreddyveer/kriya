import Foundation

/// Files used lately, from Spotlight's `mdfind -attr kMDItemLastUsedDate` output (each line is a path, then the date).
enum RecentFiles {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    /// The newest files worth showing, newest first. Library folders, app bundles, hidden items and the like are left out.
    static func parse(_ output: String, home: String, limit: Int) -> [URL] {
        var found: [(path: String, date: Date)] = []
        for line in output.split(separator: "\n") {
            guard let marker = line.range(of: "   kMDItemLastUsedDate = ") else { continue }
            let path = String(line[..<marker.lowerBound])
            guard path.hasPrefix("/"), LauncherFileSearch.isWorthShowing(path, home: home),
                  !path.contains(".app/"), !path.hasSuffix(".app"),
                  let date = formatter.date(from: String(line[marker.upperBound...]).trimmingCharacters(in: .whitespaces)) else { continue }
            found.append((path, date))
        }
        return found.sorted { $0.date > $1.date }.prefix(limit).map { URL(fileURLWithPath: $0.path) }
    }
}
