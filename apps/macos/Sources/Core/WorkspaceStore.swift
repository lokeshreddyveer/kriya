import Combine
import Foundation

extension Workspace: Identifiable {}

/// Workspaces, focus mode's app list, the apps "quit all" leaves alone, and favourite windows.
final class WorkspaceStore: ObservableObject {
    @Published private(set) var config = WorkspaceConfig(workspaces: [], focusAppIds: [], quitKeepAppIds: [], favorites: [], confirmQuitAll: true)
    @Published var lastError: String?

    private let core: KriyaCore
    private let lock = NSLock()
    private var snapshot: WorkspaceConfig?      // guarded by lock

    init(core: KriyaCore) {
        self.core = core
        reload()
    }

    func reload() {
        do {
            config = try core.workspaceConfig()
        } catch {
            Log.error("Workspaces", "Could not load workspaces: \(error.userMessage)")
        }
        lock.lock()
        snapshot = config
        lock.unlock()
    }

    var current: WorkspaceConfig {
        lock.lock()
        defer { lock.unlock() }
        return snapshot ?? config
    }

    func update(_ change: (inout WorkspaceConfig) -> Void) {
        var next = config
        change(&next)
        do {
            try core.saveWorkspaceConfig(config: next)
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
        reload()
    }

    func upsert(_ workspace: Workspace) {
        update { config in
            if let index = config.workspaces.firstIndex(where: { $0.id == workspace.id }) {
                config.workspaces[index] = workspace
            } else {
                config.workspaces.append(workspace)
            }
        }
    }

    func delete(_ id: String) { update { $0.workspaces.removeAll { $0.id == id } } }
    func move(from source: IndexSet, to destination: Int) { update { $0.workspaces.move(fromOffsets: source, toOffset: destination) } }

    func exportWorkspaces(to url: URL) throws {
        try core.exportWorkspaces(ids: []).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Adds the workspaces in a file under new ids, with their layouts. Says what was added and what was left out.
    func importWorkspaces(from url: URL) throws -> WorkspaceImportReport {
        guard let json = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw CoreError.Backup(message: "the file is not a Kriya workspace file") }
        let report = try core.importWorkspaces(json: json, now: SystemInfo.nowSeconds)
        reload()
        return report
    }

    func newWorkspace() -> Workspace {
        Workspace(id: UUID().uuidString, name: "", appIds: [], layoutId: nil, hideOthers: false, urls: [])
    }
}
