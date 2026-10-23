import AppKit
import SwiftUI

/// Pictures kept on top of everything, to work from while you do something else. Drag to move, scroll to change the size, ⌥-scroll
/// for see-through, double-click or press Esc to close. Right-click for copy and save.
final class PinnedShots {
    static let shared = PinnedShots()
    private var panels: [NSPanel] = []
    private let maxPinned = 8

    func pin(_ image: NSImage) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        if panels.count >= maxPinned { panels.first?.close(); panels.removeFirst() }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let fit = min(1, min(screen.width * 0.4 / image.size.width, screen.height * 0.5 / image.size.height))
        let size = NSSize(width: image.size.width * fit, height: image.size.height * fit)
        let origin = NSPoint(x: screen.maxX - size.width - 40 - CGFloat(panels.count) * 26, y: screen.maxY - size.height - 60 - CGFloat(panels.count) * 26)
        let panel = PinPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .floating; panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let view = PinView(image: image)
        view.onClose = { [weak self, weak panel] in guard let panel else { return }; panel.close(); self?.panels.removeAll { $0 === panel } }
        panel.contentView = view
        panel.aspect = image.size
        panel.contentAspectRatio = image.size
        panel.orderFrontRegardless()
        panels.append(panel)
    }

    /// Pins the picture on the clipboard, or the newest capture in the folder.
    func pinClipboardOrLatest(folder: URL) -> Bool {
        if let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage { pin(image); return true }
        if let latest = CaptureHistory.read(folder: folder, limit: 1).first, !latest.isMovie, let image = NSImage(contentsOfFile: latest.path) { pin(image); return true }
        return false
    }

    func closeAll() { panels.forEach { $0.close() }; panels.removeAll() }

    private final class PinPanel: NSPanel {
        var aspect = NSSize(width: 1, height: 1)
        override var canBecomeKey: Bool { true }
    }

    private final class PinView: NSView {
        let image: NSImage
        var onClose: () -> Void = {}

        init(image: NSImage) {
            self.image = image
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 8
            layer?.masksToBounds = true
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        }

        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) { image.draw(in: bounds) }
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { onClose() } else { super.mouseDown(with: event) } }
        override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onClose() } else { super.keyDown(with: event) } }

        override func scrollWheel(with event: NSEvent) {
            guard let window else { return }
            if event.modifierFlags.contains(.option) {
                window.alphaValue = min(max(window.alphaValue + event.scrollingDeltaY * 0.01, 0.2), 1)
            } else {
                let factor = 1 + event.scrollingDeltaY * 0.01
                var frame = window.frame
                let newW = min(max(frame.width * factor, 80), 2400)
                let newH = newW * image.size.height / image.size.width
                frame.origin.y += frame.height - newH
                frame.size = NSSize(width: newW, height: newH)
                window.setFrame(frame, display: true)
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            menu.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Save…", action: #selector(save), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Close", action: #selector(close), keyEquivalent: "").target = self
            return menu
        }

        @objc private func copyImage() { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) }
        @objc private func close() { onClose() }
        @objc private func save() {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Pinned picture.png"
            guard panel.runModal() == .OK, let url = panel.url, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: url)
        }
    }
}
