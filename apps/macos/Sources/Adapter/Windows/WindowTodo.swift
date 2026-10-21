import AppKit

/// Todo mode: one app lives in a narrow column at the side of its display, and every layout, drag snap and maximize
/// uses only the space that is left. Turn it on from the app you want in the column; do the same again to turn it off.
final class TodoManager {
    private unowned let controller: WindowController
    private var displayID: String?

    init(controller: WindowController) {
        self.controller = controller
    }

    private var config: WindowConfig { controller.store.currentConfig }

    /// The todo app's main window, if the app is running and has one open.
    func window() -> AXWindow? {
        guard let id = config.todoAppId,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == id }) else { return nil }
        return AXWindow.windows(ofApp: app.processIdentifier).first { $0.isStandard && !$0.isMinimized }
    }

    /// The todo column and the space left for everything else on a display, or nil when todo mode is off or the todo
    /// window is on another display.
    func split(on display: DisplayInfo) -> (todo: Rect, rest: Rect)? {
        guard config.todoAppId != nil else { return nil }
        if displayID == nil, let frame = window()?.frame {
            // After a restart: the window is wherever it was left.
            displayID = controller.displays.display(containing: frame)?.id
        }
        guard displayID == display.id else { return nil }
        let parts = windowTodoSplit(area: display.area, fraction: config.todoFraction, onRight: config.todoOnRight)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// Makes the app in front the todo app, or turns todo mode off if it already is.
    func toggleFocused() {
        guard AXIsProcessTrusted(), let focused = AXWindow.focused(), let appID = focused.appID else { return }
        if config.todoAppId == appID {
            controller.store.updateConfig { $0.todoAppId = nil }
            displayID = nil
            return
        }
        guard let frame = focused.frame, let display = controller.displays.display(containing: frame) else { return }
        controller.store.updateConfig { $0.todoAppId = appID }
        displayID = display.id
        dock(focused, on: display)
    }

    /// Brings the todo window to the front, back in its column.
    func focus() {
        guard let window = window() else { return }
        if displayID == nil, let frame = window.frame { displayID = controller.displays.display(containing: frame)?.id }
        if let id = displayID, let display = controller.displays.info(id: id) { dock(window, on: display) }
        window.raise()
    }

    private func dock(_ window: AXWindow, on display: DisplayInfo) {
        guard let parts = split(on: display), let current = window.frame else { return }
        controller.place(window, to: parts.todo, from: current, label: "Todo", layout: nil)
    }
}

extension WindowController {
    /// The part of a display that layouts may use: the usable area, less the todo column when todo mode is on.
    func usableArea(_ display: DisplayInfo) -> Rect {
        todo.split(on: display)?.rest ?? display.area
    }
}
