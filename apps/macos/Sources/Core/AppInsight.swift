import Foundation

/// Where an app gets its updates from, worked out from what is inside the app and what Homebrew has installed, never from its name.
enum AppUpdateSource: String, Codable, CaseIterable {
    case appStore, homebrew, sparkle, github, electron, system, iosApp, webApp, direct, unknown

    var title: String {
        switch self {
        case .appStore: return "App Store"
        case .homebrew: return "Homebrew"
        case .sparkle: return "Sparkle"
        case .github: return "GitHub"
        case .electron: return "Electron"
        case .system: return "System"
        case .iosApp: return "iPhone/iPad app"
        case .webApp: return "Web app"
        case .direct: return "Direct download"
        case .unknown: return "Unknown"
        }
    }
}

/// How sure the source is. Verified means the app itself names its update feed or the store receipt is present; detected means a
/// tool Kriya can ask (Homebrew) lists it; inferred means a framework inside it suggests how it updates; unknown means nothing says.
enum SourceConfidence: Int, Codable, Comparable {
    case unknown = 0, inferred, detected, verified
    static func < (a: SourceConfidence, b: SourceConfidence) -> Bool { a.rawValue < b.rawValue }
    var title: String { ["Unknown", "Inferred", "Detected", "Verified"][rawValue] }
}

struct AppSourceInfo: Hashable, Codable {
    var source: AppUpdateSource
    var confidence: SourceConfidence
    /// One sentence on how it was decided, shown on hover.
    var why: String
}

/// Everything looked at to decide an app's source. Collected from the app bundle by the adapter; decided here so it can be tested.
struct AppSourceFacts: Equatable {
    var path: String
    var bundleID: String
    var hasStoreReceipt = false
    var sparkleFeed: URL?
    var hasSparkleFramework = false
    var hasElectron = false
    /// The provider named in an Electron app's update config (`github`, `generic`, `s3`...), if it has one.
    var electronProvider: String?
    var inHomebrewCaskroom = false
    var isIOSWrapper = false
    var isWebApp = false
}

enum AppSourceDetector {
    static func detect(_ f: AppSourceFacts) -> AppSourceInfo {
        let lower = f.path.lowercased()
        if lower.hasPrefix("/system/applications") || lower.hasPrefix("/system/library") || f.bundleID.hasPrefix("com.apple.") && !f.hasStoreReceipt && !f.isIOSWrapper {
            return AppSourceInfo(source: .system, confidence: .verified, why: "Part of macOS, updated by Software Update.")
        }
        if f.isIOSWrapper { return AppSourceInfo(source: .iosApp, confidence: .verified, why: "An iPhone or iPad app running on this Mac, updated by the App Store.") }
        if f.hasStoreReceipt { return AppSourceInfo(source: .appStore, confidence: .verified, why: "Has a Mac App Store receipt.") }
        if f.isWebApp { return AppSourceInfo(source: .webApp, confidence: .verified, why: "A web app made by a browser, updated by the website.") }
        if f.inHomebrewCaskroom { return AppSourceInfo(source: .homebrew, confidence: .detected, why: "Homebrew lists this app among its installed casks.") }
        if let feed = f.sparkleFeed {
            if (feed.host ?? "").contains("github") { return AppSourceInfo(source: .github, confidence: .verified, why: "Its update feed is hosted on GitHub: \(feed.host ?? "").") }
            return AppSourceInfo(source: .sparkle, confidence: .verified, why: "Names its own Sparkle update feed: \(feed.host ?? feed.absoluteString).")
        }
        if f.hasElectron {
            if f.electronProvider == "github" { return AppSourceInfo(source: .github, confidence: .verified, why: "An Electron app whose update config points at GitHub Releases.") }
            if f.electronProvider != nil { return AppSourceInfo(source: .electron, confidence: .verified, why: "An Electron app with an update config (\(f.electronProvider ?? "")).") }
            return AppSourceInfo(source: .electron, confidence: .inferred, why: "Built with Electron; it probably updates itself, but names no update address.")
        }
        if f.hasSparkleFramework { return AppSourceInfo(source: .sparkle, confidence: .inferred, why: "Contains the Sparkle framework but no feed address was found in it.") }
        return AppSourceInfo(source: .direct, confidence: .unknown, why: "Nothing inside says how it updates, so it was probably downloaded from the developer.")
    }
}

/// Which kinds of processor an app's program contains, read from the first bytes of its executable.
enum AppArchitecture: String, Codable, Hashable, Comparable {
    case arm64, x86_64, other
    static func < (a: AppArchitecture, b: AppArchitecture) -> Bool { a.rawValue < b.rawValue }

    /// "Apple silicon", "Intel", "Universal" from the set found.
    static func badge(_ set: Set<AppArchitecture>) -> String? {
        if set.contains(.arm64) && set.contains(.x86_64) { return "Universal" }
        if set.contains(.arm64) { return "Apple silicon" }
        if set.contains(.x86_64) { return "Intel only" }
        return nil
    }

    /// Reads a Mach-O header: a thin one (one processor) or a fat one (a list of them). Anything else gives an empty set.
    static func parse(header data: Data) -> Set<AppArchitecture> {
        let b = [UInt8](data.prefix(4096))
        guard b.count >= 8 else { return [] }
        func be32(_ i: Int) -> UInt32 { b[i..<i + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        func le32(_ i: Int) -> UInt32 { b[i..<i + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        func kind(_ cpu: UInt32) -> AppArchitecture { cpu == 0x0100000C ? .arm64 : cpu == 0x01000007 ? .x86_64 : .other }
        let magic = be32(0)
        if magic == 0xCAFEBABE || magic == 0xCAFEBABF {
            let count = Int(be32(4)), entry = magic == 0xCAFEBABF ? 32 : 20
            guard count > 0, count <= 16 else { return [] }
            var out = Set<AppArchitecture>()
            for i in 0..<count where 8 + i * entry + 4 <= b.count { out.insert(kind(be32(8 + i * entry))) }
            return out
        }
        if le32(0) == 0xFEEDFACF, b.count >= 8 { return [kind(le32(4))] }
        return []
    }
}

/// Why a file was matched to an app, so each can be explained and only the strong matches are ticked by default.
enum LeftoverEvidence: Int, Codable, Comparable {
    /// Only the name matched. Never ticked by default, never removed on this alone.
    case nameOnly = 0
    /// Shared with other apps from the same developer or with the system.
    case shared
    /// Named with the developer's Team ID (a group container).
    case developer
    /// The file's name is the app's exact bundle identifier.
    case bundleID

    static func < (a: LeftoverEvidence, b: LeftoverEvidence) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .bundleID: return "Exact bundle identifier"
        case .developer: return "Developer's team"
        case .shared: return "Shared file"
        case .nameOnly: return "Name only"
        }
    }

    var preselected: Bool { self == .bundleID }
}

enum LeftoverClassifier {
    /// How strongly `fileName` (lower-cased) ties to the app, or nil when it does not. A name must match whole, never partly.
    static func evidence(fileName: String, folder: String, bundleID: String, appName: String, teamID: String? = nil) -> LeftoverEvidence? {
        let file = fileName.lowercased(), id = bundleID.lowercased(), name = appName.lowercased()
        let stem = (file as NSString).deletingPathExtension
        if !id.isEmpty, file == id || file.hasPrefix(id + ".") || stem == id || file.hasSuffix("." + id) { return .bundleID }
        if let team = teamID?.lowercased(), !team.isEmpty, folder == "Group Containers", file.hasPrefix(team + ".") { return .developer }
        if name.count >= 4, file == name || stem == name, folder != "Preferences" { return .nameOnly }
        return nil
    }
}

/// How to treat an update, by where it comes from. Nothing outside Homebrew is ever installed without being asked.
enum UpdatePolicy: String, Codable, CaseIterable {
    case automatic, notify, manual
    var title: String { ["Automatic", "Tell me", "Manual"][Self.allCases.firstIndex(of: self) ?? 0] }

    /// Only Homebrew casks can be upgraded by Kriya itself, and only when the policy says so.
    static func mayInstall(source: AppUpdateSource, policy: UpdatePolicy) -> Bool { source == .homebrew && policy == .automatic }
}

enum AppInventoryTools {
    /// Folders where apps normally live; anywhere else is unusual.
    static func isUnusualLocation(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let usual = ["/Applications", "/System/Applications", home + "/Applications"]
        return !usual.contains { DiskRisk.isInside(path, $0) }
    }

    /// Bundle identifiers installed more than once, with every path.
    static func duplicates(_ apps: [(bundleID: String, path: String)]) -> [String: [String]] {
        Dictionary(grouping: apps.filter { !$0.bundleID.isEmpty }, by: \.bundleID).filter { $0.value.count > 1 }.mapValues { $0.map(\.path).sorted() }
    }

    /// Apps not opened for `months`. An app that was never opened counts as unused.
    static func unused(_ apps: [(name: String, lastUsed: Date?)], months: Int, now: Date = Date()) -> [String] {
        let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: now) ?? now
        return apps.filter { ($0.lastUsed ?? .distantPast) < cutoff }.map(\.name)
    }

    struct Row: Codable, Equatable {
        var name: String, bundleID: String, version: String, source: String, confidence: String, architecture: String
        var path: String, bytes: Int64, lastOpened: Date?
    }

    static func csv(_ rows: [Row]) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let iso = ISO8601DateFormatter()
        return (["name,bundle_id,version,source,confidence,architecture,path,bytes,last_opened"] + rows.map {
            [q($0.name), q($0.bundleID), q($0.version), q($0.source), q($0.confidence), q($0.architecture), q($0.path), String($0.bytes), $0.lastOpened.map { iso.string(from: $0) } ?? ""].joined(separator: ",")
        }).joined(separator: "\n") + "\n"
    }

    static func json(_ rows: [Row]) -> Data? {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
        return try? e.encode(rows)
    }

    static func markdown(_ rows: [Row]) -> String {
        func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|") }
        return (["| App | Version | Source | Architecture |", "|---|---|---|---|"] + rows.map { "| \(cell($0.name)) | \(cell($0.version)) | \(cell($0.source)) (\($0.confidence.lowercased())) | \(cell($0.architecture)) |" }).joined(separator: "\n") + "\n"
    }
}

/// Keeps a copy of an app before it is replaced, so the old version can be put back.
enum AppBackupNaming {
    static func folderName(app: String, version: String, at date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd-HHmmss"
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters)
        let clean = app.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let v = version.components(separatedBy: bad).joined(separator: "-")
        return "\(clean.isEmpty ? "App" : String(clean.prefix(50))) \(v.isEmpty ? "" : v + " ")\(f.string(from: date))"
    }

    /// The ids of backups to remove so at most `keep` remain for each app, the oldest going first.
    static func expired(_ items: [(id: String, app: String, date: Date)], keep: Int = 2) -> [String] {
        Dictionary(grouping: items, by: \.app).values.flatMap { group in group.sorted { $0.date > $1.date }.dropFirst(keep).map(\.id) }
    }
}
