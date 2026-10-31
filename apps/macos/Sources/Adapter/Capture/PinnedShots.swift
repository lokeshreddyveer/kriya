import AppKit
import SwiftUI

/// Pictures kept on top of everything, to work from while you do something else. Drag to move, scroll to change the size, ⌥-scroll
/// for see-through, double-click or press Esc to close. Right-click for copy and save.
final class PinnedShots {
    static let shared = PinnedShots()
    private var panels: [NSPanel] = []
    private let maxPinned = 8
    /// Whether the pinned pictures are put away for now (they are still there, and come back together).
    private(set) var isHidden = false

    var count: Int { panels.count }

    /// Puts every pinned picture away, or brings them all back.
    func toggleVisibility() {
        guard !panels.isEmpty else { return }
        setHidden(!isHidden)
    }

    private func setHidden(_ hidden: Bool) {
        isHidden = hidden
        for panel in panels {
            if hidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        }
    }

    /// Asks for pictures and pins each. Returns how many were pinned.
    @discardableResult
    func chooseAndPin() -> Int {
        let open = NSOpenPanel()
        open.title = "Choose pictures to pin"
        open.allowedContentTypes = [.image]
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard open.runModal() == .OK else { return 0 }
        var pinned = 0
        for url in open.urls.prefix(maxPinned) {
            if let image = NSImage(contentsOf: url) { pin(image); pinned += 1 }
        }
        return pinned
    }

    func pin(_ image: NSImage) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        // A new picture brings the others back, so it is not pinned out of sight.
        if isHidden { setHidden(false) }
        let look = lookProvider()
        if panels.count >= maxPinned { panels.first?.close(); panels.removeFirst() }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let fit = min(1, min(screen.width * 0.4 / image.size.width, screen.height * 0.5 / image.size.height))
        let size = NSSize(width: image.size.width * fit, height: image.size.height * fit)
        let origin = NSPoint(x: screen.maxX - size.width - 40 - CGFloat(panels.count) * 26, y: screen.maxY - size.height - 60 - CGFloat(panels.count) * 26)
        let panel = PinPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .floating; panel.hasShadow = look.shadow
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // Left out of screen sharing and other apps' screenshots when the person asked for that.
        panel.sharingType = CaptureOverlay.hideWhenSharing ? .none : .readOnly
        let view = PinView(image: image, look: look)
        view.onClose = { [weak self, weak panel] in
            guard let panel else { return }
            panel.close()
            self?.panels.removeAll { $0 === panel }
            if self?.panels.isEmpty == true { self?.isHidden = false }
        }
        panel.contentView = view
        panel.aspect = image.size
        panel.contentAspectRatio = image.size
        apply(look, to: panel)
        panel.orderFrontRegardless()
        panels.append(panel)
    }

    /// Where the style comes from. The saved one; replaced in tests.
    var lookProvider: () -> PinPolicy = { CaptureExtraSettings.delivery.pin }

    /// The look of one pin: its shadow and opacity, and the picture's corners, border and background colour. Only appearance. A pin's
    /// position and size are the person's own (they drag and resize it), so this never touches its frame.
    private func apply(_ look: PinPolicy, to panel: NSPanel) {
        panel.hasShadow = look.shadow
        panel.alphaValue = look.alpha
        (panel.contentView as? PinView)?.apply(look)
        panel.invalidateShadow()
    }

    /// Puts a changed style on every pin already on the screen, at once. Their positions and sizes are left exactly as they are. An
    /// opacity set on one pin by hand (⌥-scroll) is replaced by the style's.
    func restyle() {
        let look = lookProvider()
        for panel in panels { apply(look, to: panel) }
    }

    /// What each pin looks like now, for checking. Appearance only.
    struct Appearance: Equatable {
        var shadow: Bool
        var alpha: CGFloat
        var cornerRadius: CGFloat
        var borderWidth: CGFloat
        /// The colour behind the picture as red, green, blue and opacity, or nil for none.
        var background: [CGFloat]?
    }

    var appearances: [Appearance] {
        panels.map { panel in
            let layer = panel.contentView?.layer
            return Appearance(shadow: panel.hasShadow, alpha: panel.alphaValue, cornerRadius: layer?.cornerRadius ?? 0, borderWidth: layer?.borderWidth ?? 0,
                              background: layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }.map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent] })
        }
    }

    /// Where each pin is and how big, for checking that a style change leaves them alone.
    var frames: [NSRect] { panels.map(\.frame) }

    /// Pins the picture on the clipboard, or the newest capture in the folder.
    func pinClipboardOrLatest(folder: URL) -> Bool {
        if let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage { pin(image); return true }
        if let latest = CaptureHistory.read(folder: folder, limit: 1).first, !latest.isMovie, let image = NSImage(contentsOfFile: latest.path) { pin(image); return true }
        return false
    }

    func closeAll() { panels.forEach { $0.close() }; panels.removeAll(); isHidden = false }

    private final class PinPanel: NSPanel {
        var aspect = NSSize(width: 1, height: 1)
        override var canBecomeKey: Bool { true }
    }

    private final class PinView: NSView {
        let image: NSImage
        var onClose: () -> Void = {}

        init(image: NSImage, look: PinPolicy = PinPolicy()) {
            self.image = image
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
            apply(look)
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Corners, border and the colour behind the picture. Nothing about where the view is or how big.
        func apply(_ look: PinPolicy) {
            layer?.cornerRadius = look.cornerRadius
            layer?.borderWidth = look.borderWidth
            layer?.backgroundColor = look.background?.cgColor
            needsDisplay = true
        }

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
