import AppKit

/// Carries out an action on the files the person chose. It never overwrites anything (a name that is taken becomes
/// "name 2"), refuses to touch system folders, asks first when the action changes files, and says what happened.
final class FileActionRunner {
    private let store: FinderStore
    /// What recent actions did, so they can be looked at and undone.
    let history: FileOperationHistory
    /// Where items were sent lately, and the starred folders, for the Move to / Copy to chooser.
    let destinations: FolderDestinations
    private lazy var chooser = DestinationChooser(destinations: destinations)
    private let toast = Toast()
    private let fm = FileManager.default
    /// Disk work runs one task at a time, so two quick actions never pick the same new name.
    private let diskQueue = DispatchQueue(label: "app.kriya.fileactions", qos: .userInitiated)

    /// Starts a workflow with the selected files as its input. Set by the app.
    var runWorkflow: (_ id: String, _ input: String) -> Void = { _, _ in }

    /// Shows the batch rename window. Set by the app; tests leave it out.
    var presentBatchRename: ((_ names: [String], _ others: [String], _ rule: BatchRenameRule, _ apply: @escaping (BatchRenameRule) -> Void) -> Void)?

    init(store: FinderStore, history: FileOperationHistory = .shared, destinations: FolderDestinations = .shared) {
        self.store = store
        self.history = history
        self.destinations = destinations
    }

    // MARK: Entry point (main thread)

    /// `paths` are the selected items; with none selected, `target` is the folder to act in.
    func run(_ item: FinderItem, paths: [String], target: String?, child: String?) {
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { fm.fileExists(atPath: $0.path) }
        let folder = target.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard !urls.isEmpty || folder != nil else {
            toast.show("Nothing is selected.", isError: true)
            return
        }
        let count = max(urls.count, 1)
        Log.info("Finder", "Running an action of kind \(String(describing: item.kind).prefix(24)) on \(count) item(s)")

        // Batch rename has its own window with a preview, which is its confirmation.
        // The question carries the real list of what will change (which files lose the warning, which move where), not just a count.
        if case .batchRename = item.kind {} else if let question = finderConfirmationMessage(item: item, count: UInt32(count), config: store.config), !confirm(question, detail: FinderPreview.detail(item, urls: urls, folder: folder)) {
            return
        }
        perform(item, urls: urls, folder: folder, child: child)
    }

    private func perform(_ item: FinderItem, urls: [URL], folder: URL?, child: String?) {
        switch item.kind {
        case .copyPath(let style):
            let paths = urls.isEmpty ? [folder?.path ?? ""] : urls.map(\.path)
            copyToPasteboard(finderPathText(style: style, paths: paths))
            toast.show(paths.count == 1 ? "Copied" : "Copied \(paths.count) paths")

        case .copyPathAs:
            guard let style = child.flatMap(FinderPresets.pathFormat) else { toast.show("Choose a format.", isError: true); return }
            let paths = urls.isEmpty ? [folder?.path ?? ""] : urls.map(\.path)
            copyToPasteboard(FinderPresets.text(style: style, paths: paths))
            toast.show(paths.count == 1 ? "Copied" : "Copied \(paths.count) paths")

        case .openInIde:
            guard let appID = child, FinderPresets.ideCatalog.contains(where: { $0.id == appID }) else { toast.show("Choose an app.", isError: true); return }
            // A terminal opens in the folder; an editor opens the items themselves (or the folder when nothing is selected).
            if FinderPresets.isTerminal(appID) { openInTerminal(urls: urls, folder: folder, appID: appID) }
            else { openWith(urls: urls.isEmpty ? (folder.map { [$0] } ?? []) : urls, appID: appID) }

        case .toFolderSet(let copy):
            // The destination comes in the request, so it is only used when it is one of the person's saved folders.
            guard let path = child, FinderPresets.isSavedDestination(path, in: FolderSetStore.shared.sets), fm.fileExists(atPath: path) else {
                toast.show("That folder is not in a saved set any more.", isError: true)
                return
            }
            transfer(urls, to: path, move: !copy)

        case .quickTag:
            guard !urls.isEmpty else { toast.show("Select the items to tag.", isError: true); return }
            guard let preset = store.tagPresets.first(where: { $0.id == child }) else { toast.show("That preset is gone.", isError: true); return }
            inBackground { try Self.apply(preset, to: urls) }

        case .inspect:
            FinderInspect.run(child ?? "", urls: urls.isEmpty ? (folder.map { [$0] } ?? []) : urls)

        case .runWorkflow(let id):
            runWorkflow(id, (urls.isEmpty ? [folder?.path ?? ""] : urls.map(\.path)).joined(separator: "\n"))

        case .copyMetadata:
            let source = urls.isEmpty ? (folder.map { [$0] } ?? []) : urls
            copyToPasteboard(source.map(FileMetadata.describe).joined(separator: "\n\n"))
            toast.show("Copied file info")

        case .showHiddenFiles:
            toast.show(FinderExtraActions.toggleHiddenFiles())

        case .openParentFolder:
            FinderExtraActions.openParentFolders(urls: urls, folder: folder)

        case .newFolders:
            guard let names = FolderTools.askFolderNames() else { return }
            inBackground { [self] in try FolderTools.createFolders(names, in: try destination(urls, folder)) }

        case .findLargeFiles(let megabytes):
            let root: URL
            do { root = try destination(urls, folder) } catch { fail(error); return }
            toast.show("Looking for large files…")
            DispatchQueue.global(qos: .userInitiated).async {
                let found = FolderTools.largeFiles(in: root, minimumBytes: Int64(megabytes) * 1_048_576, limit: 30)
                DispatchQueue.main.async { FolderTools.present(found, in: root, minimumMB: megabytes) }
            }

        case .cleanupFolder:
            inBackground { [self] in try FolderTools.tidy(try destination(urls, folder)) }

        case .undoLast:
            inBackground { try FolderTools.undoLastTidy() }

        case .copyChecksum:
            inBackground { try FolderTools.copyChecksums(urls) }

        case .removeQuarantine:
            inBackground { try FolderTools.removeQuarantine(urls) }

        case .makeAlias:
            inBackground { try FolderTools.makeAliases(urls) }

        case .editTags:
            guard !urls.isEmpty else { toast.show("Select the items to tag.", isError: true); return }
            guard let names = FinderMetadata.askTags(existing: FinderMetadata.tags(of: urls[0]), count: urls.count) else { return }
            inBackground { try FinderMetadata.addTags(names, to: urls) }

        case .editComment:
            guard !urls.isEmpty else { toast.show("Select the items to comment on.", isError: true); return }
            guard let comment = FinderMetadata.askComment(existing: urls.count == 1 ? FinderMetadata.comment(of: urls[0]) : "", count: urls.count) else { return }
            inBackground { try FinderMetadata.setComment(comment, on: urls) }

        case .share:
            guard !urls.isEmpty else { toast.show("Select the files to share.", isError: true); return }
            FinderMetadata.share(urls)

        case .openInTerminal(let appID):
            openInTerminal(urls: urls, folder: folder, appID: appID ?? child)

        case .openWith(let appID):
            openWith(urls: urls, appID: appID ?? child)

        case .rename:
            rename(urls)

        case .batchRename(let rule):
            batchRename(urls, rule: rule)

        case .moveTo(let destination):
            transfer(urls, to: destination, move: true)

        case .copyTo(let destination):
            transfer(urls, to: destination, move: false)

        default:
            // Everything else changes the disk, so it runs away from the interface.
            background(item, urls: urls, folder: folder, child: child)
        }
    }

    // MARK: Work on a background queue

    private func background(_ item: FinderItem, urls: [URL], folder: URL?, child: String?) {
        let templates = store.fileTemplates
        let folderTemplates = store.folderTemplates
        let jobID = UUID().uuidString
        FinderJobs.shared.add(id: jobID, title: Self.jobTitle(item, count: max(urls.count, 1)))
        diskQueue.async { [self] in
            guard FinderJobs.shared.waitUntilAllowedToStart(jobID) else { return }
            defer { FinderJobs.shared.finish(jobID) }
            do {
                let outcome: Outcome
                switch item.kind {
                case .newFile(let name):
                    outcome = try newFile(named: name, in: try destination(urls, folder))
                case .newFromTemplate(let id):
                    guard let chosen = (id ?? child).flatMap({ id in templates.first { $0.id == id } }) else { throw FileActionError("Choose a template.") }
                    outcome = try newFile(from: chosen, in: try destination(urls, folder))
                case .newFolder(let name):
                    outcome = try newFolder(named: name, in: try destination(urls, folder))
                case .newFolderFromTemplate(let id):
                    guard let chosen = (id ?? child).flatMap({ id in folderTemplates.first { $0.id == id } }) else { throw FileActionError("Choose a template.") }
                    outcome = try newFolder(from: chosen, in: try destination(urls, folder))
                case .duplicate:
                    outcome = try duplicate(urls)
                case .compress:
                    outcome = try compress(urls)
                case .extract:
                    outcome = try extract(urls)
                case .convert(let target):
                    guard let targetID = target ?? child, let conversion = Converter.target(id: targetID) else { throw FileActionError("Choose a format.") }
                    outcome = try convert(urls, to: conversion)
                case .runScript(let language, let source):
                    outcome = try runScript(language, source, urls: urls, folder: folder)
                case .runShortcut(let name):
                    outcome = try runShortcut(name, urls: urls)
                default:
                    outcome = Outcome(message: "Done", reveal: [])
                }
                finish(outcome)
            } catch {
                fail(error)
            }
        }
    }

    /// Runs disk work away from the interface and reports the result.
    private func inBackground(_ work: @escaping () throws -> Outcome) {
        diskQueue.async { [self] in
            do { finish(try work()) } catch { fail(error) }
        }
    }

    struct Outcome {
        var message: String
        var reveal: [URL]
        /// What changed on disk, for the history and for undo. Empty when nothing was changed.
        var steps: [FileStep] = []
        /// Items that failed, each with its reason.
        var failures: [String] = []
        var isError = false

        static func created(_ message: String, _ urls: [URL]) -> Outcome {
            Outcome(message: message, reveal: urls, steps: urls.map { .created(path: $0.path) })
        }
    }

    private func finish(_ outcome: Outcome) {
        DispatchQueue.main.async { [self] in
            history.record(title: outcome.message, steps: outcome.steps, failures: outcome.failures)
            toast.show(outcome.message, isError: outcome.isError)
            if !outcome.reveal.isEmpty && outcome.reveal.count <= 50 { NSWorkspace.shared.activateFileViewerSelecting(outcome.reveal) }
        }
    }

    // MARK: Undo

    /// Takes an earlier operation back. It runs with the other disk work, so it never overlaps an action in progress.
    func undo(_ id: UUID) {
        guard let operation = history.operation(id), operation.canUndo else { return }
        let steps = operation.steps
        diskQueue.async { [self] in
            let report = FileUndo.perform(steps)
            DispatchQueue.main.async { [self] in
                history.applyUndo(report, to: id)
                toast.show(report.summary, isError: report.restored + report.trashed == 0 && !report.problems.isEmpty)
            }
        }
    }

    /// Shows where an operation's items are now.
    func reveal(_ id: UUID) {
        guard let operation = history.operation(id) else { return }
        let urls = operation.affectedPaths.map { URL(fileURLWithPath: $0) }.filter { fm.fileExists(atPath: $0.path) }
        if urls.isEmpty {
            toast.show("Those items are no longer where they were left.", isError: true)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(Array(urls.prefix(50)))
        }
    }

    private func fail(_ error: Error) {
        Log.warning("Finder", "An action failed")
        let reason = error.localizedDescription
        DispatchQueue.main.async { [self] in
            history.record(title: "An action failed", steps: [], failures: [reason])
            toast.show(reason, isError: true)
        }
    }

    // MARK: Creating

    /// The folder to create things in: the folder itself when one is selected, otherwise the item's parent.
    private func destination(_ urls: [URL], _ folder: URL?) throws -> URL {
        if let first = urls.first { return isDirectory(first) ? first : first.deletingLastPathComponent() }
        if let folder { return folder }
        throw FileActionError("There is no folder to work in.")
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private func names(in folder: URL) -> [String] {
        (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    private func newFile(named name: String, in folder: URL) throws -> Outcome {
        let unique = finderUniqueName(candidate: name, existing: names(in: folder))
        let url = folder.appendingPathComponent(unique)
        guard fm.createFile(atPath: url.path, contents: Data()) else { throw FileActionError("Could not create the file here.") }
        return .created("Created \(unique)", [url])
    }

    private func newFile(from template: FileTemplate, in folder: URL) throws -> Outcome {
        let unique = finderUniqueName(candidate: template.fileName, existing: names(in: folder))
        let url = folder.appendingPathComponent(unique)
        if let source = template.sourcePath {
            guard fm.fileExists(atPath: source) else { throw FileActionError("The template's source file is missing.") }
            try fm.copyItem(atPath: source, toPath: url.path)
        } else {
            guard fm.createFile(atPath: url.path, contents: Data((template.content ?? "").utf8)) else { throw FileActionError("Could not create the file here.") }
        }
        return .created("Created \(unique)", [url])
    }

    private func newFolder(named name: String, in folder: URL) throws -> Outcome {
        let unique = finderUniqueName(candidate: name, existing: names(in: folder))
        let url = folder.appendingPathComponent(unique, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return .created("Created \(unique)", [url])
    }

    private func newFolder(from template: FolderTemplate, in folder: URL) throws -> Outcome {
        let unique = finderUniqueName(candidate: template.folderName, existing: names(in: folder))
        let root = folder.appendingPathComponent(unique, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        for entry in template.entries {
            // The core already refused paths that climb out of the folder; check again where it matters.
            let target = root.appendingPathComponent(entry.path)
            guard target.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { continue }
            if entry.path.hasSuffix("/") {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: target.path, contents: Data((entry.content ?? "").utf8))
            }
        }
        return .created("Created \(unique)", [root])
    }

    // MARK: Copying and moving

    private func duplicate(_ urls: [URL]) throws -> Outcome {
        var made: [URL] = []
        for url in urls {
            let parent = url.deletingLastPathComponent()
            let name = finderCopyName(name: url.lastPathComponent, existing: names(in: parent))
            let copy = parent.appendingPathComponent(name)
            try fm.copyItem(at: url, to: copy)
            made.append(copy)
        }
        return .created(made.count == 1 ? "Duplicated" : "Duplicated \(made.count) items", made)
    }

    private func transfer(_ urls: [URL], to fixed: String?, move: Bool) {
        guard !urls.isEmpty else { return }
        if move, let blocked = urls.first(where: { ProtectedPaths.isProtected($0.path) }) {
            toast.show("“\(blocked.lastPathComponent)” is a system folder and cannot be moved.", isError: true)
            return
        }
        let destination: URL
        if let fixed {
            destination = URL(fileURLWithPath: fixed, isDirectory: true)
        } else {
            guard let chosen = chooser.choose(count: urls.count, move: move) else { return }
            destination = chosen
            destinations.used(chosen.path)
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Each item is tried on its own, so one that cannot be placed does not stop the rest, and what happened to
            // every item is written down.
            var placed: [URL] = []
            var steps: [FileStep] = []
            var failures: [String] = []
            let verb = move ? "Moved" : "Copied"
            for url in urls {
                do {
                    let into = destination.standardizedFileURL.path
                    let from = url.standardizedFileURL.path
                    if into == from || into.hasPrefix(from + "/") { throw FileActionError("A folder cannot be moved or copied into itself.") }
                    let name = finderUniqueName(candidate: url.lastPathComponent, existing: names(in: destination))
                    let result = destination.appendingPathComponent(name)
                    if move { try fm.moveItem(at: url, to: result) } else { try fm.copyItem(at: url, to: result) }
                    placed.append(result)
                    steps.append(move ? .moved(from: url.path, to: result.path) : .created(path: result.path))
                } catch {
                    failures.append("“\(url.lastPathComponent)”: \(error.localizedDescription)")
                }
            }
            let message: String
            if failures.isEmpty {
                message = "\(verb) \(placed.count) item\(placed.count == 1 ? "" : "s")"
            } else if placed.isEmpty {
                message = failures.count == 1 ? failures[0] : "Nothing was \(verb.lowercased()). \(failures.count) items failed."
            } else {
                message = "\(verb) \(placed.count) of \(urls.count) items. \(failures.count) failed: see Recent File Operations."
            }
            finish(Outcome(message: message, reveal: placed, steps: steps, failures: failures, isError: placed.isEmpty))
        }
    }

    // MARK: Renaming

    private func rename(_ urls: [URL]) {
        guard let url = urls.first, urls.count == 1 else { return }
        guard !ProtectedPaths.isProtected(url.path) else {
            toast.show("“\(url.lastPathComponent)” is a system folder and cannot be renamed.", isError: true)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = "Enter a new name."
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        guard name != url.lastPathComponent else { return }
        if let problem = finderNameProblem(name: name) {
            toast.show("Cannot rename: \(problem).", isError: true)
            return
        }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        if fm.fileExists(atPath: target.path), target.path.lowercased() != url.path.lowercased() {
            toast.show("A file named “\(name)” already exists.", isError: true)
            return
        }
        do {
            try fm.moveItem(at: url, to: target)
            history.record(title: "Renamed “\(url.lastPathComponent)”", steps: [.moved(from: url.path, to: target.path)], failures: [])
            toast.show("Renamed")
        } catch {
            fail(error)
        }
    }

    private func batchRename(_ urls: [URL], rule: BatchRenameRule) {
        guard urls.count >= 1 else { return }
        let parents = Set(urls.map { $0.deletingLastPathComponent().path })
        guard parents.count == 1, let parent = parents.first else {
            toast.show("Select items in one folder to rename them together.", isError: true)
            return
        }
        if let blocked = urls.first(where: { ProtectedPaths.isProtected($0.path) }) {
            toast.show("“\(blocked.lastPathComponent)” is a system folder and cannot be renamed.", isError: true)
            return
        }
        let ordered = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let others = names(in: URL(fileURLWithPath: parent))
        guard let present = presentBatchRename else { return }
        present(ordered.map(\.lastPathComponent), others, rule) { [self] finalRule in
            let plan = finderPlanBatchRename(names: ordered.map(\.lastPathComponent), rule: finalRule, others: others)
            guard finderRenamePlanReady(plan: plan) else { return }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    let folder = URL(fileURLWithPath: parent, isDirectory: true)
                    try applyRenames(plan, in: folder)
                    let changes = plan.filter { !$0.unchanged }
                    let steps = changes.map { FileStep.moved(from: folder.appendingPathComponent($0.from).path, to: folder.appendingPathComponent($0.to).path) }
                    finish(Outcome(message: "Renamed \(changes.count) items", reveal: [], steps: steps))
                } catch {
                    fail(error)
                }
            }
        }
    }

    /// Renames through temporary names, so files can swap names and a name another file is leaving is free. If a step
    /// fails, what was already renamed is put back.
    private func applyRenames(_ plan: [RenamePlanItem], in folder: URL) throws {
        let changes = plan.filter { !$0.unchanged }
        var staged: [(temp: URL, original: URL, final: URL)] = []
        do {
            for (index, change) in changes.enumerated() {
                let original = folder.appendingPathComponent(change.from)
                let temp = folder.appendingPathComponent(".kriya-rename-\(UUID().uuidString)-\(index)")
                try fm.moveItem(at: original, to: temp)
                staged.append((temp, original, folder.appendingPathComponent(change.to)))
            }
        } catch {
            for step in staged.reversed() { try? fm.moveItem(at: step.temp, to: step.original) }
            throw error
        }
        var placed: [(final: URL, temp: URL, original: URL)] = []
        do {
            for step in staged {
                try fm.moveItem(at: step.temp, to: step.final)
                placed.append((step.final, step.temp, step.original))
            }
        } catch {
            for step in placed.reversed() { try? fm.moveItem(at: step.final, to: step.temp) }
            for step in staged.reversed() { try? fm.moveItem(at: step.temp, to: step.original) }
            throw error
        }
    }

    // MARK: Opening

    private func openInTerminal(urls: [URL], folder: URL?, appID: String?) {
        let target: URL
        if let first = urls.first { target = isDirectory(first) ? first : first.deletingLastPathComponent() } else if let folder { target = folder } else { return }
        let id = appID ?? store.config.defaultTerminal ?? "com.apple.Terminal"
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            toast.show("That terminal app is not installed.", isError: true)
            return
        }
        NSWorkspace.shared.open([target], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [toast] _, error in
            if error != nil { toast.show("The terminal could not open that folder.", isError: true) }
        }
    }

    private func openWith(urls: [URL], appID: String?) {
        guard let appID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) else {
            toast.show("That app is not installed.", isError: true)
            return
        }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [toast] _, error in
            if error != nil { toast.show("That app could not open the items.", isError: true) }
        }
    }

    // MARK: Archives

    private func compress(_ urls: [URL]) throws -> Outcome {
        guard !urls.isEmpty else { throw FileActionError("Nothing to compress.") }
        let parents = Set(urls.map { $0.deletingLastPathComponent().path })
        var made: [URL] = []
        if parents.count == 1, let parent = parents.first {
            let folder = URL(fileURLWithPath: parent, isDirectory: true)
            let base = urls.count == 1 ? urls[0].lastPathComponent : "Archive"
            let name = finderUniqueName(candidate: "\(base).zip", existing: names(in: folder))
            try ToolRunner.run("/usr/bin/zip", ["-r", "-y", "-q", name] + urls.map(\.lastPathComponent), in: folder)
            made.append(folder.appendingPathComponent(name))
        } else {
            for url in urls {
                let folder = url.deletingLastPathComponent()
                let name = finderUniqueName(candidate: "\(url.lastPathComponent).zip", existing: names(in: folder))
                try ToolRunner.run("/usr/bin/zip", ["-r", "-y", "-q", name, url.lastPathComponent], in: folder)
                made.append(folder.appendingPathComponent(name))
            }
        }
        return .created(made.count == 1 ? "Compressed" : "Made \(made.count) archives", made)
    }

    private func extract(_ urls: [URL]) throws -> Outcome {
        var made: [URL] = []
        for url in urls {
            let parent = url.deletingLastPathComponent()
            var stem = finderSplitExtension(name: url.lastPathComponent).stem
            if stem.hasSuffix(".tar") { stem = String(stem.dropLast(4)) }
            let name = finderUniqueName(candidate: stem, existing: names(in: parent))
            let out = parent.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: out, withIntermediateDirectories: false)
            do {
                if url.pathExtension.lowercased() == "zip" {
                    try ToolRunner.run("/usr/bin/ditto", ["-x", "-k", url.path, out.path])
                } else {
                    try ToolRunner.run("/usr/bin/tar", ["-xf", url.path, "-C", out.path])
                }
            } catch {
                // Do not leave an empty folder behind when the archive could not be read.
                if (try? fm.contentsOfDirectory(atPath: out.path).isEmpty) == true { try? fm.removeItem(at: out) }
                throw error
            }
            made.append(out)
        }
        return .created(made.count == 1 ? "Extracted" : "Extracted \(made.count) archives", made)
    }

    private func convert(_ urls: [URL], to target: ConversionTarget) throws -> Outcome {
        var made: [URL] = []
        for url in urls {
            made.append(try Converter.convert(url, to: target, into: url.deletingLastPathComponent()))
        }
        return .created("Converted \(made.count) file\(made.count == 1 ? "" : "s") to \(target.title)", made)
    }

    // MARK: Scripts and Shortcuts

    private func runScript(_ language: FinderScript, _ source: String, urls: [URL], folder: URL?) throws -> Outcome {
        let paths = urls.map(\.path)
        let environment = [
            "KRIYA_COUNT": "\(paths.count)",
            "KRIYA_FOLDER": folder?.path ?? urls.first?.deletingLastPathComponent().path ?? "",
        ]
        let directory = folder ?? urls.first?.deletingLastPathComponent()
        switch language {
        case .shell:
            // The selected paths arrive as "$@", so names with spaces or quotes cannot break the script.
            try ToolRunner.run("/bin/zsh", ["-c", source, "kriya"] + paths, in: directory, environment: environment, timeout: 60)
        case .appleScript:
            let script = source.contains("on run") ? source : "on run argv\n\(source)\nend run"
            try ToolRunner.run("/usr/bin/osascript", ["-e", script] + paths, in: directory, environment: environment, timeout: 60)
        }
        return Outcome(message: "Script finished", reveal: [])
    }

    private func runShortcut(_ name: String, urls: [URL]) throws -> Outcome {
        var arguments = ["run", name]
        for url in urls { arguments += ["--input-path", url.path] }
        try ToolRunner.run("/usr/bin/shortcuts", arguments, timeout: 120)
        return Outcome(message: "Shortcut finished", reveal: [])
    }

    // MARK: Small helpers

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func confirm(_ question: String, detail: String? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = (detail.map { $0 + "\n\n" } ?? "") + "Nothing is overwritten: a name that is taken becomes “name 2”."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}


extension FileActionRunner {
    /// Puts a preset's tags (after clearing, if it says so) and comment on each item.
    static func apply(_ preset: FinderTagPreset, to urls: [URL]) throws -> Outcome {
        var failures: [String] = []
        var changed = 0
        for url in urls {
            let tags = preset.clearsTags ? preset.tags : FinderMetadata.merged(existing: FinderMetadata.tags(of: url), adding: preset.tags)
            do { try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey); changed += 1 } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if let comment = preset.comment { _ = try FinderMetadata.setComment(comment, on: urls) }
        let message = failures.isEmpty ? "“\(preset.title)” applied to \(changed) item\(changed == 1 ? "" : "s")" : "“\(preset.title)” applied to \(changed), \(failures.count) failed"
        return Outcome(message: message, reveal: [], steps: [], failures: failures, isError: changed == 0)
    }

    static func jobTitle(_ item: FinderItem, count: Int) -> String {
        let what: String
        switch item.kind {
        case .compress: what = "Compress"
        case .extract: what = "Extract"
        case .convert: what = "Convert"
        case .duplicate: what = "Duplicate"
        case .newFile, .newFromTemplate: what = "New file"
        case .newFolder, .newFolderFromTemplate: what = "New folder"
        case .runScript, .runShortcut: what = "Run"
        default: what = "Do"
        }
        return count > 1 ? "\(what) \(count) items" : "\(what) 1 item"
    }
}

/// The file jobs, shared so the Finder pane can show them and hold back the ones that have not started.
final class FinderJobs: ObservableObject {
    static let shared = FinderJobs()
    @Published private(set) var state = JobQueueState()
    private let condition = NSCondition()
    private var failedIDs = Set<String>()

    func add(id: String, title: String) { DispatchQueue.main.async { self.state.add(id: id, title: title) } }

    func setPaused(_ paused: Bool) {
        condition.lock(); defer { condition.unlock() }
        pausedFlag = paused
        condition.broadcast()
        DispatchQueue.main.async { self.state.setPaused(paused) }
    }

    func cancelWaiting(_ id: String) {
        condition.lock(); cancelled.insert(id); condition.unlock()
        DispatchQueue.main.async { self.state.cancelWaiting(id) }
    }

    private var pausedFlag = false
    private var cancelled = Set<String>()

    /// Blocks the disk queue while paused. Returns false for a job that was cancelled while it waited, which must not run.
    func waitUntilAllowedToStart(_ id: String) -> Bool {
        condition.lock()
        while pausedFlag && !cancelled.contains(id) { condition.wait() }
        let wasCancelled = cancelled.remove(id) != nil
        condition.unlock()
        if !wasCancelled { DispatchQueue.main.async { self.state.start(id) } }
        return !wasCancelled
    }

    func finish(_ id: String) {
        DispatchQueue.main.async { self.state.finish(id, failed: false) }
    }
}
