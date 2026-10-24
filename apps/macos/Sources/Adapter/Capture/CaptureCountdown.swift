import AppKit
import SwiftUI

/// A visible countdown before a capture: a big number in the middle of the display, a Cancel button, Escape to cancel. It never takes
/// the keyboard focus from the app in front (so a menu that was opened for a menu capture stays open), and it is hidden from the
/// picture it counts down to.
@MainActor
final class CaptureCountdown {
    private final class Model: ObservableObject {
        @Published var remaining: Int
        let total: Int
        let title: String
        var cancel: () -> Void = {}
        init(seconds: Int, title: String) { remaining = seconds; total = seconds; self.title = title }
    }

    private var panel: NSPanel?
    private var timer: Timer?
    private var monitors: [Any] = []

    /// Counts down `seconds` on the display `screen`. True when it reached zero, false if the person cancelled.
    func run(seconds: Int, title: String = "Capturing in", on screen: NSScreen? = NSScreen.main) async -> Bool {
        guard seconds > 0 else { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var finished = false
            let model = Model(seconds: seconds, title: title)
            @MainActor func end(_ completed: Bool) {
                guard !finished else { return }
                finished = true
                self.close()
                // The panel leaves the screen before the picture is taken.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { continuation.resume(returning: completed) }
            }
            model.cancel = { MainActor.assumeIsolated { end(false) } }
            show(model, on: screen)
            // Escape cancels even though the panel does not take focus: it is watched for system-wide where macOS allows that, and
            // while Kriya is the active app. The Cancel button always works.
            let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { MainActor.assumeIsolated { end(false) }; return nil }
                return event
            }
            let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in if event.keyCode == 53 { MainActor.assumeIsolated { end(false) } } }
            monitors = [local, global].compactMap { $0 }
            let timer = Timer(timeInterval: 1, repeats: true) { t in
                MainActor.assumeIsolated {
                    model.remaining -= 1
                    if model.remaining <= 0 { t.invalidate(); end(true) }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private func show(_ model: Model, on screen: NSScreen?) {
        let size = NSSize(width: 230, height: 250)
        let host = NSHostingView(rootView: CountdownView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let frame = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func close() {
        timer?.invalidate(); timer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        panel?.orderOut(nil)
        panel = nil
    }

    private struct CountdownView: View {
        @ObservedObject var model: Model

        var body: some View {
            VStack(spacing: 10) {
                Text(model.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                Text("\(max(model.remaining, 0))")
                    .font(.system(size: 92, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.smooth(duration: 0.25), value: model.remaining)
                ProgressView(value: Double(model.total - max(model.remaining, 0)), total: Double(max(model.total, 1)))
                    .tint(.white).frame(width: 140)
                Button("Cancel  ⎋") { model.cancel() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6).background(Color.white.opacity(0.16), in: Capsule())
            }
            .padding(24).frame(width: 230, height: 250)
            .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}
