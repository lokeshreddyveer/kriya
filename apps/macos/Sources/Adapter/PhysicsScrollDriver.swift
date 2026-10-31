import AppKit
import CoreVideo

/// Something that calls back once per screen refresh. The real one follows the display; a check supplies one it can step by hand.
protocol FrameClock: AnyObject {
    /// Starts calling `tick` with the time since the last call, in milliseconds. Called on any thread.
    func start(_ tick: @escaping (_ dtMs: Double) -> Void)
    func stop()
}

/// Ticks in step with the display's refresh, so a glide is drawn once per frame, not at a rate that beats against it. Uses the
/// display link on its own thread; a Mac with no display link (nothing is attached) falls back to a 120 Hz timer.
final class DisplayLinkClock: FrameClock {
    private var link: CVDisplayLink?
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var last: UInt64 = 0
    private var handler: ((Double) -> Void)?

    func start(_ tick: @escaping (Double) -> Void) {
        lock.lock()
        handler = tick
        last = 0
        lock.unlock()
        var created: CVDisplayLink?
        if CVDisplayLinkCreateWithActiveCGDisplays(&created) == kCVReturnSuccess, let created {
            let context = Unmanaged.passUnretained(self).toOpaque()
            CVDisplayLinkSetOutputCallback(created, { _, _, outTime, _, _, context in
                guard let context else { return kCVReturnSuccess }
                Unmanaged<DisplayLinkClock>.fromOpaque(context).takeUnretainedValue().fire(hostTime: outTime.pointee.hostTime)
                return kCVReturnSuccess
            }, context)
            if CVDisplayLinkStart(created) == kCVReturnSuccess { link = created; return }
        }
        // No display link: a timer at 120 Hz, which is smooth on any screen.
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.kriya.scrollphysics.timer", qos: .userInteractive))
        source.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.fire(hostTime: DispatchTime.now().uptimeNanoseconds) }
        timer = source
        source.resume()
    }

    func stop() {
        if let link { CVDisplayLinkStop(link) }
        link = nil
        timer?.cancel()
        timer = nil
        lock.lock(); handler = nil; lock.unlock()
    }

    private func fire(hostTime: UInt64) {
        lock.lock()
        let tick = handler
        let previous = last
        last = hostTime
        lock.unlock()
        guard let tick, previous != 0 else { return }
        // Host time is in the machine's own units; convert to nanoseconds, and from there to milliseconds.
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        let ns = Double(hostTime &- previous) * Double(base.numer) / Double(max(base.denom, 1))
        tick(ns / 1_000_000)
    }
}

/// Where scroll frames end up. The real one posts events that carry the gesture and momentum phases; a check collects them.
protocol ScrollPoster: AnyObject {
    func post(dx: Int32, dy: Int32, frame: ScrollFrame, flags: CGEventFlags, location: CGPoint)
    /// Zoom by `amount` (positive zooms in): the system's own scroll-to-zoom, sent as a scroll with the Control key.
    func zoom(_ amount: Double, flags: CGEventFlags, location: CGPoint)
}

/// Posts scroll events the way a trackpad does: continuous pixel scrolling with an explicit scroll phase and momentum phase, so apps
/// that care about gestures (rubber-banding, pull-to-refresh, swipe-back) see a real gesture begin, change and end.
final class PhasedScrollPoster: ScrollPoster {
    func post(dx: Int32, dy: Int32, frame: ScrollFrame, flags: CGEventFlags, location: CGPoint) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        event.flags = flags
        event.location = location
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(frame.phase.rawValue))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(frame.momentum.rawValue))
        event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }

    func zoom(_ amount: Double, flags: CGEventFlags, location: CGPoint) {
        let pixels = Int32(max(min((amount * 10).rounded(), 400), -400))
        guard pixels != 0, let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0) else { return }
        event.flags = flags.union(.maskControl)
        event.location = location
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }
}

/// Runs the engine against a clock and posts what it produces. Everything is on one queue, so wheel input, the clock and a cancel from
/// outside never see each other half done.
final class PhysicsScrollDriver {
    private let queue = DispatchQueue(label: "app.kriya.scrollphysics", qos: .userInteractive)
    private let clock: FrameClock
    private let poster: ScrollPoster
    private var engine: ScrollPhysicsEngine          // used only on `queue`
    private var carry = ScrollCarry()                // used only on `queue`
    private var flags = CGEventFlags()
    private var location = CGPoint.zero
    private var running = false

    init(config: ScrollPhysicsConfig = ScrollPhysicsConfig(), clock: FrameClock = DisplayLinkClock(), poster: ScrollPoster = PhasedScrollPoster()) {
        engine = ScrollPhysicsEngine(config: config)
        self.clock = clock
        self.poster = poster
    }

    func update(_ config: ScrollPhysicsConfig) { queue.async { self.engine.update(config) } }

    /// One wheel movement, in pixels. Starts the clock if the scroll was at rest.
    func push(dx: Double, dy: Double, precise: Bool, flags: CGEventFlags, location: CGPoint) {
        queue.async { [self] in
            self.flags = flags
            self.location = location
            // Anything that was carrying on is stopped first, with its explicit cancel, before the new movement is posted.
            emit(engine.push(dx: dx, dy: dy, precise: precise))
            startClockIfNeeded()
        }
    }

    func zoom(_ amount: Double, flags: CGEventFlags, location: CGPoint) {
        queue.async { [self] in poster.zoom(amount, flags: flags, location: location) }
    }

    /// Stops a glide or momentum from outside, posting the cancel so apps stop with it.
    func cancel() {
        queue.async { [self] in
            emit(engine.cancel())
            stopClock()
        }
    }

    private func startClockIfNeeded() {
        guard !running, engine.isActive else { return }
        running = true
        clock.start { [weak self] dt in self?.queue.async { self?.tick(dt) } }
    }

    private func stopClock() {
        guard running else { return }
        running = false
        clock.stop()
        carry.clear()
    }

    private func tick(_ dtMs: Double) {
        guard running else { return }
        emit(engine.step(dtMs: dtMs))
        if !engine.isActive { stopClock() }
    }

    private func emit(_ frames: [ScrollFrame]) {
        for frame in frames {
            // The last frame of a gesture or of momentum is flushed, so no leftover fraction of a pixel is lost.
            let ends = frame.phase == .ended || frame.phase == .cancelled || frame.momentum == .ended
            let (ix, iy) = carry.take(dx: frame.dx, dy: frame.dy, flush: ends)
            // A frame that moves nothing is still posted when it carries a phase: the end of a gesture and the momentum cancel are
            // events in their own right.
            if ix != 0 || iy != 0 || frame.phase != .changed && frame.momentum != .changed {
                poster.post(dx: ix, dy: iy, frame: frame, flags: flags, location: location)
            }
        }
    }
}
