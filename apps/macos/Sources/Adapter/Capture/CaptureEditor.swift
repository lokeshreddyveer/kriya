import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What is being drawn in the editor.
final class CaptureEditorModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case box = "Box", ellipse = "Oval", arrow = "Arrow", line = "Line", pen = "Pen", highlight = "Highlight", number = "Step", text = "Text", hide = "Hide", blur = "Blur", crop = "Crop"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .box: return "rectangle"
            case .ellipse: return "circle"
            case .arrow: return "arrow.up.right"
            case .line: return "line.diagonal"
            case .pen: return "pencil.tip"
            case .highlight: return "highlighter"
            case .number: return "1.circle.fill"
            case .text: return "textformat"
            case .hide: return "rectangle.fill"
            case .blur: return "square.grid.3x3.fill"
            case .crop: return "crop"
            }
        }

        var help: String {
            switch self {
            case .box: return "Draw a box around something"
            case .ellipse: return "Draw an oval around something"
            case .arrow: return "Point at something"
            case .line: return "Draw a straight line"
            case .pen: return "Draw freehand"
            case .highlight: return "Highlight with a see-through colour"
            case .number: return "Click to place the next numbered step"
            case .text: return "Click to add a note"
            case .hide: return "Cover something with a solid block"
            case .blur: return "Turn something into a coarse mosaic"
            case .crop: return "Drag the part to keep"
            }
        }
    }

    @Published private(set) var image: CGImage
    @Published var annotations: [Annotation] = []
    @Published var undone: [Annotation] = []
    @Published var tool: Tool = .box
    @Published var color: Annotation.Color = .red
    @Published var working = false
    @Published var message: String?
    /// The part to keep (fractions from the top left), set with the crop tool.
    @Published var crop: CGRect?
    /// Backdrop, space, corners and shadow around the finished picture.
    @Published var style = CaptureBeautify()
    /// Shows the finished picture instead of the drawing surface, to see the style.
    @Published var previewStyled = false

    init(image: CGImage) { self.image = image }

    var nextStep: Int { annotations.reduce(0) { if case .number = $1.kind { return $0 + 1 } else { return $0 } } + 1 }

    /// Everything needed to open this editing session again later.
    var project: CaptureProject? {
        guard let data = image.pngData else { return nil }
        return CaptureProject(image: data, marks: annotations.map(\.mark), beautify: style, crop: crop.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] })
    }

    func load(_ project: CaptureProject) {
        guard let source = CGImageSourceCreateWithData(project.image as CFData, nil), let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else { message = "That picture could not be read."; return }
        image = picture
        annotations = project.marks.compactMap(Annotation.init(mark:))
        undone = []
        style = project.beautify
        crop = project.crop.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
    }

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
        var result = annotations.isEmpty ? image : (CaptureRenderer.render(image, annotations: annotations) ?? image)
        if let crop { result = CaptureRenderer.crop(result, to: crop) }
        return style.isOn ? (CaptureRenderer.beautified(result, style) ?? result) : result
    }
}

struct CaptureEditorView: View {
    @ObservedObject var model: CaptureEditorModel
    let findPrivateText: (CGImage) -> [CGRect]
    let copyText: (CGImage) -> Void
    let onDone: (CGImage?) -> Void

    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var penPoints: [CGPoint] = []

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
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(model.annotations.isEmpty).keyboardShortcut("z", modifiers: .command).help("Undo").accessibilityLabel("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(model.undone.isEmpty).keyboardShortcut("z", modifiers: [.command, .shift]).help("Redo").accessibilityLabel("Redo")
            Spacer()
            styleMenu
            projectMenu
            Button { hidePrivateText() } label: { Label("Hide Private Text", systemImage: "eye.slash") }
                .disabled(model.working).help("Finds emails, phone numbers, card numbers, addresses and keys in the picture and covers them")
            Button { copyText(model.image) } label: { Label("Copy Text", systemImage: "text.viewfinder") }
                .disabled(model.working).help("Reads the text in the picture and copies it")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    /// A backdrop, space, round corners and a shadow around the finished picture, at a chosen shape.
    private var styleMenu: some View {
        Menu {
            Picker("Backdrop", selection: $model.style.background) { ForEach(CaptureBeautify.Background.allCases) { Text($0.id == "none" ? "None" : $0.title).tag($0) } }
            Picker("Space around", selection: $model.style.padding) { Text("Small").tag(0.04); Text("Medium").tag(0.08); Text("Large").tag(0.14) }
            Picker("Corners", selection: $model.style.corners) { Text("Square").tag(0.0); Text("Round").tag(0.02); Text("Rounder").tag(0.05) }
            Picker("Shape", selection: $model.style.aspect) { ForEach(CaptureBeautify.Aspect.allCases) { Text($0.title).tag($0) } }
            Toggle("Shadow", isOn: $model.style.shadow)
            Divider()
            Toggle("Preview the Result", isOn: $model.previewStyled.animation(.smooth(duration: 0.2)))
        } label: { Label(model.style.isOn ? "Style: On" : "Style", systemImage: "sparkles.rectangle.stack") }
            .menuStyle(.borderlessButton).fixedSize().help("Make the screenshot presentable: backdrop, space, corners, shadow")
    }

    /// Keeps the picture and every mark together in a file that can be opened and changed later.
    private var projectMenu: some View {
        Menu {
            Button("Save Project…") { saveProject() }
            Button("Open Project…") { openProject() }
        } label: { Image(systemName: "doc.badge.gearshape") }
            .menuStyle(.borderlessButton).fixedSize().help("Save the marks to change later, or open a saved project")
    }

    private func saveProject() {
        guard let data = model.project?.encoded() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Capture.\(CaptureProject.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic); model.message = "Saved \(url.lastPathComponent)" } catch { model.message = "The project could not be saved." }
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .data]
        panel.message = "Choose a Kriya capture project (.\(CaptureProject.fileExtension))"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        if let project = CaptureProject.decode(data) { model.load(project); model.message = "Opened \(url.lastPathComponent)" } else { model.message = "That is not a capture project this version can open." }
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

    @ViewBuilder
    private var canvas: some View {
        if model.previewStyled, let result = model.finished() {
            Image(decorative: result, scale: 1).resizable().interpolation(.high).aspectRatio(CGFloat(result.width) / CGFloat(max(result.height, 1)), contentMode: .fit)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2).transition(.opacity)
        } else {
            drawingSurface
        }
    }

    private var drawingSurface: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Image(decorative: model.image, scale: 1).resizable().interpolation(.high)
                ForEach(model.annotations) { mark in preview(mark, size: size) }
                if model.tool == .pen, penPoints.count > 1 {
                    preview(Annotation(kind: .pen, start: penPoints[0], end: penPoints[penPoints.count - 1], color: model.color, points: penPoints), size: size).opacity(0.85)
                } else if let start = dragStart, let end = dragEnd, model.tool != .text, model.tool != .number, model.tool != .crop {
                    preview(Annotation(kind: kind(for: model.tool), start: start, end: end, color: model.color), size: size).opacity(0.85)
                }
                cropOverlay(size: size)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard size.width > 0, size.height > 0 else { return }
                        if dragStart == nil { dragStart = unit(value.startLocation, size); penPoints = [] }
                        dragEnd = unit(value.location, size)
                        if model.tool == .pen { penPoints.append(unit(value.location, size)) }
                    }
                    .onEnded { value in
                        let start = unit(value.startLocation, size), end = unit(value.location, size)
                        let stroke = penPoints
                        dragStart = nil; dragEnd = nil; penPoints = []
                        finishDrag(from: start, to: end, stroke: stroke)
                    }
            )
        }
        .aspectRatio(model.aspect, contentMode: .fit)
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

    /// The part being kept, with the rest dimmed, while the crop tool is in use or a crop is set.
    @ViewBuilder
    private func cropOverlay(size: CGSize) -> some View {
        let live: CGRect? = (model.tool == .crop && dragStart != nil && dragEnd != nil) ? Annotation(kind: .box, start: dragStart!, end: dragEnd!).rect : model.crop
        if let keep = live {
            let box = CGRect(x: keep.minX * size.width, y: keep.minY * size.height, width: keep.width * size.width, height: keep.height * size.height)
            Path { p in p.addRect(CGRect(origin: .zero, size: size)); p.addRect(box) }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true)).allowsHitTesting(false)
            Rectangle().strokeBorder(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])).frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY).allowsHitTesting(false)
        }
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
        case .ellipse: return .ellipse
        case .line: return .line
        case .pen: return .pen
        case .number: return .number(model.nextStep)
        case .crop: return .box
        }
    }

    private func finishDrag(from start: CGPoint, to end: CGPoint, stroke: [CGPoint] = []) {
        let moved = hypot(end.x - start.x, end.y - start.y)
        switch model.tool {
        case .text:
            if let note = askForText() { model.add(Annotation(kind: .text(note), start: start, end: start, color: model.color)) }
            return
        case .number:
            model.add(Annotation(kind: .number(model.nextStep), start: start, end: start, color: model.color))
            return
        case .pen:
            if stroke.count > 2 { model.add(Annotation(kind: .pen, start: stroke[0], end: stroke[stroke.count - 1], color: model.color, points: stroke)) }
            return
        case .crop:
            // A drag sets the part to keep; a click without a drag brings the whole picture back.
            model.crop = moved > 0.03 ? Annotation(kind: .box, start: start, end: end).rect : nil
            return
        default: break
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
        case .line:
            Path { path in
                path.move(to: CGPoint(x: mark.start.x * size.width, y: mark.start.y * size.height))
                path.addLine(to: CGPoint(x: mark.end.x * size.width, y: mark.end.y * size.height))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        case .ellipse:
            Ellipse().stroke(color, lineWidth: 3).frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
        case .number(let n):
            Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white).frame(width: 24, height: 24).background(Circle().fill(color))
                .position(x: mark.start.x * size.width, y: mark.start.y * size.height)
        case .pen:
            Path { path in
                guard let first = mark.points.first else { return }
                path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
                for p in mark.points.dropFirst() { path.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height)) }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
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
        window.sharingType = CaptureOverlay.hideWhenSharing ? .none : .readOnly
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
