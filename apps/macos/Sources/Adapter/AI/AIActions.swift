import AppKit
import CoreAudio
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The common way to ask

enum AIRun {
    struct Output {
        let text: String
        let context: AIContext?
        let provider: AIProviderConfig
    }

    /// One question to the provider chosen for a feature, with the content wrapped by the context builder: secrets hidden, outside
    /// content marked as data, size limited. A model that cannot return structured output is told the shape in words instead.
    static func ask(feature: AIFeature, system: String, items: [AIContextItem], question: String, schema: JSONValue? = nil, maxTokens: Int = 800, gateway: AIGateway = .shared) async throws -> Output {
        guard let config = gateway.resolve(feature: feature) else { throw AIError.notConfigured("no provider is switched on for \(feature.title). Switch one on in Apple Intelligence settings.") }
        var context: AIContext?
        var prompt = ""
        if !items.isEmpty {
            let policy = AIContextPolicy(maxCharacters: 12_000, redactSecrets: true, redactPersonal: gateway.store.redactPersonal, providerIsOnThisMac: config.isOnThisMac)
            switch AIContextBuilder.build(items, policy: policy) {
            case .failure(let refusal): throw AIError.provider(refusal.errorDescription ?? "Nothing could be sent.")
            case .success(let c): context = c; prompt = c.rendered + "\n\n"
            }
        }
        prompt += SecretRedactor.redact(question).text
        var instructions = system + "\n" + AIContextBuilder.untrustedRule
        var wanted = schema
        if let schema, config.kind == .appleIntelligence {
            instructions += "\nReply with JSON only, in this shape: " + schema.text
            wanted = nil
        }
        let response = try await gateway.generate(feature: feature, AIRequest(system: instructions, messages: [AIMessage(.user, prompt)], responseSchema: wanted, temperature: 0.2, maxTokens: maxTokens), secretsHidden: context?.redactionCount ?? 0)
        return Output(text: response.text, context: context, provider: config)
    }

    static func message(_ error: Error) -> String { (error as? AIError)?.errorDescription ?? (error as? IntelligenceError)?.errorDescription ?? error.localizedDescription }

    static func toast(_ error: Error) { DispatchQueue.main.async { Toast().show(message(error), isError: true) } }
}

// MARK: - Showing results

final class AIResultWindow {
    static let shared = AIResultWindow()
    private var windows: [NSWindow] = []

    func show(title: String, text: String, buttons: [(title: String, run: () -> Void)] = []) {
        DispatchQueue.main.async {
            let view = AIResultView(text: text, buttons: buttons)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = title
            window.contentViewController = NSHostingController(rootView: view)
            window.isReleasedWhenClosed = false
            window.applyPopupPrivacy()
            window.center()
            self.windows.append(window)
            // A closed result is let go, so the text it showed is not kept for the rest of the session.
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak window] _ in
                self?.windows.removeAll { $0 === window }
                if let observer { NotificationCenter.default.removeObserver(observer) }
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}

private struct AIResultView: View {
    let text: String
    let buttons: [(title: String, run: () -> Void)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14) }
            Divider()
            HStack {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, b in Button(b.title, action: b.run) }
                Spacer()
            }
            .padding(10)
        }
        .frame(minWidth: 420, minHeight: 240)
    }
}

enum AIConfirm {
    /// Shows what would happen, in a list, and asks. Returns whether the person chose to go ahead. Must be called on the main thread.
    @MainActor
    static func list(title: String, lines: [String], note: String? = nil, applyTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = note ?? ""
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 220))
        text.string = lines.joined(separator: "\n")
        text.isEditable = false
        text.font = .systemFont(ofSize: 12)
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: applyTitle)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Reading a file's text

enum FileTextReader {
    struct Unreadable: LocalizedError { let reason: String; var errorDescription: String? { reason } }

    static func isBlocked(_ path: String) -> Bool { IndexPolicy.blockedPathParts.contains { path.contains($0) } }

    /// The start of a file's text. Plain text, source code, PDF, and rich text documents are read; pictures, programs and archives are not.
    static func read(_ url: URL, limit: Int = 12_000) throws -> String {
        guard !isBlocked(url.path) else { throw Unreadable(reason: "That file is in a place Kriya never reads for an AI (keys, credentials).") }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { throw Unreadable(reason: "That is a folder.") }
        guard (values?.fileSize ?? 0) <= 20_000_000 else { throw Unreadable(reason: "That file is too large to read.") }
        let ext = url.pathExtension.lowercased()
        var text: String?
        switch ext {
        case "pdf": text = PDFDocument(url: url)?.string
        case "rtf", "rtfd", "html", "htm", "doc", "docx", "odt":
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        default:
            if let type = UTType(filenameExtension: ext), !(type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml) || type.conforms(to: .yaml)), ext != "md", ext != "csv" {
                throw Unreadable(reason: "Kriya can read text, code, PDF and document files, not this kind.")
            }
            guard (values?.fileSize ?? 0) <= 2_000_000, let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8) else { throw Unreadable(reason: "That file is not plain text, or is too large.") }
            text = s
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Unreadable(reason: "No text could be read from that file.") }
        return String(text.prefix(limit))
    }
}

// MARK: - Finder

enum FinderAI {
    private static func item(_ url: URL, text: String) -> AIContextItem {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).flatMap { $0 }
        return AIContextItem(source: .file, title: url.lastPathComponent, text: text, permission: .userAction, sensitivity: .normal, age: modified.map { Date().timeIntervalSince($0) }, citation: url.lastPathComponent)
    }

    static func selection() throws -> FinderSelection { try FinderSelectionReader.read() }

    // Summaries

    static func summarize(_ url: URL) {
        Task {
            do {
                let text = try FileTextReader.read(url)
                let out = try await AIRun.ask(feature: .finder, system: "You summarize files for the person who owns them. Use at most six short bullet points, then one line saying what kind of document it is.", items: [item(url, text: text)], question: "Summarize this file.")
                AIResultWindow.shared.show(title: "Summary of \(url.lastPathComponent)", text: out.text + "\n\n— by \(out.provider.name)" + (out.context.map { $0.redactionCount > 0 ? ", \($0.redactionCount) secret(s) hidden before sending" : "" } ?? ""))
            } catch { AIRun.toast(error) }
        }
    }

    // Names

    static func suggestNames(for urls: [URL]) {
        let chosen = Array(urls.filter { !$0.hasDirectoryPath }.prefix(RenameSuggestions.maxFiles))
        guard !chosen.isEmpty else { Toast().show("Select some files in Finder first.", isError: true); return }
        Task {
            do {
                let folder = chosen[0].deletingLastPathComponent()
                guard chosen.allSatisfy({ $0.deletingLastPathComponent() == folder }) else { throw FileTextReader.Unreadable(reason: "Choose files from one folder.") }
                let items = chosen.map { url in item(url, text: "File name: \(url.lastPathComponent)\n" + ((try? FileTextReader.read(url, limit: 400)).map { "Starts with: \($0)" } ?? "(contents not read)")) }
                let out = try await AIRun.ask(feature: .finder, system: "You suggest clear, consistent file names. Keep each file's extension. Use plain words, no slashes or colons. Only rename a file if the new name is clearly better.", items: items,
                                              question: "Suggest better names for these files. Reply as JSON: {\"renames\":[{\"from\":\"old name\",\"to\":\"new name\"}]}", schema: RenameSuggestions.schema, maxTokens: 900)
                let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                let result = RenameSuggestions.validate(out.text, files: chosen.map(\.lastPathComponent), existing: existing)
                await MainActor.run {
                    guard !result.renames.isEmpty else { Toast().show(result.rejected.isEmpty ? "The AI had no better names to suggest." : "None of the suggested names could be used.", isError: result.rejected.isEmpty == false); return }
                    let lines = result.renames.map { "\($0.from)  →  \($0.to)" } + result.rejected.compactMap { if case .rejected(let n, let why) = $0 { return "Left out “\(n)”: \(why)" }; return nil }
                    guard AIConfirm.list(title: "Rename \(result.renames.count) file\(result.renames.count == 1 ? "" : "s")?", lines: lines, note: "Suggested by \(out.provider.name). You can undo this from Finder Actions › Recent operations.", applyTitle: "Rename") else { return }
                    apply(renames: result.renames.map { (folder.appendingPathComponent($0.from).path, folder.appendingPathComponent($0.to).path) }, title: "AI rename")
                }
            } catch { AIRun.toast(error) }
        }
    }

    @MainActor
    static func apply(renames: [(String, String)], title: String) {
        var steps: [FileStep] = []
        var failures: [String] = []
        for (from, to) in renames {
            do { try FileManager.default.moveItem(atPath: from, toPath: to); steps.append(.moved(from: from, to: to)) }
            catch { failures.append("\((from as NSString).lastPathComponent): \(error.localizedDescription)") }
        }
        FileOperationHistory.shared.record(title: title, steps: steps, failures: failures)
        AuditLog.shared.record(.files, "\(title): \(steps.count) renamed")
        Toast().show(failures.isEmpty ? "Renamed \(steps.count). Undo is in Finder Actions › Recent operations." : "Renamed \(steps.count), \(failures.count) failed", isError: steps.isEmpty)
    }

    // Tags

    static func suggestTags(for url: URL) {
        Task {
            do {
                let text = try FileTextReader.read(url, limit: 6000)
                let out = try await AIRun.ask(feature: .finder, system: "You suggest Finder tags: one or two words each, at most five, describing what the file is about.", items: [item(url, text: text)],
                                              question: "Suggest tags. Reply as JSON: {\"tags\":[\"tag\"]}", schema: .object(["type": .string("object"), "required": .array([.string("tags")]), "properties": .object(["tags": .object(["type": .string("array"), "maxItems": .number(5), "items": .object(["type": .string("string")])])])]), maxTokens: 200)
                let tags = TagSuggestions.fromReply(out.text)
                await MainActor.run {
                    guard !tags.isEmpty else { Toast().show("No tags were suggested.", isError: true); return }
                    guard AIConfirm.list(title: "Add these tags to “\(url.lastPathComponent)”?", lines: tags, note: "Suggested by \(out.provider.name). Tags it already has are kept.", applyTitle: "Add Tags") else { return }
                    if let outcome = try? FinderMetadata.addTags(tags, to: [url]) { Toast().show(outcome.message, isError: outcome.isError) }
                }
            } catch { AIRun.toast(error) }
        }
    }

    // Folder rules

    static func suggestFolderRules(for folder: URL) {
        Task {
            do {
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
                guard !names.isEmpty else { throw FileTextReader.Unreadable(reason: "That folder is empty.") }
                var byExtension: [String: Int] = [:]
                for n in names { byExtension[(n as NSString).pathExtension.lowercased().isEmpty ? "(none)" : (n as NSString).pathExtension.lowercased(), default: 0] += 1 }
                let summary = "Folder: \(folder.lastPathComponent)\nItems: \(names.count)\nBy type: " + byExtension.sorted { $0.value > $1.value }.prefix(12).map { ".\($0.key) × \($0.value)" }.joined(separator: ", ") + "\nSome names: " + names.prefix(40).joined(separator: "; ")
                let it = AIContextItem(source: .file, title: folder.lastPathComponent, text: summary, permission: .userAction, sensitivity: .normal, age: nil, citation: folder.lastPathComponent)
                let out = try await AIRun.ask(feature: .finder, system: "You suggest rules for a Mac app's Folder Rules: a rule watches a folder and, for files whose name or type matches, moves, copies, renames, archives or trashes them. Suggest at most five rules, each as one line: when (condition) → do (action). Be cautious: prefer moving to a folder over deleting.", items: [it], question: "Suggest folder rules for this folder.")
                AIResultWindow.shared.show(title: "Folder rule ideas for \(folder.lastPathComponent)", text: out.text + "\n\nThese are ideas. Add the ones you want in Folder Rules; use its dry run to see what a rule would do first.")
            } catch { AIRun.toast(error) }
        }
    }

    // Plans

    static func plan(instruction: String, selection: FinderSelection) {
        Task {
            do {
                var roots = Set(selection.paths.map { ($0 as NSString).deletingLastPathComponent })
                if let folder = selection.folder { roots.insert(folder) }
                roots = Set(roots.filter { $0.hasPrefix(NSHomeDirectory() + "/") && !ProtectedPaths.isProtected($0) })
                guard !roots.isEmpty else { throw FileTextReader.Unreadable(reason: "Open a folder in your home folder in Finder first. Kriya plans changes only inside it.") }
                var listing: [String] = []
                for root in roots.sorted() {
                    let names = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { !$0.hasPrefix(".") }.prefix(120)
                    listing.append("Folder \(root):\n" + names.map { "  " + $0 }.joined(separator: "\n"))
                }
                let it = AIContextItem(source: .file, title: "Folders", text: listing.joined(separator: "\n"), permission: .userAction, sensitivity: .normal, age: nil, citation: "folders")
                let out = try await AIRun.ask(feature: .finder, system: "You plan file changes for the user. You may only use these operations: move (path, to = an existing folder), rename (path, to = new name), trash (path). Use full paths from the listing. Change as little as possible, never overwrite, and do nothing the user did not ask for.", items: [it],
                                              question: "Request: " + String(instruction.prefix(400)) + "\nReply as JSON: {\"steps\":[{\"op\":\"move\",\"path\":\"/full/path\",\"to\":\"/full/folder\"}]}", schema: FinderPlan.schema, maxTokens: 1200)
                let fm = FileManager.default
                let plan = FinderPlan.validate(out.text, allowed: { p in roots.contains { p == $0 || p.hasPrefix($0 + "/") } }, exists: { fm.fileExists(atPath: $0) }, isFolder: { var d: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &d) && d.boolValue })
                await MainActor.run {
                    guard !plan.operations.isEmpty else { Toast().show("The AI's plan had nothing Kriya could safely do.", isError: true); return }
                    let lines = plan.operations.map(\.summary) + plan.rejected.compactMap { if case .rejected(let n, let why) = $0 { return "Left out “\(n)”: \(why)" }; return nil }
                    guard AIConfirm.list(title: "Do these \(plan.operations.count) changes?", lines: lines, note: "Planned by \(out.provider.name). Moves and renames can be undone from Finder Actions › Recent operations; the Trash can be emptied only by you.", applyTitle: "Do It") else { return }
                    run(plan)
                }
            } catch { AIRun.toast(error) }
        }
    }

    @MainActor
    static func run(_ plan: FinderPlan) {
        var steps: [FileStep] = []
        var failures: [String] = []
        for op in plan.operations {
            do {
                switch op {
                case .move(let from, let to):
                    let target = (to as NSString).appendingPathComponent((from as NSString).lastPathComponent)
                    try FileManager.default.moveItem(atPath: from, toPath: target)
                    steps.append(.moved(from: from, to: target))
                case .rename(let path, let name):
                    let target = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
                    try FileManager.default.moveItem(atPath: path, toPath: target)
                    steps.append(.moved(from: path, to: target))
                case .trash(let path):
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                }
            } catch { failures.append(op.summary + ": " + error.localizedDescription) }
        }
        FileOperationHistory.shared.record(title: "AI plan", steps: steps, failures: failures)
        AuditLog.shared.record(.files, "AI plan: \(plan.operations.count - failures.count) of \(plan.operations.count) changes made")
        Toast().show(failures.isEmpty ? "Done: \(plan.operations.count) changes." : "\(failures.count) of \(plan.operations.count) changes failed", isError: failures.count == plan.operations.count)
    }
}

// MARK: - Capture

enum CaptureAI {
    static func latestCapture() -> URL? {
        let folder = CaptureSettingsStore().settings.folder
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .max { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
    }

    static func read(_ url: URL) throws -> (image: CGImage, text: String) {
        guard let image = ScreenCaptureService.loadImage(at: url) else { throw FileTextReader.Unreadable(reason: "That picture could not be opened.") }
        let text = (try TextRecognizer().text(in: image)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { throw FileTextReader.Unreadable(reason: "No text could be read from that picture, and Kriya sends only text, never the picture, to an AI.") }
        return (image, text)
    }

    enum Kind: String, CaseIterable {
        case explain, summarize, markdown, cleanText
        var title: String {
            switch self {
            case .explain: return "Explain what is on the screen"
            case .summarize: return "Summarize the capture"
            case .markdown: return "Turn the capture into Markdown"
            case .cleanText: return "Clean up the text read from the capture"
            }
        }
        var instruction: String {
            switch self {
            case .explain: return "Explain what the screenshot shows and what the person was probably doing, in a few sentences. If it shows an error message, say what it means and the safest thing to try."
            case .summarize: return "Summarize the content in at most five short bullet points."
            case .markdown: return "Rewrite the text as clean Markdown, keeping its structure (headings, lists, tables) and not adding anything that was not there."
            case .cleanText: return "Fix obvious errors from text recognition (broken words, wrong characters, stray symbols) without changing the meaning or adding anything. Reply with the corrected text only."
            }
        }
    }

    static func run(_ kind: Kind, on url: URL) {
        Task {
            do {
                let (_, text) = try read(url)
                let item = AIContextItem(source: .capture, title: url.lastPathComponent, text: text, permission: .userAction, sensitivity: .normal, age: nil, citation: url.lastPathComponent)
                let out = try await AIRun.ask(feature: .capture, system: "You only see the text that was read from a screenshot, not the picture. " + kind.instruction, items: [item], question: kind.title + ".", maxTokens: 900)
                AIResultWindow.shared.show(title: kind.title, text: out.text, buttons: kind == .markdown || kind == .cleanText ? [("Save as File", { saveText(out.text, beside: url) })] : [])
            } catch { AIRun.toast(error) }
        }
    }

    private static func saveText(_ text: String, beside url: URL) {
        let target = url.deletingPathExtension().appendingPathExtension("md")
        do { try text.write(to: target, atomically: true, encoding: .utf8); Toast().show("Saved \(target.lastPathComponent)") } catch { Toast().show(error.localizedDescription, isError: true) }
    }

    /// Asks which words in the picture look private, then covers exactly those and saves a copy. The original is not changed.
    static func hideSensitive(in url: URL) {
        Task {
            do {
                let (image, text) = try read(url)
                let item = AIContextItem(source: .capture, title: url.lastPathComponent, text: text, permission: .userAction, sensitivity: .normal, age: nil, citation: url.lastPathComponent)
                let out = try await AIRun.ask(feature: .capture, system: "You find private details in text read from a screenshot: names of people, account or ID numbers, addresses, amounts tied to a person, internal hostnames. Reply with exact phrases copied from the text.", items: [item],
                                              question: "Which phrases should be hidden before sharing this screenshot? Reply as JSON: {\"hide\":[\"exact phrase\"]}", schema: .object(["type": .string("object"), "required": .array([.string("hide")]), "properties": .object(["hide": .object(["type": .string("array"), "maxItems": .number(30), "items": .object(["type": .string("string")])])])]), maxTokens: 500)
                let words = RedactionSuggestions.clean(out.text, ocrText: text)
                guard !words.isEmpty else { await MainActor.run { Toast().show("The AI found nothing it was sure should be hidden.") }; return }
                let lines = try TextRecognizer().recognize(image)
                let boxes = Redaction.plan(lines, options: Redaction.Options(extraWords: words))
                guard !boxes.isEmpty, let covered = CaptureRenderer.hide(image, rects: boxes), let data = covered.pngData else { await MainActor.run { Toast().show("Those phrases could not be found in the picture.", isError: true) }; return }
                let target = url.deletingPathExtension().appendingPathExtension("hidden").appendingPathExtension("png")
                try data.write(to: target, options: .atomic)
                await MainActor.run { Toast().show("Saved \(target.lastPathComponent) with \(boxes.count) place\(boxes.count == 1 ? "" : "s") covered"); NSWorkspace.shared.activateFileViewerSelecting([target]) }
            } catch { AIRun.toast(error) }
        }
    }

    /// A short name for the capture, from what is in it. Renames the file after asking.
    static func nameCapture(_ url: URL) {
        Task {
            do {
                let (_, text) = try read(url)
                let item = AIContextItem(source: .capture, title: url.lastPathComponent, text: String(text.prefix(2000)), permission: .userAction, sensitivity: .normal, age: nil, citation: url.lastPathComponent)
                let out = try await AIRun.ask(feature: .capture, system: "You name screenshots. Reply with a name of two to six plain words that says what is in it. No punctuation, no file extension.", items: [item], question: "Name this screenshot.", maxTokens: 40)
                guard let slug = CaptureNameSuggestion.slug(from: out.text) else { throw FileTextReader.Unreadable(reason: "The AI's name could not be used.") }
                let stamp = url.deletingPathExtension().lastPathComponent
                let target = url.deletingLastPathComponent().appendingPathComponent("\(slug) – \(stamp.suffix(19)).\(url.pathExtension)")
                await MainActor.run {
                    guard !FileManager.default.fileExists(atPath: target.path), AIConfirm.list(title: "Rename this capture?", lines: ["\(url.lastPathComponent)  →  \(target.lastPathComponent)"], applyTitle: "Rename") else { return }
                    do {
                        try FileManager.default.moveItem(at: url, to: target)
                        FileOperationHistory.shared.record(title: "AI capture name", steps: [.moved(from: url.path, to: target.path)], failures: [])
                        Toast().show("Renamed to \(target.lastPathComponent)")
                    } catch { Toast().show(error.localizedDescription, isError: true) }
                }
            } catch { AIRun.toast(error) }
        }
    }
}

// MARK: - Audio

enum AudioAI {
    static weak var runner: SoundRuleRunner?
    static weak var appAudio: AppAudioEngine?

    static func facts() -> String {
        let audio = AudioControl.shared
        let devices = audio.devices()
        func name(_ id: AudioDeviceID?) -> String? { id.flatMap { id in devices.first { $0.id == id }?.name } }
        let out = audio.defaultDevice(input: false), inp = audio.defaultDevice(input: true)
        let apps: [AudioFacts.App] = (appAudio?.settings ?? [:]).filter { !$0.value.isDefault }.map { key, s in
            AudioFacts.App(name: AppChoice.name(for: key), volumePercent: Int((s.volume * 100).rounded()), muted: s.muted, output: s.outputs.first.flatMap { uid in devices.first { $0.uid == uid }?.name }, equaliserChanged: s.eq.contains { abs($0) >= 0.01 })
        }
        return AudioFacts.render(output: name(out), input: name(inp), volumePercent: out.flatMap { audio.volume(of: $0) }.map { Int(($0 * 100).rounded()) },
                                 outputMuted: out.flatMap { audio.isMuted($0) }, micMuted: inp.flatMap { audio.isMuted($0, input: true) },
                                 devices: devices.map { AudioFacts.Device(name: $0.name, isOutput: $0.isOutput, isInput: $0.isInput) }, apps: apps,
                                 modeOn: runner?.activeModeID.flatMap { id in runner?.modes.first { $0.id == id }?.name })
    }

    /// Looks at the sound settings and says what could explain a problem. Nothing is changed.
    static func diagnose(_ problem: String) {
        Task {
            do {
                let item = AIContextItem(source: .diagnostics, title: "Sound settings", text: facts(), permission: .userAction, sensitivity: .normal, age: 0, citation: "sound settings")
                let out = try await AIRun.ask(feature: .audio, system: "You help someone fix sound problems on a Mac. You are given the current sound settings (device names, levels, mutes, per-app changes). Name the most likely causes first, then the simplest thing to try, using the settings given. If the settings show nothing wrong, say so and suggest what else to check (the app's own sound settings, the cable, Bluetooth).", items: [item],
                                              question: problem.isEmpty ? "Why might an app be silent or sound wrong?" : problem, maxTokens: 700)
                AIResultWindow.shared.show(title: "Sound check", text: out.text)
            } catch { AIRun.toast(error) }
        }
    }

    /// Turns a description into a sound mode using only devices that are connected now, shows it, and saves it if the person agrees.
    static func draftMode(_ description: String) {
        Task {
            do {
                let devices = AudioControl.shared.devices()
                let outputs = devices.filter(\.isOutput).map(\.name), inputs = devices.filter(\.isInput).map(\.name)
                let facts = "Connected outputs: \(outputs.joined(separator: ", "))\nConnected microphones: \(inputs.joined(separator: ", "))"
                let item = AIContextItem(source: .diagnostics, title: "Sound devices", text: facts, permission: .userAction, sensitivity: .normal, age: 0, citation: "devices")
                let out = try await AIRun.ask(feature: .audio, system: "You design a sound mode: a named set of changes turned on together. Use only the connected devices listed, written exactly as listed. Do not mute the microphone unless asked.", items: [item],
                                              question: "Request: " + String(description.prefix(300)) + "\nReply as JSON: {\"name\":\"…\",\"actions\":[{\"type\":\"use_output\",\"device\":\"…\"}]}. Types: use_output, use_input, set_volume (percent), mute_mic (on), mute_sound (on).", schema: SoundModeDraft.schema, maxTokens: 500)
                switch SoundModeDraft.parse(out.text, outputs: outputs, inputs: inputs) {
                case .failure(let problem): AIRun.toast(problem)
                case .success(let mode):
                    await MainActor.run {
                        guard AIConfirm.list(title: "Add the sound mode “\(mode.name)”?", lines: mode.actions.map { $0.title.prefix(1).uppercased() + $0.title.dropFirst() }, note: "Drafted by \(out.provider.name). It does nothing until you turn it on in Sound settings.", applyTitle: "Add Mode") else { return }
                        runner?.modes.append(mode)
                        FeatureActivity.shared.changed("aiProviders", "Sound mode “\(mode.name)” added")
                        Toast().show("Added the sound mode “\(mode.name)”. Turn it on in Sound settings.")
                    }
                }
            } catch { AIRun.toast(error) }
        }
    }
}
