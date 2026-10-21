import AppKit
import Combine

struct DisplayInfo: Equatable, Identifiable {
    let id: String
    let name: String
    /// The whole display and the part windows may use (without the menu bar and Dock), in top-left coordinates.
    let full: Rect
    let area: Rect
    let isMain: Bool
}

/// The connected displays, in the coordinates the Accessibility API uses (origin at the top left of the main display,
/// y growing downward). Notices when displays are added, removed or rearranged.
final class DisplayManager: ObservableObject {
    @Published private(set) var displays: [DisplayInfo] = []

    /// Called with the displays before and after a change.
    var onChange: (([DisplayInfo], [DisplayInfo]) -> Void)?

    private var observer: NSObjectProtocol?
    private var pending: DispatchWorkItem?

    init() {
        displays = Self.current()
    }

    deinit { stop() }

    func start() {
        guard observer == nil else { return }
        displays = Self.current()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRefresh() }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        pending?.cancel()
    }

    /// Display changes arrive as a burst of notifications; act once it settles.
    private func scheduleRefresh() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let before = displays
            let after = Self.current()
            guard before != after else { return }
            displays = after
            Log.info("Windows", "Displays changed: \(before.count) → \(after.count)")
            onChange?(before, after)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func refresh() { displays = Self.current() }

    /// The same for the same set of displays, whatever their order.
    var setKey: String { windowDisplaySetKey(displayIds: displays.map(\.id)) }

    /// Displays from left to right, for "next display" and "previous display".
    var ordered: [DisplayInfo] {
        displays.sorted { ($0.full.x, $0.full.y) < ($1.full.x, $1.full.y) }
    }

    func info(id: String) -> DisplayInfo? { displays.first { $0.id == id } }
    var main: DisplayInfo? { displays.first { $0.isMain } ?? displays.first }

    /// The display that holds most of a frame, or the nearest one.
    func display(containing frame: Rect) -> DisplayInfo? {
        guard let index = windowDisplayIndex(frame: frame, areas: displays.map(\.full)) else { return nil }
        return displays[Int(index)]
    }

    func display(at point: CGPoint) -> DisplayInfo? {
        displays.first { $0.full.cg.contains(point) } ?? main
    }

    // MARK: Reading the screens

    static func current() -> [DisplayInfo] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryHeight = primary.frame.height
        func topLeft(_ r: CGRect) -> Rect {
            Rect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        }
        return screens.enumerated().map { index, screen in
            DisplayInfo(
                id: identifier(of: screen) ?? "screen-\(index)",
                name: screen.localizedName,
                full: topLeft(screen.frame),
                area: topLeft(screen.visibleFrame),
                isMain: index == 0
            )
        }
    }

    /// A stable name for a physical display: it survives unplugging and plugging it back in.
    private static func identifier(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let text = CFUUIDCreateString(nil, uuid) as String? else { return "display-\(displayID)" }
        return text
    }

    /// The mouse position in the top-left coordinates of the Accessibility API.
    static func mouseLocation() -> CGPoint {
        let location = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: location.x, y: height - location.y)
    }

    /// Converts a top-left rectangle to the bottom-left one AppKit windows use.
    static func appKitFrame(_ rect: Rect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.x, y: height - rect.y - rect.height, width: rect.width, height: rect.height)
    }
}
