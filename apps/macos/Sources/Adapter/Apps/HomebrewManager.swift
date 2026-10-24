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

    /// What an install is doing, judged from the last thing Homebrew printed. Nil when there is nothing worth saying.
    static func stage(forOutput text: String) -> String? {
        let tail = String(text.suffix(600)).lowercased()
        if tail.contains("password:") || tail.contains("a terminal is required") || tail.contains("no tty present") || tail.contains("sudo:") {
            return "Needs your password. Use “Run in Terminal” to finish this one."
        }
        if tail.contains("auto-updating homebrew") || tail.contains("updating homebrew") { return "Updating Homebrew first…" }
        if tail.contains("downloading") || tail.contains("fetching") { return "Downloading…" }
        if tail.contains("moving app") || tail.contains("installing cask") || tail.contains("running installer") || tail.contains("linking") { return "Installing…" }
        if tail.contains("verifying") || tail.contains("verified") { return "Verifying download…" }
        return nil
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
    /// What the install in progress is doing right now, or why it looks stuck.
    @Published private(set) var stage: String?
    /// The cask being installed now, and how far through the list it is ("2 of 5").
    @Published private(set) var currentCask: String?
    @Published private(set) var progressNote: String?
    /// How many casks of the run have finished and how many there are, for the bar. One cask has no percentage to show.
    @Published private(set) var installDone = 0
    @Published private(set) var installTotal = 0
    /// The casks that did not install, with why, after the last run.
    @Published private(set) var failures: [String: String] = [:]
    /// How long an install may run, and how long it may be silent before it is called stalled. Changed by tests.
    var installTimeout: TimeInterval = 1_200
    var stallAfter: TimeInterval = 90
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
        guard !LocalOnly.isOn else { status = LocalOnly.blockedMessage; return }
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
        guard !LocalOnly.isOn else { status = LocalOnly.blockedMessage; return }
        AuditLog.shared.record(.install, "brew install --cask " + wanted.joined(separator: " "))
        isRunning = true
        setCancelRequested(false)
        log = ""
        failures = [:]
        stage = nil
        installDone = 0
        installTotal = wanted.count
        queue.async { [self] in
            for (index, token) in wanted.enumerated() {
                if isCancelRequested { append("Stopped.\n"); break }
                DispatchQueue.main.async { self.installDone = index }
                setProgress(cask: token, note: wanted.count > 1 ? "\(index + 1) of \(wanted.count)" : nil)
                append("$ \(Self.command(install: token))\n")
                let code = runStreaming(brewPath, ["install", "--cask", token])
                switch code {
                case 0: append("\nInstalled \(token).\n\n")
                case Self.timedOutCode: recordFailure(token, "It took longer than \(Int(installTimeout / 60)) minutes and was stopped."); append("\n\(token) was stopped: it took too long.\n\n")
                case -2: break
                default: recordFailure(token, "Homebrew stopped with code \(code)."); append("\nHomebrew stopped with code \(code) for \(token).\n\n")
                }
            }
            DispatchQueue.main.async {
                self.isRunning = false
                self.installDone = 0
                self.installTotal = 0
                self.setProgress(cask: nil, note: nil)
                self.stage = nil
                self.refreshInstalled()
            }
        }
    }

    private func setProgress(cask: String?, note: String?) {
        DispatchQueue.main.async { self.currentCask = cask; self.progressNote = note; self.stage = nil }
    }

    private func recordFailure(_ token: String, _ reason: String) {
        DispatchQueue.main.async { self.failures[token] = reason }
    }

    /// Opens Terminal with the install command ready to run, for the apps that need a password. The command is also copied.
    static func runInTerminal(install token: String) {
        guard HomebrewParsing.isValidToken(token) else { return }
        let command = command(install: token)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(command)\"\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }

    /// Stops the install in progress, and the ones waiting behind it.
    func cancel() {
        stateLock.lock()
        cancelRequested = true
        if let process, process.isRunning { Self.terminateTree(process.processIdentifier) }
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

    static var environment: [String: String] {
        ["PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOMEBREW_NO_ENV_HINTS": "1", "NONINTERACTIVE": "1"]
    }

    /// The install log kept on disk, so what Homebrew said is still there after Kriya closes. Trimmed when it grows large.
    static var logFileURL: URL { AppPaths.live.logs.appendingPathComponent("homebrew-install.log") }
    private static let logQueue = DispatchQueue(label: "app.kriya.homebrew.log", qos: .utility)

    private func append(_ text: String) {
        Self.logQueue.async {
            let url = Self.logFileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > 500_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try? handle.close()
            } else {
                try? Data(text.utf8).write(to: url)
            }
        }
        DispatchQueue.main.async {
            self.log += text
            // The log keeps the end of a long install, not all of it.
            if self.log.count > 200_000 { self.log = String(self.log.suffix(150_000)) }
        }
    }

    /// The code `runStreaming` returns when it ended the command for taking too long.
    static let timedOutCode: Int32 = -3

    /// Every process below this one, deepest first, so a stuck installer's helpers are ended before their parent.
    static func descendants(of pid: pid_t) -> [pid_t] {
        guard let output = try? ToolRunner.run("/usr/bin/pgrep", ["-P", String(pid)], timeout: 5) else { return [] }
        let children = output.split(whereSeparator: \.isNewline).compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        return children.flatMap { descendants(of: $0) } + children
    }

    /// Ends a process and everything it started. Homebrew runs curl, sudo and installers as children, and ending only the
    /// parent leaves them holding the output open.
    static func terminateTree(_ root: pid_t) {
        let tree = descendants(of: root)
        for pid in tree { kill(pid, SIGTERM) }
        kill(root, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            for pid in tree + [root] where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    /// Runs a command and streams its output into the log as it arrives. Returns the exit code, or `timedOutCode` when it ran
    /// past `installTimeout`. While it runs, `stage` says what it is doing, or that it has gone quiet.
    private func runStreaming(_ executable: String, _ arguments: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.environment = ProcessInfo.processInfo.environment.merging(Self.environment) { _, new in new }
        task.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        let activity = ActivityClock()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                activity.touch(text)
                self?.append(text)
                if let stage = HomebrewParsing.stage(forOutput: activity.recent) { self?.publish(stage: stage) }
            }
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

        // Watch it instead of waiting blindly: a quiet install is reported, and one that never ends is ended.
        let started = Date()
        var timedOut = false
        var warned = false
        while task.isRunning {
            Thread.sleep(forTimeInterval: 0.2)
            let now = Date()
            if now.timeIntervalSince(started) > installTimeout {
                timedOut = true
                Self.terminateTree(task.processIdentifier)
                break
            }
            if !warned, activity.silence(since: now) > stallAfter, HomebrewParsing.stage(forOutput: activity.recent) == nil {
                warned = true
                publish(stage: "No news from Homebrew for \(Int(stallAfter)) seconds. It may be waiting for the network or a password. Stop it, or use “Run in Terminal”.")
            }
        }
        // After ending the tree the output closes; give the last of it a moment, then stop reading either way.
        if timedOut { Thread.sleep(forTimeInterval: 0.5) } else { task.waitUntilExit() }
        pipe.fileHandleForReading.readabilityHandler = nil
        stateLock.lock()
        process = nil
        stateLock.unlock()
        return timedOut ? Self.timedOutCode : task.terminationStatus
    }

    private func publish(stage: String) {
        DispatchQueue.main.async { if self.isRunning { self.stage = stage } }
    }
}

/// When Homebrew last printed something, and the last of what it printed. Written from the pipe's thread, read by the watcher.
private final class ActivityClock {
    private let lock = NSLock()
    private var last = Date()
    private var tail = ""
    func touch(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        last = Date()
        tail = String((tail + text).suffix(800))
    }
    var recent: String { lock.lock(); defer { lock.unlock() }; return tail }
    func silence(since now: Date) -> TimeInterval { lock.lock(); defer { lock.unlock() }; return now.timeIntervalSince(last) }
}

/// The one place Homebrew installs and upgrades run, so two of them never run at once.
enum HomebrewQueue {
    static let shared = DispatchQueue(label: "app.kriya.homebrew", qos: .userInitiated)
}
