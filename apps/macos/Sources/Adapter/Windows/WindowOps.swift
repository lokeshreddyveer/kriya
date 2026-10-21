import AppKit

extension WindowController {
    /// Window commands beyond the layouts: margins, one-direction maximize, growing and shrinking, arranging many
    /// windows, and moving between the windows of one app. Returns false when the command is not one of these.
    func runExtraOp(_ command: String) -> Bool {
        switch command {
        case "window.almost_maximize":
            reshape("Almost maximize") { _, area, config in windowInsetFrame(area: area, margin: config.almostMaximizeMargin) }
        case "window.maximize_width":
            reshape("Maximize width") { frame, area, _ in windowMaximizeAxis(frame: frame, area: area, horizontal: true) }
        case "window.maximize_height":
            reshape("Maximize height") { frame, area, _ in windowMaximizeAxis(frame: frame, area: area, horizontal: false) }
        case "window.grow":
            reshape("Bigger") { frame, area, config in
                windowResizeBy(frame: frame, area: area, dw: config.resizeStep, dh: config.resizeStep, keepAspect: config.keepAspect)
            }
        case "window.shrink":
            reshape("Smaller") { frame, area, config in
                windowResizeBy(frame: frame, area: area, dw: -config.resizeStep, dh: -config.resizeStep, keepAspect: config.keepAspect)
            }
        case "window.wider":
            reshape("Wider") { frame, area, config in windowResizeBy(frame: frame, area: area, dw: config.resizeStep, dh: 0, keepAspect: false) }
        case "window.narrower":
            reshape("Narrower") { frame, area, config in windowResizeBy(frame: frame, area: area, dw: -config.resizeStep, dh: 0, keepAspect: false) }
        case "window.taller":
            reshape("Taller") { frame, area, config in windowResizeBy(frame: frame, area: area, dw: 0, dh: config.resizeStep, keepAspect: false) }
        case "window.shorter":
            reshape("Shorter") { frame, area, config in windowResizeBy(frame: frame, area: area, dw: 0, dh: -config.resizeStep, keepAspect: false) }
        case "window.cascade":
            arrange("Cascade") { area, count, _ in windowCascadeFrames(area: area, count: UInt32(count), offset: 30) }
        case "window.tile":
            arrange("Tile") { area, count, config in windowTileFrames(area: area, count: UInt32(count), gap: config.gap) }
        case "window.next_same_app":
            cycleWindowsOfApp()
        default:
            return false
        }
        return true
    }

    /// Changes the shape of the window that has focus (or is under the pointer, if that is chosen).
    private func reshape(_ label: String, _ make: (_ frame: Rect, _ area: Rect, _ config: WindowConfig) -> Rect) {
        guard let (window, current, display) = target() else { return }
        let frame = make(current, usableArea(display), store.currentConfig)
        guard frame != current else { return }
        place(window, to: frame, from: current, label: label, layout: nil)
    }

    /// Puts every ordinary window on the display of the focused one into a new arrangement. The focused window goes
    /// last, so in a cascade it ends up on top.
    private func arrange(_ label: String, _ frames: (_ area: Rect, _ count: Int, _ config: WindowConfig) -> [Rect]) {
        guard let (focused, _, display) = target(checkResizable: false) else { return }
        let config = store.currentConfig
        let onDisplay = WindowController.openWindows(excluding: config).filter {
            displays.display(containing: $0.frame)?.id == display.id && $0.window.canResize && !$0.window.isFullScreen
        }
        let ordered = onDisplay.filter { $0.window.key != focused.key } + onDisplay.filter { $0.window.key == focused.key }
        guard ordered.count > 1 else { return }
        let planned = frames(usableArea(display), ordered.count, config)
        guard planned.count == ordered.count else { return }
        for (item, frame) in zip(ordered, planned) {
            place(item.window, to: frame, from: item.frame, label: label, layout: nil)
        }
        focused.raise()
    }

    /// Moves to the next window of the app in front, including minimized ones.
    private func cycleWindowsOfApp() {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication, let current = AXWindow.focused() else { return }
        let windows = AXWindow.windows(ofApp: app.processIdentifier).filter { $0.isStandard || $0.isMinimized }
        guard windows.count > 1, let index = windows.firstIndex(where: { $0.key == current.key }) else { return }
        windows[(index + 1) % windows.count].raise()
    }
}
