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
        let handler: Handler
    }

    @Published private(set) var state: State = .stopped

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

    @discardableResult
    func subscribe(owner: String, events: [CGEventType], mode: Mode, handler: @escaping Handler) -> Token {
        let token = Token()
        lock.lock()
        subscriptions.append(Subscription(token: token, owner: owner, mask: Self.mask(events), mode: mode, handler: handler))
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
        let subs = subscriptions
        lock.unlock()

        let bit = CGEventMask(1) << CGEventMask(type.rawValue)
        let started = DispatchTime.now().uptimeNanoseconds
        var current = event
        var replaced = false
        var dropped = false
        for sub in subs where sub.mask & bit != 0 {
            switch sub.handler(type, current) {
            case .passThrough: continue
            case .drop: dropped = true
            case .replace(let new): current = new; replaced = true
            }
            if dropped { break }
        }
        record(elapsed: DispatchTime.now().uptimeNanoseconds - started)
        if dropped { return nil }
        return replaced ? Unmanaged.passRetained(current) : Unmanaged.passUnretained(event)
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

    private func recoverTap(reason: String) {
        lock.lock()
        let port = tapPort
        stats.tapRecoveries += 1
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldLog = now - lastRecoveryLog > 1_000_000_000
        if shouldLog { lastRecoveryLog = now }
        lock.unlock()
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
        if shouldLog { Log.warning("Events", "The system switched the event tap off (\(reason)); switched it back on") }
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
