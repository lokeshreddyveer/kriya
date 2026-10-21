import AppKit
import Carbon.HIToolbox

/// Global keyboard shortcuts through the system's hot-key service. Unlike watching every key press, this needs no
/// Input Monitoring permission: macOS tells Kriya only about the combinations it registered.
final class HotkeyCenter {
    private struct Registration {
        let ref: EventHotKeyRef
        let command: String
    }

    private static let signature: OSType = 0x4B52_4959   // "KRIY"

    private var registrations: [UInt32: Registration] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1
    private let onFire: (String) -> Void

    /// Commands the system refused, usually because another app already owns the combination.
    private(set) var failures: [String] = []

    init(onFire: @escaping (String) -> Void) {
        self.onFire = onFire
    }

    deinit { unregisterAll() }

    /// Replaces every registered shortcut with this list. Returns the commands that could not be registered.
    @discardableResult
    func update(_ bindings: [ShortcutBinding]) -> [String] {
        unregisterAll()
        installHandlerIfNeeded()
        var failed: [String] = []
        for binding in bindings {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: nextID)
            let status = RegisterEventHotKey(
                UInt32(binding.keyCode), Self.carbonModifiers(binding.modifiers), id, GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                registrations[nextID] = Registration(ref: ref, command: binding.command)
                nextID += 1
            } else {
                failed.append(binding.command)
            }
        }
        failures = failed
        if !failed.isEmpty { Log.warning("Windows", "\(failed.count) shortcut(s) could not be registered; another app may use them") }
        return failed
    }

    func unregisterAll() {
        for registration in registrations.values { UnregisterEventHotKey(registration.ref) }
        registrations.removeAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    fileprivate func fire(id: UInt32) {
        guard let command = registrations[id]?.command else { return }
        onFire(command)
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
                guard status == noErr, hotKeyID.signature == HotkeyCenter.signature else { return OSStatus(eventNotHandledErr) }
                Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue().fire(id: hotKeyID.id)
                return noErr
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
