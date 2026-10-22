import AppKit
import SwiftUI

/// One piece of work shown in the result window: what was asked, and how it stands.
final class IntelligenceJob: ObservableObject {
    enum State: Equatable {
        case working
        case done(String, truncated: Bool)
        case failed(String)
    }

    let title: String
    /// A short look at what it was asked about, shown above the result. Cut to a couple of lines.
    let source: String
    /// Puts the result in place of the selection. Nil when the text cannot be replaced.
    let replace: ((String) -> Bool)?
    let start: () async throws -> AppleIntelligence.Output

    @Published private(set) var state: State = .working
    @Published private(set) var replaced = false
    private var task: Task<Void, Never>?

    init(title: String, source: String, replace: ((String) -> Bool)?, start: @escaping () async throws -> AppleIntelligence.Output) {
        self.title = title
        self.source = String(source.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        self.replace = replace
        self.start = start
    }

    var result: String? {
        if case .done(let text, _) = state { return text }
        return nil
    }

    func run() {
        task?.cancel()
        state = .working
        replaced = false
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await start()
                if Task.isCancelled { return }
                await MainActor.run { self.state = .done(output.text, truncated: output.truncated) }
            } catch {
                if Task.isCancelled { return }
                let reason = IntelligenceError.classify(error)
                await MainActor.run { self.state = .failed(reason.errorDescription ?? "Apple Intelligence could not finish that.") }
            }
        }
    }

    func cancel() { task?.cancel() }

    func copy() {
        guard let result else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
    }

    @discardableResult
    func replaceSelection() -> Bool {
        guard let result, let replace else { return false }
        let ok = replace(result)
        replaced = ok
        return ok
    }
}

/// The small window that shows what Apple Intelligence wrote. Return does the main thing (replace the selection where
/// that is possible, copy otherwise), and Escape closes it.
final class IntelligencePanel: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private var panel: Panel?
    private var job: IntelligenceJob?

    func show(_ job: IntelligenceJob, near pointer: CGPoint?) {
        close()
        self.job = job
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: IntelligenceResultView(job: job, onClose: { [weak self] in self?.close() }))
        self.panel = panel

        let screen = NSScreen.screens.first { screen in pointer.map { screen.frame.contains(NSPoint(x: $0.x, y: screen.frame.height - $0.y)) } ?? false } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = panel.frame.size
            var origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + frame.height * 0.1)
            if let pointer {
                // Next to where the text was selected, kept fully on the screen.
                let fromBottom = (NSScreen.screens.first?.frame.height ?? frame.maxY) - pointer.y
                origin = NSPoint(x: min(max(pointer.x - size.width / 2, frame.minX + 8), frame.maxX - size.width - 8), y: min(max(fromBottom - size.height - 24, frame.minY + 8), frame.maxY - size.height - 8))
            }
            panel.setFrameOrigin(origin)
        }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.14; panel.animator().alphaValue = 1 }
        job.run()
    }

    func close() {
        job?.cancel()
        job = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking away keeps a finished result open, so it can be copied from elsewhere; a request still running is stopped.
        if job?.result == nil { close() }
    }
}

private struct IntelligenceResultView: View {
    @ObservedObject var job: IntelligenceJob
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Text(job.title).font(.headline)
                Spacer()
                Label("On this Mac", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
            }
            if !job.source.isEmpty {
                Text(job.source).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            content
            footer
        }
        .padding(14)
        .frame(width: 440, height: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.22), lineWidth: 1))
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onKeyPress(.return) { primary(); return .handled }
        .animation(.smooth(duration: 0.2), value: job.state)
    }

    @ViewBuilder
    private var content: some View {
        switch job.state {
        case .working:
            VStack(spacing: 8) {
                ProgressView().controlSize(.regular)
                Text("Working on it…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done(let text, let truncated):
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    Text(text).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if truncated {
                    Label("The text was long, so only the first part was used.", systemImage: "scissors").font(.caption).foregroundStyle(Theme.warn)
                }
            }
            .frame(maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(Theme.warn)
                Text(message).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("AI can make mistakes. Check the result.").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            if job.result != nil {
                Button("Copy") { job.copy(); onClose() }.controlSize(.small)
                if job.replace != nil {
                    Button(job.replaced ? "Replaced" : "Replace Selection") { if job.replaceSelection() { onClose() } }
                        .controlSize(.small).buttonStyle(.borderedProminent).disabled(job.replaced)
                }
            }
            if case .failed = job.state { Button("Try Again") { job.run() }.controlSize(.small) }
            if case .done = job.state { Button("Try Again") { job.run() }.controlSize(.small) }
        }
    }

    /// Return: replace the selection if that is possible, otherwise copy.
    private func primary() {
        guard job.result != nil else { return }
        if job.replace != nil, job.replaceSelection() { onClose(); return }
        job.copy()
        onClose()
    }
}

/// What the rest of Kriya calls to put Apple Intelligence to work: the selection bar, the launcher and clipboard items.
final class IntelligenceCoordinator {
    let service: AppleIntelligence
    private let panel = IntelligencePanel()
    private let toast = Toast()

    init(service: AppleIntelligence) { self.service = service }

    /// Works on some text and shows the result. `replace` is given when the text can be replaced in place.
    func perform(_ task: IntelligenceTask, on text: String, near pointer: CGPoint? = nil, replace: ((String) -> Bool)? = nil) {
        guard service.isAvailable else {
            toast.show(service.availability.explanation, isError: true)
            return
        }
        // A task that only produces something to read has nothing to put back.
        let place = intelligenceReplacesSelection(task: task) ? replace : nil
        let job = IntelligenceJob(title: intelligenceTitle(task: task), source: text, replace: place) { [service] in try await service.run(task, on: text) }
        panel.show(job, near: pointer)
    }

    /// Answers a question.
    func ask(_ question: String, near pointer: CGPoint? = nil) {
        guard service.isAvailable else {
            toast.show(service.availability.explanation, isError: true)
            return
        }
        let job = IntelligenceJob(title: "Apple Intelligence", source: question, replace: nil) { [service] in try await service.ask(question) }
        panel.show(job, near: pointer)
    }
}
