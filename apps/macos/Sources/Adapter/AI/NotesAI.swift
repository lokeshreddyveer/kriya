import AppKit

/// What an AI can do with the note that is open. Each action works on that note only, shows its result first, and changes the note
/// only when the person presses the button for it.
enum NotesAI {
    static weak var workflowStore: WorkflowStore?

    private static func item(_ model: NotesModel) -> AIContextItem {
        let title = NoteStore.title(of: model.text)
        return AIContextItem(source: .notes, title: title, text: String(model.text.prefix(14_000)), permission: .userAction, sensitivity: .normal, age: 0, citation: title)
    }

    private static func guardText(_ model: NotesModel) -> Bool {
        if model.text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 { Toast().show("Write a little more in the note first.", isError: true); return false }
        return true
    }

    static func suggestTags(_ model: NotesModel) {
        guard guardText(model) else { return }
        Task {
            do {
                let out = try await AIRun.ask(feature: .notes, system: "You suggest tags for a note: one or two words each, lower case, at most five.", items: [item(model)], question: "Suggest tags. Reply as JSON: {\"tags\":[\"tag\"]}",
                                              schema: .object(["type": .string("object"), "required": .array([.string("tags")]), "properties": .object(["tags": .object(["type": .string("array"), "maxItems": .number(5), "items": .object(["type": .string("string")])])])]), maxTokens: 200)
                let tags = TagSuggestions.fromReply(out.text).map { $0.lowercased().replacingOccurrences(of: " ", with: "-") }
                guard !tags.isEmpty else { throw FileTextReader.Unreadable(reason: "No tags were suggested.") }
                let line = "Tags: " + tags.map { "#" + $0 }.joined(separator: " ")
                AIResultWindow.shared.show(title: "Tags for this note", text: line, buttons: [("Add to Note", { DispatchQueue.main.async { model.text += "\n\n" + line } })])
            } catch { AIRun.toast(error) }
        }
    }

    static func extractTasks(_ model: NotesModel) {
        guard guardText(model) else { return }
        Task {
            do {
                let out = try await AIRun.ask(feature: .notes, system: "You list the tasks and follow-ups in a note: things someone has to do. One short line each, starting with a verb. Do not invent tasks that are not in the note. If there are none, say NONE.", items: [item(model)], question: "List the tasks.", maxTokens: 500)
                let tasks = NoteSimilarity.tasks(from: out.text).filter { $0.uppercased() != "NONE" }
                guard !tasks.isEmpty else { await MainActor.run { Toast().show("No tasks found in this note.") }; return }
                let checklist = tasks.map { "- [ ] " + $0 }.joined(separator: "\n")
                AIResultWindow.shared.show(title: "Tasks in this note", text: checklist, buttons: [("Add Checklist to Note", { DispatchQueue.main.async { model.text += "\n\n" + checklist } })])
            } catch { AIRun.toast(error) }
        }
    }

    static func cleanUp(_ model: NotesModel) {
        guard guardText(model) else { return }
        let original = model.text
        Task {
            do {
                let out = try await AIRun.ask(feature: .notes, system: "You tidy a note: fix spelling and grammar, fix broken lines and headings, keep every fact, every name and every number exactly, keep the language, and add nothing. Reply with the tidied note only.", items: [item(model)], question: "Tidy this note.", maxTokens: 1500)
                let tidy = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard tidy.count > original.count / 3, tidy.count < original.count * 2 else { throw FileTextReader.Unreadable(reason: "The tidied version looked wrong (much shorter or longer), so it was not offered.") }
                AIResultWindow.shared.show(title: "Tidied note", text: tidy, buttons: [("Replace the Note", {
                    DispatchQueue.main.async {
                        // The note as it was is kept as a note of its own first.
                        _ = model.store.create(original + "\n\n(kept before an AI tidy-up)")
                        model.text = tidy
                        Toast().show("Replaced. The old version is saved as another note.")
                    }
                })])
            } catch { AIRun.toast(error) }
        }
    }

    /// Notes that read like this one, by shared wording, and (if the search index is on) by meaning. Possible duplicates come first.
    static func related(_ model: NotesModel) {
        let store = model.store
        let current = model.current
        let text = model.text
        guard guardText(model) else { return }
        Task {
            let others = store.list().filter { $0.url != current }.prefix(300).map { (title: $0.title, text: store.read($0.url), url: $0.url) }
            let alike = NoteSimilarity.similar(to: text, in: others.map { ($0.title, $0.text) }, atLeast: 0.2)
            var lines: [String] = []
            let duplicates = alike.filter { $0.score >= 0.6 }
            if !duplicates.isEmpty { lines.append("Possible duplicates:"); lines += duplicates.map { "  • \($0.title) (\(Int($0.score * 100))% alike)" } }
            let rest = alike.filter { $0.score < 0.6 }.prefix(6)
            if !rest.isEmpty { lines.append("Reads like:"); lines += rest.map { "  • \($0.title) (\(Int($0.score * 100))%)" } }
            if AIIndexer.shared.enabled {
                let hits = await AIIndexer.shared.search(NoteStore.title(of: text) + " " + String(text.prefix(200)), limit: 8).filter { $0.source == .notes && $0.target != current?.path }
                let known = Set(alike.map(\.title))
                let extra = hits.filter { !known.contains($0.title) }.prefix(5)
                if !extra.isEmpty { lines.append("Close in meaning:"); lines += extra.map { "  • \($0.title)" } }
            }
            let top = (duplicates + Array(rest)).prefix(3).compactMap { hit in others.first { $0.title == hit.title }?.url }
            AIResultWindow.shared.show(title: "Related notes", text: lines.isEmpty ? "No other note is close to this one." : lines.joined(separator: "\n"),
                                       buttons: top.map { url in ("Open “\(String(NoteStore.title(of: store.read(url)).prefix(24)))”", { NSWorkspace.shared.open(url) }) })
        }
    }

    /// Drafts a workflow from the note, and adds it switched off. It uses only the safe steps a draft can have.
    static func toWorkflow(_ model: NotesModel) {
        guard guardText(model) else { return }
        let text = model.text
        Task {
            do {
                let draft = try await AIWorkflowDrafter.draft(from: "From this note:\n" + String(text.prefix(1500)))
                await MainActor.run {
                    guard let store = workflowStore, let saved = store.save(draft) else { Toast().show("The workflow could not be saved.", isError: true); return }
                    Toast().show("Added “\(saved.name)” to Automation, switched off. Check it there.")
                }
            } catch { AIRun.toast(error) }
        }
    }
}
