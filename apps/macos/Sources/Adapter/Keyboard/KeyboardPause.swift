import Foundation

/// The pause switches for remapping, text expansion and shortcuts. Read from the event tap's thread on every key, so the state is
/// behind a lock; changes come from the pane and from a command.
final class KeyboardPause: ObservableObject {
    static let shared = KeyboardPause()

    @Published private(set) var published = KeyboardPauseState()
    private let lock = NSLock()
    private var state = KeyboardPauseState()

    var current: KeyboardPauseState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    var remapsPaused: Bool { current.remaps }
    var expansionPaused: Bool { current.expansion }
    var shortcutsPaused: Bool { current.shortcuts }

    func change(_ edit: (inout KeyboardPauseState) -> Void) {
        lock.lock()
        edit(&state)
        let next = state
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.published = next }
        FeatureActivity.shared.changed("keyboard", next.isAnyPaused ? next.summary : "Everything resumed")
    }

    func toggleAll() { change { $0.toggleAll() } }
    func resumeAll() { change { $0 = KeyboardPauseState() } }
}
