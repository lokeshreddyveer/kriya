import CoreGraphics
import Foundation

/// A way of moving what is in the scrolling area. Tried in the order the world lists them; the first that actually moves the page is
/// kept for the rest of the capture.
enum ScrollStrategy: String, Equatable {
    /// Asking the browser itself (a page scroll through its scripting), which is exact.
    case browser
    /// Setting the scroll bar of the scroll area under the pointer through Accessibility.
    case accessibility
    /// Turning the mouse wheel.
    case wheel
    /// Pressing Page Down.
    case pageKey
    /// Pressing the arrow key several times.
    case arrowKeys

    var title: String {
        switch self {
        case .browser: return "the browser"
        case .accessibility: return "the scroll bar"
        case .wheel: return "the mouse wheel"
        case .pageKey: return "Page Down"
        case .arrowKeys: return "the arrow keys"
        }
    }

    /// Whether the other direction is worth trying (a wheel can be set the other way round; a key cannot).
    var reversible: Bool { self == .wheel || self == .accessibility || self == .browser }
    var verticalOnly: Bool { self == .pageKey || self == .arrowKeys }
}

/// Where the scrolling area is within what scrolls, when the app can say: in points.
struct ScrollPosition: Equatable {
    var offset: Double
    var total: Double
    var viewport: Double

    var atEnd: Bool { offset + viewport >= total - 2 }
    var fraction: Double { total <= viewport ? 1 : min(max((offset + viewport) / total, 0), 1) }
}

/// What the scrolling capture needs from the screen: a picture of the scrolling area, and ways to move what is in it. The real one
/// takes the picture with ScreenCaptureKit and scrolls with the browser, the scroll bar, the wheel or the keyboard; a test supplies a
/// page held in memory.
protocol ScrollWorld: AnyObject {
    /// The scrolling area as it looks now.
    func grab() async throws -> CGImage
    /// Scrolls by this many points with the mouse wheel (positive is on towards the end: down, or to the right).
    func scroll(by points: Int, axis: CaptureScrollAxis) async
    /// Presses Page Down, for pages that ignore the wheel. False if it could not.
    func pageForward() async -> Bool
    /// Pixels per point of the pictures `grab` returns.
    var scale: CGFloat { get }

    /// The ways to move the page, best first.
    var strategies: [ScrollStrategy] { get }
    /// Scrolls by this many points a given way. False if that way is not available here.
    func scroll(by points: Int, axis: CaptureScrollAxis, using strategy: ScrollStrategy) async -> Bool
    /// Where the area is within what scrolls, if the app can say.
    func position(axis: CaptureScrollAxis) async -> ScrollPosition?
    /// Something worth telling the person about the area (it scrolls only part of what was selected, say).
    var advice: String? { get }
}

extension ScrollWorld {
    var strategies: [ScrollStrategy] { [.wheel, .pageKey] }

    func scroll(by points: Int, axis: CaptureScrollAxis, using strategy: ScrollStrategy) async -> Bool {
        switch strategy {
        case .wheel: await scroll(by: points, axis: axis); return true
        case .pageKey: return await pageForward()
        default: return false
        }
    }

    func position(axis: CaptureScrollAxis) async -> ScrollPosition? { nil }
    var advice: String? { nil }
}

/// Takes the pictures of a scrolling capture and decides when it is done. Runs in one of two ways: Kriya scrolls (a step at a time,
/// waiting only as long as the page takes to settle, halving the step when a picture does not join the one before, turning round or
/// changing method if the first scroll does nothing, waiting again at the end in case more is still loading), or the person scrolls
/// while Kriya watches. Either way the pictures are joined afterwards by `ScrollStitch.plan`, with a tolerance for small changes, and a
/// picture that cannot be joined is kept as a section of its own, never dropped.
final class ScrollEngine {
    struct Result {
        var frames: [CGImage]
        var axis: CaptureScrollAxis
        var plan: ScrollStitch.Plan
        var cancelled: Bool
        /// Why it ended, in a sentence, for the person.
        var reason: String
        var hitLimit: Bool
        /// Things the person should know about how it went (columns that differ in height, a scroll method that was given up).
        var warnings: [String] = []
        /// Which way of scrolling worked.
        var strategy: ScrollStrategy?
    }

    let world: ScrollWorld
    let axis: CaptureScrollAxis
    let mode: ScrollMode
    /// How far each scroll goes, as a share of the area (0.3 to 0.9).
    var stepFraction = 0.7
    /// The longest to wait for the page to settle after a scroll. 0 means do not wait at all (for tests).
    var settle: TimeInterval = 1.0
    /// While the person scrolls, how often the area is looked at, and how long it must stand still to be kept.
    var pollInterval: TimeInterval = 0.06
    var stableWait: TimeInterval = 0.06
    var maxFrames = 400
    /// Pixels of all the pictures held, as a way of keeping memory in check.
    var maxPixels = 380_000_000
    var onProgress: (_ frames: Int, _ length: Int) -> Void = { _, _ in }
    /// Called once when the joined picture passes the warning length.
    var onLong: (_ length: Int) -> Void = { _ in }
    /// Where in the page the capture has got to (0 to 1), when the app can say.
    var onPosition: (_ fraction: Double) -> Void = { _ in }
    /// The latest picture kept.
    var onFrame: (_ image: CGImage) -> Void = { _ in }
    /// While the person scrolls: true when the picture on screen does not overlap the last one kept (they scrolled too far), false once
    /// that is put right.
    var onNeedsOverlap: (_ needed: Bool) -> Void = { _ in }
    /// Said as the capture goes: which way of scrolling is in use, and when one is given up for another.
    var onNote: (_ note: String) -> Void = { _ in }

    private let lock = NSLock()
    private var flags = (paused: false, stopped: false, cancelled: false)
    private var requests = (capture: false, undo: false, keep: false)
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

    /// While the person scrolls: take the picture on screen now, without waiting for the next look.
    func captureNow() { lock.lock(); requests.capture = true; lock.unlock() }
    /// While the person scrolls: take back the last picture kept.
    func undoLast() { lock.lock(); requests.undo = true; lock.unlock() }
    /// While the person scrolls: keep the picture that does not overlap as a section of its own.
    func keepUnjoined() { lock.lock(); requests.keep = true; lock.unlock() }

    private func set(_ change: (inout (paused: Bool, stopped: Bool, cancelled: Bool)) -> Void) { lock.lock(); change(&flags); lock.unlock() }
    private func read<T>(_ get: ((paused: Bool, stopped: Bool, cancelled: Bool)) -> T) -> T { lock.lock(); defer { lock.unlock() }; return get(flags) }
    private var shouldEnd: Bool { read { $0.stopped || $0.cancelled } }
    private func take(_ key: WritableKeyPath<(capture: Bool, undo: Bool, keep: Bool), Bool>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = requests[keyPath: key]
        requests[keyPath: key] = false
        return value
    }

    // MARK: Running

    func run() async -> Result {
        do {
            // Down and across needs Kriya to scroll; if the person scrolls, it is taken down only.
            if axis == .both, mode == .automatic { return try await runBoth() }
            let a = try await runAxis(axis == .horizontal ? .horizontal : .vertical)
            return Result(frames: a.frames, axis: a.axis, plan: ScrollStitch.plan(signatures: a.signatures, expected: a.expected), cancelled: read { $0.cancelled },
                          reason: a.reason, hitLimit: a.hitLimit, warnings: a.warnings, strategy: a.strategy)
        } catch {
            return Result(frames: [], axis: axis, plan: ScrollStitch.plan(signatures: []), cancelled: false, reason: error.localizedDescription, hitLimit: false)
        }
    }

    private struct AxisRun {
        var axis: CaptureScrollAxis
        var frames: [CGImage]
        var signatures: [ScrollSignature]
        /// For each picture, how many lines it should overlap the one before, if the page moved as asked.
        var expected: [Int?]
        var reason: String
        var hitLimit: Bool
        /// Which way a scroll in the positive direction went.
        var forward: Int
        var warnings: [String] = []
        var strategy: ScrollStrategy?
    }

    private func signature(of image: CGImage, _ axis: CaptureScrollAxis) -> ScrollSignature {
        axis == .horizontal ? ScrollImage.columnSignature(image) : ScrollImage.rowSignature(image)
    }

    private func waitWhilePaused() async {
        while read({ $0.paused && !$0.stopped && !$0.cancelled }) { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    private func sleep(_ seconds: TimeInterval) async {
        if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    }

    /// A picture once the page has stopped moving: two in a row that match, or the last of the tries when the time is up. Only as slow
    /// as the page is: a page that settles at once is looked at again after a fraction of a second, not a whole one.
    private func settled(_ axis: CaptureScrollAxis) async throws -> (CGImage, ScrollSignature) {
        guard settle > 0 else {
            let shot = try await world.grab()
            return (shot, signature(of: shot, axis))
        }
        await sleep(min(0.08, settle))
        var shot = try await world.grab()
        var sig = signature(of: shot, axis)
        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline {
            await sleep(0.05)
            let again = try await world.grab()
            let next = signature(of: again, axis)
            if ScrollMatch.same(sig, next) { return (again, next) }
            shot = again; sig = next
        }
        return (shot, sig)
    }

    /// The ways to try, in order: each method forwards, then (for those that can) the other way.
    private func options(for axis: CaptureScrollAxis, startDirection: Int) -> [(strategy: ScrollStrategy, direction: Int)] {
        var list: [(ScrollStrategy, Int)] = []
        for strategy in world.strategies where !(strategy.verticalOnly && axis != .vertical) {
            let direction = list.isEmpty ? startDirection : 1
            list.append((strategy, direction))
            if strategy.reversible { list.append((strategy, -direction)) }
        }
        return list
    }

    private func runAxis(_ axis: CaptureScrollAxis, startDirection: Int = 1) async throws -> AxisRun {
        let firstShot = try await world.grab()
        var frames = [firstShot]
        var sigs = [signature(of: firstShot, axis)]
        var expected: [Int?] = [nil]
        var reason = "Reached the end."
        var hitLimit = false
        var warnings: [String] = []
        let scale = Double(max(world.scale, 1))
        let viewport = Double(axis == .horizontal ? firstShot.width : firstShot.height) / scale
        var step = max(Int(viewport * min(max(stepFraction, 0.3), 0.9)), 40)
        let firstStep = step
        var failures = 0, stalls = 0, unjoinedRun = 0
        var triedFlip = false
        var length = sigs[0].count
        onProgress(1, length)

        if mode == .manual {
            var run = try await watch(axis, frames: &frames, signatures: &sigs, length: &length)
            run.expected = Array(repeating: nil, count: run.frames.count)
            return run
        }

        let ways = options(for: axis, startDirection: startDirection)
        var wayIndex = 0
        var working: ScrollStrategy?
        func current() -> (strategy: ScrollStrategy, direction: Int) { ways.isEmpty ? (.wheel, startDirection) : ways[min(wayIndex, ways.count - 1)] }

        while !shouldEnd {
            await waitWhilePaused()
            if shouldEnd { break }
            if frames.count >= maxFrames || frames.count * firstShot.width * firstShot.height >= maxPixels { reason = "Stopped: that is as much as fits in memory."; hitLimit = true; break }
            let way = current()
            let before = await world.position(axis: axis)
            _ = await world.scroll(by: way.direction * step, axis: axis, using: way.strategy)
            let (shot, sig) = try await settled(axis)
            let after = await world.position(axis: axis)
            if let after { onPosition(after.fraction) }

            if ScrollMatch.same(sig, sigs[sigs.count - 1]) {
                // The page did not move. At the start that means this way of scrolling does not work here (or goes the other way):
                // try the next. Later it means the end, once a few more looks have given a slow page time to load more.
                if frames.count == 1, wayIndex + 1 < ways.count {
                    wayIndex += 1
                    onNote("Scrolling with \(ways[wayIndex].strategy.title).")
                    continue
                }
                if let after, after.atEnd { break }
                stalls += 1
                if stalls >= 3 { break }
                await sleep(settle > 0 ? 0.5 * Double(stalls) : 0)     // more may still be loading
                continue
            }

            let (header, footer) = ScrollMatch.fixedBars(sigs[0], sig)
            let previous = sigs[sigs.count - 1]
            guard sig.count > header + footer, previous.count > header + footer else { break }
            let previousBody = previous.slice(header..<(previous.count - footer))
            let body = sig.slice(header..<(sig.count - footer))
            // How far the page really moved, when the app says; else how far it was asked to.
            let movedPoints: Double? = before.flatMap { b in after.map { abs($0.offset - b.offset) } }
            let hint = max(body.count - Int((movedPoints ?? Double(step)) * scale), 0)
            guard let match = ScrollMatch.overlap(previous: previousBody, next: body, expected: hint) else {
                // It moved too far (or is still loading) to join. Go back, and take smaller steps.
                failures += 1
                if failures > 4 {
                    // Smaller steps do not help: the page is changing as it scrolls (a video, an animation, content being swapped).
                    // The picture is kept as a section of its own, so nothing is lost, and the next ones join to it.
                    unjoinedRun += 1
                    if unjoinedRun >= 3 { reason = "Stopped: the page keeps changing while it scrolls, so the pictures could not be joined."; break }
                    frames.append(shot); sigs.append(sig); expected.append(nil)
                    length += max(sig.count - header - footer, 0)
                    onProgress(frames.count, length); onFrame(shot)
                    failures = 0
                    step = firstStep
                    continue
                }
                _ = await world.scroll(by: -way.direction * step, axis: axis, using: way.strategy)
                // Smaller steps first. If even those do not join at the very start, the first scroll may have gone the wrong way
                // (from the middle of a page): try the other, with the first step size again.
                if frames.count == 1, failures == 3, !triedFlip, way.strategy.reversible {
                    triedFlip = true
                    if let flipped = ways.firstIndex(where: { $0.strategy == way.strategy && $0.direction == -way.direction }) { wayIndex = flipped }
                    step = firstStep
                    continue
                }
                step = max(step / 2, 20)
                continue
            }
            // Overlapping the whole picture means it did not move: a spinner or a clock changed, not the page. Same as not moving.
            if match.lines >= body.count {
                if frames.count == 1, wayIndex + 1 < ways.count {
                    wayIndex += 1
                    onNote("Scrolling with \(ways[wayIndex].strategy.title).")
                    continue
                }
                if let after, after.atEnd { break }
                stalls += 1
                if stalls >= 3 { break }
                await sleep(settle > 0 ? 0.5 * Double(stalls) : 0)
                continue
            }
            failures = 0
            unjoinedRun = 0
            stalls = 0
            if working == nil { working = way.strategy; if wayIndex > 0 { warnings.append("Scrolled with \(way.strategy.title): the first way did not move this page.") } }
            frames.append(shot); sigs.append(sig); expected.append(hint)
            length += max(body.count - match.lines, 0)
            onProgress(frames.count, length)
            onFrame(shot)
            if ScrollStitch.shouldWarn(length: length, warned: warned) { warned = true; onLong(length) }
            if ScrollStitch.mustStop(length: length) { reason = "Stopped at the longest length Kriya joins."; hitLimit = true; break }
            if let after, after.atEnd { break }
        }
        return AxisRun(axis: axis, frames: frames, signatures: sigs, expected: expected, reason: reason, hitLimit: hitLimit, forward: current().direction, warnings: warnings, strategy: working)
    }

    // MARK: The person scrolls

    /// The person scrolls; each picture the page settles on is kept if it joins the one before. One that does not (they went too far)
    /// is held and said so, and is kept as a section of its own if they ask, if they carry on from there, or when they finish.
    private func watch(_ axis: CaptureScrollAxis, frames: inout [CGImage], signatures sigs: inout [ScrollSignature], length: inout Int) async throws -> AxisRun {
        var reason = "Done."
        var hitLimit = false
        var pending: (image: CGImage, sig: ScrollSignature)?
        // The picture that was just taken back: it stays on screen, and must not be taken again until the page moves on.
        var undone: ScrollSignature?
        // How many lines each picture adds to the joined one, so the length is kept up to date without joining everything again.
        var added: [Int] = [sigs[0].count]
        func recount() { length = added.reduce(0, +) }
        func commit(_ held: (image: CGImage, sig: ScrollSignature)) {
            let (header, footer) = ScrollMatch.fixedBars(sigs[0], held.sig)
            frames.append(held.image); sigs.append(held.sig)
            added.append(max(held.sig.count - header - footer, 0))
            recount()
            onProgress(frames.count, length); onFrame(held.image)
        }
        while !shouldEnd {
            await waitWhilePaused()
            if take(\.undo) {
                if frames.count > 1 { undone = sigs.last; frames.removeLast(); sigs.removeLast(); added.removeLast(); recount(); onProgress(frames.count, length); if let f = frames.last { onFrame(f) } }
                if pending != nil { pending = nil; onNeedsOverlap(false) }
                continue
            }
            if take(\.keep) {
                if let held = pending { pending = nil; onNeedsOverlap(false); commit(held) }
                continue
            }
            let forced = take(\.capture)
            if !forced { await sleep(max(pollInterval, 0.001)) }
            var shot = try await world.grab()
            var sig = signature(of: shot, axis)
            if !forced, ScrollMatch.same(sig, sigs[sigs.count - 1]) { continue }
            // Wait for it to stop moving.
            if !forced {
                await sleep(max(stableWait, 0.001))
                let again = try await world.grab()
                let next = signature(of: again, axis)
                if !ScrollMatch.same(sig, next) { continue }
                shot = again; sig = next
            }
            if ScrollMatch.same(sig, sigs[sigs.count - 1]) { continue }
            if let gone = undone {
                if !forced, ScrollMatch.same(gone, sig) { continue }
                undone = nil
            }
            if sigs.contains(where: { ScrollMatch.same($0, sig) }) {
                // Back at somewhere already taken: whatever was held is not needed.
                if pending != nil { pending = nil; onNeedsOverlap(false) }
                continue
            }
            if let held = pending, ScrollMatch.same(held.sig, sig) { continue }
            let (header, footer) = ScrollMatch.fixedBars(sigs[0], sig)
            let previous = sigs[sigs.count - 1]
            guard sig.count > header + footer, previous.count > header + footer else { continue }
            let body = sig.slice(header..<(sig.count - footer))
            var match = ScrollMatch.overlap(previous: previous.slice(header..<(previous.count - footer)), next: body)
            if match == nil, let held = pending {
                // They carried on from the far position: that one is a section of its own, and this joins to it.
                let hb = held.sig.slice(header..<max(held.sig.count - footer, header))
                if let m = ScrollMatch.overlap(previous: hb, next: body) {
                    pending = nil; onNeedsOverlap(false); commit(held)
                    match = m
                }
            }
            guard let match else {
                // Not joined to anything: held, and the person is told to scroll back a little.
                pending = (shot, sig)
                onNeedsOverlap(true)
                continue
            }
            if pending != nil { pending = nil; onNeedsOverlap(false) }
            frames.append(shot); sigs.append(sig)
            added.append(max(body.count - match.lines, 0))
            recount()
            onProgress(frames.count, length); onFrame(shot)
            if ScrollStitch.shouldWarn(length: length, warned: warned) { warned = true; onLong(length) }
            if ScrollStitch.mustStop(length: length) { reason = "Stopped at the longest length Kriya joins."; hitLimit = true; break }
            if frames.count >= maxFrames { hitLimit = true; reason = "Stopped: that is as many pictures as Kriya keeps."; break }
        }
        // Finishing keeps what was held: it is shown below a line, not thrown away.
        if let held = pending, !read({ $0.cancelled }) { commit(held); onNeedsOverlap(false) }
        return AxisRun(axis: axis, frames: frames, signatures: sigs, expected: [], reason: reason, hitLimit: hitLimit, forward: 1)
    }

    // MARK: Down and across

    /// Down and across: the page is taken down in one column, then moved across by most of a width and taken down again from the
    /// top, and the columns are joined side by side. Kriya scrolls for this one. Each column is its own pass: going back to the top is
    /// checked (the page must stop moving up), and columns of different heights are reported, not hidden.
    private func runBoth() async throws -> Result {
        var columns: [CGImage] = []
        var reason = "Reached the end."
        var hit = false
        var direction = 1
        var previousTop: ScrollSignature?
        var warnings: [String] = []
        var strategy: ScrollStrategy?
        for column in 0..<12 {
            if shouldEnd { break }
            let run = try await runAxis(.vertical, startDirection: direction)
            direction = run.forward
            strategy = strategy ?? run.strategy
            warnings += run.warnings
            guard let joined = ScrollImage.assemble(frames: run.frames, plan: ScrollStitch.plan(signatures: run.signatures, expected: run.expected), axis: .vertical) else { break }
            columns.append(joined)
            hit = hit || run.hitLimit
            if shouldEnd { break }
            // Back to the top: scroll up until the picture stops changing twice running, and, if the app says where it is, until it
            // says it is at the top.
            var steady = 0
            for _ in 0..<60 {
                let before = signature(of: try await world.grab(), .vertical)
                _ = await world.scroll(by: -direction * Int(Double(joined.height) / Double(max(world.scale, 1))), axis: .vertical, using: strategy ?? .wheel)
                await sleep(min(settle, 0.45))
                let now = signature(of: try await world.grab(), .vertical)
                steady = ScrollMatch.same(before, now) ? steady + 1 : 0
                if steady >= 2 { break }
            }
            if let position = await world.position(axis: .vertical), position.offset > 2 {
                warnings.append("Column \(column + 1): the page did not return to the top, so the next column may be out of line.")
            }
            let top = signature(of: try await world.grab(), .horizontal)
            _ = await world.scroll(by: direction * Int(Double(joined.width) / Double(max(world.scale, 1)) * 0.8), axis: .horizontal, using: strategy ?? .wheel)
            let (_, nextTop) = try await settled(.horizontal)
            if ScrollMatch.same(nextTop, top) || previousTop.map({ ScrollMatch.same(nextTop, $0) }) == true { break }      // the page did not move sideways: that was the last column
            previousTop = top
            reason = "Reached the end."
        }
        if shouldEnd, read({ $0.cancelled }) { return Result(frames: [], axis: .both, plan: ScrollStitch.plan(signatures: []), cancelled: true, reason: "Cancelled.", hitLimit: false) }
        let heights = columns.map(\.height)
        if let tallest = heights.max(), let shortest = heights.min(), tallest > 0, Double(tallest - shortest) / Double(tallest) > 0.02 {
            warnings.append("The columns are not all the same height (\(shortest) to \(tallest) px), so the page may not line up across.")
        }
        let signatures = columns.map { ScrollImage.columnSignature($0) }
        let plan = ScrollStitch.plan(signatures: signatures)
        return Result(frames: columns, axis: .horizontal, plan: plan, cancelled: false, reason: reason, hitLimit: hit, warnings: warnings, strategy: strategy)
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

    // MARK: Signatures

    /// A grayscale description of every row, from the left 85% of the picture (the right edge is where a scroll bar fades in and out).
    static func rowSignature(_ image: CGImage) -> ScrollSignature {
        let h = image.height
        guard h > 0, image.width > 0 else { return ScrollSignature() }
        let usable = max(image.width * 85 / 100, 1)
        guard let cropped = image.cropping(to: CGRect(x: 0, y: 0, width: usable, height: h)) else { return ScrollSignature() }
        let n = ScrollSignature.samples
        var data = [UInt8](repeating: 0, count: n * h)
        guard let context = CGContext(data: &data, width: n, height: h, bitsPerComponent: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return ScrollSignature() }
        context.interpolationQuality = .medium
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: n, height: h))
        return ScrollSignature(width: n, data: data)
    }

    /// The same for every column, from the top 85% of the picture.
    static func columnSignature(_ image: CGImage) -> ScrollSignature {
        let w = image.width
        guard w > 0, image.height > 0 else { return ScrollSignature() }
        let usable = max(image.height * 85 / 100, 1)
        guard let cropped = image.cropping(to: CGRect(x: 0, y: 0, width: w, height: usable)) else { return ScrollSignature() }
        let n = ScrollSignature.samples
        var raw = [UInt8](repeating: 0, count: w * n)
        guard let context = CGContext(data: &raw, width: w, height: n, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return ScrollSignature() }
        context.interpolationQuality = .medium
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: n))
        // Rows of the little picture are samples; the signature wants one line per column.
        var data = [UInt8](repeating: 0, count: w * n)
        for x in 0..<w { for s in 0..<n { data[x * n + s] = raw[s * w + x] } }
        return ScrollSignature(width: n, data: data)
    }

    // MARK: Joining

    /// The red line that marks where one section ends and a picture that did not join begins.
    static let separatorThickness = 6

    /// The finished picture from the pictures taken and the plan for joining them. A section that did not join is set off by a line.
    static func assemble(frames: [CGImage], plan: ScrollStitch.Plan, axis: CaptureScrollAxis) -> CGImage? {
        var pieces: [CGImage] = []
        for (index, strip) in plan.strips.enumerated() {
            guard frames.indices.contains(strip.frame) else { continue }
            let f = frames[strip.frame]
            let rect = axis == .horizontal ? CGRect(x: strip.rows.lowerBound, y: 0, width: strip.rows.count, height: f.height)
                                           : CGRect(x: 0, y: strip.rows.lowerBound, width: f.width, height: strip.rows.count)
            guard let piece = f.cropping(to: rect) else { continue }
            if plan.breaks.contains(index), let line = separator(like: f, axis: axis) { pieces.append(line) }
            pieces.append(piece)
        }
        return stack(pieces, axis: axis)
    }

    private static func separator(like frame: CGImage, axis: CaptureScrollAxis) -> CGImage? {
        let w = axis == .horizontal ? separatorThickness : frame.width
        let h = axis == .horizontal ? frame.height : separatorThickness
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
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
