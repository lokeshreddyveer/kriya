import AppKit

/// Carries out key remapping: reads each key press from the shared event tap, asks the core's engine what it means (a
/// tap, a hold, a double tap, a combination, a modifier) and sends the answer on. Kriya's own key events carry a marker,
/// so they are never remapped twice.
///
/// Caps Lock is handed to the engine as F18, which the system helper `hidutil` swaps in while a rule uses it. The swap is
/// removed again when remapping stops and when Kriya quits, so Caps Lock is never left changed.
final class RemapService {
    private let events: EventMonitor
    private let store: RemapStore
    private let runAction: (String) -> Void
    private let keyboards: KeyboardDevices
    private var token: EventMonitor.Token?
    private let engine = RemapEngine(config: RemapConfig(enabled: false, rules: [], holdMs: 200, doubleTapMs: 250, chordMs: 50))
    private let queue = DispatchQueue(label: "app.kriya.remap", qos: .userInteractive)
    private var timer: DispatchSourceTimer?      // used only on `queue`
    private var capsSwapped = false

    /// The modifier a modifier key code stands for.
    private static let modifierFlags: [UInt16: CGEventFlags] = [
        54: .maskCommand, 55: .maskCommand, 56: .maskShift, 60: .maskShift, 58: .maskAlternate, 61: .maskAlternate,
        59: .maskControl, 62: .maskControl, 63: .maskSecondaryFn,
    ]

    init(events: EventMonitor, store: RemapStore, keyboards: KeyboardDevices, runAction: @escaping (String) -> Void) {
        self.events = events
        self.store = store
        self.keyboards = keyboards
        self.runAction = runAction
    }

    /// A media key arrives as a system event, not a key press; the engine knows them by 1000 plus the system's number.
    private static let systemDefined = CGEventType(rawValue: 14)!

    /// Follows the settings: running while remapping is on and allowed, off otherwise.
    func apply(allowed: Bool) {
        var config = store.current
        // A rule for one keyboard counts only while that keyboard is connected.
        config.rules = config.rules.filter { rule in rule.keyboard.map { keyboards.names.contains($0) } ?? true }
        engine.setConfig(config: config)
        if config.enabled, !config.rules.isEmpty, allowed {
            if token == nil {
                token = events.subscribe(owner: "keyboard.remap", events: [.keyDown, .keyUp, .flagsChanged, Self.systemDefined], mode: .active) { [weak self] type, event in
                    self?.handle(type, event) ?? .passThrough
                }
            }
            setCapsSwap(store.usesCapsLock)
        } else {
            stop()
        }
    }

    func stop() {
        if let token { events.unsubscribe(token) }
        token = nil
        engine.reset()
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
        setCapsSwap(false)
    }

    // MARK: Events (on the tap's thread)

    private func handle(_ type: CGEventType, _ event: CGEvent) -> EventDisposition {
        var code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let down: Bool
        if type == Self.systemDefined {
            // Volume, brightness and play keys: subtype 8, the key in the top half of data1 and up or down in its low half.
            guard let system = NSEvent(cgEvent: event), system.subtype.rawValue == 8 else { return .passThrough }
            let data = system.data1
            let state = (data & 0xFF00) >> 8
            guard state == 0xA || state == 0xB else { return .passThrough }
            code = UInt16(1000 + ((data & 0xFFFF0000) >> 16))
            down = state == 0xA
        } else if type == .flagsChanged {
            // A modifier key reports a change; whether it went down is whether its modifier is now on.
            guard let flag = Self.modifierFlags[code] else { return .passThrough }
            down = event.flags.contains(flag)
        } else {
            down = type == .keyDown
        }
        let held = KeyModifiers.bits(from: event.flags)
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let result = engine.handleKey(keyCode: code, isDown: down, modifiers: held, appId: app, nowMs: Self.now())
        perform(result.effects)
        if result.addModifiers != 0 || result.stripModifiers != 0 {
            event.flags = event.flags.subtracting(KeyModifiers.flags(from: result.stripModifiers)).union(KeyModifiers.flags(from: result.addModifiers))
        }
        startTimerIfNeeded()
        return result.swallow ? .drop : .passThrough
    }

    // MARK: Time (tap, hold and double-tap windows)

    private func startTimerIfNeeded() {
        guard engine.isBusy() else { return }
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + .milliseconds(15), repeating: .milliseconds(15), leeway: .milliseconds(3))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let result = self.engine.tick(nowMs: Self.now())
                self.perform(result.effects)
                if !self.engine.isBusy() {
                    self.timer?.cancel()
                    self.timer = nil
                }
            }
            timer = source
            source.resume()
        }
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }

    // MARK: Doing what the engine decided

    private func perform(_ effects: [EngineEffect]) {
        for effect in effects {
            switch effect {
            case .press(let code, let mods):
                post(code, down: true, mods)
                post(code, down: false, mods)
            case .keyDown(let code, let mods):
                post(code, down: true, mods)
            case .keyUp(let code, let mods):
                post(code, down: false, mods)
            case .runAction(let id):
                DispatchQueue.main.async { [runAction] in runAction(id) }
            }
        }
    }

    private func post(_ code: UInt16, down: Bool, _ modifiers: UInt64) {
        if code >= 1000 {
            postMedia(Int(code) - 1000, down: down)
            return
        }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down) else { return }
        event.flags = KeyModifiers.flags(from: modifiers)
        event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }

    private func postMedia(_ key: Int, down: Bool) {
        let state = down ? 0xA00 : 0xB00
        let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)), timestamp: 0,
            windowNumber: 0, context: nil, subtype: 8, data1: (key << 16) | state, data2: -1
        )
        guard let cg = event?.cgEvent else { return }
        cg.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
        cg.post(tap: .cghidEventTap)
    }

    // MARK: Caps Lock

    /// Turns Caps Lock into F18 (and back) for the whole keyboard, with the system's own `hidutil`.
    private func setCapsSwap(_ on: Bool) {
        guard on != capsSwapped else { return }
        capsSwapped = on
        let mapping = on
            ? "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":30064771129,\"HIDKeyboardModifierMappingDst\":30064771181}]}"
            : "{\"UserKeyMapping\":[]}"
        DispatchQueue.global(qos: .utility).async {
            _ = try? ToolRunner.run("/usr/bin/hidutil", ["property", "--set", mapping])
        }
    }
}
