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

    /// The cask names in the output of `brew search --cask`, without its headings.
    static func parseSearch(_ output: String) -> [String] {
        let tokens = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("==>") && isValidToken($0) }
        var seen = Set<String>()
        return Array(tokens.filter { seen.insert($0).inserted }.prefix(40))
    }

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

    private var process: Process?
    private var cancelRequested = false
    private let queue = DispatchQueue(label: "app.kriya.homebrew", qos: .userInitiated)

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
        guard let brewPath, !text.isEmpty, text.count <= 60, !text.contains("\0"), !text.hasPrefix("-") else { return }
        status = "Searching…"
        queue.async { [self] in
            let output = (try? ToolRunner.run(brewPath, ["search", "--cask", text], environment: Self.environment, timeout: 60)) ?? ""
            let found = HomebrewParsing.parseSearch(output)
            DispatchQueue.main.async {
                self.results = found
                self.status = found.isEmpty ? "No casks match “\(text)”." : nil
            }
        }
    }

    func refreshInstalled() {
        guard let brewPath else { return }
        queue.async { [self] in
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
        cancelRequested = false
        log = ""
        queue.async { [self] in
            for token in wanted {
                if cancelRequested { append("Stopped.\n"); break }
                append("$ \(Self.command(install: token))\n")
                let code = runStreaming(brewPath, ["install", "--cask", token])
                append(code == 0 ? "\nInstalled \(token).\n\n" : "\nHomebrew stopped with code \(code) for \(token).\n\n")
            }
            DispatchQueue.main.async {
                self.isRunning = false
                self.process = nil
                self.refreshInstalled()
            }
        }
    }

    /// Stops the install in progress, and the ones waiting behind it.
    func cancel() {
        cancelRequested = true
        process?.terminate()
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
        DispatchQueue.main.async { self.process = task }
        do { try task.run() } catch {
            append("Could not start Homebrew.\n")
            return -1
        }
        task.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        return task.terminationStatus
    }
}
