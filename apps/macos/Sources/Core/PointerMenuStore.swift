import Combine
import Foundation

/// The pointer menu's settings: the person's own items and whether the frontmost app's menu bar is added.
final class PointerMenuStore: ObservableObject {
    @Published private(set) var config = PointerMenuConfig(items: [], showAppMenu: true, optionRightClick: false)
    @Published var lastError: String?

    private let core: KriyaCore
    private let lock = NSLock()
    private var snapshot = PointerMenuConfig(items: [], showAppMenu: true, optionRightClick: false)   // guarded by lock, for the menu

    init(core: KriyaCore) {
        self.core = core
        reload()
    }

    func reload() {
        do {
            config = try core.pointerMenuConfig()
        } catch {
            Log.error("PointerMenu", "Could not load the pointer menu: \(error.userMessage)")
        }
        lock.lock()
        snapshot = config
        lock.unlock()
    }

    var current: PointerMenuConfig {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func update(_ change: (inout PointerMenuConfig) -> Void) {
        var next = config
        change(&next)
        do {
            try core.savePointerMenuConfig(config: next)
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
        reload()
    }

    func upsert(_ item: PointerMenuItem) {
        update { config in
            if let index = config.items.firstIndex(where: { $0.id == item.id }) {
                config.items[index] = item
            } else {
                config.items.append(item)
            }
        }
    }

    func delete(_ id: String) {
        update { $0.items.removeAll { $0.id == id } }
    }

    func move(from source: IndexSet, to destination: Int) {
        update { $0.items.move(fromOffsets: source, toOffset: destination) }
    }

    func newItem() -> PointerMenuItem {
        PointerMenuItem(id: UUID().uuidString, title: "", actionId: nil, workflowId: nil, appIds: [], enabled: true)
    }
}
