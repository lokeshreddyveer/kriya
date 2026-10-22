import AppKit

/// One feature's global keyboard shortcuts. The shortcuts themselves are held by the shared `ShortcutRegistry`, which gives
/// each a unique identifier, routes each press to the right feature and checks for clashes; this keeps the small interface
/// each feature already uses.
final class HotkeyCenter {
    private let owner: String
    private let title: (String) -> String
    private let onFire: (String) -> Void
    private let registry: ShortcutRegistry

    /// Commands the system refused, usually because another app already owns the combination.
    private(set) var failures: [String] = []

    init(owner: String, title: @escaping (String) -> String = ShortcutRegistry.title(for:), registry: ShortcutRegistry = .shared, onFire: @escaping (String) -> Void) {
        self.owner = owner
        self.title = title
        self.registry = registry
        self.onFire = onFire
    }

    deinit { unregisterAll() }

    /// Replaces every shortcut of this feature with this list. Returns the commands that could not be registered.
    @discardableResult
    func update(_ bindings: [ShortcutBinding]) -> [String] {
        failures = registry.register(owner: owner, bindings: bindings, title: title, onFire: onFire)
        return failures
    }

    func unregisterAll() {
        registry.unregister(owner: owner)
        failures = []
    }

    /// The core's modifier bits as the system's hot-key service wants them.
    static func carbonModifiers(_ bits: UInt64) -> UInt32 { CarbonHotKeyBackend.carbonModifiers(bits) }
}
