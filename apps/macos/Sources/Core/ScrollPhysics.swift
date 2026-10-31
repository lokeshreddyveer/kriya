import Foundation

// MARK: - Phases and frames

/// The phase of a scroll gesture, as a trackpad reports it: a finger touches down, moves, lifts, or the system takes the gesture away.
enum ScrollPhase: Int, Equatable {
    case none = 0
    case began = 1
    case changed = 4
    case ended = 8
    case cancelled = 16
}

/// The phase of the glide that carries on after the finger lifts.
enum MomentumPhase: Int, Equatable {
    case none = 0
    case began = 1
    case changed = 4
    case ended = 8
}

/// One step of scrolling to post: how far, and where in the gesture it falls.
struct ScrollFrame: Equatable {
    var dx: Double
    var dy: Double
    var phase: ScrollPhase
    var momentum: MomentumPhase
    /// True for the explicit "stop gliding" frame sent when new input arrives, or when the glide is cancelled from outside. It carries no
    /// movement; apps see the end of the momentum phase and stop at once.
    var isMomentumCancel = false

    var isEmpty: Bool { dx == 0 && dy == 0 }
}

/// Where a scroll event came from. Each kind is handled differently, and Kriya's own are never scrolled a second time.
enum ScrollInputKind: Equatable {
    /// A notched wheel: whole lines at a time.
    case wheel
    /// A trackpad or Magic Mouse: fine, continuous movement that already has its own phases and momentum.
    case continuous
    /// A momentum or glide event Kriya posted itself.
    case syntheticMomentum

    /// From the fields of an event. `marker` is the mark Kriya puts on everything it posts.
    static func classify(isContinuous: Bool, userData: Int64, marker: Int64) -> ScrollInputKind {
        if userData == marker { return .syntheticMomentum }
        return isContinuous ? .continuous : .wheel
    }
}

// MARK: - Curves

/// How a glide approaches where it is going.
enum ScrollCurve: String, Codable, CaseIterable, Identifiable {
    /// Steady speed from start to finish.
    case linear
    /// Fast at first, easing out: each step covers a share of what is left.
    case exponential
    /// A spring tuned so it never overshoots and settles as quickly as it can.
    case criticallyDamped
    /// A finger's feel: it follows the wheel closely, then carries on and slows like a trackpad's momentum.
    case trackpadLike

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linear: return "Linear"
        case .exponential: return "Exponential (eases out)"
        case .criticallyDamped: return "Critically damped (spring)"
        case .trackpadLike: return "Trackpad-like"
        }
    }
}

enum HorizontalTransform: String, Codable, CaseIterable, Identifiable {
    case none, invert
    var id: String { rawValue }
    var title: String { self == .none ? "As sent" : "Reverse sideways scrolling" }
}

// MARK: - Settings

struct ScrollPhysicsConfig: Codable, Equatable {
    var curve: ScrollCurve = .exponential
    /// How far one notch of the wheel asks to scroll, in pixels.
    var pixelsPerLine = 40.0
    /// How long a glide takes to settle, in milliseconds.
    var glideMs = 220.0
    /// The glide carries on after the last wheel movement, slowing like a trackpad's.
    var momentum = true
    /// How long the carry-on takes to slow by a factor of e, in milliseconds.
    var momentumMs = 350.0
    /// Hold these keys for quick scrolling (larger steps) or precise scrolling (small steps, no carry-on). Key bits as the core counts them.
    var quickModifier: UInt64 = 0
    var preciseModifier: UInt64 = 0
    var quickMultiplier = 4.0
    var preciseMultiplier = 0.25
    /// Hold these keys while scrolling to zoom, or to rotate, instead of scrolling.
    var zoomModifier: UInt64 = 0
    var rotateModifier: UInt64 = 0
    var invertVertical = false
    var horizontal: HorizontalTransform = .none

    static let glideRange: ClosedRange<Double> = 40...1200
    static let momentumRange: ClosedRange<Double> = 80...2000
    static let stepRange: ClosedRange<Double> = 4...200
    static let multiplierRange: ClosedRange<Double> = 0.05...16

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScrollPhysicsConfig()
        curve = c.value(.curve, d.curve); pixelsPerLine = c.value(.pixelsPerLine, d.pixelsPerLine); glideMs = c.value(.glideMs, d.glideMs)
        momentum = c.value(.momentum, d.momentum); momentumMs = c.value(.momentumMs, d.momentumMs)
        quickModifier = c.value(.quickModifier, d.quickModifier); preciseModifier = c.value(.preciseModifier, d.preciseModifier)
        quickMultiplier = c.value(.quickMultiplier, d.quickMultiplier); preciseMultiplier = c.value(.preciseMultiplier, d.preciseMultiplier)
        zoomModifier = c.value(.zoomModifier, d.zoomModifier); rotateModifier = c.value(.rotateModifier, d.rotateModifier)
        invertVertical = c.value(.invertVertical, d.invertVertical); horizontal = c.value(.horizontal, d.horizontal)
    }

    /// Every number brought into what the engine can use; damaged ones become the usual.
    func sanitized() -> ScrollPhysicsConfig {
        func clamp(_ v: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double { v.isNaN ? fallback : min(max(v, r.lowerBound), r.upperBound) }
        var next = self
        let d = ScrollPhysicsConfig()
        next.pixelsPerLine = clamp(pixelsPerLine, Self.stepRange, d.pixelsPerLine)
        next.glideMs = clamp(glideMs, Self.glideRange, d.glideMs)
        next.momentumMs = clamp(momentumMs, Self.momentumRange, d.momentumMs)
        next.quickMultiplier = clamp(quickMultiplier, Self.multiplierRange, d.quickMultiplier)
        next.preciseMultiplier = clamp(preciseMultiplier, Self.multiplierRange, d.preciseMultiplier)
        return next
    }
}

/// Whether the engine is on, and how it is set. Off by default: Kriya's existing smooth scrolling is untouched until this is switched on.
struct ScrollPhysicsSettings: Codable, Equatable {
    var enabled = false
    var config = ScrollPhysicsConfig()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, false)
        config = c.value(.config, ScrollPhysicsConfig()).sanitized()
    }
}

struct ScrollPhysicsStore {
    static let key = "mouse.scrollPhysics.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var settings: ScrollPhysicsSettings {
        get { defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(ScrollPhysicsSettings.self, from: $0) } ?? ScrollPhysicsSettings() }
        nonmutating set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.key) } }
    }
}

// MARK: - Turning input into movement

/// What one wheel movement is asked to do, after the keys held and the settings are taken into account.
enum ScrollRoute: Equatable {
    case scroll(dx: Double, dy: Double, precise: Bool)
    case zoom(Double)
    case rotate(Double)
}

enum ScrollTransform {
    /// `lineX`, `lineY` are the wheel's movement in lines. `held` are the keys down, as the core counts them. `swapAxes` turns up and
    /// down into left and right (the "sideways" keys). Quick and precise scrolling scale the step; precise also asks for no carry-on.
    static func route(lineX: Double, lineY: Double, held: UInt64, swapAxes: Bool, config: ScrollPhysicsConfig) -> ScrollRoute {
        func isHeld(_ mask: UInt64) -> Bool { mask != 0 && held & mask == mask }
        var x = lineX, y = lineY
        if swapAxes { x = y; y = 0 }
        if isHeld(config.zoomModifier) { return .zoom(lineY != 0 ? lineY : lineX) }
        if isHeld(config.rotateModifier) { return .rotate(lineY != 0 ? lineY : lineX) }
        // Precise wins over quick when both are held: the careful one is the safer to get.
        let precise = isHeld(config.preciseModifier)
        let factor = precise ? config.preciseMultiplier : (isHeld(config.quickModifier) ? config.quickMultiplier : 1)
        let step = config.pixelsPerLine * factor
        if config.invertVertical { y = -y }
        if config.horizontal == .invert { x = -x }
        return .scroll(dx: x * step, dy: y * step, precise: precise)
    }

    /// Fine, continuous movement (a trackpad or Magic Mouse) already scrolls smoothly with its own momentum, so only the direction
    /// and the keys apply: it is never glided again.
    static func continuous(dx: Double, dy: Double, held: UInt64, config: ScrollPhysicsConfig) -> ScrollRoute {
        var x = dx, y = dy
        if config.invertVertical { y = -y }
        if config.horizontal == .invert { x = -x }
        if config.zoomModifier != 0, held & config.zoomModifier == config.zoomModifier { return .zoom(dy != 0 ? dy : dx) }
        if config.rotateModifier != 0, held & config.rotateModifier == config.rotateModifier { return .rotate(dy != 0 ? dy : dx) }
        return .scroll(dx: x, dy: y, precise: false)
    }
}

// MARK: - The engine

/// Scrolling as a trackpad does it: a gesture that begins, changes and ends, then momentum that begins, carries on and ends. Wheel
/// movement adds to where the scroll is going; time moves it there along the chosen curve. Pure arithmetic with no clock of its own:
/// the caller says how much time has passed, so every step can be checked.
struct ScrollPhysicsEngine {
    enum State: Equatable { case idle, gesture, momentum }

    private(set) var config: ScrollPhysicsConfig
    private(set) var state = State.idle
    /// Movement still to make, in pixels.
    private(set) var remainingX = 0.0
    private(set) var remainingY = 0.0
    /// The speed of the scroll now, in pixels a second, as it is being posted.
    private(set) var velocityX = 0.0
    private(set) var velocityY = 0.0

    private var springVX = 0.0
    private var springVY = 0.0
    private var linearSpeedX = 0.0
    private var linearSpeedY = 0.0
    private var gestureStarted = false
    private var momentumStarted = false
    private var precise = false
    /// The fastest the glide has gone this gesture (pixels a second). A glide that has slowed well below it is where a finger would lift.
    private var peakSpeed = 0.0

    /// Below this speed (pixels a second) a glide has stopped and momentum ends.
    static let stopSpeed = 12.0
    /// Below this much left (pixels) a glide has arrived.
    static let arrived = 0.25
    /// A step longer than this is cut: a stall (the Mac was busy) must not become one huge jump.
    static let longestStepMs = 50.0

    init(config: ScrollPhysicsConfig = ScrollPhysicsConfig()) { self.config = config.sanitized() }

    var isActive: Bool { state != .idle }
    var speed: Double { hypot(velocityX, velocityY) }

    mutating func update(_ config: ScrollPhysicsConfig) { self.config = config.sanitized() }

    // MARK: Input

    /// More movement asked for (a wheel notch). If the scroll was carrying on, that stops at once, with an explicit cancel, and a new
    /// gesture begins. Returns the frames to post before anything else.
    @discardableResult
    mutating func push(dx: Double, dy: Double, precise: Bool = false) -> [ScrollFrame] {
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return [] }
        var frames: [ScrollFrame] = []
        if state == .momentum {
            frames.append(ScrollFrame(dx: 0, dy: 0, phase: .none, momentum: .ended, isMomentumCancel: true))
            velocityX = 0; velocityY = 0
            state = .idle
        }
        // Wheel movement the other way turns the glide round at once rather than first finishing the old direction.
        if remainingX != 0, dx.sign != remainingX.sign { remainingX = 0; springVX = 0 }
        if remainingY != 0, dy.sign != remainingY.sign { remainingY = 0; springVY = 0 }
        remainingX += dx
        remainingY += dy
        self.precise = precise
        if state == .idle { state = .gesture; gestureStarted = false; velocityX = 0; velocityY = 0 }
        let seconds = max(config.glideMs, 1) / 1000
        linearSpeedX = abs(remainingX) / seconds
        linearSpeedY = abs(remainingY) / seconds
        return frames
    }

    /// Stops everything from outside (a click, a key, Kriya being switched off). A gesture is cancelled and momentum is stopped with the
    /// explicit cancel. Returns the frames to post.
    mutating func cancel() -> [ScrollFrame] {
        defer { reset() }
        switch state {
        case .idle: return []
        case .gesture: return gestureStarted ? [ScrollFrame(dx: 0, dy: 0, phase: .cancelled, momentum: .none)] : []
        case .momentum: return [ScrollFrame(dx: 0, dy: 0, phase: .none, momentum: .ended, isMomentumCancel: true)]
        }
    }

    private mutating func reset() {
        state = .idle
        remainingX = 0; remainingY = 0; velocityX = 0; velocityY = 0
        springVX = 0; springVY = 0; linearSpeedX = 0; linearSpeedY = 0
        gestureStarted = false; momentumStarted = false; precise = false; peakSpeed = 0
    }

    // MARK: Time

    /// Moves on by `dtMs` milliseconds. Returns the frames to post for that time: none when idle.
    mutating func step(dtMs: Double) -> [ScrollFrame] {
        guard dtMs.isFinite, dtMs > 0 else { return [] }
        let dt = min(dtMs, Self.longestStepMs)
        switch state {
        case .idle: return []
        case .gesture: return stepGesture(dt)
        case .momentum: return stepMomentum(dt)
        }
    }

    private mutating func stepGesture(_ dt: Double) -> [ScrollFrame] {
        let (mx, _) = advance(remaining: remainingX, springV: &springVX, linear: linearSpeedX, dt: dt)
        let (my, _) = advance(remaining: remainingY, springV: &springVY, linear: linearSpeedY, dt: dt)
        remainingX -= mx; remainingY -= my
        // The speed is smoothed over a few tens of milliseconds, so momentum starts from how fast it was really going.
        let blend = 1 - exp(-dt / 40)
        velocityX += (mx / dt * 1000 - velocityX) * blend
        velocityY += (my / dt * 1000 - velocityY) * blend
        var frames: [ScrollFrame] = []
        if mx != 0 || my != 0 {
            frames.append(ScrollFrame(dx: mx, dy: my, phase: gestureStarted ? .changed : .began, momentum: .none))
            gestureStarted = true
        }
        let instant = hypot(mx, my) / dt * 1000
        peakSpeed = max(peakSpeed, instant)
        let arrived = abs(remainingX) < Self.arrived && abs(remainingY) < Self.arrived && abs(springVX) < Self.stopSpeed && abs(springVY) < Self.stopSpeed
        // A glide that was quick and has slowed down lifts here, so momentum carries on from a real speed. Waiting for the last fraction of a
        // pixel would leave it with no speed at all, and a fast spin would never glide on.
        let lifts = config.momentum && !precise && gestureStarted && peakSpeed >= 400 && instant <= peakSpeed * 0.35 && speed >= Self.stopSpeed * 4
        if arrived || lifts {
            // What is left is posted so the glide ends exactly where it was going.
            if remainingX != 0 || remainingY != 0 {
                frames.append(ScrollFrame(dx: remainingX, dy: remainingY, phase: gestureStarted ? .changed : .began, momentum: .none))
                gestureStarted = true
                remainingX = 0; remainingY = 0
            }
            if gestureStarted { frames.append(ScrollFrame(dx: 0, dy: 0, phase: .ended, momentum: .none)) }
            if config.momentum, !precise, speed >= Self.stopSpeed * 4 {
                state = .momentum; momentumStarted = false
            } else {
                reset()
            }
        }
        return frames
    }

    /// How far a glide moves in `dt`, by the curve, and the speed it leaves behind.
    private func advance(remaining: Double, springV: inout Double, linear: Double, dt: Double) -> (move: Double, speed: Double) {
        guard remaining != 0 else { springV = 0; return (0, 0) }
        switch config.curve {
        case .linear:
            let direction = remaining < 0 ? -1.0 : 1.0
            let m = min(abs(remaining), linear * dt / 1000) * direction
            return (m, linear * direction)
        case .exponential:
            let tau = max(config.glideMs, 1) / 3
            let m = remaining * (1 - exp(-dt / tau))
            return (m, m / dt * 1000)
        case .criticallyDamped:
            // x(t) = (e0 + (v0 + w e0) t) e^(-w t), the exact solution of a critically damped spring, so it is stable at any step.
            let w = 6 / max(config.glideMs, 1) * 1000
            let t = dt / 1000
            let e0 = remaining, v0 = -springV
            let decay = exp(-w * t)
            let e = (e0 + (v0 + w * e0) * t) * decay
            let v = (v0 - w * (v0 + w * e0) * t) * decay
            springV = -v
            return (e0 - e, -v)
        case .trackpadLike:
            // A finger follows the wheel closely; the carry-on afterwards is the momentum.
            let tau = max(config.glideMs, 1) / 8
            let m = remaining * (1 - exp(-dt / tau))
            return (m, m / dt * 1000)
        }
    }

    private mutating func stepMomentum(_ dt: Double) -> [ScrollFrame] {
        let tau = max(config.momentumMs, 1)
        let decay = exp(-dt / tau)
        velocityX *= decay; velocityY *= decay
        if speed < Self.stopSpeed {
            let frame = ScrollFrame(dx: 0, dy: 0, phase: .none, momentum: .ended)
            let started = momentumStarted
            reset()
            return started ? [frame] : []
        }
        let frame = ScrollFrame(dx: velocityX * dt / 1000, dy: velocityY * dt / 1000, phase: .none, momentum: momentumStarted ? .changed : .began)
        momentumStarted = true
        return [frame]
    }
}

/// Posting whole pixels while keeping the fraction for the next step, so slow scrolling is smooth and nothing is lost.
struct ScrollCarry: Equatable {
    private var x = 0.0
    private var y = 0.0

    /// The whole pixels to post now. `flush` rounds what is left (the last frame of a gesture) instead of dropping up to a pixel.
    mutating func take(dx: Double, dy: Double, flush: Bool) -> (Int32, Int32) {
        x += dx; y += dy
        let rule: FloatingPointRoundingRule = flush ? .toNearestOrAwayFromZero : .towardZero
        let ix = Int32(max(min(x.rounded(rule), 1e8), -1e8)), iy = Int32(max(min(y.rounded(rule), 1e8), -1e8))
        x -= Double(ix); y -= Double(iy)
        if flush { x = 0; y = 0 }
        return (ix, iy)
    }

    mutating func clear() { x = 0; y = 0 }
}
