import AppKit
import Combine

/// The plain parts of working with Homebrew casks: which names are acceptable, reading search output, and the file an app
/// list is saved in. Kept apart from running anything, so they can be tested.
enum HomebrewParsing {
    /// A cask name as Homebrew writes it: lower case letters, digits and a few separators. Anything else is refused, so
    /// nothing odd can ever be handed to the command.
    static func isValidToken(_ token: String) -> Bool {
        token.range(of: #"^[a-z0-9][a-z0-9@._+-]{0,80}$"#, options: .regularExpression) != nil
    }

    /// The cask names in the output of `brew search --cask`. Homebrew may print a "Casks" part and a "Formulae" part; only
    /// what is under Casks counts, and output with no headings at all is all casks.
    static func parseSearch(_ output: String) -> [String] {
        var inCasks = true
        var tokens: [String] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("==>") {
                inCasks = line.lowercased().contains("cask")
                continue
            }
            if inCasks, !line.isEmpty, isValidToken(line) { tokens.append(line) }
        }
        var seen = Set<String>()
        return Array(tokens.filter { seen.insert($0).inserted }.prefix(40))
    }

    /// What Homebrew knows about a cask, for showing next to its name.
    struct CaskInfo: Identifiable, Equatable {
        let token: String
        let name: String
        let description: String
        let version: String
        let homepage: String
        var id: String { token }
    }

    /// The cask details in the output of `brew info --json=v2 --cask …`. Anything that is not understood gives nothing.
    static func parseInfo(_ data: Data) -> [CaskInfo] {
        guard data.count < 8_000_000,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else { return [] }
        return casks.compactMap { cask in
            guard let token = cask["token"] as? String, isValidToken(token) else { return nil }
            let names = cask["name"] as? [String] ?? []
            return CaskInfo(
                token: token, name: names.first ?? token, description: (cask["desc"] as? String) ?? "",
                version: (cask["version"] as? String) ?? "", homepage: (cask["homepage"] as? String) ?? ""
            )
        }
    }

    /// Search results in a useful order: the exact name first, then names that start with what was typed, then the rest.
    static func rank(_ tokens: [String], query: String) -> [String] {
        let wanted = query.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        func score(_ token: String) -> Int {
            if token == wanted { return 0 }
            if token.hasPrefix(wanted + "-") || token.hasPrefix(wanted + "@") { return 1 }
            if token.hasPrefix(wanted) { return 2 }
            return token.contains(wanted) ? 3 : 4
        }
        return tokens.enumerated().sorted { (score($0.element), $0.offset) < (score($1.element), $1.offset) }.map(\.element)
    }

    /// Well-known apps to suggest before anything is typed.
    static let featured: [String] = [
        "google-chrome", "firefox", "visual-studio-code", "slack", "zoom", "spotify", "vlc", "iterm2", "obsidian", "notion", "raycast", "rectangle",
    ]

    /// What an exported list holds: the casks, and the apps they sit beside for reference.
    struct AppList: Codable, Equatable {
        struct AppRecord: Codable, Equatable {
            var name: String
            var bundleId: String
        }
        var format = 1
        var casks: [String]
        var apps: [AppRecord]
    }

    static func encodeList(casks: [String], apps: [(name: String, bundleID: String)]) throws -> Data {
        let list = AppList(casks: casks.filter(isValidToken).sorted(), apps: apps.map { AppList.AppRecord(name: $0.name, bundleId: $0.bundleID) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(list)
    }

    /// The cask names in an exported list. A file that is not one of ours, or from a newer version, is refused; names that
    /// are not valid are dropped.
    static func decodeList(_ data: Data) throws -> [String] {
        guard data.count < 2_000_000, let list = try? JSONDecoder().decode(AppList.self, from: data), list.format == 1 else {
            throw HomebrewError("That is not an app list made by Kriya.")
        }
        var seen = Set<String>()
        return list.casks.filter { isValidToken($0) && seen.insert($0).inserted }
    }

    /// The wanted casks that are not installed yet, in the order they were wanted.
    static func missing(wanted: [String], installed: [String]) -> [String] {
        let have = Set(installed)
        return wanted.filter { !have.contains($0) }
    }
}

struct HomebrewError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Finding and installing apps with Homebrew, if it is on this Mac. Every command is built from validated names, shown to
/// the person before it runs, and its output is kept in a log they can read. Kriya never installs Homebrew itself.
final class HomebrewManager: ObservableObject {
    @Published private(set) var brewPath: String?
    @Published private(set) var results: [String] = []
    @Published private(set) var installed: [String] = []
    @Published private(set) var log = ""
    @Published private(set) var isRunning = false
    @Published private(set) var status: String?
    /// Names, descriptions and versions for the casks shown, filled in a moment after the names appear.
    @Published private(set) var details: [String: HomebrewParsing.CaskInfo] = [:]
    @Published private(set) var isSearching = false
    private var searchGeneration = 0

    // The running process and the Stop request are touched from the main thread and from the install queue, so they are
    // guarded by one lock. The process is started while the lock is held, so Stop either comes before it starts (and it never
    // does) or after it is running (and it is ended).
    private let stateLock = NSLock()
    private var process: Process?
    private var cancelRequested = false
    /// Installs and upgrades run one after another on this queue, shared with the automatic upgrades in the Apps pane.
    private let queue = HomebrewQueue.shared
    /// Searching and listing only read, so they do not wait behind an install.
    private let readQueue = DispatchQueue(label: "app.kriya.homebrew.read", qos: .userInitiated)

    /// `brewPath` is for tests, which point it at a stand-in program. Normally it is found on the Mac.
    init(brewPath: String? = nil) {
        if let brewPath {
            self.brewPath = brewPath
        } else {
            locate()
        }
    }

    func locate() {
        brewPath = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
        if brewPath != nil { refreshInstalled() }
    }

    /// The command that will run, exactly as it would be typed.
    static func command(install token: String) -> String { "brew install --cask \(token)" }

    func search(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { clearSearch(); return }
        guard let brewPath, text.count <= 60, !text.contains("\0"), !text.hasPrefix("-") else { return }
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        status = nil
        readQueue.async { [self] in
            let output = (try? ToolRunner.run(brewPath, ["search", "--cask", text], environment: Self.environment, timeout: 60)) ?? ""
            let found = HomebrewParsing.rank(HomebrewParsing.parseSearch(output), query: text)
            DispatchQueue.main.async {
                // A newer search has started since: this answer is old.
                guard generation == self.searchGeneration else { return }
                self.results = found
                self.isSearching = false
                self.status = found.isEmpty ? "No apps match “\(text)”." : nil
                self.describe(Array(found.prefix(12)))
            }
        }
    }

    /// Forgets the last search (the box was emptied).
    func clearSearch() {
        searchGeneration += 1
        results = []
        isSearching = false
        status = nil
    }

    /// Looks up names and descriptions for casks, so a list shows more than their short names.
    func describe(_ tokens: [String]) {
        let wanted = tokens.filter(HomebrewParsing.isValidToken).filter { details[$0] == nil }
        guard let brewPath, !wanted.isEmpty else { return }
        readQueue.async { [self] in
            // Homebrew may print a warning before the JSON, so the reading starts at its first brace.
            let text = (try? ToolRunner.run(brewPath, ["info", "--json=v2", "--cask"] + wanted, environment: Self.environment, timeout: 60)) ?? ""
            let infos = HomebrewParsing.parseInfo(Data((text.firstIndex(of: "{").map { String(text[$0...]) } ?? "").utf8))
            DispatchQueue.main.async { for info in infos { self.details[info.token] = info } }
        }
    }

    func refreshInstalled() {
        guard let brewPath else { return }
        readQueue.async { [self] in
            let output = (try? ToolRunner.run(brewPath, ["list", "--cask"], environment: Self.environment, timeout: 60)) ?? ""
            let tokens = output.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter(HomebrewParsing.isValidToken)
            DispatchQueue.main.async { self.installed = tokens.sorted() }
        }
    }

    /// Installs each cask in turn, writing what Homebrew says to the log. Names that are not valid are skipped.
    func install(_ tokens: [String]) {
        let wanted = tokens.filter(HomebrewParsing.isValidToken)
        guard let brewPath, !wanted.isEmpty, !isRunning else { return }
        isRunning = true
        setCancelRequested(false)
        log = ""
        queue.async { [self] in
            for token in wanted {
                if isCancelRequested { append("Stopped.\n"); break }
                append("$ \(Self.command(install: token))\n")
                let code = runStreaming(brewPath, ["install", "--cask", token])
                append(code == 0 ? "\nInstalled \(token).\n\n" : "\nHomebrew stopped with code \(code) for \(token).\n\n")
            }
            DispatchQueue.main.async {
                self.isRunning = false
                self.refreshInstalled()
            }
        }
    }

    /// Stops the install in progress, and the ones waiting behind it.
    func cancel() {
        stateLock.lock()
        cancelRequested = true
        if let process, process.isRunning { process.terminate() }
        stateLock.unlock()
    }

    private var isCancelRequested: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelRequested
    }

    private func setCancelRequested(_ value: Bool) {
        stateLock.lock()
        cancelRequested = value
        stateLock.unlock()
    }

    // MARK: Lists

    func exportList(to url: URL, apps: [(name: String, bundleID: String)]) throws {
        try HomebrewParsing.encodeList(casks: installed, apps: apps).write(to: url, options: .atomic)
    }

    func readList(from url: URL) throws -> [String] {
        try HomebrewParsing.decodeList(try Data(contentsOf: url))
    }

    // MARK: Running

    private static var environment: [String: String] {
        ["PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOMEBREW_NO_ENV_HINTS": "1", "NONINTERACTIVE": "1"]
    }

    private func append(_ text: String) {
        DispatchQueue.main.async {
            self.log += text
            // The log keeps the end of a long install, not all of it.
            if self.log.count > 200_000 { self.log = String(self.log.suffix(150_000)) }
        }
    }

    /// Runs a command and streams its output into the log as it arrives. Returns the exit code.
    private func runStreaming(_ executable: String, _ arguments: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.environment = ProcessInfo.processInfo.environment.merging(Self.environment) { _, new in new }
        task.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) { self?.append(text) }
        }
        // Start it under the lock: a Stop that arrives first is seen here, and one that arrives later finds it running.
        stateLock.lock()
        if cancelRequested {
            stateLock.unlock()
            return -2
        }
        do { try task.run() } catch {
            stateLock.unlock()
            append("Could not start Homebrew.\n")
            return -1
        }
        process = task
        stateLock.unlock()
        task.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        stateLock.lock()
        process = nil
        stateLock.unlock()
        return task.terminationStatus
    }
}

/// The one place Homebrew installs and upgrades run, so two of them never run at once.
enum HomebrewQueue {
    static let shared = DispatchQueue(label: "app.kriya.homebrew", qos: .userInitiated)
}
