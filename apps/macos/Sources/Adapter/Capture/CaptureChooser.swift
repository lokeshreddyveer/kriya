import AppKit
import SwiftUI

/// One shortcut, one small panel: every way of capturing in one place. A key from 1 to 9 picks one, ⏎ repeats the one used last, the
/// timer row adds a countdown to this capture, Escape closes it. It remembers the last mode and opens with that one marked.
@MainActor
final class CaptureChooser {
    private var panel: ChooserPanel?

    private final class ChooserPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    nonisolated init() {}

    var isShowing: Bool { panel != nil }

    func show(last: CaptureChoice, timerSeconds: Int, previousAvailable: Bool, choose: @escaping (CaptureChoice, Int) -> Void) {
        guard panel == nil else { return }
        let model = ChooserModel(last: last, timer: timerSeconds, previousAvailable: previousAvailable)
        model.choose = { [weak self] choice, timer in
            self?.close()
            // The panel leaves the screen before anything is captured.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { choose(choice, timer) }
        }
        model.dismiss = { [weak self] in self?.close() }
        let size = NSSize(width: 372, height: 292)
        let host = NSHostingView(rootView: ChooserView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        let panel = ChooserPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + 60))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.14; panel.animator().alphaValue = 1 }
        self.panel = panel
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 }, completionHandler: { panel.orderOut(nil) })
    }
}

@MainActor
final class ChooserModel: ObservableObject {
    @Published var selected: CaptureChoice
    @Published var timer: Int
    let previousAvailable: Bool
    var choose: (CaptureChoice, Int) -> Void = { _, _ in }
    var dismiss: () -> Void = {}

    init(last: CaptureChoice, timer: Int, previousAvailable: Bool) {
        selected = last
        self.timer = timer
        self.previousAvailable = previousAvailable
    }

    func pick(_ choice: CaptureChoice) {
        // "Previous area" is greyed out until there is one; the keys must not reach it either.
        guard choice != .previousArea || previousAvailable else { return }
        choose(choice, timer)
    }
}

private struct ChooserView: View {
    @ObservedObject var model: ChooserModel
    @FocusState private var focused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Capture").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("1–9 choose   ⏎ \(model.selected.title.lowercased())   ⎋ close").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(CaptureChoice.allCases) { choice in
                    let disabled = choice == .previousArea && !model.previousAvailable
                    Button { model.pick(choice) } label: {
                        VStack(spacing: 5) {
                            Image(systemName: choice.symbol).font(.system(size: 20, weight: .regular))
                            Text(choice.title).font(.system(size: 12, weight: .medium))
                            Text(String(choice.key)).font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 66)
                        .background(choice == model.selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(choice == model.selected ? Color.accentColor : .clear, lineWidth: 1.5))
                        .opacity(disabled ? 0.4 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                    .accessibilityLabel(choice.title)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "timer").foregroundStyle(.secondary)
                Picker("Timer", selection: $model.timer) {
                    Text("No timer").tag(0)
                    ForEach(SelfTimer.presets, id: \.self) { Text("\($0) s").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        }
        .padding(16)
        .frame(width: 372, height: 292)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.escape) { model.dismiss(); return .handled }
        .onKeyPress(.return) { model.pick(model.selected); return .handled }
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-3); return .handled }
        .onKeyPress(.downArrow) { move(3); return .handled }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let digit = press.characters.first.flatMap({ Int(String($0)) }), digit >= 1, digit <= CaptureChoice.allCases.count else { return .ignored }
            model.pick(CaptureChoice.allCases[digit - 1])
            return .handled
        }
    }

    private func move(_ by: Int) {
        let all = CaptureChoice.allCases
        guard let index = all.firstIndex(of: model.selected) else { return }
        let next = index + by
        if all.indices.contains(next) { withAnimation(.smooth(duration: 0.12)) { model.selected = all[next] } }
    }
}
