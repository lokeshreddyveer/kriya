import Foundation

/// One change a file action made, written down so it can be taken back.
enum FileStep: Codable, Equatable, Hashable {
    /// An item that was moved or renamed.
    case moved(from: String, to: String)
    /// An item that was made (a new file, a copy, an archive, an alias). Undoing it moves it to the Trash.
    case created(path: String)
}

/// What a person did with a file action, kept for a while so it can be undone and looked at.
struct FileOperation: Codable, Identifiable, Equatable {
    enum UndoState: String, Codable { case available, undone, partly }

    var id = UUID()
    var date: Date
    var title: String
    /// What can still be taken back. After a partial undo this is only what is left.
    var steps: [FileStep]
    /// One line per item that failed, with the reason.
    var failures: [String]
    var undoState: UndoState = .available
    var undoNote: String?

    var canUndo: Bool { undoState != .undone && !steps.isEmpty }

    /// Where the affected items are now, for "Show in Finder": the new places of moved items and the created ones.
    var affectedPaths: [String] {
        steps.map { step in
            switch step {
            case .moved(_, let to): return to
            case .created(let path): return path
            }
        }
    }
}

/// How an undo went. Anything that could not be put back is named, and stays available to try again.
struct FileUndoReport: Equatable {
    var restored = 0
    var trashed = 0
    var alreadyGone = 0
    var problems: [String] = []
    var remaining: [FileStep] = []

    var summary: String {
        var parts: [String] = []
        if restored > 0 { parts.append("Put back \(restored) item\(restored == 1 ? "" : "s")") }
        if trashed > 0 { parts.append("moved \(trashed) item\(trashed == 1 ? "" : "s") to the Trash") }
        if parts.isEmpty { parts.append(alreadyGone > 0 ? "Nothing needed undoing" : "Nothing could be undone") }
        var text = parts.joined(separator: " and ")
        text = text.prefix(1).uppercased() + text.dropFirst()
        if !problems.isEmpty { text += ". \(problems.count) could not be undone" }
        return text
    }
}

/// Takes file changes back. It never overwrites: an item goes back only when its old place is free, and an item that was
/// made is moved to the Trash, not deleted.
enum FileUndo {
    static func perform(
        _ steps: [FileStep],
        fileManager fm: FileManager = .default,
        trash: ((URL) throws -> Void)? = nil,
        isProtected: (String) -> Bool = ProtectedPaths.isProtected
    ) -> FileUndoReport {
        var report = FileUndoReport()
        let moveToTrash = trash ?? { url in try fm.trashItem(at: url, resultingItemURL: nil) }
        // `fileExists` follows links; this does not, so a broken link still counts as being there.
        func exists(_ path: String) -> Bool { (try? fm.attributesOfItem(atPath: path)) != nil }
        func name(_ path: String) -> String { (path as NSString).lastPathComponent }

        // Things that were made go to the Trash, the last one made first.
        for case .created(let path) in steps.reversed() {
            guard exists(path) else { report.alreadyGone += 1; continue }
            if isProtected(path) {
                report.problems.append("“\(name(path))” is in a protected place.")
                report.remaining.append(.created(path: path))
                continue
            }
            do {
                try moveToTrash(URL(fileURLWithPath: path))
                report.trashed += 1
            } catch {
                report.problems.append("“\(name(path))” could not be moved to the Trash.")
                report.remaining.append(.created(path: path))
            }
        }

        var moves: [(from: String, to: String)] = steps.compactMap {
            if case .moved(let from, let to) = $0 { return (from, to) }
            return nil
        }
        // Each is checked against what is on disk now; one whose place is taken, or whose item has gone, is set aside.
        var eligible: [(from: String, to: String)] = []
        var keep: [FileStep] = []
        for move in moves {
            if !exists(move.to) {
                report.alreadyGone += 1
                continue
            }
            if isProtected(move.from) || isProtected(move.to) {
                report.problems.append("“\(name(move.to))” is in a protected place.")
                keep.append(.moved(from: move.from, to: move.to))
                continue
            }
            if !exists((move.from as NSString).deletingLastPathComponent) {
                report.problems.append("The folder “\(name((move.from as NSString).deletingLastPathComponent))” is gone, so “\(name(move.to))” cannot go back.")
                keep.append(.moved(from: move.from, to: move.to))
                continue
            }
            eligible.append(move)
        }
        // An old place that another item in this same undo is about to leave counts as free; settle that until it is stable.
        var changed = true
        while changed {
            changed = false
            let leaving = Set(eligible.map(\.to))
            for (index, move) in eligible.enumerated().reversed() {
                let sameFile = move.from.lowercased() == move.to.lowercased()
                if exists(move.from) && !leaving.contains(move.from) && !sameFile {
                    report.problems.append("“\(name(move.from))” is already taken, so “\(name(move.to))” stays where it is.")
                    keep.append(.moved(from: move.from, to: move.to))
                    eligible.remove(at: index)
                    changed = true
                    break
                }
            }
        }
        moves = eligible

        let froms = Set(moves.map { $0.from.lowercased() })
        let tos = Set(moves.map { $0.to.lowercased() })
        let needsStaging = !froms.isDisjoint(with: tos)
        if !needsStaging {
            for move in moves {
                do {
                    try fm.moveItem(atPath: move.to, toPath: move.from)
                    report.restored += 1
                } catch {
                    report.problems.append("“\(name(move.to))” could not be put back.")
                    keep.append(.moved(from: move.from, to: move.to))
                }
            }
        } else {
            // Names are being swapped (or a letter's case changed): everything steps aside first, then goes home.
            var staged: [(temp: String, from: String, to: String)] = []
            var stagingFailed = false
            for (index, move) in moves.enumerated() {
                let folder = (move.to as NSString).deletingLastPathComponent
                let temp = (folder as NSString).appendingPathComponent(".kriya-undo-\(UUID().uuidString)-\(index)")
                do {
                    try fm.moveItem(atPath: move.to, toPath: temp)
                    staged.append((temp, move.from, move.to))
                } catch {
                    stagingFailed = true
                    break
                }
            }
            if stagingFailed {
                for step in staged.reversed() { try? fm.moveItem(atPath: step.temp, toPath: step.to) }
                report.problems.append("The items could not be moved aside to swap their names back.")
                keep += moves.map { .moved(from: $0.from, to: $0.to) }
            } else {
                for step in staged {
                    do {
                        try fm.moveItem(atPath: step.temp, toPath: step.from)
                        report.restored += 1
                    } catch {
                        try? fm.moveItem(atPath: step.temp, toPath: step.to)
                        report.problems.append("“\(name(step.to))” could not be put back.")
                        keep.append(.moved(from: step.from, to: step.to))
                    }
                }
            }
        }
        report.remaining += keep
        return report
    }
}

/// The recent file operations, newest first. Kept in the app's preferences, so an undo is still possible after Kriya
/// restarts; each entry is dropped after two weeks.
final class FileOperationHistory: ObservableObject {
    /// The one history every part of Kriya writes to, so a change made from anywhere can be undone from the Finder screen.
    static let shared = FileOperationHistory()
    static let limit = 25
    static let maxAge: TimeInterval = 14 * 24 * 3600

    @Published private(set) var operations: [FileOperation] = []

    private let defaults: UserDefaults
    private let key: String
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, key: String = "finder.fileOperations.v1", now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.key = key
        self.now = now
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([FileOperation].self, from: data) {
            operations = saved
        }
        trim()
    }

    /// Adds an operation. One that changed nothing and failed at nothing is not worth a line.
    func record(title: String, steps: [FileStep], failures: [String]) {
        guard !steps.isEmpty || !failures.isEmpty else { return }
        operations.insert(FileOperation(date: now(), title: title, steps: steps, failures: failures), at: 0)
        trim()
        save()
    }

    func operation(_ id: UUID) -> FileOperation? { operations.first { $0.id == id } }

    /// Writes down how an undo went. What could not be undone stays, so it can be tried again.
    func applyUndo(_ report: FileUndoReport, to id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].steps = report.remaining
        operations[index].undoState = report.remaining.isEmpty ? .undone : .partly
        operations[index].undoNote = ([report.summary + "."] + report.problems).joined(separator: "\n")
        save()
    }

    func remove(_ id: UUID) {
        operations.removeAll { $0.id == id }
        save()
    }

    func clear() {
        operations = []
        save()
    }

    private func trim() {
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        operations = Array(operations.filter { $0.date >= cutoff }.prefix(Self.limit))
    }

    private func save() {
        if operations.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(operations) {
            defaults.set(data, forKey: key)
        }
    }
}
