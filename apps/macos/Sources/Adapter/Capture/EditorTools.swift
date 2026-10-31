import CoreGraphics
import Foundation

// MARK: - Edits that can be undone

/// Where a mark is: the two ends, and every point of a freehand stroke. Fractions of the picture from its top left.
struct MarkGeometry: Equatable {
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint]

    init(_ mark: Annotation) { start = mark.start; end = mark.end; points = mark.points }
    init(start: CGPoint, end: CGPoint, points: [CGPoint]) { self.start = start; self.end = end; self.points = points }
}

/// One thing done in the editor, and enough to take it back. Every tool does its work through one of these, so every tool can be undone
/// and done again.
enum EditorEdit: Equatable {
    case added(Annotation)
    case removed(Annotation, at: Int)
    case moved(id: UUID, from: MarkGeometry, to: MarkGeometry)
    /// Many marks changed at once (the same shadow on all of them).
    case replaced(old: [Annotation], new: [Annotation])
    case cropped(old: CGRect?, new: CGRect?)
    /// The finished picture's width in pixels; nil keeps its size.
    case resized(old: Int?, new: Int?)
}

/// What the editor holds: the marks, the part kept, and the size the picture is brought to. The picture itself is not in here, so the
/// source image and its bounds are never touched by editing.
struct EditorDocument: Equatable {
    var marks: [Annotation] = []
    var crop: CGRect?
    var resizeWidth: Int?

    mutating func apply(_ edit: EditorEdit, reversed: Bool = false) {
        switch edit {
        case .added(let mark):
            if reversed { marks.removeAll { $0.id == mark.id } } else { marks.append(mark) }
        case .removed(let mark, let index):
            if reversed { marks.insert(mark, at: min(max(index, 0), marks.count)) } else { marks.removeAll { $0.id == mark.id } }
        case .moved(let id, let from, let to):
            let geometry = reversed ? from : to
            guard let i = marks.firstIndex(where: { $0.id == id }) else { return }
            marks[i].start = geometry.start; marks[i].end = geometry.end; marks[i].points = geometry.points
        case .replaced(let old, let new):
            marks = reversed ? old : new
        case .cropped(let old, let new):
            crop = reversed ? old : new
        case .resized(let old, let new):
            resizeWidth = reversed ? old : new
        }
    }
}

/// The editor's undo and redo.
struct EditorHistory: Equatable {
    private(set) var document: EditorDocument
    private(set) var undoStack: [EditorEdit] = []
    private(set) var redoStack: [EditorEdit] = []

    init(document: EditorDocument = EditorDocument()) { self.document = document }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Does something. A new edit ends whatever could have been done again.
    mutating func perform(_ edit: EditorEdit) {
        document.apply(edit)
        undoStack.append(edit)
        redoStack.removeAll()
    }

    @discardableResult
    mutating func undo() -> Bool {
        guard let edit = undoStack.popLast() else { return false }
        document.apply(edit, reversed: true)
        redoStack.append(edit)
        return true
    }

    @discardableResult
    mutating func redo() -> Bool {
        guard let edit = redoStack.popLast() else { return false }
        document.apply(edit)
        undoStack.append(edit)
        return true
    }
}

// MARK: - Finding and moving marks

extension Annotation {
    /// How close, as a fraction of the picture, a click must be to count as on a mark.
    static let hitTolerance: CGFloat = 0.012

    /// A box that holds the mark, for deciding what a click is on and how far it can move.
    var holdingBox: CGRect {
        switch kind {
        case .text: return CGRect(x: start.x, y: start.y, width: 0.18, height: 0.05)
        case .number: return CGRect(x: start.x - 0.02, y: start.y - 0.02, width: 0.04, height: 0.04)
        case .pen:
            guard let first = points.first else { return rect }
            return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        default: return rect
        }
    }

    /// Whether a point (fractions of the picture) is on the mark.
    func isHit(at point: CGPoint, tolerance: CGFloat = Annotation.hitTolerance) -> Bool {
        switch kind {
        case .arrow, .line:
            return Self.distance(from: point, toSegment: start, end) <= tolerance * 1.5
        case .pen:
            guard points.count > 1 else { return false }
            return zip(points, points.dropFirst()).contains { Self.distance(from: point, toSegment: $0, $1) <= tolerance * 1.5 }
        default:
            return holdingBox.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// This mark's place after moving by `delta`, held so it stays within the picture (or within the room marks may use outside it
    /// when the canvas can grow).
    func geometry(movedBy delta: CGPoint, canGrow: Bool) -> MarkGeometry {
        let box = holdingBox
        let low: CGFloat = canGrow ? -CanvasExpansion.reach : 0, high: CGFloat = canGrow ? 1 + CanvasExpansion.reach : 1
        var d = delta
        d.x = min(max(d.x, low - box.minX), high - box.maxX)
        d.y = min(max(d.y, low - box.minY), high - box.maxY)
        // A mark already outside what is allowed is not pulled in just by being touched.
        if box.minX < low || box.maxX > high { d.x = delta.x }
        if box.minY < low || box.maxY > high { d.y = delta.y }
        func shift(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.x, y: p.y + d.y) }
        return MarkGeometry(start: shift(start), end: shift(end), points: points.map(shift))
    }
}

/// Selecting and moving marks with the Move tool.
struct MoveSession: Equatable {
    let id: UUID
    let original: MarkGeometry
    let origin: CGPoint

    /// Starts on the topmost mark under the point, or nil when the point is on none. Later marks are drawn on top.
    static func begin(at point: CGPoint, in marks: [Annotation]) -> (session: MoveSession, mark: Annotation)? {
        guard let mark = marks.last(where: { $0.isHit(at: point) }) else { return nil }
        return (MoveSession(id: mark.id, original: MarkGeometry(mark), origin: point), mark)
    }

    /// Where the mark is when the pointer is at `point`.
    func geometry(at point: CGPoint, for mark: Annotation, canGrow: Bool) -> MarkGeometry {
        var moving = mark
        moving.start = original.start; moving.end = original.end; moving.points = original.points
        return moving.geometry(movedBy: CGPoint(x: point.x - origin.x, y: point.y - origin.y), canGrow: canGrow)
    }
}

// MARK: - Resizing the picture

enum ResizeRules {
    static let widthRange = 16...16_384

    /// The width after scaling by `factor`, kept to what can be made. `current` is the width now (the picture's, or the one set).
    static func width(from current: Int, factor: CGFloat) -> Int {
        guard factor.isFinite, factor > 0 else { return current }
        return min(max(Int((CGFloat(current) * factor).rounded()), widthRange.lowerBound), widthRange.upperBound)
    }

    /// The factor a horizontal drag asks for: dragging right by a tenth of the picture's width makes it a tenth larger.
    static func factor(forDrag dx: CGFloat) -> CGFloat { max(0.05, 1 + dx) }

    /// The size with the same shape at a new width; both sides at least 1.
    static func size(of source: CGSize, width: Int) -> CGSize {
        guard source.width > 0, source.height > 0 else { return source }
        return CGSize(width: CGFloat(width), height: max((CGFloat(width) * source.height / source.width).rounded(), 1))
    }
}

// MARK: - Keys

/// What a key does for the tool that is selected. Keys the tool does not use give nil, so they fall through as before.
enum EditorToolAction: Equatable {
    case nudge(dx: CGFloat, dy: CGFloat)
    case deleteSelected
    case resizeBy(CGFloat)
    case resetResize
    case clearCrop
    case deselect
}

enum EditorToolKeys {
    /// `key` is the name of the key: "left", "right", "up", "down", "delete", "escape", or the character.
    static func action(for tool: CaptureEditorModel.Tool, key: String, shift: Bool, hasSelection: Bool, hasCrop: Bool) -> EditorToolAction? {
        let step: CGFloat = shift ? 0.02 : 0.002
        switch tool {
        case .move:
            switch key {
            case "left": return hasSelection ? .nudge(dx: -step, dy: 0) : nil
            case "right": return hasSelection ? .nudge(dx: step, dy: 0) : nil
            case "up": return hasSelection ? .nudge(dx: 0, dy: -step) : nil
            case "down": return hasSelection ? .nudge(dx: 0, dy: step) : nil
            case "delete": return hasSelection ? .deleteSelected : nil
            case "escape": return hasSelection ? .deselect : nil
            default: return nil
            }
        case .resize:
            switch key {
            case "+", "=": return .resizeBy(shift ? 1.25 : 1.1)
            case "-", "_": return .resizeBy(shift ? 0.8 : 1 / 1.1)
            case "0": return .resetResize
            default: return nil
            }
        case .crop:
            return (key == "escape" || key == "delete") && hasCrop ? .clearCrop : nil
        default:
            return nil
        }
    }
}
