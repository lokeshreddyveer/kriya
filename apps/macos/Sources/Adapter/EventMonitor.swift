import AppKit
import Combine

/// What a subscriber wants done with an event.
enum EventDisposition {
    case passThrough
    case drop
    case replace(CGEvent)
}

/// The single global event tap every feature shares. Features subscribe with the events they care about; the tap exists
/// only while someone is subscribed, runs on its own thread so the interface never stalls it, and is switched back on
/// if the system turns it off for being slow. Handlers run on the tap's thread and must return quickly.
final class EventMonitor: ObservableObject {
    /// Events Kriya posts itself carry this value, and are passed straight through so features never react to them.
    static let syntheticMarker: Int64 = 0x4B52_4959

    typealias Handler = (CGEventType, CGEvent) -> EventDisposition

    enum Mode { case listenOnly, active }

    enum State: Equatable {
        case stopped
        case running
        case failed(String)
    }

    struct Token: Hashable { fileprivate let id = UUID() }

    struct Stats {
        var eventsHandled = 0
        var slowHandlers = 0
        var worstHandlerMicroseconds = 0
        var tapRecoveries = 0
        /// Over the most recent events only.
        var averageMicroseconds = 0
        var p95Microseconds = 0
        var p99Microseconds = 0
    }

    private struct Subscription {
        let token: Token
        let owner: String
        let mask: CGEventMask
        let mode: Mode
        let priority: Int
        let handler: Handler
    }

    @Published private(set) var state: State = .stopped
    /// Pass-through for every mouse event: no Kriya rule sees or changes a click, move or scroll, whatever is switched on. Keys are not
    /// affected. Set by the person (menu bar, a bound key) or automatically when the tap keeps being switched off for being slow.
    @Published private(set) var mouseRulesPaused = false
    private var passThroughMouse = false              // the tap thread's copy, guarded by lock
    private var recentTimeouts: [UInt64] = []         // guarded by lock
    /// Set when the pause was automatic, so the interface can say why.
    @Published private(set) var pausedAutomatically = false
    /// Why, in words, when it was automatic.
    @Published private(set) var pauseReason: String?

    private let lock = NSLock()
    private var subscriptions: [Subscription] = []   // guarded by lock
    private var tapPort: CFMachPort?                  // guarded by lock
    private var stats = Stats()                       // guarded by lock
    private var lastRecoveryLog: UInt64 = 0           // guarded by lock
    private var samples = [UInt32](repeating: 0, count: EventMonitor.sampleCapacity)   // guarded by lock
    private var nextSample = 0                        // guarded by lock
    private var sampleCount = 0                       // guarded by lock

    private static let sampleCapacity = 512

    private var runLoop: CFRunLoop?
    private var activeMask: CGEventMask = 0
    private var activeMode: Mode = .listenOnly

    private static let slowHandlerNanoseconds: UInt64 = 20_000_000

    static func mask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }

    // MARK: Subscribing

    /// The drag tools take a mouse press before the mouse rules see it, and the mouse rules before everyone else. Higher goes first;
    /// features with no priority keep the order they subscribed in, after these.
    static let dragToolsPriority = 20
    static let mousePriority = 10

    /// Where a new subscriber goes: before the first one with a lower priority, so equal priorities stay in the order they arrived.
    static func insertionIndex(existing priorities: [Int], priority: Int) -> Int {
        priorities.firstIndex(where: { $0 < priority }) ?? priorities.count
    }

    @discardableResult
    func subscribe(owner: String, events: [CGEventType], mode: Mode, priority: Int = 0, handler: @escaping Handler) -> Token {
        let token = Token()
        let new = Subscription(token: token, owner: owner, mask: Self.mask(events), mode: mode, priority: priority, handler: handler)
        lock.lock()
        // Before the first one with a lower priority; equal priorities stay in the order they arrived.
        subscriptions.insert(new, at: Self.insertionIndex(existing: subscriptions.map(\.priority), priority: priority))
        lock.unlock()
        reconfigure()
        return token
    }

    func unsubscribe(_ token: Token) {
        lock.lock()
        subscriptions.removeAll { $0.token == token }
        lock.unlock()
        reconfigure()
    }

    func unsubscribeAll(owner: String) {
        lock.lock()
        subscriptions.removeAll { $0.owner == owner }
        lock.unlock()
        reconfigure()
    }

    /// Who is listening, in the order events are offered to them, and whether each one can change an event or only watch.
    func orderedSubscribers() -> [(owner: String, canChange: Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions.map { ($0.owner, $0.mode == .active) }
    }

    var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions.count
    }

    func currentStats() -> Stats {
        lock.lock()
        var result = stats
        let recent = Array(samples.prefix(sampleCount))
        lock.unlock()
        if !recent.isEmpty {
            let sorted = recent.sorted()
            result.averageMicroseconds = Int(sorted.reduce(0) { $0 + UInt64($1) } / UInt64(sorted.count))
            result.p95Microseconds = Int(sorted[min(sorted.count - 1, sorted.count * 95 / 100)])
            result.p99Microseconds = Int(sorted[min(sorted.count - 1, sorted.count * 99 / 100)])
        }
        return result
    }

    /// Forgets the numbers so far, for measuring a fresh run.
    func resetStats() {
        lock.lock()
        stats = Stats()
        sampleCount = 0
        nextSample = 0
        lock.unlock()
    }

    // MARK: Tap lifecycle (main thread)

    /// Brings the tap in line with the subscriptions: starts it, rebuilds it if the events or mode changed, or stops it.
    private func reconfigure() {
        lock.lock()
        let wanted = subscriptions
        lock.unlock()
        guard !wanted.isEmpty else {
            stopTap()
            return
        }
        let mask = wanted.reduce(CGEventMask(0)) { $0 | $1.mask }
        let mode: Mode = wanted.contains { $0.mode == .active } ? .active : .listenOnly
        if state == .running, mask == activeMask, mode == activeMode { return }
        stopTap()
        startTap(mask: mask, mode: mode)
    }

    private final class StartResult {
        var port: CFMachPort?
        var runLoop: CFRunLoop?
    }

    private func startTap(mask: CGEventMask, mode: Mode) {
        let result = StartResult()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            guard let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: mode == .active ? .defaultTap : .listenOnly,
                eventsOfInterest: mask,
                callback: eventTapCallback,
                userInfo: refcon
            ) else {
                ready.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            self.lock.lock()
            self.tapPort = port
            self.lock.unlock()
            CGEvent.tapEnable(tap: port, enable: true)
            result.port = port
            result.runLoop = loop
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFMachPortInvalidate(port)
        }
        thread.name = "app.kriya.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        guard result.port != nil, let loop = result.runLoop else {
            state = .failed("macOS refused the event tap. Check Accessibility and Input Monitoring in Privacy & Security.")
            Log.error("Events", "Could not create the event tap")
            return
        }
        runLoop = loop
        activeMask = mask
        activeMode = mode
        state = .running
        Log.info("Events", "Event tap started (\(mode == .active ? "active" : "listen-only"), \(subscriberCount) subscribers)")
    }

    private func stopTap() {
        lock.lock()
        let port = tapPort
        tapPort = nil
        lock.unlock()
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let loop = runLoop { CFRunLoopStop(loop) }
        runLoop = nil
        activeMask = 0
        if state == .running { Log.info("Events", "Event tap stopped") }
        state = .stopped
    }

    /// Rebuilds the tap if the system quietly turned it off, for example after sleep or a permission change.
    func verifyHealth() {
        lock.lock()
        let port = tapPort
        let hasSubscribers = !subscriptions.isEmpty
        lock.unlock()
        guard hasSubscribers else { return }
        if let port, CGEvent.tapIsEnabled(tap: port) { return }
        Log.warning("Events", "The event tap was not running; rebuilding it")
        stopTap()
        reconfigure()
    }

    // MARK: Tap thread

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            recoverTap(reason: type == .tapDisabledByTimeout ? "timeout" : "user input")
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        lock.lock()
        let skip = passThroughMouse
        lock.unlock()
        if skip, Self.isMouseEvent(type) { return Unmanaged.passUnretained(event) }

        lock.lock()
        let subs = subscriptions
        lock.unlock()

        let bit = CGEventMask(1) << CGEventMask(type.rawValue)
        let started = DispatchTime.now().uptimeNanoseconds
        let result = Self.dispatch(handlers: subs.filter { $0.mask & bit != 0 }.map(\.handler), type: type, event: event)
        record(elapsed: DispatchTime.now().uptimeNanoseconds - started)
        if result.dropped { return nil }
        if let replacement = result.replacement { return Unmanaged.passRetained(replacement) }
        return Unmanaged.passUnretained(event)
    }

    struct DispatchResult {
        var dropped = false
        var replacement: CGEvent?
    }

    /// Hands an event to each feature in turn. A feature can let it pass, take it (drop) or swap it for another. Once one has
    /// taken it, the features after it do not act on it, but the events that end something are still handed on, so none of
    /// them is left waiting for a release it never saw.
    static func dispatch(handlers: [Handler], type: CGEventType, event: CGEvent) -> DispatchResult {
        var result = DispatchResult()
        var current = event
        for handler in handlers {
            if result.dropped {
                guard endsInteraction(type) else { break }
                _ = handler(type, current)
                continue
            }
            switch handler(type, current) {
            case .passThrough: continue
            case .drop: result.dropped = true
            case .replace(let new): current = new; result.replacement = new
            }
        }
        return result
    }

    /// Clicks, drags, moves and scrolls.
    static func isMouseEvent(_ type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved, .scrollWheel: return true
        default: return false
        }
    }

    /// Whether the system has switched the tap off for being slow this often in this time, which means something is wrong badly enough
    /// that the mouse should be left alone. Pure, so it can be tested.
    static let timeoutWindowNs: UInt64 = 10_000_000_000
    static func tooManyTimeouts(_ times: [UInt64], now: UInt64, count: Int = 3, windowNs: UInt64 = timeoutWindowNs) -> Bool {
        times.filter { now &- $0 <= windowNs }.count >= count
    }

    /// Pauses or resumes every mouse rule at once.
    func setMouseRulesPaused(_ paused: Bool, automatically: Bool = false) {
        lock.lock()
        passThroughMouse = paused
        if !paused { recentTimeouts = [] }
        lock.unlock()
        DispatchQueue.main.async {
            self.mouseRulesPaused = paused
            self.pausedAutomatically = paused && automatically
            if !paused || !automatically { self.pauseReason = nil }
        }
    }

    static func endsInteraction(_ type: CGEventType) -> Bool {
        switch type {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp, .keyUp, .flagsChanged: return true
        default: return false
        }
    }

    private func record(elapsed: UInt64) {
        lock.lock()
        stats.eventsHandled += 1
        let micros = Int(elapsed / 1000)
        if micros > stats.worstHandlerMicroseconds { stats.worstHandlerMicroseconds = micros }
        samples[nextSample] = UInt32(clamping: micros)
        nextSample = (nextSample + 1) % samples.count
        sampleCount = min(sampleCount + 1, samples.count)
        if elapsed > Self.slowHandlerNanoseconds { stats.slowHandlers += 1 }
        lock.unlock()
    }

    /// Called on the main thread, before the tap is switched back on after a pause forced by repeated timeouts: puts every mouse rule
    /// back (held buttons let go, the pointer free, nothing waiting). Set by the app.
    var cleanUpBeforeResuming: (() -> Void)?

    /// The system switched the tap off. A timeout is it saying a handler took too long. The tap is switched back on, except when this is
    /// the third timeout in ten seconds: then mouse events are passed straight through at once, everything is cleaned up, and only then
    /// is the tap switched back on, so keyboard features keep working and nothing is left held. Only the number of timeouts and the time
    /// are kept, never what was typed or clicked.
    private func recoverTap(reason: String) {
        lock.lock()
        let port = tapPort
        stats.tapRecoveries += 1
        let now = DispatchTime.now().uptimeNanoseconds
        var pausing = false
        var count = 0
        if reason == "timeout" {
            recentTimeouts.append(now)
            recentTimeouts.removeAll { now &- $0 > Self.timeoutWindowNs }
            count = recentTimeouts.count
            pausing = Self.tooManyTimeouts(recentTimeouts, now: now) && !passThroughMouse
            // Set here, under the lock, so the very next mouse event already passes through untouched.
            if pausing { passThroughMouse = true }
        }
        let shouldLog = now - lastRecoveryLog > 1_000_000_000
        if shouldLog { lastRecoveryLog = now }
        lock.unlock()

        guard pausing else {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            if shouldLog { Log.warning("Events", "The system switched the event tap off (\(reason)); switched it back on") }
            return
        }
        Log.warning("Events", "The event tap was switched off for being slow \(count) times in ten seconds; mouse rules are paused")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pausedAutomatically = true
            self.pauseReason = "macOS switched Kriya’s mouse hold off for being too slow \(count) times in ten seconds."
            self.mouseRulesPaused = true
            self.cleanUpBeforeResuming?()
            // Only now, with everything let go, is the tap switched back on.
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        }
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EventMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
