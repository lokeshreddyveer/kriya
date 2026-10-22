import Combine
import Foundation

/// Settings for dragging to scroll and for windows that follow the pointer.
final class DragToolsStore: ObservableObject {
    @Published private(set) var config = DragToolsConfig(
        scrollEnabled: false, scrollButton: 2, scrollModifier: 0, scrollInvert: false, scrollSpeed: 1, momentum: true,
        momentumKeep: 0.94, followModifier: 0, doubleClicks: [], doubleClickMs: 300, buttonScrolls: [],
        autoScrollEnabled: false, autoScrollButton: 2, autoScrollModifier: 0, autoScrollSpeed: 1
    )
    @Published var lastError: String?

    private let core: KriyaCore
    private let lock = NSLock()
    private var snapshot: DragToolsConfig?      // guarded by lock

    init(core: KriyaCore) {
        self.core = core
        reload()
    }

    func reload() {
        do {
            config = try core.dragToolsConfig()
        } catch {
            Log.error("Drag", "Could not load drag settings: \(error.userMessage)")
        }
        lock.lock()
        snapshot = config
        lock.unlock()
    }

    /// Safe to read from the event tap's thread.
    var current: DragToolsConfig {
        lock.lock()
        defer { lock.unlock() }
        return snapshot ?? config
    }

    func update(_ change: (inout DragToolsConfig) -> Void) {
        var next = config
        change(&next)
        do {
            try core.saveDragToolsConfig(config: next)
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
        reload()
    }
}
