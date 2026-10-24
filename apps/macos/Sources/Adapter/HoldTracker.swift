import CoreGraphics
import Foundation

/// Telling a button that is held down from one that is let go straight away. A button that has a hold rule has its press
/// kept back for a moment: held long enough, the rule runs and the release is swallowed; let go sooner, it was an
/// ordinary click and is passed on as one. The clock is given in, so the timing can be tested without waiting.
final class HoldTracker<Payload> {
    struct Press {
        let id: Int
        let device: String
        let button: UInt32
        let downAtMs: UInt64
        let holdMs: UInt64
        let location: CGPoint
        let flags: CGEventFlags
        let payload: Payload
        var fired = false
    }

    enum Release {
        /// This button was not being tracked: nothing to do.
        case notTracked
        /// The hold already ran, so the release is swallowed.
        case afterHold
        /// Let go before the time was up: an ordinary click, to be passed on.
        case early(location: CGPoint, flags: CGEventFlags, payload: Payload)
    }

    private let lock = NSLock()
    private var presses: [HeldKey: Press] = [:]
    private var nextID = 0

    var isTracking: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !presses.isEmpty
    }

    /// Starts keeping a press back. The result identifies it for the timer that will ask whether time is up. A press is kept per device
    /// and button, so the same button held on two devices at once is two presses.
    @discardableResult
    func press(device: String = "", button: UInt32, location: CGPoint, flags: CGEventFlags, nowMs: UInt64, holdMs: UInt64, payload: Payload) -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        presses[HeldKey(device: device, button: button)] = Press(id: nextID, device: device, button: button, downAtMs: nowMs, holdMs: holdMs, location: location, flags: flags, payload: payload)
        return nextID
    }

    /// Asked by the timer. If that same press is still down, was not already handled and has been held long enough, it is
    /// marked as run and its payload is returned. A timer that fires early, late or for a press that is gone gets nothing.
    func fireIfDue(id: Int, nowMs: UInt64) -> Payload? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = presses.first(where: { $0.value.id == id }), !entry.value.fired,
              nowMs >= entry.value.downAtMs, nowMs - entry.value.downAtMs >= entry.value.holdMs else { return nil }
        presses[entry.key]?.fired = true
        return entry.value.payload
    }

    /// A release belongs to its own device's press. If the device is named differently on the way up, it belongs to the oldest press of
    /// that button, so a press is never left running its hold rule after the button was let go.
    func release(device: String = "", button: UInt32) -> Release {
        lock.lock()
        defer { lock.unlock() }
        var key = HeldKey(device: device, button: button)
        if presses[key] == nil {
            guard let other = presses.filter({ $0.key.button == button }).min(by: { $0.value.id < $1.value.id })?.key else { return .notTracked }
            key = other
        }
        guard let press = presses.removeValue(forKey: key) else { return .notTracked }
        return press.fired ? .afterHold : .early(location: press.location, flags: press.flags, payload: press.payload)
    }

    /// Forgets everything, for when the Mac wakes or the feature stops. Nothing is run.
    func cancel() {
        lock.lock()
        presses.removeAll()
        lock.unlock()
    }
}
