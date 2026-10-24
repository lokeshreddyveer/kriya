import AppKit
import SwiftUI

/// After the bar replaces someone's text, a small card shows what changed: the text before and after, with Undo, and buttons to copy
/// either version. It goes away by itself; hovering keeps it.
final class ReplacementPeek {
    static let shared = ReplacementPeek()
    static let enabledKey = "selection.showReplacement"
    static var enabled: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil && (UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true) }

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(original: String, result: String, title: String, undo: @escaping () -> Void) {
        guard Self.enabled else { return }
        DispatchQueue.main.async { [self] in
            close(animated: false)
            let summary = ReplacementSummary(original: original, result: result)
            let view = ReplacementPeekView(title: title, summary: summary, undo: { [weak self] in self?.close(animated: true); undo() },
                                           copy: { text in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) },
                                           close: { [weak self] in self?.close(animated: true) },
                                           hover: { [weak self] inside in inside ? self?.hideWork?.cancel() : self?.schedule(after: 3) })
            let host = NSHostingView(rootView: view)
            let size = host.fittingSize
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.applyPopupPrivacy()
            panel.contentView = host
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                let x = min(max(mouse.x - size.width / 2, frame.minX + 8), frame.maxX - size.width - 8)
                let y = min(max(mouse.y - size.height - 24, frame.minY + 8), frame.maxY - size.height - 8)
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
            self.panel = panel
            schedule(after: 8)
        }
    }

    private func schedule(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close(animated: true) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func close(animated: Bool) {
        hideWork?.cancel()
        guard let panel else { return }
        self.panel = nil
        if animated { NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 }, completionHandler: { panel.orderOut(nil) }) } else { panel.orderOut(nil) }
    }
}

private struct ReplacementPeekView: View {
    let title: String
    let summary: ReplacementSummary
    let undo: () -> Void
    let copy: (String) -> Void
    let close: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(summary.headline).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).accessibilityLabel("Dismiss")
            }
            line("Before", summary.original, tint: .red)
            line("After", summary.result, tint: .green)
            HStack(spacing: 8) {
                Button("Undo", action: undo).controlSize(.small)
                Button("Copy Original") { copy(summary.original) }.controlSize(.small)
                Button("Copy Result") { copy(summary.result) }.controlSize(.small)
            }
        }
        .padding(10)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.18)))
        .padding(6)
        .onHover(perform: hover)
    }

    private func line(_ label: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint).frame(width: 40, alignment: .leading)
            Text(ReplacementSummary.preview(text)).font(.system(size: 11, design: .monospaced)).lineLimit(2).foregroundStyle(.secondary)
        }
    }
}
