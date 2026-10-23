import AppKit
import Foundation

/// Runs the folder rules: looks at each watched folder now and then, and carries out what a rule says. It only ever moves,
/// copies, renames or sends to the Trash, never overwrites, writes every change into the file history so it can be undone,
/// and tells the person what it did.
final class FolderRulesService: ObservableObject {
    let store: FolderRulesStore
    private let history: FileOperationHistory
    private let toast = Toast()
    private let queue = DispatchQueue(label: "app.kriya.folderrules", qos: .utility)
    private var timer: Timer?
    private var running = Set<String>()

    /// What each rule did last, for the list.
    @Published private(set) var lastResult: [String: String] = [:]

    init(store: FolderRulesStore, history: FileOperationHistory) {
        self.store = store
        self.history = history
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.runEnabledRules() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.runEnabledRules() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func runEnabledRules() {
        guard !store.paused else { return }
        for rule in store.rules where rule.enabled { run(rule, announce: true) }
    }

    // MARK: Looking

    /// The files in a rule's folder, with what a rule can ask about them.
    static func files(in folder: String, markDuplicates: Bool = false) -> [FolderFile] {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey, .tagNamesKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])) ?? []
        var files: [FolderFile] = entries.compactMap { entry in
            guard let values = try? entry.resourceValues(forKeys: Set(keys)), let modified = values.contentModificationDate else { return nil }
            return FolderFile(name: entry.lastPathComponent, isDirectory: values.isDirectory ?? false, isHidden: values.isHidden ?? false, size: Int64(values.fileSize ?? 0), modified: modified, tags: values.tagNames ?? [])
        }
        if markDuplicates {
            let copies = FolderRuleEngine.duplicateNames(files) { FileCleanupScanner.fingerprint(of: url.appendingPathComponent($0.name).path) }
            for index in files.indices where copies.contains(files[index].name) { files[index].isDuplicate = true }
        }
        return files
    }

    /// The files a rule looks at; copies are worked out only for a rule that asks about them.
    static func files(for rule: FolderRule) -> [FolderFile] {
        files(in: rule.folder, markDuplicates: rule.conditions.contains(.isDuplicate))
    }

    /// What a rule would do right now, without doing it.
    func preview(_ rule: FolderRule, completion: @escaping ([PlannedChange]) -> Void) {
        queue.async {
            let changes = FolderRuleEngine.plan(rule, files: Self.files(for: rule), now: Date())
            DispatchQueue.main.async { completion(changes) }
        }
    }

    // MARK: Doing

    /// Carries out a rule. The files it acts on are read again just now, so a file that changed since a preview is judged
    /// as it is.
    func run(_ rule: FolderRule, announce: Bool) {
        guard !running.contains(rule.id) else { return }
        running.insert(rule.id)
        queue.async { [weak self] in
            guard let self else { return }
            let changes = FolderRuleEngine.plan(rule, files: Self.files(for: rule), now: Date())
            let result = Self.apply(changes)
            DispatchQueue.main.async {
                self.running.remove(rule.id)
                guard !changes.isEmpty else { self.lastResult[rule.id] = "Nothing to do"; return }
                let verb: String
                switch rule.action {
                case .copyTo: verb = "Copied"
                case .rename: verb = "Renamed"
                case .trash: verb = "Moved to the Trash"
                case .tag: verb = "Tagged"
                case .archiveByMonth: verb = "Archived"
                default: verb = "Moved"
                }
                let done = result.steps.count + result.tagged
                let text = "\(verb) \(done) file\(done == 1 ? "" : "s")" + (result.failures.isEmpty ? "" : ", \(result.failures.count) failed")
                self.lastResult[rule.id] = text + " · " + Date().formatted(date: .omitted, time: .shortened)
                if !result.steps.isEmpty || !result.failures.isEmpty { self.history.record(title: "Folder rule “\(rule.name)”: \(text.lowercased())", steps: result.steps, failures: result.failures) }
                if announce, done > 0 || !result.failures.isEmpty { self.toast.show("“\(rule.name)”: \(text)", isError: done == 0 && !result.failures.isEmpty) }
            }
        }
    }

    /// Does what was planned, one change at a time. A change that fails is reported and the rest still run.
    static func apply(_ changes: [PlannedChange]) -> (steps: [FileStep], failures: [String], tagged: Int) {
        let fm = FileManager.default
        var steps: [FileStep] = []
        var failures: [String] = []
        var tagged = 0
        for change in changes {
            let name = (change.from as NSString).lastPathComponent
            do {
                switch change.kind {
                case .move, .copy:
                    guard let to = change.to else { continue }
                    // Something may have arrived with this name since the plan; it is never replaced.
                    var target = to
                    if fm.fileExists(atPath: target) {
                        let folder = (to as NSString).deletingLastPathComponent
                        let unique = finderUniqueName(candidate: (to as NSString).lastPathComponent, existing: (try? fm.contentsOfDirectory(atPath: folder)) ?? [])
                        target = (folder as NSString).appendingPathComponent(unique)
                    }
                    try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    if change.kind == .move {
                        try fm.moveItem(atPath: change.from, toPath: target)
                        steps.append(.moved(from: change.from, to: target))
                    } else {
                        try fm.copyItem(atPath: change.from, toPath: target)
                        steps.append(.created(path: target))
                    }
                case .tag:
                    guard let tag = change.to else { continue }
                    let url = URL(fileURLWithPath: change.from) as NSURL
                    var names: AnyObject?
                    try? url.getResourceValue(&names, forKey: .tagNamesKey)
                    let existing = (names as? [String]) ?? []
                    try url.setResourceValue(existing + [tag], forKey: .tagNamesKey)
                    tagged += 1
                case .trash:
                    var trashed: NSURL?
                    try fm.trashItem(at: URL(fileURLWithPath: change.from), resultingItemURL: &trashed)
                    if let path = (trashed as URL?)?.path { steps.append(.moved(from: change.from, to: path)) }
                }
            } catch {
                failures.append("“\(name)”: \(error.localizedDescription)")
            }
        }
        return (steps, failures, tagged)
    }
}
