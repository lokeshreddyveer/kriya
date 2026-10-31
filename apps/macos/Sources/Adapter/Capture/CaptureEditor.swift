import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What is being drawn in the editor.
final class CaptureEditorModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case box = "Box", ellipse = "Oval", arrow = "Arrow", line = "Line", pen = "Pen", highlight = "Highlight", number = "Step", text = "Text", hide = "Hide", blur = "Blur", crop = "Crop"
        case spotlight = "Spotlight", filledBox = "Filled Box", resize = "Resize", move = "Move"
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
            case .spotlight: return "circle.lefthalf.filled.inverse"
            case .filledBox: return "rectangle.fill"
            case .resize: return "arrow.up.left.and.arrow.down.right"
            case .move: return "arrow.up.and.down.and.arrow.left.and.right"
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
            case .spotlight: return "Darken everything except a place"
            case .filledBox: return "Draw a solid rectangle"
            case .resize: return "Drag sideways to resize the picture, or press + and −"
            case .move: return "Click a mark to select it, drag to move it, arrow keys to nudge, Delete to remove it"
            }
        }

        /// What a screen reader says: the tool, then what it does.
        var accessibilityName: String { "\(rawValue) tool. \(help)" }

        /// Tools that draw a mark by dragging out a box or line.
        var drawsMark: Bool {
            switch self {
            case .crop, .resize, .move, .text, .number, .pen: return false
            default: return true
            }
        }
    }

    @Published private(set) var image: CGImage
    /// Everything done in the editor, with undo and redo. The marks, the part kept and the size to bring the picture to live here; the
    /// picture itself is never changed by editing.
    @Published private(set) var history = EditorHistory()
    @Published var tool: Tool = .box
    @Published var color: Annotation.Color = .red
    @Published var working = false
    @Published var message: String?
    /// The mark the Move tool has selected.
    @Published private(set) var selectedID: UUID?
    /// Backdrop, space, corners and shadow around the finished picture.
    @Published var style = CaptureBeautify()
    /// Shows the finished picture instead of the drawing surface, to see the style.
    @Published var previewStyled = false
    /// How the editor behaves: smooth pen, the arrow's direction, colour names, the shadow new marks start with. Preferences of the
    /// person, not part of any project.
    @Published var preferences: EditorPreferences

    init(image: CGImage, preferences: EditorPreferences = EditorPreferencesStore().preferences) {
        self.image = image
        self.preferences = preferences
    }

    var annotations: [Annotation] { history.document.marks }
    /// The part to keep (fractions from the top left), set with the crop tool.
    var crop: CGRect? { history.document.crop }
    var resizeWidth: Int? { history.document.resizeWidth }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var selected: Annotation? { selectedID.flatMap { id in annotations.first { $0.id == id } } }
    /// Whether marks may be drawn past the edge of the picture (the canvas grows to hold them).
    var canGrow: Bool { preferences.autoExpandCanvas }

    /// The shadow a new mark starts with.
    var shadowForNewMarks: AnnotationShadow { preferences.annotationShadow }

    /// Puts the shadow chosen now on every mark already drawn (the ones that can have one).
    func applyShadowToAllMarks() {
        let old = annotations
        let new = old.map { var mark = $0; if mark.canHaveShadow { mark.shadow = preferences.annotationShadow }; return mark }
        if new != old { perform(.replaced(old: old, new: new)) }
    }

    var nextStep: Int { annotations.reduce(0) { if case .number = $1.kind { return $0 + 1 } else { return $0 } } + 1 }

    /// Everything needed to open this editing session again later.
    var project: CaptureProject? {
        guard let data = image.pngData else { return nil }
        return CaptureProject(image: data, marks: annotations.map(\.mark), beautify: style, crop: crop.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] },
                              canvasExpanded: preferences.autoExpandCanvas ? true : nil, resizeWidth: resizeWidth)
    }

    func load(_ project: CaptureProject) {
        guard let source = CGImageSourceCreateWithData(project.image as CFData, nil), let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else { message = "That picture could not be read."; return }
        image = picture
        history = EditorHistory(document: EditorDocument(marks: project.marks.compactMap(Annotation.init(mark:)),
                                                         crop: project.crop.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) },
                                                         resizeWidth: project.resizeWidth))
        selectedID = nil
        style = project.beautify
    }

    var aspect: CGFloat { CGFloat(image.width) / max(CGFloat(image.height), 1) }

    /// Does an edit, so it can be undone.
    func perform(_ edit: EditorEdit) { history.perform(edit) }

    func add(_ annotation: Annotation) { perform(.added(annotation)) }

    func undo() { if history.undo(), let id = selectedID, !annotations.contains(where: { $0.id == id }) { selectedID = nil } }
    func redo() { history.redo() }

    // MARK: Crop and resize

    func setCrop(_ new: CGRect?) {
        guard new != crop else { return }
        perform(.cropped(old: crop, new: new))
    }

    /// Brings the finished picture to a width (nil keeps its size). The size now is the picture's, or the one already set.
    func setResizeWidth(_ new: Int?) {
        guard new != resizeWidth else { return }
        perform(.resized(old: resizeWidth, new: new))
    }

    func resize(byFactor factor: CGFloat) {
        let current = resizeWidth ?? Int(CGFloat(image.width) * (crop.map { $0.width } ?? 1))
        setResizeWidth(ResizeRules.width(from: current, factor: factor))
    }

    // MARK: Move and select

    private var moving: (session: MoveSession, mark: Annotation, last: MarkGeometry)?

    /// Selects the mark under the point and starts moving it, or selects nothing.
    func beginMove(at point: CGPoint) {
        guard let found = MoveSession.begin(at: point, in: annotations) else { selectedID = nil; moving = nil; return }
        selectedID = found.mark.id
        moving = (found.session, found.mark, found.session.original)
    }

    /// Shows the mark at the pointer without recording an edit yet: one move is one undo step, however far it was dragged.
    func dragMove(to point: CGPoint) {
        guard var current = moving, let index = history.document.marks.firstIndex(where: { $0.id == current.mark.id }) else { return }
        let g = current.session.geometry(at: point, for: current.mark, canGrow: canGrow)
        current.last = g
        moving = current
        // Shown through a copy of the document, so nothing is recorded in the history until the drag ends.
        var preview = history.document
        preview.marks[index].start = g.start; preview.marks[index].end = g.end; preview.marks[index].points = g.points
        livePreview = preview
    }

    /// The marks as they are while a drag is going on, or nil when none is.
    @Published private(set) var livePreview: EditorDocument?

    func endMove() {
        defer { moving = nil; livePreview = nil }
        guard let m = moving, m.last != m.session.original else { return }
        perform(.moved(id: m.mark.id, from: m.session.original, to: m.last))
    }

    func nudgeSelected(dx: CGFloat, dy: CGFloat) {
        guard let mark = selected else { return }
        let to = mark.geometry(movedBy: CGPoint(x: dx, y: dy), canGrow: canGrow)
        guard to != MarkGeometry(mark) else { return }
        perform(.moved(id: mark.id, from: MarkGeometry(mark), to: to))
    }

    func deleteSelected() {
        guard let mark = selected, let index = annotations.firstIndex(where: { $0.id == mark.id }) else { return }
        perform(.removed(mark, at: index))
        selectedID = nil
    }

    func deselect() { selectedID = nil }

    /// What a key does for the tool selected. Returns whether it was used.
    @discardableResult
    func handleKey(_ key: String, shift: Bool) -> Bool {
        guard let action = EditorToolKeys.action(for: tool, key: key, shift: shift, hasSelection: selectedID != nil, hasCrop: crop != nil) else { return false }
        switch action {
        case .nudge(let dx, let dy): nudgeSelected(dx: dx, dy: dy)
        case .deleteSelected: deleteSelected()
        case .resizeBy(let factor): resize(byFactor: factor)
        case .resetResize: setResizeWidth(nil)
        case .clearCrop: setCrop(nil)
        case .deselect: deselect()
        }
        return true
    }

    /// Puts another picture in the editor, with nothing drawn on it yet.
    func replaceImage(_ new: CGImage) {
        image = new
        history = EditorHistory()
        selectedID = nil
        livePreview = nil
    }

    /// Copies the last mark, a little to one side, and selects the copy. Undo takes it back.
    func duplicateLastMark() {
        guard let last = annotations.last else { return }
        var copy = Annotation(kind: last.kind, start: last.start, end: last.end, color: last.color, points: last.points, shadow: last.shadow)
        let g = copy.geometry(movedBy: CGPoint(x: 0.03, y: 0.03), canGrow: canGrow)
        copy.start = g.start; copy.end = g.end; copy.points = g.points
        add(copy)
        selectedID = copy.id
    }

    /// The picture with every mark painted on.
    func finished() -> CGImage? {
        // The canvas grows for marks past the edge when that is on; with a part kept, marks outside it are cut away anyway, so it does not.
        let expand: CGFloat? = preferences.autoExpandCanvas && crop == nil ? CGFloat(preferences.expandPadding) : nil
        var result = annotations.isEmpty ? image : (CaptureRenderer.render(image, annotations: annotations, expandPadding: expand) ?? image)
        if let crop { result = CaptureRenderer.crop(result, to: crop) }
        if let width = resizeWidth { result = CaptureRenderer.resized(result, toWidth: width) }
        return style.needsCanvas ? (CaptureRenderer.beautified(result, style) ?? result) : result
    }
}

/// What the editor's own commands do that only the app can: write a file, upload, print.
struct EditorCommandHandlers {
    var save: (CGImage) -> Void = { _ in }
    var saveAs: (CGImage) -> Void = { _ in }
    var upload: (CGImage) -> Void = { _ in }
    var print: (CGImage) -> Void = { _ in }
}

struct CaptureEditorView: View {
    @ObservedObject var model: CaptureEditorModel
    let findPrivateText: (CGImage) -> [CGRect]
    let copyText: (CGImage) -> Void
    let onDone: (CGImage?) -> Void
    var commands = EditorCommandHandlers()

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
        .background(commandShortcuts)
    }

    // MARK: Editor commands

    private static func modifiers(_ key: EditorKey) -> EventModifiers {
        var m: EventModifiers = []
        if key.modifiers.contains(.command) { m.insert(.command) }
        if key.modifiers.contains(.shift) { m.insert(.shift) }
        if key.modifiers.contains(.option) { m.insert(.option) }
        if key.modifiers.contains(.control) { m.insert(.control) }
        return m
    }

    /// The editor's shortcuts, as buttons that cannot be seen: they work only while this window has the keyboard, so they never take a
    /// key from anywhere else.
    private var commandShortcuts: some View {
        let registry = model.preferences.commandRegistry
        return ZStack {
            ForEach(EditorCommand.allCases.filter { registry.key(for: $0) != nil }) { command in
                if let key = registry.key(for: command), let character = key.key.first {
                    Button(command.title) { run(command) }
                        .keyboardShortcut(KeyEquivalent(character), modifiers: Self.modifiers(key))
                }
            }
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    /// A press of an editor shortcut or a choice in the Commands menu. While a note is being typed, only the commands a text field
    /// understands are left to it, and the rest do nothing.
    private func run(_ command: EditorCommand) {
        let editing = NSApp.keyWindow?.firstResponder is NSText
        switch model.preferences.commandRegistry.outcome(command, editingText: editing, canUndo: model.canUndo, canRedo: model.canRedo, hasMarks: !model.annotations.isEmpty) {
        case .run: perform(command)
        case .unavailable(let reason): model.message = reason
        case .disabled, .leaveToText: break
        }
    }

    private func perform(_ command: EditorCommand) {
        switch command {
        case .save: if let result = model.finished() { commands.save(result) }
        case .saveAs: if let result = model.finished() { commands.saveAs(result) }
        case .upload: if let result = model.finished() { commands.upload(result) }
        case .print: if let result = model.finished() { commands.print(result) }
        case .copy:
            if let data = model.finished()?.pngData {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: .png)
                model.message = "Copied the picture."
            }
        case .duplicate: model.duplicateLastMark()
        case .addFile: addFile()
        case .addClipboardImage: addClipboardImage()
        case .undo: model.undo()
        case .redo: model.redo()
        case .restoreDefaults:
            var registry = model.preferences.commandRegistry
            registry.restoreDefaults()
            model.preferences.commandRegistry = registry
            var saved = EditorPreferencesStore().preferences
            saved.shortcutOverrides = [:]
            EditorPreferencesStore().preferences = saved
            model.message = "Editor shortcuts are back to their defaults."
        }
    }

    /// Puts another picture in the editor. The marks on this one are lost, so that is asked about first.
    private func replaceImage(with image: CGImage) {
        guard CaptureEditorController.confirmDiscard(model.annotations.count) else { return }
        model.replaceImage(image)
    }

    private func addFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            model.message = "That file could not be read as a picture."
            return
        }
        replaceImage(with: image)
    }

    private func addClipboardImage() {
        guard let nsImage = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
              let image = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            model.message = "There is no picture on the clipboard."
            return
        }
        replaceImage(with: image)
    }

    /// The commands and their keys, for finding what is there.
    private var commandsMenu: some View {
        let registry = model.preferences.commandRegistry
        return Menu {
            ForEach(EditorCommand.allCases) { command in
                Button(registry.key(for: command).map { "\(command.title)   \($0.display)" } ?? command.title) { run(command) }
            }
        } label: { Image(systemName: "command") }
            .menuStyle(.borderlessButton).fixedSize().help("The editor's commands and their shortcuts").accessibilityLabel("Editor commands")
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
                    .accessibilityLabel(tool.accessibilityName)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Divider().frame(height: 20)
            HStack(spacing: 5) {
                ForEach(Annotation.Color.allCases) { color in
                    Circle().fill(Color(nsColor: color.nsColor)).frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(model.color == color ? 0.9 : 0.25), lineWidth: model.color == color ? 2 : 1))
                        .onTapGesture { model.color = color }
                        .accessibilityLabel("\(color.rawValue) colour")
                        .accessibilityAddTraits(model.color == color ? [.isButton, .isSelected] : .isButton)
                        .help(color.rawValue.capitalized)
                }
                // The name of the colour, written out, when that is switched on.
                if model.preferences.showColourNames {
                    Text(model.color.rawValue.capitalized).font(.caption).foregroundStyle(.secondary).frame(minWidth: 44, alignment: .leading)
                }
            }
            Divider().frame(height: 20)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo).help("Undo").accessibilityLabel("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.canRedo).help("Redo").accessibilityLabel("Redo")
            Spacer()
            shadowMenu
            styleMenu
            projectMenu
            commandsMenu
            Button { hidePrivateText() } label: { Label("Hide Private Text", systemImage: "eye.slash") }
                .disabled(model.working).help("Finds emails, phone numbers, card numbers, addresses and keys in the picture and covers them")
            Button { copyText(model.image) } label: { Label("Copy Text", systemImage: "text.viewfinder") }
                .disabled(model.working).help("Reads the text in the picture and copies it")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    /// The shadow under marks: whether new marks have one, how soft, and a way to give every mark already drawn the same.
    private var shadowMenu: some View {
        Menu {
            Toggle("Shadow on new marks", isOn: $model.preferences.annotationShadow.enabled)
            Picker("Softness", selection: Binding(get: { model.preferences.annotationShadow.softness }, set: { model.preferences.annotationShadow.blur = $0.blur })) {
                ForEach(AnnotationShadow.Softness.allCases) { Text($0.title).tag($0) }
            }
            Button("Give Every Mark This Shadow") { model.applyShadowToAllMarks() }.disabled(model.annotations.isEmpty)
        } label: { Label(model.preferences.annotationShadow.enabled ? "Shadow: On" : "Shadow", systemImage: "square.stack.3d.down.right") }
            .menuStyle(.borderlessButton).fixedSize().help("A soft shadow under the marks you draw")
            .onChange(of: model.preferences.annotationShadow) { _, value in
                var all = EditorPreferencesStore().preferences
                all.annotationShadow = value
                EditorPreferencesStore().preferences = all
            }
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
            Button("Cancel") { if CaptureEditorController.confirmDiscard(model.annotations.count) { onDone(nil) } }.keyboardShortcut(.cancelAction)
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
                ForEach((model.livePreview ?? model.history.document).marks) { mark in preview(mark, size: size) }
                if let selected = model.selected { selectionOutline(selected, size: size) }
                if model.tool == .pen, penPoints.count > 1 {
                    preview(Annotation(kind: .pen, start: penPoints[0], end: penPoints[penPoints.count - 1], color: model.color, points: penPoints), size: size).opacity(0.85)
                } else if let start = dragStart, let end = dragEnd, model.tool.drawsMark {
                    preview(Annotation(kind: kind(for: model.tool), start: start, end: end, color: model.color), size: size).opacity(0.85)
                }
                cropOverlay(size: size)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                // Keys for the tool selected: arrows and Delete for Move, + and − for Resize, Escape and Delete for Crop.
                let name: String
                switch press.key {
                case .leftArrow: name = "left"
                case .rightArrow: name = "right"
                case .upArrow: name = "up"
                case .downArrow: name = "down"
                case .delete, .deleteForward: name = "delete"
                case .escape: name = "escape"
                default: name = press.characters
                }
                guard !press.modifiers.contains(.command) else { return .ignored }
                return model.handleKey(name, shift: press.modifiers.contains(.shift)) ? .handled : .ignored
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard size.width > 0, size.height > 0 else { return }
                        if dragStart == nil {
                            dragStart = unit(value.startLocation, size); penPoints = []
                            if model.tool == .move { model.beginMove(at: dragStart!) }
                        }
                        dragEnd = unit(value.location, size)
                        if model.tool == .pen { penPoints.append(unit(value.location, size)) }
                        if model.tool == .move { model.dragMove(to: dragEnd!) }
                    }
                    .onEnded { value in
                        let start = unit(value.startLocation, size), end = unit(value.location, size)
                        let stroke = penPoints
                        dragStart = nil; dragEnd = nil; penPoints = []
                        if model.tool == .move { model.endMove(); return }
                        finishDrag(from: start, to: end, stroke: stroke)
                    }
            )
        }
        .aspectRatio(model.aspect, contentMode: .fit)
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

    /// A dashed outline around the mark the Move tool has selected.
    @ViewBuilder
    private func selectionOutline(_ mark: Annotation, size: CGSize) -> some View {
        let b = mark.holdingBox
        Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            .frame(width: max(b.width * size.width, 10), height: max(b.height * size.height, 10))
            .offset(x: b.minX * size.width, y: b.minY * size.height).allowsHitTesting(false)
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
        // Within the picture, or a little way outside it when the canvas can grow to hold what is drawn there.
        CanvasExpansion.clamped(CGPoint(x: point.x / size.width, y: point.y / size.height), canGrow: model.canGrow)
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
        case .crop, .resize, .move: return .box
        case .spotlight: return .spotlight
        case .filledBox: return .filledBox
        }
    }

    private func finishDrag(from start: CGPoint, to end: CGPoint, stroke: [CGPoint] = []) {
        let moved = hypot(end.x - start.x, end.y - start.y)
        switch model.tool {
        case .text:
            if let note = askForText() { model.add(Annotation(kind: .text(note), start: start, end: start, color: model.color, shadow: model.shadowForNewMarks)) }
            return
        case .number:
            model.add(Annotation(kind: .number(model.nextStep), start: start, end: start, color: model.color, shadow: model.shadowForNewMarks))
            return
        case .pen:
            // With "smooth pen", the stroke's jitter is taken out when it ends; it starts and ends where the hand did.
            let line = model.preferences.smoothPen ? PenSmoothing.smooth(stroke) : stroke
            if line.count > 2 { model.add(Annotation(kind: .pen, start: line[0], end: line[line.count - 1], color: model.color, points: line, shadow: model.shadowForNewMarks)) }
            return
        case .crop:
            // A drag sets the part to keep; a click without a drag brings the whole picture back.
            model.setCrop(moved > 0.03 ? Annotation(kind: .box, start: start, end: end).rect : nil)
            return
        case .resize:
            // Dragging sideways sets the size: right makes the picture larger, left smaller.
            if abs(end.x - start.x) > 0.01 { model.resize(byFactor: ResizeRules.factor(forDrag: end.x - start.x)) }
            return
        case .move:
            return
        default: break
        }
        // A click without a drag draws nothing.
        guard moved > 0.01 else { return }
        // ⌥ held when an arrow is finished points it the other way, if that is switched on.
        var (from, to) = (start, end)
        if model.tool == .arrow { (from, to) = ArrowRules.ends(start: start, end: end, optionHeld: NSEvent.modifierFlags.contains(.option), preferences: model.preferences) }
        model.add(Annotation(kind: kind(for: model.tool), start: from, end: to, color: model.tool == .hide ? .black : model.color, shadow: model.tool == .hide || model.tool == .blur ? AnnotationShadow() : model.shadowForNewMarks))
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
        case .spotlight:
            Path { path in path.addRect(CGRect(origin: .zero, size: size)); path.addRect(box) }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true)).allowsHitTesting(false)
        case .filledBox:
            Rectangle().fill(color).frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
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
    private var model: CaptureEditorModel?
    private var finish: ((CGImage?) -> Void)?

    /// Marks that took effort to draw are not thrown away by a stray Escape or the close button.
    static let discardWarning = "capture.editor.discard-marks"

    static func confirmDiscard(_ marks: Int, warnings: WarningStore = WarningStore()) -> Bool {
        guard marks > 0, warnings.shouldShow(discardWarning) else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard your \(marks) mark\(marks == 1 ? "" : "s")?"
        alert.informativeText = "The edits are lost. Use Done to keep the picture with its marks, or Save Project to keep editing later."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again (Settings › Diagnostics brings it back)"
        let discard = alert.runModal() == .alertSecondButtonReturn
        // Only a "yes, discard" with the box ticked switches the question off; ticking it and keeping the marks does not.
        if discard, alert.suppressionButton?.state == .on { warnings.dismiss(discardWarning) }
        return discard
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { Self.confirmDiscard(model?.annotations.count ?? 0) }

    func show(_ image: CGImage, service: ScreenCaptureService, startingStyle: CaptureBeautify? = nil, completion: @escaping (CGImage?) -> Void) {
        close(with: nil)
        finish = completion
        let model = CaptureEditorModel(image: image)
        let prefs = model.preferences
        // A backdrop that goes on before the editor opens is shown and can be changed; the picture itself is not flattened. Otherwise
        // the backdrop panel is as it was left, when that is remembered.
        if let startingStyle, startingStyle.isOn {
            model.style = startingStyle; model.previewStyled = true
        } else if let remembered = prefs.startingBackdrop() {
            model.style = remembered.style; model.previewStyled = remembered.shown
        }
        self.model = model
        let words = service.settings.settings.redactWords
        let view = CaptureEditorView(
            model: model,
            findPrivateText: { service.privateTextBoxes(in: $0, words: words) },
            copyText: { service.copyText(from: $0) },
            onDone: { [weak self] result in self?.close(with: result) },
            commands: Self.handlers(service: service)
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 660), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Edit Capture"
        window.isReleasedWhenClosed = false
        window.sharingType = CaptureOverlay.hideWhenSharing ? .none : .readOnly
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self
        window.center()
        // Above other windows, when asked for.
        window.level = prefs.window.alwaysOnTop ? .floating : .normal
        self.window = window
        // A Dock icon while the editor is open, only when asked for and only if there is not one already; given back when it closes.
        if EditorWindowRules.activationToSet(current: Self.activation(of: NSApp.activationPolicy()), showDockIcon: prefs.window.showDockIcon) != nil {
            previousPolicy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Save, Save As, Upload and Print, done by the app.
    private static func handlers(service: ScreenCaptureService) -> EditorCommandHandlers {
        EditorCommandHandlers(
            save: { image in
                if let name = service.save(image, to: service.settings.settings.folder) { service.toast.show("Saved \(name)") }
                else { service.toast.show("The picture could not be saved.", isError: true) }
            },
            saveAs: { image in
                let panel = NSSavePanel()
                panel.directoryURL = service.settings.settings.folder
                panel.nameFieldStringValue = "Capture.\(CaptureExtraSettings.format.fileExtension)"
                guard panel.runModal() == .OK, let url = panel.url, let data = image.data(as: CaptureExtraSettings.format),
                      (try? data.write(to: url, options: .atomic)) != nil else { return }
                service.toast.show("Saved \(url.lastPathComponent)")
            },
            upload: { image in
                guard CaptureUploadStore.shared.ready else { service.toast.show("Uploading is not set up. Add a bucket in Settings › Screen Capture.", isError: true); return }
                guard let name = service.save(image, to: service.settings.settings.folder) else { service.toast.show("The picture could not be prepared to upload.", isError: true); return }
                let file = service.settings.settings.folder.appendingPathComponent(name)
                Task { @MainActor in
                    switch await CaptureOverlay.shared.uploadReturningLink(file) {
                    case .uploaded(let link):
                        service.pasteboard.clearContents(); service.pasteboard.setString(link, forType: .string)
                        service.toast.show("Uploaded. The link is on the clipboard.")
                    case .failed(let reason): service.toast.show(reason, isError: true)
                    }
                }
            },
            print: { image in
                let view = NSImageView(frame: NSRect(x: 0, y: 0, width: image.width, height: image.height))
                view.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                NSPrintOperation(view: view).run()
            }
        )
    }

    /// The policy the app had before the editor asked for a Dock icon, so exactly that is restored. Nil if it was never changed.
    private var previousPolicy: NSApplication.ActivationPolicy?

    static func activation(of policy: NSApplication.ActivationPolicy) -> AppActivation {
        switch policy {
        case .regular: return .regular
        case .accessory: return .accessory
        default: return .prohibited
        }
    }

    /// What ends an editing session, however it ends: the backdrop panel is remembered (if that is on) and the Dock icon given back.
    private func endSession() {
        if let model {
            let store = EditorPreferencesStore()
            var prefs = store.preferences
            prefs.rememberBackdrop(model.style, shown: model.previewStyled)
            if prefs != store.preferences { store.preferences = prefs }
        }
        if let previous = previousPolicy {
            NSApp.setActivationPolicy(previous)
            previousPolicy = nil
        }
    }

    private func close(with result: CGImage?) {
        let done = finish
        finish = nil
        let closing = window
        window = nil
        closing?.delegate = nil
        closing?.orderOut(nil)
        endSession()
        done?(result)
    }

    func windowWillClose(_ notification: Notification) {
        let done = finish
        finish = nil
        window = nil
        endSession()
        done?(nil)
    }
}
