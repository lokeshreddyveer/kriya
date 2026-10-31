import AppKit
import SwiftUI

/// A small window shown while a GIF is made: how far along it is, and a Cancel. Cancelling is noticed between pictures, and nothing is
/// left behind.
@MainActor
final class GIFProgressPanel: ObservableObject {
    @Published private(set) var fraction = 0.0
    @Published private(set) var cancelled = false
    private var panel: NSPanel?

    func show(title: String) {
        let host = NSHostingView(rootView: ProgressView(model: self, title: title))
        let size = host.fittingSize
        host.frame.size = size
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "GIF"
        panel.contentView = host
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.sharingType = CaptureOverlay.hideWhenSharing ? .none : .readOnly
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(_ value: Double) { fraction = min(max(value, 0), 1) }
    func cancel() { cancelled = true }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    private struct ProgressView: View {
        @ObservedObject var model: GIFProgressPanel
        let title: String

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 13, weight: .semibold))
                SwiftUI.ProgressView(value: model.fraction)
                HStack {
                    Text("\(Int((model.fraction * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button(model.cancelled ? "Cancelling…" : "Cancel") { model.cancel() }.disabled(model.cancelled).keyboardShortcut(.cancelAction)
                }
            }
            .padding(16).frame(width: 320)
        }
    }
}
