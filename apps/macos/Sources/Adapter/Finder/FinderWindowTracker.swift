import AppKit

/// Remembers which folders Finder has open and which it closed lately, so a closed window can be brought back. It is off until
/// the person turns it on, asks Finder for its window folders every few seconds while on, and keeps folder paths only.
final class FinderWindowTracker: ObservableObject {
    static let shared = FinderWindowTracker()
    private static let enabledKey = "finderWindows.enabled"
    private static let historyKey = "finderWindows.history.v1"

    @Published private(set) var history: FinderWindowHistory
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled { start() } else { stop(); history.clear(); UserDefaults.standard.removeObject(forKey: Self.historyKey) }
        }
    }
    private var timer: Timer?
    private let queue = DispatchQueue(label: "app.kriya.finder-windows", qos: .utility)

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        history = UserDefaults.standard.data(forKey: Self.historyKey).flatMap { try? JSONDecoder().decode(FinderWindowHistory.self, from: $0) } ?? FinderWindowHistory()
    }

    func start() {
        guard enabled, timer == nil else { return }
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        guard enabled, NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.finder" }) else { return }
        queue.async { [weak self] in
            let (front, others) = FeatureTimings.shared.measure("Finder window check") { DialogFolderHelper.finderFolders() }
            let paths = (front.map { [$0] } ?? []) + others
            DispatchQueue.main.async { self?.observe(paths) }
        }
    }

    private func observe(_ paths: [String]) {
        guard enabled else { return }
        let excluded = FolderDestinations.shared.excluded
        var next = history
        next.observe(paths) { FolderSets.isExcluded($0, folders: excluded) }
        guard next != history else { return }
        history = next
        if let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: Self.historyKey) }
    }

    func reopen(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    func forget(_ path: String) {
        history.forget(path)
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: Self.historyKey) }
    }
}

/// The saved groups of folders.
final class FolderSetStore: ObservableObject {
    static let shared = FolderSetStore()
    private static let key = "folderSets.v1"
    @Published var sets: [FolderSet] {
        didSet { if let data = try? JSONEncoder().encode(sets) { UserDefaults.standard.set(data, forKey: Self.key) } }
    }

    private init() {
        sets = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([FolderSet].self, from: $0) } ?? []
    }

    /// Saves the folders open in Finder now under a name. Returns whether anything was saved.
    @discardableResult
    func saveOpenFolders(named name: String) -> Bool {
        let (front, others) = DialogFolderHelper.finderFolders()
        guard sets.count < FolderSets.limit, let set = FolderSets.from(open: (front.map { [$0] } ?? []) + others, named: name) else { return false }
        sets.append(set)
        return true
    }

    func open(_ set: FolderSet) {
        let folders = set.openable()
        guard !folders.isEmpty else { Toast().show("None of the folders in “\(set.name)” exist any more.", isError: true); return }
        for path in folders { NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true)) }
    }
}
