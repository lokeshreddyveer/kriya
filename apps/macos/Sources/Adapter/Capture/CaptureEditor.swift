import AppKit
import SwiftUI

/// What is being drawn in the editor.
final class CaptureEditorModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case box = "Box", arrow = "Arrow", highlight = "Highlight", hide = "Hide", blur = "Blur", text = "Text"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .box: return "rectangle"
            case .arrow: return "arrow.up.right"
            case .highlight: return "highlighter"
            case .hide: return "rectangle.fill"
            case .blur: return "square.grid.3x3.fill"
            case .text: return "textformat"
            }
        }

        var help: String {
            switch self {
            case .box: return "Draw a box around something"
            case .arrow: return "Point at something"
            case .highlight: return "Highlight with a see-through colour"
            case .hide: return "Cover something with a solid block"
            case .blur: return "Turn something into a coarse mosaic"
            case .text: return "Click to add a note"
            }
        }
    }

    let image: CGImage
    @Published var annotations: [Annotation] = []
    @Published var undone: [Annotation] = []
    @Published var tool: Tool = .box
    @Published var color: Annotation.Color = .red
    @Published var working = false
    @Published var message: String?

    init(image: CGImage) { self.image = image }

    var aspect: CGFloat { CGFloat(image.width) / max(CGFloat(image.height), 1) }

    func add(_ annotation: Annotation) {
        annotations.append(annotation)
        undone.removeAll()
    }

    func undo() {
        guard let last = annotations.popLast() else { return }
        undone.append(last)
    }

    func redo() {
        guard let last = undone.popLast() else { return }
        annotations.append(last)
    }

    /// The picture with every mark painted on.
    func finished() -> CGImage? {
        annotations.isEmpty ? image : CaptureRenderer.render(image, annotations: annotations)
    }
}

struct CaptureEditorView: View {
    @ObservedObject var model: CaptureEditorModel
    let findPrivateText: (CGImage) -> [CGRect]
    let copyText: (CGImage) -> Void
    let onDone: (CGImage?) -> Void

    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { proxy in
                ZStack {
                    Color.primary.opacity(0.05)
                    canvas.padding(16)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 540)
    }

    // MARK: Pieces

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(CaptureEditorModel.Tool.allCases) { tool in
                    let on = model.tool == tool
                    Button { model.tool = tool } label: {
                        Image(systemName: tool.symbol).frame(width: 30, height: 26)
                            .background(on ? Theme.accent.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(tool.help)
                }
            }
            Divider().frame(height: 20)
            HStack(spacing: 5) {
                ForEach(Annotation.Color.allCases) { color in
                    Circle().fill(Color(nsColor: color.nsColor)).frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(model.color == color ? 0.9 : 0.25), lineWidth: model.color == color ? 2 : 1))
                        .onTapGesture { model.color = color }
                }
            }
            Divider().frame(height: 20)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(model.annotations.isEmpty).keyboardShortcut("z", modifiers: .command).help("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(model.undone.isEmpty).keyboardShortcut("z", modifiers: [.command, .shift]).help("Redo")
            Spacer()
            Button { hidePrivateText() } label: { Label("Hide Private Text", systemImage: "eye.slash") }
                .disabled(model.working).help("Finds emails, phone numbers, card numbers, addresses and keys in the picture and covers them")
            Button { copyText(model.image) } label: { Label("Copy Text", systemImage: "text.viewfinder") }
                .disabled(model.working).help("Reads the text in the picture and copies it")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary).transition(.opacity) }
            if model.working { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
            Button("Done") { onDone(model.finished()) }.keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .animation(.smooth(duration: 0.2), value: model.message)
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Image(decorative: model.image, scale: 1).resizable().interpolation(.high)
                ForEach(model.annotations) { mark in preview(mark, size: size) }
                if let start = dragStart, let end = dragEnd, model.tool != .text {
                    preview(Annotation(kind: kind(for: model.tool), start: start, end: end, color: model.color), size: size).opacity(0.85)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard size.width > 0, size.height > 0 else { return }
                        if dragStart == nil { dragStart = unit(value.startLocation, size) }
                        dragEnd = unit(value.location, size)
                    }
                    .onEnded { value in
                        let start = unit(value.startLocation, size), end = unit(value.location, size)
                        dragStart = nil; dragEnd = nil
                        finishDrag(from: start, to: end)
                    }
            )
        }
        .aspectRatio(model.aspect, contentMode: .fit)
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

    private func unit(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
    }

    private func kind(for tool: CaptureEditorModel.Tool) -> Annotation.Kind {
        switch tool {
        case .box: return .box
        case .arrow: return .arrow
        case .highlight: return .highlight
        case .hide: return .hide
        case .blur: return .blur
        case .text: return .text("")
        }
    }

    private func finishDrag(from start: CGPoint, to end: CGPoint) {
        let moved = hypot(end.x - start.x, end.y - start.y)
        if model.tool == .text {
            if let note = askForText() { model.add(Annotation(kind: .text(note), start: start, end: start, color: model.color)) }
            return
        }
        // A click without a drag draws nothing.
        guard moved > 0.01 else { return }
        model.add(Annotation(kind: kind(for: model.tool), start: start, end: end, color: model.tool == .hide ? .black : model.color))
    }

    private func hidePrivateText() {
        model.working = true
        model.message = nil
        let image = model.image
        DispatchQueue.global(qos: .userInitiated).async {
            let boxes = findPrivateText(image)
            DispatchQueue.main.async {
                for box in boxes {
                    model.add(Annotation(kind: .hide, start: box.origin, end: CGPoint(x: box.maxX, y: box.maxY), color: .black))
                }
                model.working = false
                model.message = boxes.isEmpty ? "No private-looking text found." : "Covered \(boxes.count) place\(boxes.count == 1 ? "" : "s"). Undo to bring one back."
            }
        }
    }

    private func askForText() -> String? {
        let alert = NSAlert()
        alert.messageText = "Add a note"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(200))
    }

    // MARK: Drawing a mark on screen

    @ViewBuilder
    private func preview(_ mark: Annotation, size: CGSize) -> some View {
        let box = CGRect(x: mark.rect.minX * size.width, y: mark.rect.minY * size.height, width: mark.rect.width * size.width, height: mark.rect.height * size.height)
        let color = Color(nsColor: mark.color.nsColor)
        switch mark.kind {
        case .box:
            Rectangle().strokeBorder(color, lineWidth: 3).frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
        case .highlight:
            Rectangle().fill(color.opacity(0.35)).frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
        case .hide:
            Rectangle().fill(color).frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
        case .blur:
            Rectangle().fill(.gray.opacity(0.55)).overlay(Image(systemName: "square.grid.3x3.fill").foregroundStyle(.white.opacity(0.6)))
                .frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
        case .arrow:
            Path { path in
                path.move(to: CGPoint(x: mark.start.x * size.width, y: mark.start.y * size.height))
                path.addLine(to: CGPoint(x: mark.end.x * size.width, y: mark.end.y * size.height))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            Circle().fill(color).frame(width: 12, height: 12)
                .position(x: mark.end.x * size.width, y: mark.end.y * size.height)
        case .text(let string):
            Text(string).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
                .padding(5).background(Color.black.opacity(0.55))
                .offset(x: mark.start.x * size.width, y: mark.start.y * size.height)
        }
    }
}

/// The window the editor lives in.
final class CaptureEditorController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var finish: ((CGImage?) -> Void)?

    func show(_ image: CGImage, service: ScreenCaptureService, completion: @escaping (CGImage?) -> Void) {
        close(with: nil)
        finish = completion
        let model = CaptureEditorModel(image: image)
        let words = service.settings.settings.redactWords
        let view = CaptureEditorView(
            model: model,
            findPrivateText: { service.privateTextBoxes(in: $0, words: words) },
            copyText: { service.copyText(from: $0) },
            onDone: { [weak self] result in self?.close(with: result) }
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 660), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Edit Capture"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func close(with result: CGImage?) {
        let done = finish
        finish = nil
        let closing = window
        window = nil
        closing?.delegate = nil
        closing?.orderOut(nil)
        done?(result)
    }

    func windowWillClose(_ notification: Notification) {
        let done = finish
        finish = nil
        window = nil
        done?(nil)
    }
}
