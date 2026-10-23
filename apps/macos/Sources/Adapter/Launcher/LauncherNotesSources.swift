import AppKit

extension LauncherSources {
    /// "note buy milk" saves at once; "notes" opens the window; "notes shopping" finds notes.
    func noteEntries(_ text: String) -> [PaletteEntry] {
        guard let notes else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        var found: [PaletteEntry] = []
        func make(_ id: String, _ title: String, _ subtitle: String, _ symbol: String, score: Int = 700, run: @escaping () -> Void) -> PaletteEntry {
            var e = PaletteEntry(id: id, title: title, subtitle: subtitle, symbol: symbol, rememberable: false, run: run)
            e.queryScore = score
            return e
        }
        for prefix in ["note ", "note: ", "jot "] where lower.hasPrefix(prefix) && trimmed.count > prefix.count {
            let body = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            found.append(make("note:save", "Save as a note: \(String(body.prefix(60)))", "Adds a Markdown file to your Notes folder", "note.text.badge.plus", score: 800) {
                if notes.quickSave(body) != nil { Toast().show("Note saved") } else { Toast().show("The note could not be saved.", isError: true) }
            })
            break
        }
        if ["note clipboard", "note from clipboard", "save clipboard as note", "clipboard to note"].contains(lower),
           let clip = NSPasteboard.general.string(forType: .string), !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append(make("note:clip", "Save the clipboard as a note", String(clip.prefix(60)), "note.text.badge.plus", score: 800) {
                if notes.quickSave(clip) != nil { Toast().show("Note saved") } else { Toast().show("The note could not be saved.", isError: true) }
            })
        }
        if lower == "note" || lower == "notes" || lower == "new note" {
            found.append(make("note:open", "Open Notes", "The floating notes window", "note.text") { DispatchQueue.main.async { notes.show() } })
        }
        for prefix in ["notes ", "find note "] where lower.hasPrefix(prefix) {
            let q = String(trimmed.dropFirst(prefix.count))
            for note in notes.model.store.search(q).prefix(6) {
                found.append(make("note:\(note.url.path)", note.title, "Note", "note.text", score: 600) { DispatchQueue.main.async { notes.show(opening: note.url) } })
            }
            break
        }
        return found
    }
}
