import AppKit
import Combine

/// Mouse and trackpad management: scrolling, pointer speed, button remapping and gestures, per device and per app.
///
/// One handler sits on the shared event tap. For each event it finds which device it came from, takes that device's
/// settings for the app in front, and changes, replaces or swallows the event. Everything it needs is looked up in a
/// ready-made snapshot, so the handler does no disk or interface work.
final class MouseFeature: FeatureModule {
    let feature = FeatureId.mouse

    /// A notched wheel's "one line" in pixels, for turning wheel movement into smooth scrolling.
    static let pixelsPerLine = 10.0

    private static let eventTypes: [CGEventType] = [
        .scrollWheel,
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .flagsChanged,
    ]

    private var context: ServiceContext?
    private var token: EventMonitor.Token?
    private var cancellables = Set<AnyCancellable>()

    private let verticalShaper: ScrollShaper
    private let horizontalShaper: ScrollShaper
    private let smoother: SmoothScroller
    private let driver: SmoothScrollDriver
    private let gestures = GestureEngine(config: GestureEngineConfig(activationButton: nil, threshold: 60, timeoutMs: 600, rocker: false))
    private let tuner = PointerTuner()

    // Touched only on the tap's thread: which settings the shapers and the gesture engine were last given.
    private var appliedKey: String?
    private var appliedRevision = -1

    private let lock = NSLock()
    private var swallowedReleases: Set<UInt32> = []   // guarded by lock
    private var precisionActive = false               // guarded by lock

    init() {
        let neutral = defaultMouseSettings().vertical
        verticalShaper = ScrollShaper(axis: neutral)
        horizontalShaper = ScrollShaper(axis: neutral)
        let scroller = SmoothScroller()
        smoother = scroller
        driver = SmoothScrollDriver(scroller: scroller)
    }

    // MARK: FeatureModule

    func start(context: ServiceContext) throws {
        self.context = context
        context.activity.start()
        token = context.events.subscribe(owner: "mouse", events: Self.eventTypes, mode: .active) { [weak self] type, event in
            self?.process(type: type, event: event) ?? .passThrough
        }
        if case .failed(let reason) = context.events.state {
            stop()
            throw NSError(domain: "Kriya", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        Publishers.Merge(
            context.mouse.$revision.map { _ in () }.eraseToAnyPublisher(),
            context.devices.$devices.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
        .sink { [weak self] in self?.applyPointerSettings() }
        .store(in: &cancellables)
        applyPointerSettings()
        registerPointerCommands(context)
        Log.info("Mouse", "Mouse and trackpad management started")
    }

    func stop() {
        for command in Self.pointerCommands.keys { context?.executor.unregisterCommand(command) }
        if let token { context?.events.unsubscribe(token) }
        token = nil
        cancellables.removeAll()
        driver.stop()
        smoother.clear()
        gestures.reset()
        tuner.restoreAll()
        context?.activity.stop()
        lock.lock()
        swallowedReleases.removeAll()
        precisionActive = false
        lock.unlock()
        appliedKey = nil
        appliedRevision = -1
        context = nil
    }

    // MARK: Moving the pointer between displays

    private static let pointerCommands: [String: Int] = ["mouse.next_display": 1, "mouse.previous_display": -1]

    /// Makes "move the pointer to the next or previous display" available to shortcuts, buttons and gestures.
    private func registerPointerCommands(_ context: ServiceContext) {
        let displays = context.windowController.displays
        for (command, offset) in Self.pointerCommands {
            context.executor.registerCommand(command) { Self.movePointer(by: offset, displays: displays) }
        }
    }

    /// Puts the pointer on another display, at the same relative spot it had on this one.
    private static func movePointer(by offset: Int, displays: DisplayManager) {
        displays.refresh()
        let list = displays.ordered
        guard list.count > 1 else { return }
        let pointer = DisplayManager.mouseLocation()
        guard let current = list.firstIndex(where: { $0.full.cg.contains(pointer) }) else { return }
        let from = list[current].full
        let to = list[(current + offset + list.count) % list.count].full
        let rx = (pointer.x - from.x) / from.width
        let ry = (pointer.y - from.y) / from.height
        CGWarpMouseCursorPosition(CGPoint(x: to.x + rx * to.width, y: to.y + ry * to.height))
        // Warping detaches the mouse from the cursor for a moment; this puts them back together.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    func systemDidWake() {
        // Sleep can drop the pointer settings and any half-finished press.
        gestures.reset()
        applyPointerSettings()
    }

    // MARK: The event handler (runs on the event tap's thread)

    func process(type: CGEventType, event: CGEvent) -> EventDisposition {
        guard let context, context.profiles.isFeatureActive(.mouse) else { return .passThrough }

        // A drag while a gesture is being drawn is the gesture's; keep it away from other apps.
        if type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
            guard gestures.isGestureActive() else { return .passThrough }
            let location = event.location
            gestures.moved(x: location.x, y: location.y)
            return .drop
        }

        let deviceID = context.activity.currentDeviceID()
        guard let compiled = context.mouse.compiled(forDevice: deviceID) else {
            gestures.reset()
            return .passThrough
        }
        sync(compiled, deviceID: deviceID, revision: context.mouse.snapshotRevision())

        let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
        switch type {
        case .scrollWheel:
            return handleScroll(event, compiled, nowMs: now)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return handleButton(down: true, event, compiled, nowMs: now)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return handleButton(down: false, event, compiled, nowMs: now)
        case .flagsChanged:
            handleModifiers(event, compiled)
            return .passThrough
        default:
            return .passThrough
        }
    }

    /// Hands the shapers and the gesture engine the current settings, but only when they have changed.
    private func sync(_ compiled: CompiledMouse, deviceID: String?, revision: Int) {
        let key = deviceID ?? ""
        guard key != appliedKey || revision != appliedRevision else { return }
        verticalShaper.setAxis(axis: compiled.settings.vertical)
        horizontalShaper.setAxis(axis: compiled.settings.horizontal)
        gestures.setConfig(config: compiled.gestureConfig)
        appliedKey = key
        appliedRevision = revision
    }

    // MARK: Scrolling

    private func handleScroll(_ event: CGEvent, _ compiled: CompiledMouse, nowMs: UInt64) -> EventDisposition {
        let settings = compiled.settings
        let held = KeyModifiers.bits(from: event.flags)
        // Holding the "plain scroll" keys leaves the scroll exactly as the mouse sent it.
        if settings.rawScrollModifier != 0, held & settings.rawScrollModifier == settings.rawScrollModifier { return .passThrough }
        // Holding the "sideways" keys turns up and down into left and right.
        let sideways = settings.horizontalScrollModifier != 0 && held & settings.horizontalScrollModifier == settings.horizontalScrollModifier
        if !sideways, compiled.verticalIsNeutral && compiled.horizontalIsNeutral { return .passThrough }
        if sideways { event.flags = event.flags.subtracting(KeyModifiers.flags(from: settings.horizontalScrollModifier)) }

        // Trackpads and Magic Mouse send fine, continuous movement: only direction and speed apply.
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
            if sideways { swapAxes(event) }
            scaleContinuous(event, axis: 1, settings.vertical)
            scaleContinuous(event, axis: 2, settings.horizontal)
            return .passThrough
        }

        var lineY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        var lineX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        if sideways {
            lineX = lineY
            lineY = 0
        }
        let y = verticalShaper.shape(delta: lineY, nowMs: nowMs)
        let x = horizontalShaper.shape(delta: lineX, nowMs: nowMs)

        let smoothing = max(settings.vertical.smoothing, settings.horizontal.smoothing)
        if smoothing > 0 {
            smoother.push(dx: x * Self.pixelsPerLine, dy: y * Self.pixelsPerLine, smoothing: smoothing)
            driver.wake(flags: event.flags, location: event.location)
            return .drop
        }

        write(event, axis: 1, lines: y)
        write(event, axis: 2, lines: x)
        return .passThrough
    }

    /// Swaps up-and-down with left-and-right in a scroll event from a trackpad or Magic Mouse.
    private func swapAxes(_ event: CGEvent) {
        let whole: [(CGEventField, CGEventField)] = [
            (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2),
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
        ]
        for (a, b) in whole {
            let first = event.getIntegerValueField(a)
            event.setIntegerValueField(a, value: event.getIntegerValueField(b))
            event.setIntegerValueField(b, value: first)
        }
        let fixed1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixed1)
    }

    private func scaleContinuous(_ event: CGEvent, axis: Int, _ settings: ScrollAxis) {
        let factor = scrollContinuous(delta: 1, speed: settings.speed, reverse: settings.reverse)
        guard factor != 1 else { return }
        let point: CGEventField = axis == 1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2
        let fixed: CGEventField = axis == 1 ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2
        let whole: CGEventField = axis == 1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2
        event.setIntegerValueField(point, value: Int64((Double(event.getIntegerValueField(point)) * factor).rounded()))
        event.setDoubleValueField(fixed, value: event.getDoubleValueField(fixed) * factor)
        event.setIntegerValueField(whole, value: Int64((Double(event.getIntegerValueField(whole)) * factor).rounded()))
    }

    /// Writes a notched wheel's shaped movement back into the event, in lines, whole lines and pixels.
    private func write(_ event: CGEvent, axis: Int, lines: Double) {
        let fixed: CGEventField = axis == 1 ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2
        let whole: CGEventField = axis == 1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2
        let point: CGEventField = axis == 1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2
        event.setDoubleValueField(fixed, value: lines)
        event.setIntegerValueField(whole, value: Self.wholeLines(lines))
        event.setIntegerValueField(point, value: Int64((lines * Self.pixelsPerLine).rounded()))
    }

    /// Whole lines for apps that read only whole numbers: never zero for a movement that was not zero.
    static func wholeLines(_ lines: Double) -> Int64 {
        guard lines != 0 else { return 0 }
        let rounded = Int64(lines.rounded())
        if rounded != 0 { return rounded }
        return lines > 0 ? 1 : -1
    }

    // MARK: Buttons, gestures and rocker clicks

    private func handleButton(down: Bool, _ event: CGEvent, _ compiled: CompiledMouse, nowMs: UInt64) -> EventDisposition {
        let button = UInt32(truncatingIfNeeded: event.getIntegerValueField(.mouseEventButtonNumber))
        let location = event.location
        let modifiers = KeyModifiers.bits(from: event.flags)

        let decision = down
            ? gestures.buttonDown(button: button, x: location.x, y: location.y, nowMs: nowMs)
            : gestures.buttonUp(button: button, x: location.x, y: location.y, nowMs: nowMs)
        switch decision {
        case .passThrough:
            break
        case .swallow:
            return .drop
        case .rocker(let kind):
            run(kind == .rightThenLeft ? compiled.rockerRightThenLeft : compiled.rockerLeftThenRight)
            return .drop
        case .gesture(let direction):
            run(compiled.gestureActions[direction])
            return .drop
        case .replayClick(let replayed):
            // The press was held back to see if it became a gesture. It did not, so it is an ordinary click, or
            // the button's own rule if it has one.
            if let action = compiled.buttonActions[ButtonKey(button: replayed, modifiers: modifiers)] {
                run(action)
            } else {
                replayClick(button: replayed, at: location, flags: event.flags)
            }
            return .drop
        }

        let key = ButtonKey(button: button, modifiers: modifiers)
        lock.lock()
        defer { lock.unlock() }
        if down {
            if let action = compiled.buttonActions[key] {
                swallowedReleases.insert(button)
                run(action)
                return .drop
            }
        } else if swallowedReleases.remove(button) != nil {
            return .drop
        }
        return .passThrough
    }

    private func run(_ action: Action?) {
        guard let action, let executor = context?.executor else { return }
        Task.detached { _ = await executor.perform(action) }
    }

    /// Performs the click a gesture button would have made, marked so Kriya does not handle it again.
    private func replayClick(button: UInt32, at location: CGPoint, flags: CGEventFlags) {
        let types: (down: CGEventType, up: CGEventType)
        switch button {
        case 0: types = (.leftMouseDown, .leftMouseUp)
        case 1: types = (.rightMouseDown, .rightMouseUp)
        default: types = (.otherMouseDown, .otherMouseUp)
        }
        let mouseButton = CGMouseButton(rawValue: button) ?? .center
        for type in [types.down, types.up] {
            guard let click = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: mouseButton) else { continue }
            click.flags = flags
            click.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            click.setIntegerValueField(.mouseEventClickState, value: 1)
            click.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
            click.post(tap: .cghidEventTap)
        }
    }

    // MARK: Pointer precision mode

    private func handleModifiers(_ event: CGEvent, _ compiled: CompiledMouse) {
        let wanted = compiled.settings.pointer.precisionModifier
        guard wanted != 0 else { return }
        let held = (KeyModifiers.bits(from: event.flags) & wanted) == wanted
        lock.lock()
        let changed = held != precisionActive
        precisionActive = held
        lock.unlock()
        if changed { DispatchQueue.main.async { [weak self] in self?.applyPointerSettings() } }
    }

    // MARK: Pointer speed (main thread)

    private func applyPointerSettings() {
        guard let context else { return }
        lock.lock()
        let precision = precisionActive
        lock.unlock()
        for device in context.devices.devices where device.isConnected {
            guard let compiled = context.mouse.compiled(forDevice: device.id) else {
                tuner.apply(vendor: Int(device.record.vendorId), product: Int(device.record.productId), trackpad: device.record.kind == .trackpad, value: nil)
                continue
            }
            let pointer = compiled.settings.pointer
            let value = precision ? pointerPrecisionTrackingValue(pointer: pointer) : pointerTrackingValue(pointer: pointer)
            tuner.apply(
                vendor: Int(device.record.vendorId), product: Int(device.record.productId),
                trackpad: device.record.kind == .trackpad, value: value
            )
        }
    }
}
