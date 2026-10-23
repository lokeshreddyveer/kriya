import AppKit

extension LauncherSources {
    /// "ai" in the launcher lists what an AI can do for Finder, captures and sound; extra words after it are the request for the ones
    /// that take one ("ai plan move the PDFs into Documents").
    func aiActionEntries(_ text: String) -> [PaletteEntry] {
        guard prefs.data.isEnabled(.command) else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        guard lower == "ai" || lower.hasPrefix("ai ") else { return [] }
        let rest = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        let words = rest.lowercased().split(separator: " ").map(String.init)
        let gateway = AIGateway.shared
        var entries: [PaletteEntry] = []

        func add(_ id: String, _ feature: AIFeature, _ title: String, _ subtitle: String, _ symbol: String, takesText: Bool = false, run: @escaping () -> Void) {
            guard gateway.isAvailable(for: feature) else { return }
            // With words after "ai", an entry that does not take them is shown only if its title has them.
            if !words.isEmpty && !takesText && !words.allSatisfy({ title.lowercased().contains($0) }) { return }
            if takesText && rest.isEmpty { return }
            var e = PaletteEntry(id: id, title: title, subtitle: subtitle, symbol: symbol, rememberable: false, run: run)
            e.queryScore = takesText ? 780 : 740
            entries.append(e)
        }

        func withSelection(_ body: @escaping (FinderSelection) -> Void) {
            DispatchQueue.global(qos: .userInitiated).async {
                do { let s = try FinderAI.selection(); DispatchQueue.main.async { body(s) } }
                catch { DispatchQueue.main.async { Toast().show("Kriya could not read Finder's selection. Allow Automation for Finder in System Settings.", isError: true) } }
            }
        }

        add("ai.f.names", .finder, "Finder: suggest better names for the selected files", "Shows the new names for you to approve; can be undone", "textformat.abc") {
            withSelection { FinderAI.suggestNames(for: $0.paths.map { URL(fileURLWithPath: $0) }) }
        }
        add("ai.f.summary", .finder, "Finder: summarize the selected file", "Reads its text and gives the main points", "doc.text.magnifyingglass") {
            withSelection { s in if let first = s.paths.first { FinderAI.summarize(URL(fileURLWithPath: first)) } else { Toast().show("Select a file in Finder first.", isError: true) } }
        }
        add("ai.f.tags", .finder, "Finder: suggest tags for the selected file", "Shows the tags for you to approve", "tag") {
            withSelection { s in if let first = s.paths.first { FinderAI.suggestTags(for: URL(fileURLWithPath: first)) } else { Toast().show("Select a file in Finder first.", isError: true) } }
        }
        add("ai.f.rules", .finder, "Finder: suggest folder rules for this folder", "Ideas only; nothing is created", "folder.badge.gearshape") {
            withSelection { s in if let folder = s.folder { FinderAI.suggestFolderRules(for: URL(fileURLWithPath: folder)) } else { Toast().show("Open a folder in Finder first.", isError: true) } }
        }
        add("ai.f.plan", .finder, "Finder: plan changes — \(String(rest.prefix(50)))", "Move, rename or trash inside the open folder; you approve each plan", "list.bullet.clipboard", takesText: true) {
            withSelection { FinderAI.plan(instruction: rest, selection: $0) }
        }

        for kind in CaptureAI.Kind.allCases {
            add("ai.c.\(kind.rawValue)", .capture, "Capture: \(kind.title.prefix(1).lowercased() + kind.title.dropFirst())", "Works on the latest capture (its text, not the picture)", "camera.viewfinder") {
                if let url = CaptureAI.latestCapture() { CaptureAI.run(kind, on: url) } else { Toast().show("There is no capture yet.", isError: true) }
            }
        }
        add("ai.c.hide", .capture, "Capture: hide private text in the latest capture", "Saves a copy with the phrases covered", "eye.slash") {
            if let url = CaptureAI.latestCapture() { CaptureAI.hideSensitive(in: url) } else { Toast().show("There is no capture yet.", isError: true) }
        }
        add("ai.c.name", .capture, "Capture: give the latest capture a name", "Names it from what it shows, after you approve", "pencil.line") {
            if let url = CaptureAI.latestCapture() { CaptureAI.nameCapture(url) } else { Toast().show("There is no capture yet.", isError: true) }
        }

        add("ai.a.diagnose", .audio, rest.isEmpty ? "Sound: check my sound settings" : "Sound: check — \(String(rest.prefix(50)))", "Looks at devices, levels and per-app changes; changes nothing", "speaker.wave.2.circle", takesText: !rest.isEmpty) {
            AudioAI.diagnose(rest)
        }
        add("ai.a.mode", .audio, "Sound: draft a sound mode — \(String(rest.prefix(50)))", "Uses only connected devices; you approve it before it is added", "slider.horizontal.3", takesText: true) {
            AudioAI.draftMode(rest)
        }
        if rest.isEmpty, gateway.isAvailable(for: .audio) {
            var e = PaletteEntry(id: "ai.a.mode.hint", title: "Sound: draft a sound mode…", subtitle: "Type what you want after “ai”, for example: ai a calm mode for calls with my headset", symbol: "slider.horizontal.3", rememberable: false) {}
            e.queryScore = 700
            entries.append(e)
        }
        return entries
    }
}
