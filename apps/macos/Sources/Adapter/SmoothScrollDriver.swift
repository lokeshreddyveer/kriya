import CoreGraphics
import Foundation

/// Posts the glide the core's `SmoothScroller` produces. While there is movement left it runs a timer at about 125 Hz,
/// turns each slice into whole-pixel scroll events, and carries the leftover fraction to the next tick.
final class SmoothScrollDriver {
    typealias Poster = (_ dx: Int32, _ dy: Int32, _ flags: CGEventFlags, _ location: CGPoint) -> Void

    private let scroller: SmoothScroller
    private let post: Poster
    private let queue = DispatchQueue(label: "app.kriya.smoothscroll", qos: .userInteractive)
    private var timer: DispatchSourceTimer?   // used only on `queue`
    private var flags = CGEventFlags()
    private var location = CGPoint.zero
    private var carryX = 0.0
    private var carryY = 0.0
    private var lastTick: UInt64 = 0

    private static let interval: DispatchTimeInterval = .milliseconds(8)

    init(scroller: SmoothScroller, post: @escaping Poster = SmoothScrollDriver.postScroll) {
        self.scroller = scroller
        self.post = post
    }

    /// Makes sure the timer is running. Called whenever movement has been added to the scroller.
    func wake(flags: CGEventFlags, location: CGPoint) {
        queue.async { [self] in
            self.flags = flags
            self.location = location
            guard timer == nil else { return }
            lastTick = DispatchTime.now().uptimeNanoseconds
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(1))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            carryX = 0
            carryY = 0
        }
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let dtMs = Double(now &- lastTick) / 1_000_000
        lastTick = now
        let step = scroller.tick(dtMs: dtMs)
        carryX += step.dx
        carryY += step.dy
        let idle = scroller.isIdle()
        // When the glide has finished, round what is left instead of dropping up to a pixel.
        let mode: FloatingPointRoundingRule = idle ? .toNearestOrAwayFromZero : .towardZero
        let ix = Int32(carryX.rounded(mode))
        let iy = Int32(carryY.rounded(mode))
        carryX -= Double(ix)
        carryY -= Double(iy)
        if ix != 0 || iy != 0 { post(ix, iy, flags, location) }
        if idle {
            carryX = 0
            carryY = 0
            timer?.cancel()
            timer = nil
        }
    }

    /// Posts one smooth-scroll event. Kriya's own events carry a marker so Kriya never scrolls them a second time.
    static func postScroll(dx: Int32, dy: Int32, flags: CGEventFlags, location: CGPoint) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0
        ) else { return }
        event.flags = flags
        event.location = location
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: EventMonitor.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }
}
