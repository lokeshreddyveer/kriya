import Foundation

/// What a mouse tool running at the same time can interfere with.
enum MouseArea: String, Codable, CaseIterable, Hashable {
    case scrolling, buttons, gestures, pointerSpeed

    var title: String {
        switch self {
        case .scrolling: return "scrolling"
        case .buttons: return "buttons"
        case .gestures: return "gestures"
        case .pointerSpeed: return "pointer speed"
        }
    }
}

/// Another program that changes how a mouse behaves. Found by the apps that are open, never by looking inside them.
struct CompetingTool: Equatable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var bundleIDs: [String]
    /// Names the program runs under, for when its identifier is not known.
    var processNames: [String]
    var areas: Set<MouseArea>
}

enum CompetingTools {
    /// Mouse tools Kriya knows about. What each one touches is what its maker describes; it is a guide to what may clash, not a promise.
    static let known: [CompetingTool] = [
        CompetingTool(name: "Mac Mouse Fix", bundleIDs: ["com.nuebling.mac-mouse-fix", "com.nuebling.mac-mouse-fix.helper"], processNames: ["Mac Mouse Fix", "Mac Mouse Fix Helper"], areas: [.scrolling, .buttons, .gestures]),
        CompetingTool(name: "BetterTouchTool", bundleIDs: ["com.hegenberg.BetterTouchTool"], processNames: ["BetterTouchTool"], areas: [.scrolling, .buttons, .gestures]),
        CompetingTool(name: "LinearMouse", bundleIDs: ["com.lujjjh.LinearMouse"], processNames: ["LinearMouse"], areas: [.scrolling, .buttons, .pointerSpeed]),
        CompetingTool(name: "Mos", bundleIDs: ["com.caldis.Mos"], processNames: ["Mos"], areas: [.scrolling]),
        CompetingTool(name: "SteerMouse", bundleIDs: ["jp.plentycom.boa.SteerMouse"], processNames: ["SteerMouse"], areas: [.scrolling, .buttons, .pointerSpeed]),
        CompetingTool(name: "Scroll Reverser", bundleIDs: ["com.pilotmoon.scroll-reverser"], processNames: ["Scroll Reverser"], areas: [.scrolling]),
    ]

    /// Which known tools are among these running apps, by identifier or by name.
    static func detect(running: [(bundleID: String?, name: String?)], among tools: [CompetingTool] = known) -> [CompetingTool] {
        tools.filter { tool in
            running.contains { app in
                if let id = app.bundleID, tool.bundleIDs.contains(id) { return true }
                if let name = app.name, tool.processNames.contains(name) { return true }
                return false
            }
        }
    }
}

struct CoexistenceSettings: Codable, Equatable {
    /// While another tool that handles scrolling is running, Kriya leaves scrolling to it, so a wheel turn is not smoothed twice.
    var yieldScrollingToOthers = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        yieldScrollingToOthers = c.value(.yieldScrollingToOthers, true)
    }

    private enum CodingKeys: String, CodingKey { case yieldScrollingToOthers }
}

struct CoexistenceStore {
    static let key = "mouse.coexistence.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var settings: CoexistenceSettings {
        get { defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(CoexistenceSettings.self, from: $0) } ?? CoexistenceSettings() }
        nonmutating set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.key) } }
    }
}

// MARK: - What is known about each tool

/// Kriya can see which apps are installed and open. It cannot see another app’s permissions or settings, and it only knows two apps
/// clash when it sees evidence in the events themselves. These are kept apart so none is claimed for another.
struct CompetingToolStatus: Equatable, Identifiable {
    var tool: CompetingTool
    /// Found on this Mac.
    var installed: Bool
    /// Open now.
    var running: Bool
    /// Whether macOS has given this app Accessibility or Input Monitoring is kept per app and is not something Kriya can read, so it is
    /// never known. Nil says so; the screen says "cannot be checked", not "no".
    var accessibilityGranted: Bool? { nil }
    /// This tool is open, handles an area Kriya is also set to change. A reason to look, not proof of a clash.
    var knownOverlappingConfiguration: Bool
    /// Scroll events Kriya received whose source metadata names this tool’s process. It comes from the events themselves, but it is
    /// only metadata: a source can be missing or wrong, so it shows the tool is probably active, not that it owns scrolling.
    var observedSourceMetadata: Set<MouseArea>

    var id: String { tool.id }

    /// The strongest thing that can honestly be said, one line.
    var summary: String {
        if !observedSourceMetadata.isEmpty {
            return "Source metadata observed on \(observedSourceMetadata.map(\.title).sorted().joined(separator: ", ")) events. This is a hint, not proof."
        }
        if running { return knownOverlappingConfiguration ? "Open, and handles the same area as Kriya’s settings" : "Open" }
        return installed ? "Installed, not open" : "Not found"
    }
}

/// How scrolling stands. Never says who really owns it unless events show it.
enum ScrollOwnership: Equatable {
    /// Nothing is set to change the wheel.
    case nothingConfigured
    case kriyaConfigured
    /// Another utility is open; Kriya is not set to change scrolling.
    case otherUtilityDetected(String)
    /// Kriya is set to change scrolling and another utility that handles it is open.
    case bothConfigured(String)

    var title: String {
        switch self {
        case .nothingConfigured: return "Nothing is set to change scrolling"
        case .kriyaConfigured: return "Kriya is configured"
        case .otherUtilityDetected(let name): return "Other utility detected: \(name)"
        case .bothConfigured(let name): return "Kriya is configured, and \(name) is open"
        }
    }

    /// Whether who is changing the wheel is actually known. It is only when nobody else is open.
    var isKnown: Bool {
        switch self {
        case .nothingConfigured, .kriyaConfigured: return true
        case .otherUtilityDetected, .bothConfigured: return false
        }
    }
}

enum CoexistencePlan {
    struct Result: Equatable {
        var ownership: ScrollOwnership
        /// Kriya should leave scrolling to the other tool. A choice, made because it is safer, not because a clash was proven.
        var yieldsScrolling: Bool
        /// Another open tool’s process was named as the source of scroll events while Kriya is set to change scrolling. A hint only.
        var observedOverlaps: [String]
        /// One sentence for each thing worth knowing.
        var notes: [String]
    }

    /// `kriyaChangesScrolling` is whether Kriya would smooth, speed up or reshape the wheel with the settings in force. `evidence` is what
    /// the events showed, by tool name.
    static func evaluate(statuses: [CompetingToolStatus], settings: CoexistenceSettings, kriyaChangesScrolling: Bool) -> Result {
        let open = statuses.filter(\.running)
        let scrollers = open.filter { $0.tool.areas.contains(.scrolling) }
        var notes: [String] = []
        let ownership: ScrollOwnership
        var yields = false
        if let first = scrollers.first {
            ownership = kriyaChangesScrolling ? .bothConfigured(first.tool.name) : .otherUtilityDetected(first.tool.name)
            if kriyaChangesScrolling, settings.yieldScrollingToOthers {
                yields = true
                notes.append("\(first.tool.name) is open and may also change scrolling. Kriya cannot see its settings, so as a precaution it leaves scrolling to it. Quit \(first.tool.name), or turn this off below, to use Kriya’s scrolling.")
            } else if kriyaChangesScrolling {
                notes.append("\(first.tool.name) is open and may also change scrolling. Kriya cannot tell whether it does. If scrolling feels doubled or jumpy, turn on “Let other tools handle scrolling”, or quit one of them.")
            }
        } else {
            ownership = kriyaChangesScrolling ? .kriyaConfigured : .nothingConfigured
        }
        if !ownership.isKnown { notes.append("Which of them is really changing scrolling is not known.") }

        let confirmed = statuses.filter { $0.running && $0.observedSourceMetadata.contains(.scrolling) && kriyaChangesScrolling }.map(\.tool.name)
        for name in confirmed {
            notes.append("Scroll events whose source metadata names \(name) were observed while Kriya is also set to change scrolling. That does not prove \(name) owns scrolling: a source can be missing or wrong.")
        }
        for status in open {
            let others = status.tool.areas.subtracting([.scrolling])
            if !others.isEmpty {
                let list = others.map(\.title).sorted().joined(separator: ", ")
                notes.append("\(status.tool.name) can also handle \(list). If one of those misbehaves, only one of the two should have a rule for it.")
            }
        }
        if open.count > 1 {
            notes.append("Several mouse tools are open (\(open.map(\.tool.name).joined(separator: ", "))). Each sees the mouse’s events in turn.")
        }
        return Result(ownership: ownership, yieldsScrolling: yields, observedOverlaps: confirmed, notes: notes)
    }

    /// The status of each known tool from what can be seen. `evidence` is the areas events have shown, by tool name.
    static func statuses(installed: Set<String>, running: [CompetingTool], kriyaAreas: Set<MouseArea>, evidence: [String: Set<MouseArea>],
                         among tools: [CompetingTool] = CompetingTools.known) -> [CompetingToolStatus] {
        let openNames = Set(running.map(\.name))
        return tools.compactMap { tool in
            let isRunning = openNames.contains(tool.name)
            let isInstalled = installed.contains(tool.name) || isRunning
            guard isInstalled else { return nil }
            return CompetingToolStatus(tool: tool, installed: isInstalled, running: isRunning,
                                       knownOverlappingConfiguration: isRunning && !tool.areas.isDisjoint(with: kriyaAreas),
                                       observedSourceMetadata: evidence[tool.name] ?? [])
        }
    }
}
