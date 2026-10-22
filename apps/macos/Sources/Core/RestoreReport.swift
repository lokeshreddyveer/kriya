import Foundation

/// What happened to one window of a layout when it was restored, in words that say what to do about it.
struct RestoreEntryResult: Identifiable, Equatable {
    enum Status: Equatable {
        /// Put where the layout says, on the display it was saved for.
        case placed(display: String)
        /// The saved display is not connected, so it went to another one.
        case placedOnOtherDisplay(display: String)
        /// The saved display is not connected, so it went to the main display.
        case movedToMainDisplay(display: String)
        /// A window was found but the app did not let it be moved.
        case couldNotMove
        /// The app was not running; it was opened and its window is placed when it appears.
        case opening
        case appNotRunning
        case appHidden
        case appExcluded
        case onlyMinimized(Int)
        case noWindow
        /// The app has windows, but the layout has more entries for it than there are windows.
        case notEnoughWindows(open: Int)
    }

    /// The position of the entry in the layout.
    let id: Int
    let appID: String
    let appName: String
    let title: String
    var status: Status
    /// The window was taken because it was the app's next free one, not because its title matched the saved one.
    var matchedByAppOnly = false

    var isPlaced: Bool {
        switch status {
        case .placed, .placedOnOtherDisplay, .movedToMainDisplay: return true
        default: return false
        }
    }

    /// Needs the person to look: nothing was done for it, or what was done is probably not what they want.
    var needsAttention: Bool {
        switch status {
        case .placed, .opening: return false
        case .placedOnOtherDisplay, .movedToMainDisplay: return false
        default: return true
        }
    }

    /// Whether choosing a replacement window can help.
    var canChooseReplacement: Bool {
        switch status {
        case .couldNotMove, .appHidden, .onlyMinimized, .noWindow, .notEnoughWindows, .appExcluded, .appNotRunning: return true
        default: return false
        }
    }

    var label: String { title.isEmpty ? appName : "\(appName) · \(title)" }

    var explanation: String {
        switch status {
        case .placed(let display):
            return matchedByAppOnly ? "Placed on \(display). No window had the saved title, so this app’s next window was used." : "Placed on \(display)."
        case .placedOnOtherDisplay(let display):
            return "Its display is not connected, so it went to \(display)."
        case .movedToMainDisplay(let display):
            return "Its display is not connected, so it went to the main display (\(display))."
        case .couldNotMove:
            return "The window was found, but the app did not let it be moved. Some windows have a fixed size or are full screen."
        case .opening:
            return "The app was not running. It is opening, and its window is placed when it appears."
        case .appNotRunning:
            return "The app is not running. Turn on “Open apps that are not running” for this layout, or open it and try again."
        case .appHidden:
            return "The app is hidden. Show it, then try again."
        case .appExcluded:
            return "The app is left out of window management in Windows › Options."
        case .onlyMinimized(let count):
            return count == 1 ? "Its only window is minimized." : "All \(count) of its windows are minimized."
        case .noWindow:
            return "The app is running but has no window open here. It may be on another Space, or closed."
        case .notEnoughWindows(let open):
            return "The layout has more windows for this app than are open (\(open)), so this one had none left."
        }
    }
}

/// How restoring a layout went, window by window.
struct RestoreReport: Equatable {
    var layoutID: String
    var layoutName: String
    var results: [RestoreEntryResult]

    var placed: [RestoreEntryResult] { results.filter(\.isPlaced) }
    var needAttention: [RestoreEntryResult] { results.filter(\.needsAttention) }
    var notFound: [RestoreEntryResult] {
        results.filter {
            switch $0.status {
            case .appNotRunning, .noWindow, .notEnoughWindows, .onlyMinimized, .appHidden, .appExcluded: return true
            default: return false
            }
        }
    }
    var onOtherDisplay: [RestoreEntryResult] {
        results.filter { if case .placedOnOtherDisplay = $0.status { return true } else { return false } }
    }
    var onMainDisplay: [RestoreEntryResult] {
        results.filter { if case .movedToMainDisplay = $0.status { return true } else { return false } }
    }
    var appsNotRunning: [RestoreEntryResult] {
        results.filter {
            switch $0.status {
            case .appNotRunning, .opening: return true
            default: return false
            }
        }
    }

    /// One line for a message: what was restored and what was not.
    var summary: String {
        var parts = ["\(placed.count) of \(results.count) window\(results.count == 1 ? "" : "s") restored"]
        let opening = results.filter { $0.status == .opening }.count
        if opening > 0 { parts.append("\(opening) opening") }
        let missing = needAttention.count
        if missing > 0 { parts.append("\(missing) need\(missing == 1 ? "s" : "") a look") }
        if !onMainDisplay.isEmpty || !onOtherDisplay.isEmpty {
            parts.append("\(onMainDisplay.count + onOtherDisplay.count) on a different display")
        }
        return parts.joined(separator: ", ")
    }

    var isClean: Bool { needAttention.isEmpty && onOtherDisplay.isEmpty && onMainDisplay.isEmpty }
}

/// What was true of the Mac when a layout was restored, as plain values so the diagnosis can be tested.
struct RestoreFacts {
    var runningApps: Set<String> = []
    var hiddenApps: Set<String> = []
    var excludedApps: Set<String> = []
    /// Minimized windows per app.
    var minimizedWindows: [String: Int] = [:]
}

enum RestoreDiagnosis {
    /// Works out, for each entry of a layout, what became of it.
    /// - Parameters:
    ///   - matches: for each open window, the entry it took (what the matcher returned).
    ///   - open: the open windows the matcher saw, in the same order.
    ///   - moved: for each open window, whether macOS accepted the move.
    ///   - opened: entries whose app was started by the restore.
    static func build(
        layoutID: String, layoutName: String, entries: [LayoutEntry],
        matches: [Int?], open: [(appID: String, title: String)], moved: [Bool],
        opened: Set<Int>, displays: [DisplayInfo], facts: RestoreFacts,
        appName: (String) -> String = { $0 }
    ) -> RestoreReport {
        var windowForEntry: [Int: Int] = [:]
        for (windowIndex, match) in matches.enumerated() { if let match { windowForEntry[match] = windowIndex } }
        let openCounts = Dictionary(grouping: open, by: \.appID).mapValues(\.count)

        var results: [RestoreEntryResult] = []
        for (index, entry) in entries.enumerated() {
            var result = RestoreEntryResult(id: index, appID: entry.appId, appName: appName(entry.appId), title: entry.title, status: .noWindow)
            if let windowIndex = windowForEntry[index] {
                let didMove = windowIndex < moved.count ? moved[windowIndex] : false
                result.matchedByAppOnly = windowIndex < open.count && open[windowIndex].title != entry.title
                if didMove {
                    result.status = placement(for: entry, displays: displays)
                } else {
                    result.status = .couldNotMove
                }
            } else if facts.excludedApps.contains(entry.appId) {
                result.status = .appExcluded
            } else if !facts.runningApps.contains(entry.appId) {
                result.status = opened.contains(index) ? .opening : .appNotRunning
            } else if facts.hiddenApps.contains(entry.appId) {
                result.status = .appHidden
            } else if let minimized = facts.minimizedWindows[entry.appId], minimized > 0, (openCounts[entry.appId] ?? 0) == 0 {
                result.status = .onlyMinimized(minimized)
            } else if let count = openCounts[entry.appId], count > 0 {
                result.status = .notEnoughWindows(open: count)
            } else {
                result.status = .noWindow
            }
            results.append(result)
        }
        return RestoreReport(layoutID: layoutID, layoutName: layoutName, results: results)
    }

    private static func placement(for entry: LayoutEntry, displays: [DisplayInfo]) -> RestoreEntryResult.Status {
        if let own = displays.first(where: { $0.id == entry.displayId }) { return .placed(display: own.name) }
        let main = displays.first { $0.isMain }
        let target = main ?? displays.first
        guard let target else { return .placed(display: "a display") }
        return target.isMain ? .movedToMainDisplay(display: target.name) : .placedOnOtherDisplay(display: target.name)
    }
}

/// Moving and resizing a group of windows as one: the group keeps its shape, and is fitted into a region of a display.
enum GroupRegion: String, CaseIterable, Identifiable {
    case whole, leftHalf, rightHalf, topHalf, bottomHalf, keepSize
    var id: String { rawValue }

    var title: String {
        switch self {
        case .whole: return "Fill the display"
        case .leftHalf: return "Left half"
        case .rightHalf: return "Right half"
        case .topHalf: return "Top half"
        case .bottomHalf: return "Bottom half"
        case .keepSize: return "Centered, same size"
        }
    }
}

enum GroupGeometry {
    /// The entries moved to `target` and fitted into `region` of its usable area. Every entry keeps its place inside the
    /// group, so the group looks the same, only moved or scaled. Entries are fractions of their display's usable area.
    static func fit(entries: [LayoutEntry], displays: [DisplayInfo], target: DisplayInfo, region: GroupRegion) -> [LayoutEntry] {
        guard !entries.isEmpty else { return [] }
        func display(for entry: LayoutEntry) -> DisplayInfo? { displays.first { $0.id == entry.displayId } ?? displays.first { $0.isMain } ?? displays.first }

        // Every window in points, on the screen they share.
        let absolute: [CGRect] = entries.map { entry in
            guard let area = display(for: entry)?.area else { return .zero }
            return CGRect(
                x: area.x + entry.frame.x * area.width, y: area.y + entry.frame.y * area.height,
                width: entry.frame.width * area.width, height: entry.frame.height * area.height
            )
        }
        let box = absolute.dropFirst().reduce(absolute[0]) { $0.union($1) }
        let area = CGRect(x: target.area.x, y: target.area.y, width: target.area.width, height: target.area.height)
        guard area.width > 0, area.height > 0 else { return entries }

        let place: CGRect
        switch region {
        case .whole: place = area
        case .leftHalf: place = CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height)
        case .rightHalf: place = CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height)
        case .topHalf: place = CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height / 2)
        case .bottomHalf: place = CGRect(x: area.minX, y: area.midY, width: area.width, height: area.height / 2)
        case .keepSize:
            let width = min(box.width, area.width)
            let height = min(box.height, area.height)
            place = CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        }

        let scaleX = box.width > 0 ? place.width / box.width : 1
        let scaleY = box.height > 0 ? place.height / box.height : 1
        return zip(entries, absolute).map { entry, rect in
            var moved = entry
            let x = place.minX + (rect.minX - box.minX) * scaleX
            let y = place.minY + (rect.minY - box.minY) * scaleY
            moved.displayId = target.id
            moved.frame = Rect(
                x: (x - area.minX) / area.width, y: (y - area.minY) / area.height,
                width: rect.width * scaleX / area.width, height: rect.height * scaleY / area.height
            )
            return moved
        }
    }
}
