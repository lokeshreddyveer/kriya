import CoreGraphics
import Foundation

/// What the scrolling capture needs from the screen: a picture of the scrolling area, and a way to move what is in it. The real one
/// takes the picture with ScreenCaptureKit and scrolls with wheel events; a test supplies a page held in memory.
protocol ScrollWorld: AnyObject {
    /// The scrolling area as it looks now.
    func grab() async throws -> CGImage
    /// Scrolls by this many points (positive is on towards the end: down, or to the right).
    func scroll(by points: Int, axis: CaptureScrollAxis) async
    /// Presses Page Down, for pages that ignore the wheel. False if it could not.
    func pageForward() async -> Bool
    /// Pixels per point of the pictures `grab` returns.
    var scale: CGFloat { get }
}

/// Takes the pictures of a scrolling capture and decides when it is done. Runs in one of two ways: Kriya scrolls (a step at a time,
/// waiting for the page to settle, halving the step when a picture does not overlap the one before, turning round if the first scroll
/// goes the wrong way, trying Page Down when the wheel does nothing), or the person scrolls while Kriya watches and keeps each
/// picture the page settles on. Either way the pictures are joined afterwards by `ScrollStitch.plan`.
final class ScrollEngine {
    struct Result {
        var frames: [CGImage]
        var axis: CaptureScrollAxis
        var plan: ScrollStitch.Plan
        var cancelled: Bool
        /// Why it ended, in a sentence, for the person.
        var reason: String
        var hitLimit: Bool
    }

    let world: ScrollWorld
    let axis: CaptureScrollAxis
    let mode: ScrollMode
    /// How long to wait for the page to settle after a scroll.
    var settle: TimeInterval = 0.45
    /// While the person scrolls, how often the area is looked at, and how long it must stand still to be kept.
    var pollInterval: TimeInterval = 0.22
    var stableWait: TimeInterval = 0.18
    var maxFrames = 400
    /// Pixels of all the pictures held, as a way of keeping memory in check.
    var maxPixels = 380_000_000
    var onProgress: (_ frames: Int, _ length: Int) -> Void = { _, _ in }
    /// Called once when the joined picture passes the warning length.
    var onLong: (_ length: Int) -> Void = { _ in }

    private let lock = NSLock()
    private var flags = (paused: false, stopped: false, cancelled: false)
    private var warned = false

    init(world: ScrollWorld, axis: CaptureScrollAxis, mode: ScrollMode) {
        self.world = world
        self.axis = axis
        self.mode = mode
    }

    func pause() { set { $0.paused = true } }
    func resume() { set { $0.paused = false } }
    /// Ends the capture and keeps what has been taken.
    func stop() { set { $0.stopped = true; $0.paused = false } }
    /// Ends the capture and keeps nothing.
    func cancel() { set { $0.cancelled = true; $0.paused = false } }
    var isPaused: Bool { read { $0.paused } }

    private func set(_ change: (inout (paused: Bool, stopped: Bool, cancelled: Bool)) -> Void) { lock.lock(); change(&flags); lock.unlock() }
    private func read<T>(_ get: ((paused: Bool, stopped: Bool, cancelled: Bool)) -> T) -> T { lock.lock(); defer { lock.unlock() }; return get(flags) }
    private var shouldEnd: Bool { read { $0.stopped || $0.cancelled } }

    // MARK: Running

    func run() async -> Result {
        do {
            // Down and across needs Kriya to scroll; if the person scrolls, it is taken down only.
            if axis == .both, mode == .automatic { return try await runBoth() }
            let a = try await runAxis(axis == .horizontal ? .horizontal : .vertical)
            return Result(frames: a.frames, axis: a.axis, plan: ScrollStitch.plan(frames: a.hashes), cancelled: read { $0.cancelled }, reason: a.reason, hitLimit: a.hitLimit)
        } catch {
            return Result(frames: [], axis: axis, plan: ScrollStitch.plan(frames: []), cancelled: false, reason: error.localizedDescription, hitLimit: false)
        }
    }

    private struct AxisRun {
        var axis: CaptureScrollAxis
        var frames: [CGImage]
        var hashes: [[UInt64]]
        var reason: String
        var hitLimit: Bool
        /// Whether a scroll in the positive direction moved the page.
        var forward: Int
    }

    private func hashes(of image: CGImage, _ axis: CaptureScrollAxis) -> [UInt64] {
        axis == .horizontal ? ScrollImage.columnHashes(image) : ScrollingCapture.rowHashes(image)
    }

    private func waitWhilePaused() async {
        while read({ $0.paused && !$0.stopped && !$0.cancelled }) { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    /// A picture once the page has stopped moving: two in a row the same, or the last of a few tries.
    private func settled(_ axis: CaptureScrollAxis) async throws -> (CGImage, [UInt64]) {
        if settle > 0 { try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000)) }
        var shot = try await world.grab()
        var h = hashes(of: shot, axis)
        for _ in 0..<5 {
            if settle > 0 { try? await Task.sleep(nanoseconds: 120_000_000) }
            let again = try await world.grab()
            let hh = hashes(of: again, axis)
            if hh == h { return (shot, h) }
            shot = again; h = hh
        }
        return (shot, h)
    }

    private func runAxis(_ axis: CaptureScrollAxis, startDirection: Int = 1) async throws -> AxisRun {
        let firstShot = try await world.grab()
        var frames = [firstShot]
        var hs = [hashes(of: firstShot, axis)]
        var forward = startDirection
        var reason = "Reached the end."
        var hitLimit = false
        let viewport = Double(axis == .horizontal ? firstShot.width : firstShot.height) / Double(max(world.scale, 1))
        var step = max(Int(viewport * 0.7), 40)
        let firstStep = step
        var failures = 0, stalls = 0
        var triedOtherWay = false, triedPageKey = false
        var length = hs[0].count
        onProgress(1, length)

        if mode == .manual { return try await watch(axis, frames: &frames, hashes: &hs, length: &length) }

        while !shouldEnd {
            await waitWhilePaused()
            if shouldEnd { break }
            if frames.count >= maxFrames || frames.count * firstShot.width * firstShot.height >= maxPixels { reason = "Stopped: that is as much as fits in memory."; hitLimit = true; break }
            await world.scroll(by: forward * step, axis: axis)
            var (shot, h) = try await settled(axis)
            if h == hs[hs.count - 1] {
                // The page did not move. At the start that may mean the wheel goes the other way here, or that this page only moves
                // with the keyboard; later it means the end.
                if !triedOtherWay, frames.count == 1 { triedOtherWay = true; forward = -forward; continue }
                if !triedPageKey, axis == .vertical, frames.count == 1 {
                    triedPageKey = true
                    if await world.pageForward() { (shot, h) = try await settled(axis) }
                }
                if h == hs[hs.count - 1] {
                    stalls += 1
                    if stalls >= 2 { break }
                    continue
                }
            }
            stalls = 0
            let (header, footer) = frames.count >= 1 ? ScrollStitch.fixedBars(hs[0], h) : (0, 0)
            let previous = hs[hs.count - 1]
            guard h.count > header + footer, previous.count > header + footer else { break }
            let k = ScrollStitch.overlap(rows: Array(previous[header..<(previous.count - footer)]), next: Array(h[header..<(h.count - footer)]))
            if k == 0 {
                // It moved too far (or is still loading) to join. Go back, and take smaller steps.
                failures += 1
                if failures > 6 { reason = "Stopped: the page changed too much between pictures to join them."; break }
                await world.scroll(by: -forward * step, axis: axis)
                // Smaller steps first. If even those do not join at the very start, the first scroll may have gone the wrong way
                // (from the middle of a page): try the other, with the first step size again.
                if frames.count == 1, failures == 3, !triedOtherWay { triedOtherWay = true; forward = -forward; step = firstStep; continue }
                step = max(step / 2, 20)
                continue
            }
            failures = 0
            frames.append(shot); hs.append(h)
            length += max(h.count - header - footer - k, 0)
            onProgress(frames.count, length)
            if ScrollStitch.shouldWarn(length: length, warned: warned) { warned = true; onLong(length) }
            if ScrollStitch.mustStop(length: length) { reason = "Stopped at the longest length Kriya joins."; hitLimit = true; break }
        }
        return AxisRun(axis: axis, frames: frames, hashes: hs, reason: reason, hitLimit: hitLimit, forward: forward)
    }

    /// The person scrolls; each picture the page settles on is kept if it joins the one before.
    private func watch(_ axis: CaptureScrollAxis, frames: inout [CGImage], hashes hs: inout [[UInt64]], length: inout Int) async throws -> AxisRun {
        var reason = "Done."
        var hitLimit = false
        while !shouldEnd {
            await waitWhilePaused()
            try? await Task.sleep(nanoseconds: UInt64(max(pollInterval, 0.001) * 1_000_000_000))
            let shot = try await world.grab()
            let h = hashes(of: shot, axis)
            if h == hs[hs.count - 1] { continue }
            // Wait for it to stop moving.
            try? await Task.sleep(nanoseconds: UInt64(max(stableWait, 0.001) * 1_000_000_000))
            let again = try await world.grab()
            let hh = hashes(of: again, axis)
            if hh != h { continue }
            if hs.contains(where: { $0 == hh }) { continue }      // back to somewhere already taken
            let (header, footer) = ScrollStitch.fixedBars(hs[0], hh)
            let previous = hs[hs.count - 1]
            guard hh.count > header + footer, previous.count > header + footer else { continue }
            let k = ScrollStitch.overlap(rows: Array(previous[header..<(previous.count - footer)]), next: Array(hh[header..<(hh.count - footer)]))
            if k == 0 { continue }                                  // scrolled too far at once, or the wrong way: wait for the next
            frames.append(again); hs.append(hh)
            length += max(hh.count - header - footer - k, 0)
            onProgress(frames.count, length)
            if ScrollStitch.shouldWarn(length: length, warned: warned) { warned = true; onLong(length) }
            if ScrollStitch.mustStop(length: length) { reason = "Stopped at the longest length Kriya joins."; hitLimit = true; break }
            if frames.count >= maxFrames { hitLimit = true; reason = "Stopped: that is as many pictures as Kriya keeps."; break }
        }
        return AxisRun(axis: axis, frames: frames, hashes: hs, reason: reason, hitLimit: hitLimit, forward: 1)
    }

    // MARK: Down and across

    /// Down and across: the page is taken down in one column, then moved across by most of a width and taken down again from the
    /// top, and the columns are joined side by side. Kriya scrolls for this one.
    private func runBoth() async throws -> Result {
        var columns: [CGImage] = []
        var reason = "Reached the end."
        var hit = false
        var direction = 1
        var previousTop: [UInt64]?
        for column in 0..<12 {
            if shouldEnd { break }
            let run = try await runAxis(.vertical, startDirection: direction)
            direction = run.forward
            guard let joined = ScrollImage.assemble(frames: run.frames, plan: ScrollStitch.plan(frames: run.hashes), axis: .vertical) else { break }
            columns.append(joined)
            hit = hit || run.hitLimit
            if shouldEnd { break }
            // Back to the top, then across.
            for _ in 0..<40 {
                let before = hashes(of: try await world.grab(), .vertical)
                await world.scroll(by: -direction * Int(Double(joined.height) / Double(max(world.scale, 1))), axis: .vertical)
                if settle > 0 { try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000)) }
                if hashes(of: try await world.grab(), .vertical) == before { break }
            }
            let top = hashes(of: try await world.grab(), .horizontal)
            await world.scroll(by: direction * Int(Double(columns[column].width) / Double(max(world.scale, 1)) * 0.8), axis: .horizontal)
            let (_, nextTop) = try await settled(.horizontal)
            if nextTop == top || nextTop == previousTop { break }      // the page did not move sideways: that was the last column
            previousTop = top
            reason = "Reached the end."
        }
        if shouldEnd, read({ $0.cancelled }) { return Result(frames: [], axis: .both, plan: ScrollStitch.plan(frames: []), cancelled: true, reason: "Cancelled.", hitLimit: false) }
        let hashesList = columns.map { ScrollImage.columnHashes($0) }
        let plan = ScrollStitch.plan(frames: hashesList)
        return Result(frames: columns, axis: .horizontal, plan: plan, cancelled: false, reason: reason, hitLimit: hit)
    }
}

// MARK: - Pictures

/// Reading and joining the pictures of a scrolling capture, across as well as down.
enum ScrollImage {
    /// One number for each column of pixels, ignoring the bottom of the picture where a horizontal scroll bar sits.
    static func columnHashes(_ image: CGImage) -> [UInt64] {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return [] }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let usable = max(h * 85 / 100, 1)
        return (0..<w).map { x in
            var hash: UInt64 = 0xcbf29ce484222325
            // Only the top 85% of each column counts: the strip at the bottom is where a scroll bar sits.
            for y in 0..<usable {
                let i = (y * w + x) * 4
                for b in 0..<4 { hash = (hash ^ UInt64(data[i + b])) &* 0x100000001b3 }
            }
            return hash
        }
    }

    /// The finished picture from the pictures taken and the plan for joining them.
    static func assemble(frames: [CGImage], plan: ScrollStitch.Plan, axis: CaptureScrollAxis) -> CGImage? {
        var pieces: [CGImage] = []
        for strip in plan.strips {
            guard frames.indices.contains(strip.frame) else { continue }
            let f = frames[strip.frame]
            let rect = axis == .horizontal ? CGRect(x: strip.rows.lowerBound, y: 0, width: strip.rows.count, height: f.height)
                                           : CGRect(x: 0, y: strip.rows.lowerBound, width: f.width, height: strip.rows.count)
            if let piece = f.cropping(to: rect) { pieces.append(piece) }
        }
        return stack(pieces, axis: axis)
    }

    /// Pieces laid one after another, top to bottom (or left to right).
    static func stack(_ pieces: [CGImage], axis: CaptureScrollAxis) -> CGImage? {
        guard !pieces.isEmpty else { return nil }
        let horizontal = axis == .horizontal
        let width = horizontal ? pieces.reduce(0) { $0 + $1.width } : (pieces.map(\.width).max() ?? 0)
        let height = horizontal ? (pieces.map(\.height).max() ?? 0) : pieces.reduce(0) { $0 + $1.height }
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                             space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var offset = 0
        for piece in pieces {
            if horizontal {
                context.draw(piece, in: CGRect(x: offset, y: height - piece.height, width: piece.width, height: piece.height))
                offset += piece.width
            } else {
                offset += piece.height
                context.draw(piece, in: CGRect(x: 0, y: height - offset, width: piece.width, height: piece.height))
            }
        }
        return context.makeImage()
    }
}
