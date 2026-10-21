import AppKit
import SwiftUI

// MARK: - Keyboard grid

private struct GridCell: Equatable {
    var column: UInt32
    var row: UInt32
}

private final class GridModel: ObservableObject {
    @Published var anchor = GridCell(column: 0, row: 0)
    @Published var cursor = GridCell(column: 0, row: 0)
    let columns: UInt32
    let rows: UInt32

    init(columns: UInt32, rows: UInt32) {
        self.columns = columns
        self.rows = rows
    }

    var block: GridBlock {
        GridBlock(fromColumn: anchor.column, fromRow: anchor.row, toColumn: cursor.column, toRow: cursor.row)
    }
}

/// The grid and the cells the window will cover, drawn over the usable area of one display.
private struct GridView: View {
    @ObservedObject var model: GridModel
    let area: CGRect       // the usable area, in the overlay's own (top-left) coordinates

    private var covered: (c0: UInt32, c1: UInt32, r0: UInt32, r1: UInt32) {
        (min(model.anchor.column, model.cursor.column), max(model.anchor.column, model.cursor.column),
         min(model.anchor.row, model.cursor.row), max(model.anchor.row, model.cursor.row))
    }

    var body: some View {
        let cw = area.width / CGFloat(model.columns)
        let rh = area.height / CGFloat(model.rows)
        let block = covered
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.18)
            ForEach(0..<Int(model.rows), id: \.self) { row in
                ForEach(0..<Int(model.columns), id: \.self) { column in
                    let inside = UInt32(column) >= block.c0 && UInt32(column) <= block.c1 && UInt32(row) >= block.r0 && UInt32(row) <= block.r1
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(inside ? Theme.accent.opacity(0.45) : Color.white.opacity(0.04))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(inside ? 0.5 : 0.18), lineWidth: 1))
                        .frame(width: cw - 4, height: rh - 4)
                        .offset(x: area.minX + CGFloat(column) * cw + 2, y: area.minY + CGFloat(row) * rh + 2)
                }
            }
            Text("Arrows move  ·  Shift extends  ·  Return places  ·  Esc cancels")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(.black.opacity(0.55), in: Capsule())
                .offset(x: area.midX - 215, y: area.minY + 14)
        }
        .animation(.smooth(duration: 0.12), value: model.cursor)
        .animation(.smooth(duration: 0.12), value: model.anchor)
    }
}

private final class GridPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Takes the keys while the grid is up, so the arrow keys never reach the app behind it.
private final class GridKeyView: NSView {
    var onKey: ((NSEvent) -> Void)?
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
    override func mouseDown(with event: NSEvent) { onCancel?() }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
}

/// Places the front window on a grid using only the keyboard. The arrow keys move a cursor over the cells, Shift
/// stretches the block, Return puts the window there and Escape leaves it where it was.
final class GridMenu {
    private let controller: WindowController
    private let store: WindowStore
    private let preview = SnapOverlay()
    private var panel: GridPanel?
    private var model: GridModel?
    private var target: AXWindow?
    private var area: Rect = Rect(x: 0, y: 0, width: 0, height: 0)

    init(controller: WindowController, store: WindowStore) {
        self.controller = controller
        self.store = store
    }

    var isOpen: Bool { panel != nil }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func close() {
        preview.hide()
        guard let panel else { return }
        self.panel = nil
        model = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    private func open() {
        guard AXIsProcessTrusted(), let window = AXWindow.focused(), let frame = window.frame, !window.isFullScreen,
              let display = controller.displays.display(containing: frame) else { return }
        let config = store.currentConfig
        let columns = config.gridColumns
        let rows = config.gridRows
        target = window
        area = controller.usableArea(display)

        // Start on the cell under the middle of the window.
        let cell = GridCell(
            column: UInt32(max(0, min(Double(columns - 1), floor((frame.x + frame.width / 2 - area.x) / (area.width / Double(columns)))))),
            row: UInt32(max(0, min(Double(rows - 1), floor((frame.y + frame.height / 2 - area.y) / (area.height / Double(rows))))))
        )
        let model = GridModel(columns: columns, rows: rows)
        model.anchor = cell
        model.cursor = cell
        self.model = model

        let screenFrame = DisplayManager.appKitFrame(display.full)
        let local = CGRect(x: area.x - display.full.x, y: area.y - display.full.y, width: area.width, height: area.height)
        let host = NSHostingView(rootView: GridView(model: model, area: local))
        host.frame = CGRect(origin: .zero, size: screenFrame.size)
        let keys = GridKeyView(frame: host.frame)
        keys.addSubview(host)
        keys.onKey = { [weak self] event in self?.key(event) }
        keys.onCancel = { [weak self] in self?.close() }

        let panel = GridPanel(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.contentView = keys
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(keys)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        showPreview()
    }

    private func key(_ event: NSEvent) {
        guard let model else { return }
        let direction: Direction?
        switch event.keyCode {
        case 123: direction = .left
        case 124: direction = .right
        case 125: direction = .down
        case 126: direction = .up
        case 36, 76, 49: commit(); return      // Return, Enter, Space
        case 53: close(); return               // Escape
        default: direction = nil
        }
        guard let direction else { return }
        let next = windowGridStep(column: model.cursor.column, row: model.cursor.row, direction: direction, columns: model.columns, rows: model.rows)
        guard next.count == 2 else { return }
        model.cursor = GridCell(column: next[0], row: next[1])
        if !event.modifierFlags.contains(.shift) { model.anchor = model.cursor }
        showPreview()
    }

    private func frameForSelection() -> Rect? {
        guard let model else { return nil }
        return windowGridFrame(area: area, columns: model.columns, rows: model.rows, block: model.block, gap: store.currentConfig.gap)
    }

    private func showPreview() {
        guard store.currentConfig.showPreview, let frame = frameForSelection() else { return }
        preview.show(frame)
    }

    private func commit() {
        let frame = frameForSelection()
        let window = target
        close()
        guard let frame, let window, let current = window.frame else { return }
        controller.place(window, to: frame, from: current, label: "Grid", layout: nil)
        window.raise()
    }
}

// MARK: - Drop zones

private struct ZonesView: View {
    let zones: [CGRect]     // in the overlay's own (top-left) coordinates
    let highlighted: Int?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(zones.enumerated()), id: \.offset) { index, rect in
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(index == highlighted ? Theme.accent.opacity(0.30) : Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(index == highlighted ? Theme.accent : Color.white.opacity(0.35), style: StrokeStyle(lineWidth: index == highlighted ? 2 : 1, dash: index == highlighted ? [] : [6, 5])))
                    .frame(width: max(rect.width - 8, 8), height: max(rect.height - 8, 8))
                    .offset(x: rect.minX + 4, y: rect.minY + 4)
            }
        }
        .animation(.smooth(duration: 0.12), value: highlighted)
    }
}

/// Shows the places of a saved layout while a window is dragged with the drop-zone keys held. It never takes clicks.
final class ZonesOverlay {
    private var panel: NSPanel?
    private var shownOn: String?

    func show(frames: [Rect], highlighted: Int?, on display: DisplayInfo) {
        let screenFrame = DisplayManager.appKitFrame(display.full)
        let local = frames.map { CGRect(x: $0.x - display.full.x, y: $0.y - display.full.y, width: $0.width, height: $0.height) }
        let view = NSHostingView(rootView: ZonesView(zones: local, highlighted: highlighted))
        view.frame = CGRect(origin: .zero, size: screenFrame.size)
        let panel = self.panel ?? makePanel(screenFrame)
        self.panel = panel
        if shownOn != display.id { panel.setFrame(screenFrame, display: false) }
        shownOn = display.id
        panel.contentView = view
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        shownOn = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            if let panel, panel.alphaValue == 0 { panel.orderOut(nil) }
        })
    }

    private func makePanel(_ frame: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        return panel
    }
}
