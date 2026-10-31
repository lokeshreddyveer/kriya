import Foundation

/// How wide a GIF may be.
enum GIFResolution: String, Codable, CaseIterable, Identifiable {
    case small, medium, large, original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "Small (480 wide)"
        case .medium: return "Medium (720 wide)"
        case .large: return "Large (1280 wide)"
        case .original: return "Original size"
        }
    }

    /// The widest the GIF may be, in pixels, or nil for no limit.
    var maxWidth: Int? {
        switch self {
        case .small: return 480
        case .medium: return 720
        case .large: return 1280
        case .original: return nil
        }
    }

    /// The size a picture this big comes out at: no wider than allowed, keeping its shape, never enlarged.
    func outputSize(for source: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return source }
        guard let limit = maxWidth.map(CGFloat.init), source.width > limit else { return source }
        let factor = limit / source.width
        return CGSize(width: limit, height: max((source.height * factor).rounded(), 1))
    }
}

/// How a screen recording is turned into a GIF. The defaults are what Kriya has always done: 10 pictures a second, 720 wide, the
/// first 30 seconds, every colour kept, nothing merged.
struct GIFOptions: Codable, Equatable {
    static let frameRates = [5, 10, 15, 20, 25, 30]
    static let qualityRange: ClosedRange<Double> = 0.1...1
    static let durationRange: ClosedRange<Double> = 1...600
    /// However long it is asked to be, a GIF is never more than this many pictures.
    static let hardFrameLimit = 3_000

    /// Pictures a second.
    var frameRate = 10
    var resolution: GIFResolution = .medium
    /// 1 keeps every colour; lower values use fewer, which makes a smaller file and a flatter picture.
    var quality = 1.0
    /// Pictures that repeat the one before are merged into it, so a still screen costs nothing.
    var optimize = false
    /// How much of the recording is used, in seconds from the start, or nil for all of it.
    var maximumDuration: Double? = 30

    private enum CodingKeys: String, CodingKey { case frameRate, resolution, quality, optimize, maximumDuration }

    init(frameRate: Int = 10, resolution: GIFResolution = .medium, quality: Double = 1, optimize: Bool = false, maximumDuration: Double? = 30) {
        self.frameRate = frameRate; self.resolution = resolution; self.quality = quality; self.optimize = optimize; self.maximumDuration = maximumDuration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GIFOptions()
        frameRate = c.value(.frameRate, d.frameRate); resolution = c.value(.resolution, d.resolution); quality = c.value(.quality, d.quality)
        optimize = c.value(.optimize, d.optimize)
        // A duration that is not there (an older file) or is damaged is the usual 30 seconds; one saved as null means all of it.
        if c.contains(.maximumDuration) {
            if (try? c.decodeNil(forKey: .maximumDuration)) == true { maximumDuration = nil }
            else { maximumDuration = (try? c.decode(Double.self, forKey: .maximumDuration)) ?? d.maximumDuration }
        } else {
            maximumDuration = d.maximumDuration
        }
    }

    /// "All of it" is saved as an explicit null, so it is not mistaken for a missing value (which means the usual 30 seconds).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(frameRate, forKey: .frameRate)
        try c.encode(resolution, forKey: .resolution)
        try c.encode(quality, forKey: .quality)
        try c.encode(optimize, forKey: .optimize)
        try c.encode(maximumDuration, forKey: .maximumDuration)
    }

    func sanitized() -> GIFOptions {
        var next = self
        next.frameRate = Self.frameRates.min { abs($0 - frameRate) < abs($1 - frameRate) } ?? 10
        next.quality = quality.isNaN ? 1 : min(max(quality, Self.qualityRange.lowerBound), Self.qualityRange.upperBound)
        if let duration = maximumDuration {
            next.maximumDuration = duration.isNaN ? 30 : min(max(duration, Self.durationRange.lowerBound), Self.durationRange.upperBound)
        }
        return next
    }

    /// How many levels of each colour channel the pictures are reduced to: 256 (all) at full quality, down to 8 at the lowest.
    var colourLevels: Int {
        let q = sanitized().quality
        return max(8, min(256, Int((8 + (q - Self.qualityRange.lowerBound) / (1 - Self.qualityRange.lowerBound) * 248).rounded())))
    }

    /// How long each picture is shown, in seconds. A GIF counts in hundredths of a second, and browsers show anything under 0.02 as
    /// 0.1, so it is never less.
    var frameDelay: Double { max((100 / Double(sanitized().frameRate)).rounded() / 100, 0.02) }
}

/// Which moments of a recording become pictures of the GIF.
enum GIFPlan {
    /// The times (seconds into the recording) to take a picture at: evenly spaced at the frame rate, from the start, for as long as the
    /// recording lasts or the duration limit allows, and never more than the hard limit.
    static func frameTimes(duration: Double, options: GIFOptions) -> [Double] {
        let options = options.sanitized()
        guard duration > 0, duration.isFinite else { return [] }
        let length = min(duration, options.maximumDuration ?? duration)
        let step = 1 / Double(options.frameRate)
        // A hair is added so 5 seconds at 10 a second is 50 steps, not 49 from a rounding error.
        let count = min(max(Int(((length / step) + 1e-9).rounded(.down)) + 1, 1), GIFOptions.hardFrameLimit)
        return (0..<count).map { Double($0) * step }.filter { $0 < duration || $0 == 0 }
    }

    /// The pictures to keep and how long each is shown, when pictures that repeat the one before are merged into it. `repeats[i]` says
    /// whether picture `i` is the same as the one before it (the first never is). Total time is kept: a merged picture adds its time
    /// to the one it joined.
    static func collapse(repeats: [Bool], delay: Double) -> [(index: Int, delay: Double)] {
        var kept: [(index: Int, delay: Double)] = []
        for (index, same) in repeats.enumerated() {
            if same, !kept.isEmpty { kept[kept.count - 1].delay += delay } else { kept.append((index, delay)) }
        }
        return kept
    }

    /// Without merging: every picture, for the same delay.
    static func all(count: Int, delay: Double) -> [(index: Int, delay: Double)] { (0..<max(count, 0)).map { ($0, delay) } }

    /// The most the file can come to, for deciding whether there is room before starting. GIFs vary a lot with what is in them, so this
    /// is on the high side: it is better to say "may not fit" than to fill the disk.
    static func estimatedBytes(frames: Int, size: CGSize, options: GIFOptions) -> Int64 {
        guard frames > 0, size.width > 0, size.height > 0 else { return 0 }
        // Lower quality reduces colours, which compresses better; merging is not counted on.
        let perPixel = 0.12 + 0.23 * (options.sanitized().quality - GIFOptions.qualityRange.lowerBound) / (1 - GIFOptions.qualityRange.lowerBound)
        return Int64((Double(frames) * Double(size.width * size.height) * perPixel).rounded(.up))
    }
}

extension GIFPlan {
    /// A GIF holds every picture in memory until it is written, so how many there can be depends on how big each is. About 1.5 GB at most.
    static let memoryBudget: Int64 = 1_500_000_000

    static func memoryFrameLimit(for size: CGSize) -> Int {
        let perFrame = max(Int64(size.width * size.height) * 4, 1)
        return max(Int(min(memoryBudget / perFrame, Int64(GIFOptions.hardFrameLimit))), 1)
    }
}

/// Telling whether two frames of a recording are the same, from small grey pictures of each.
enum GIFFrameSignature {
    static let width = 32
    static let height = 18
    /// The average difference (out of 255) below which two frames count as the same: a blinking cursor or a little noise does not make
    /// a new picture.
    static let tolerance = 0.6

    static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard !a.isEmpty, a.count == b.count else { return false }
        var total = 0
        for i in 0..<a.count { total += abs(Int(a[i]) - Int(b[i])) }
        return Double(total) / Double(a.count) <= tolerance
    }
}

/// Reducing the colours of a picture: how each value of a colour channel maps when there are only `levels` of them.
enum GIFColour {
    static func table(levels: Int) -> [UInt8] {
        let n = min(max(levels, 2), 256)
        return (0..<256).map { value in
            n >= 256 ? UInt8(value) : UInt8((Double(value) / 255 * Double(n - 1)).rounded() / Double(n - 1) * 255 + 0.5)
        }
    }
}

/// Whether there is room for a GIF, said before it is started and checked while it is made.
enum GIFDisk {
    /// Always left free on top of what the file needs, so the Mac is never filled to the last byte.
    static let margin: Int64 = 200 * 1_024 * 1_024

    /// A sentence saying why not, or nil if there is room. Nil free space (it could not be read) is not a reason to refuse.
    static func problem(estimated: Int64, free: Int64?) -> String? {
        guard let free else { return nil }
        guard free < estimated + margin else { return nil }
        let need = ByteCountFormatter.string(fromByteCount: estimated + margin, countStyle: .file)
        let have = ByteCountFormatter.string(fromByteCount: max(free, 0), countStyle: .file)
        return "There may not be room for this GIF: it could need about \(need) and \(have) is free. Free some space, or use a smaller size, a lower frame rate or a shorter length."
    }

    /// While the GIF is made: true when the space left is so small that going on risks filling the disk.
    static func isTooLow(free: Int64?) -> Bool {
        guard let free else { return false }
        return free < margin / 2
    }
}

/// How making a GIF ended.
enum GIFOutcome: Equatable {
    /// `note` is something the person should know: the GIF was cut short to keep memory in check.
    case saved(frames: Int, bytes: Int64, note: String?)
    /// The person pressed Cancel. Nothing is left behind.
    case cancelled
    case failed(String)

    var message: String {
        switch self {
        case .saved(let frames, let bytes, let note):
            return "GIF saved: \(frames) picture\(frames == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))." + (note.map { " " + $0 } ?? "")
        case .cancelled: return "GIF cancelled."
        case .failed(let reason): return reason
        }
    }
}
