import AppKit
import Carbon.HIToolbox
import Combine

/// Whether macOS accepted a shortcut. A refused one is held by another app, or by another feature of Kriya.
enum ShortcutStatus: Equatable {
    case active
    case refused
}

/// One shortcut some part of Kriya wants: who owns it, what it does, and the keys.
struct ShortcutEntry: Identifiable, Hashable {
    let owner: String
    let command: String
    let title: String
    let keyCode: UInt16
    let modifiers: UInt64
    /// The apps it works in. Empty means everywhere.
    var apps: [String] = []
    var status: ShortcutStatus = .active
    /// True when macOS holds the keys through its hot-key service; false when Kriya reads key presses to find it.
    var viaHotKey = true

    var id: String { "\(owner)|\(command)|\(keyCode)|\(modifiers)" }
}

/// Finding shortcuts that want the same keys in the same place. Plain logic, so it can be tested without any keys.
enum ShortcutConflicts {
    /// Groups of two or more shortcuts that clash: the same keys, and at least one place where both apply.
    static func groups(_ entries: [ShortcutEntry]) -> [[ShortcutEntry]] {
        let byKeys = Dictionary(grouping: entries) { "\($0.keyCode):\($0.modifiers)" }
        var result: [[ShortcutEntry]] = []
        for group in byKeys.values where group.count > 1 {
            let clashing = group.filter { entry in group.contains { $0.id != entry.id && overlaps($0, entry) } }
            if clashing.count > 1 { result.append(clashing.sorted { ($0.owner, $0.title) < ($1.owner, $1.title) }) }
        }
        return result.sorted { ($0.first?.keyCode ?? 0, $0.first?.modifiers ?? 0) < ($1.first?.keyCode ?? 0, $1.first?.modifiers ?? 0) }
    }

    /// Two shortcuts share a place when either works everywhere, or they have an app in common.
    static func overlaps(_ a: ShortcutEntry, _ b: ShortcutEntry) -> Bool {
        if a.apps.isEmpty || b.apps.isEmpty { return true }
        return !Set(a.apps).isDisjoint(with: b.apps)
    }
}

/// What actually registers a shortcut with the system. The real one talks to macOS; a test stands one in.
protocol HotKeyBackend: AnyObject {
    /// Called when a registered shortcut is pressed. Returns whether it was handled, so the system can try the next handler.
    var onPressed: ((UInt32) -> Bool)? { get set }
    func register(keyCode: UInt16, modifiers: UInt64, id: UInt32) -> Bool
    func unregister(id: UInt32)
}

/// The one place that owns every shortcut Kriya asks the system for.
///
/// Each feature hands its shortcuts here under its own name. Every shortcut gets an identifier that is unique across all
/// features, one handler routes each press to the feature that owns it, and the whole list can be shown and checked for
/// clashes. Shortcuts that Kriya finds by watching key presses (rather than asking the system) are listed too, so they
/// show up in the same conflict check.
final class ShortcutRegistry: ObservableObject {
    static let shared = ShortcutRegistry(backend: CarbonHotKeyBackend())

    @Published private(set) var entries: [ShortcutEntry] = []

    private struct Owned {
        var callback: (String) -> Void
        var ids: [UInt32: String]
        var entries: [ShortcutEntry]
    }

    private let backend: HotKeyBackend
    /// Guards everything below. Registering can come from any feature's thread while a press arrives from macOS, and this
    /// keeps the two from seeing each other half done. It is never held while a feature's own callback runs.
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    private var owners: [String: Owned] = [:]
    private var passive: [String: [ShortcutEntry]] = [:]

    init(backend: HotKeyBackend) {
        self.backend = backend
        backend.onPressed = { [weak self] id in self?.fire(id) ?? false }
    }

    /// Replaces everything this owner has registered. Returns the commands the system refused.
    @discardableResult
    func register(owner: String, bindings: [ShortcutBinding], title: (String) -> String, onFire: @escaping (String) -> Void) -> [String] {
        lock.lock()
        release(owner)
        var ids: [UInt32: String] = [:]
        var list: [ShortcutEntry] = []
        var failed: [String] = []
        for binding in bindings {
            let id = nextID
            nextID &+= 1
            let accepted = backend.register(keyCode: binding.keyCode, modifiers: binding.modifiers, id: id)
            if accepted { ids[id] = binding.command } else { failed.append(binding.command) }
            list.append(ShortcutEntry(
                owner: owner, command: binding.command, title: title(binding.command), keyCode: binding.keyCode,
                modifiers: binding.modifiers, status: accepted ? .active : .refused
            ))
        }
        owners[owner] = Owned(callback: onFire, ids: ids, entries: list)
        lock.unlock()
        publish()
        if !failed.isEmpty { Log.warning("Shortcuts", "\(owner): \(failed.count) shortcut(s) were refused; another app or feature may use the keys") }
        return failed
    }

    /// Takes back everything this owner registered.
    func unregister(owner: String) {
        lock.lock()
        release(owner)
        owners[owner] = nil
        lock.unlock()
        publish()
    }

    /// Lists shortcuts Kriya finds by watching key presses, so they take part in the conflict check.
    func setPassive(owner: String, entries list: [ShortcutEntry]) {
        lock.lock()
        passive[owner] = list.isEmpty ? nil : list.map { var entry = $0; entry.viaHotKey = false; return entry }
        lock.unlock()
        publish()
    }

    /// Groups of shortcuts that clash, counting the ones macOS refused.
    var conflicts: [[ShortcutEntry]] { ShortcutConflicts.groups(entries) }

    /// Everything that already uses these keys, so a new shortcut can be checked before it is saved.
    func users(of keyCode: UInt16, modifiers: UInt64) -> [ShortcutEntry] {
        entries.filter { $0.keyCode == keyCode && $0.modifiers == modifiers }
    }

    /// The name shown for a command when its owner gave none.
    static func title(for command: String) -> String {
        let known: [String: String] = [
            "palette.open": "Open the command palette", "finder.launcher": "Open the file-action launcher",
            "selection.manual": "Show the selection bar", "clipboard.quick": "Open the quick paste panel",
            "clipboard.plain": "Paste as plain text", "clipboard.strip": "Remove formatting from the clipboard",
            "clipboard.pause": "Pause clipboard history",
        ]
        if let title = known[command] { return title }
        return command.replacingOccurrences(of: ".", with: " › ").replacingOccurrences(of: "_", with: " ")
    }

    // MARK: Inside

    private func release(_ owner: String) {
        guard let owned = owners[owner] else { return }
        for id in owned.ids.keys { backend.unregister(id: id) }
        owners[owner]?.ids = [:]
    }

    private func fire(_ id: UInt32) -> Bool {
        lock.lock()
        var target: ((String) -> Void, String, String)?
        for (owner, owned) in owners {
            if let command = owned.ids[id] {
                target = (owned.callback, command, owner)
                break
            }
        }
        lock.unlock()
        // The feature's own code runs without the lock, so it may register or release shortcuts itself.
        guard let (callback, command, owner) = target else { return false }
        InteractionTrace.shared.note("Shortcut", "\(owner) › \(command)")
        callback(command)
        return true
    }

    /// Updates the list the interface reads, on the main thread.
    private func publish() {
        lock.lock()
        let all = owners.values.flatMap(\.entries) + passive.values.flatMap { $0 }
        lock.unlock()
        let sorted = all.sorted { ($0.owner, $0.title, $0.keyCode) < ($1.owner, $1.title, $1.keyCode) }
        if Thread.isMainThread {
            entries = sorted
        } else {
            DispatchQueue.main.async { self.entries = sorted }
        }
    }
}

/// Registers shortcuts with macOS's hot-key service, which needs no Input Monitoring permission.
final class CarbonHotKeyBackend: HotKeyBackend {
    var onPressed: ((UInt32) -> Bool)?

    private static let signature: OSType = 0x4B52_4959   // "KRIY"
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    deinit {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    func register(keyCode: UInt16, modifiers: UInt64, id: UInt32) -> Bool {
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), Self.carbonModifiers(modifiers), EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == CarbonHotKeyBackend.signature else { return OSStatus(eventNotHandledErr) }
                let backend = Unmanaged<CarbonHotKeyBackend>.fromOpaque(userData).takeUnretainedValue()
                // Only a press that belongs to a registered shortcut is taken; anything else is passed on.
                return backend.onPressed?(hotKeyID.id) == true ? noErr : OSStatus(eventNotHandledErr)
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
    }

    /// The core's modifier bits as the system's hot-key service wants them.
    static func carbonModifiers(_ bits: UInt64) -> UInt32 {
        var result: UInt32 = 0
        if bits & KeyModifiers.command != 0 { result |= UInt32(cmdKey) }
        if bits & KeyModifiers.shift != 0 { result |= UInt32(shiftKey) }
        if bits & KeyModifiers.option != 0 { result |= UInt32(optionKey) }
        if bits & KeyModifiers.control != 0 { result |= UInt32(controlKey) }
        return result
    }
}
