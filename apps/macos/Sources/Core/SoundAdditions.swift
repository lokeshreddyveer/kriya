import Foundation

/// A change to one app's loudness that ends by itself: muted or turned down for a while, with an optional fade out before it and
/// a fade back in after it. The app's saved settings are never touched; this multiplies on top of them.
struct TimedChange: Equatable {
    /// 0 is silent; 0.3 turns it down to 30% for the time.
    var level: Float
    /// How long it lasts, not counting the fade back in.
    var duration: TimeInterval
    var fadeOut: TimeInterval = 0
    var fadeIn: TimeInterval = 0
    var start: Date

    var end: Date { start.addingTimeInterval(duration + fadeIn) }

    /// The multiplier at `now`: 1 before and after, `level` in the middle, a straight ramp on each fade.
    func factor(at now: Date) -> Float {
        let t = now.timeIntervalSince(start)
        if t <= 0 { return 1 }
        let hold = max(duration, fadeOut)
        if t < fadeOut, fadeOut > 0 { return 1 + (level - 1) * Float(t / fadeOut) }
        if t < hold { return level }
        if t < hold + fadeIn, fadeIn > 0 { return level + (1 - level) * Float((t - hold) / fadeIn) }
        return 1
    }

    func isFinished(at now: Date) -> Bool { now >= start.addingTimeInterval(max(duration, fadeOut) + fadeIn) }

    /// Seconds left before the sound starts coming back, for "Muted for 0:42".
    func remaining(at now: Date) -> TimeInterval { max(0, start.addingTimeInterval(max(duration, fadeOut)).timeIntervalSince(now)) }

    static let presets: [(title: String, seconds: TimeInterval)] = [("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300)]
}

/// Which apps the mixer lists and in what order: favorites first (in the order the person put them), then what is playing, then
/// apps that have settings, then apps that were playing a little while ago.
enum SoundAppList {
    struct Entry: Equatable {
        let id: String
        var isFavorite: Bool
        var isPlaying: Bool
        var isRecent: Bool
    }

    static let defaultRecentMinutes = 10

    static func entries(playing: Set<String>, favorites: [String], withSettings: Set<String>, lastPlayed: [String: Date],
                        excluded: Set<String>, now: Date, recentWindow: TimeInterval, name: (String) -> String) -> [Entry] {
        var seen = Set<String>()
        var out: [Entry] = []
        func add(_ id: String, recent: Bool = false) {
            guard !id.isEmpty, !excluded.contains(id), seen.insert(id).inserted else { return }
            out.append(Entry(id: id, isFavorite: favorites.contains(id), isPlaying: playing.contains(id), isRecent: recent))
        }
        for id in favorites { add(id) }
        for id in playing.sorted(by: { name($0).lowercased() < name($1).lowercased() }) { add(id) }
        for id in withSettings.sorted(by: { name($0).lowercased() < name($1).lowercased() }) { add(id) }
        let recents = lastPlayed.filter { now.timeIntervalSince($0.value) <= recentWindow }.sorted { $0.value > $1.value }
        for (id, _) in recents { add(id, recent: true) }
        return out
    }

    /// Moves a favorite one place; the list is returned unchanged at its ends or for something that is not a favorite.
    static func move(_ id: String, by offset: Int, in favorites: [String]) -> [String] {
        guard let i = favorites.firstIndex(of: id) else { return favorites }
        let j = i + offset
        guard favorites.indices.contains(j) else { return favorites }
        var next = favorites
        next.swapAt(i, j)
        return next
    }
}

/// The whole sound setup in one name: which devices, how loud each is, what every app is set to and which apps are favorites.
struct QuickConfig: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var outputUID: String?
    var inputUID: String?
    /// Volume by device UID, 0...1, for the devices that have one.
    var deviceVolumes: [String: Double] = [:]
    /// By app (or "system"). Only apps with something set are here.
    var apps: [String: AppAudioSettings] = [:]
    var favorites: [String] = []

    static let formatName = "kriya-quick-configs"
    static let maxConfigs = 50
    static let maxFileBytes = 2_000_000

    /// "Name 2", "Name 3"… so two configurations never share a name.
    static func uniqueName(_ wanted: String, among existing: [String]) -> String {
        let base = wanted.trimmingCharacters(in: .whitespaces).isEmpty ? "Quick Config" : wanted.trimmingCharacters(in: .whitespaces)
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    func duplicated(among existing: [String]) -> QuickConfig {
        var copy = self
        copy.id = UUID().uuidString
        copy.name = Self.uniqueName(name + " copy", among: existing)
        return copy
    }

    private struct File: Codable { var format: String; var version: Int; var configs: [QuickConfig] }

    static func exported(_ configs: [QuickConfig]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(File(format: formatName, version: 1, configs: configs))
    }

    /// Reads a file made by `exported`. Anything else, or anything too large, is refused. Each setting is brought into range and
    /// every imported configuration gets a new id, so importing never replaces one that is already there.
    static func imported(_ data: Data, existingNames: [String]) -> [QuickConfig]? {
        guard data.count <= maxFileBytes, let file = try? JSONDecoder().decode(File.self, from: data),
              file.format == formatName, file.version == 1 else { return nil }
        var names = existingNames
        var out: [QuickConfig] = []
        for var config in file.configs.prefix(maxConfigs) {
            config.id = UUID().uuidString
            config.name = uniqueName(config.name, among: names)
            names.append(config.name)
            config.apps = config.apps.mapValues(\.clamped)
            config.deviceVolumes = config.deviceVolumes.mapValues { min(max($0, 0), 1) }
            out.append(config)
        }
        return out
    }
}

/// What a person calls an output or input, and the picture beside it.
struct DeviceLabel: Codable, Equatable {
    var nickname: String?
    var symbol: String?

    var isEmpty: Bool { (nickname ?? "").isEmpty && (symbol ?? "").isEmpty }

    static let symbols: [(symbol: String, title: String)] = [
        ("speaker.wave.2", "Speaker"), ("hifispeaker", "Hi-fi speaker"), ("headphones", "Headphones"), ("airpodspro", "Earbuds"),
        ("display", "Display"), ("tv", "TV"), ("laptopcomputer", "Laptop"), ("mic", "Microphone"), ("waveform", "Audio interface"), ("car", "Car"),
    ]
}

enum DeviceNaming {
    /// The name to show: the nickname if there is one, else the device's own.
    static func name(_ device: String, uid: String, labels: [String: DeviceLabel]) -> String {
        let nick = labels[uid]?.nickname?.trimmingCharacters(in: .whitespaces) ?? ""
        return nick.isEmpty ? device : nick
    }

    static func symbol(uid: String, fallback: String, labels: [String: DeviceLabel]) -> String {
        let s = labels[uid]?.symbol ?? ""
        return s.isEmpty ? fallback : s
    }

    static func setting(_ label: DeviceLabel, for uid: String, in labels: [String: DeviceLabel]) -> [String: DeviceLabel] {
        var next = labels
        var clean = label
        clean.nickname = String((label.nickname ?? "").trimmingCharacters(in: .whitespaces).prefix(40))
        if clean.nickname?.isEmpty == true { clean.nickname = nil }
        if clean.isEmpty { next[uid] = nil } else { next[uid] = clean }
        return next
    }
}

/// Left and right gain for a balance between -1 (all left) and 1 (all right): the louder side is left alone.
enum SoundBalance {
    static func gains(_ balance: Float) -> (left: Float, right: Float) {
        let b = min(max(balance, -1), 1)
        return (b > 0 ? 1 - b : 1, b < 0 ? 1 + b : 1)
    }

    static func preampGain(db: Float) -> Float { powf(10, min(max(db, -SoundPreamp.limit), SoundPreamp.limit) / 20) }
}

enum SoundPreamp { static let limit: Float = 12 }

/// A problem the mixer ran into, kept so it can be read later.
struct SoundAlert: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var at: Date
    var app: String
    var message: String

    static let keep = 50

    /// The newest first, with the same message for the same app only once in a row.
    static func adding(_ alert: SoundAlert, to list: [SoundAlert]) -> [SoundAlert] {
        if let last = list.first, last.app == alert.app, last.message == alert.message { return list }
        return Array(([alert] + list).prefix(keep))
    }
}


/// One Audio Unit effect on an app or on all sound.
struct PluginRef: Codable, Equatable, Identifiable {
    /// The four-character codes of the Audio Unit's type, subtype and maker, joined: unique to the plug-in.
    var id: String
    var name: String
    var manufacturer: String
    var bypassed = false
    /// The plug-in's own saved settings, as a property list.
    var state: Data?

    static let maxPerApp = 8

    static func code(_ value: UInt32) -> String {
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(value)
    }

    static func id(type: UInt32, subtype: UInt32, manufacturer: UInt32) -> String { "\(code(type)).\(code(subtype)).\(code(manufacturer))" }

    /// The codes back from an id made by `id(type:subtype:manufacturer:)`.
    var codes: (type: UInt32, subtype: UInt32, manufacturer: UInt32)? {
        let parts = id.components(separatedBy: ".")
        func value(_ s: String) -> UInt32? {
            let b = Array(s.data(using: .macOSRoman) ?? Data())
            return b.count == 4 ? b.reduce(0) { $0 << 8 | UInt32($1) } : nil
        }
        guard parts.count >= 3, let t = value(parts[0]), let s = value(parts[1]), let m = value(parts[2]) else { return nil }
        return (t, s, m)
    }

    /// Plug-ins grouped by who made them, makers and plug-ins in alphabetical order.
    static func grouped(_ list: [PluginRef]) -> [(manufacturer: String, plugins: [PluginRef])] {
        Dictionary(grouping: list, by: { $0.manufacturer.isEmpty ? "Other" : $0.manufacturer })
            .map { (manufacturer: $0.key, plugins: $0.value.sorted { $0.name.lowercased() < $1.name.lowercased() }) }
            .sorted { $0.manufacturer.lowercased() < $1.manufacturer.lowercased() }
    }
}

/// The small-speaker shaping that "Magic Boost" adds on top of the equaliser, and the gain that goes with it.
enum MagicBoost {
    static let strength: Float = 0.6
    static let preampDB: Float = 2

    static func gains(over eq: [Float]) -> [Float] {
        let base = EQBands.clamped(eq)
        return zip(base, EQPreset.smallSpeakers.gains).map { min(max($0 + $1 * strength, -EQBands.limit), EQBands.limit) }
    }
}
