import AppKit
import SwiftUI

/// Rules that look after a folder by themselves: files that match are moved, copied, renamed or sent to the Trash. A new rule
/// starts switched off, shows what it would do first, and every change it makes can be undone from Finder Actions.
struct FolderRulesPane: View {
    @EnvironmentObject private var store: FolderRulesStore
    @EnvironmentObject private var service: FolderRulesService
    @State private var editing: FolderRule?
    @State private var previewing: FolderRule?
    @State private var message: String?
    @State private var overlaps: [RuleOverlap.Overlap] = []
    @State private var deleting: FolderRule?

    var body: some View {
        Form {
            if !overlaps.isEmpty {
                Section {
                    ForEach(Array(overlaps.prefix(8).enumerated()), id: \.offset) { _, overlap in
                        Label(RuleOverlap.sentence(overlap), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Theme.warn)
                    }
                    if overlaps.count > 8 { Text("and \(overlaps.count - 8) more").font(.caption).foregroundStyle(.secondary) }
                } header: { Text("Two rules want the same file") } footer: {
                    Text("Rules run in the order of the list. Switch one off or change its conditions if you want a different one to act on these files.")
                }
            }
            Section {
                if store.rules.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No rules yet.").font(.headline)
                        Text("A rule watches one folder. When a file matches, Kriya acts on it: “move PDFs from Downloads to Documents”, “sort the Desktop by kind”, “send installers older than a week to the Trash”.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Tidy Downloads by Kind") { editing = Self.starter(.downloadsByKind) }
                            Button("Clear Old Installers") { editing = Self.starter(.oldInstallers) }
                            Button("Screenshots to a Folder") { editing = Self.starter(.screenshots) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                ForEach(store.rules) { rule in row(rule) }
                if let message { Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).transition(.opacity) }
            } header: {
                HStack {
                    Text("Rules")
                    Spacer()
                    Toggle("Pause all", isOn: $store.paused).toggleStyle(.switch).controlSize(.small)
                    Button("Export…") { exportRules() }.controlSize(.small).disabled(store.rules.isEmpty)
                    Button("Import…") { importRules() }.controlSize(.small)
                    Button { editing = FolderRule(name: "", folder: NSHomeDirectory() + "/Downloads", conditions: [.kind("Documents")], action: .moveTo(NSHomeDirectory() + "/Documents")) } label: { Label("Add Rule", systemImage: "plus") }.controlSize(.small)
                }
            } footer: {
                Text("Rules look at their folder every minute. They only touch files that have been still for a minute (so downloads in progress are left alone), never folders or hidden files, and never overwrite: a name that is taken becomes “name 2”. Everything a rule does is listed under Finder Actions › Recent file operations, with Undo.")
            }
        }
        .formStyle(.grouped)
        .animation(.smooth(duration: 0.25), value: store.rules)
        .animation(.smooth(duration: 0.25), value: message)
        .animation(.smooth(duration: 0.25), value: overlaps)
        .onAppear(perform: refreshOverlaps)
        .onChange(of: store.rules) { _, _ in refreshOverlaps() }
        .sheet(item: $editing) { rule in
            FolderRuleEditor(rule: rule, onSave: { saved in
                if let problem = store.save(saved) { return problem }
                editing = nil
                message = "Saved “\(saved.name)”. It is off until you look at what it would do and switch it on."
                return nil
            }, onCancel: { editing = nil })
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let r = deleting { store.delete(r.id) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("The files it already moved stay where they are; they can be undone from Finder Actions while the history lasts.") }
        .sheet(item: $previewing) { rule in
            FolderRulePreview(rule: rule, onClose: { previewing = nil })
        }
    }

    /// Reads each folder that has more than one switched-on rule and lists the files two of them would both act on.
    private func refreshOverlaps() {
        let rules = store.rules
        DispatchQueue.global(qos: .utility).async {
            var found: [RuleOverlap.Overlap] = []
            let groups = Dictionary(grouping: rules.filter(\.enabled), by: { ($0.folder as NSString).standardizingPath })
            for (folder, group) in groups where group.count > 1 {
                let files = FolderRulesService.files(in: folder, markDuplicates: group.contains { $0.conditions.contains(.isDuplicate) })
                found += RuleOverlap.find(group, files: files, now: Date())
            }
            DispatchQueue.main.async { overlaps = found }
        }
    }

    private func exportRules() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Kriya Folder Rules.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = store.exported() else { return }
        do { try data.write(to: url, options: .atomic); message = "Saved \(store.rules.count) rule\(store.rules.count == 1 ? "" : "s") to \(url.lastPathComponent)." } catch { message = "The rules could not be saved." }
    }

    private func importRules() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else { message = "That file could not be read."; return }
        guard let result = store.importRules(data) else { message = "That file is not a set of folder rules."; return }
        message = "Added \(result.added) rule\(result.added == 1 ? "" : "s"), all switched off until you preview them." + (result.skipped > 0 ? " \(result.skipped) were skipped because their folder is missing or not allowed here." : "")
    }

    private func row(_ rule: FolderRule) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(rule.name, isOn: Binding(get: { rule.enabled }, set: { on in message = store.setEnabled(rule.id, on) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name).font(.headline)
                Text(rule.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let result = service.lastResult[rule.id] { Text(result).font(.caption2).foregroundStyle(.tertiary) }
            }
            Spacer()
            Button("Preview") { previewing = rule }.controlSize(.small)
            Button("Edit") { editing = rule }.controlSize(.small)
            Button(role: .destructive) { deleting = rule } label: { Image(systemName: "trash") }.accessibilityLabel("Delete the rule \(rule.name)").buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
    }

    enum Starter { case downloadsByKind, oldInstallers, screenshots }

    private static func starter(_ kind: Starter) -> FolderRule {
        let home = NSHomeDirectory()
        switch kind {
        case .downloadsByKind:
            return FolderRule(name: "Tidy Downloads by kind", folder: home + "/Downloads", conditions: [.olderThanDays(1)], action: .sortByKind)
        case .oldInstallers:
            return FolderRule(name: "Clear old installers", folder: home + "/Downloads", conditions: [.kind("Installers"), .olderThanDays(7)], action: .trash)
        case .screenshots:
            return FolderRule(name: "Screenshots to a folder", folder: home + "/Desktop", conditions: [.nameStartsWith("Screenshot")], action: .moveTo(home + "/Pictures/Screenshots"))
        }
    }
}

// MARK: - Editor

private struct FolderRuleEditor: View {
    @State var rule: FolderRule
    let onSave: (FolderRule) -> String?
    let onCancel: () -> Void
    @State private var problem: String?

    private enum ActionKind: String, CaseIterable, Identifiable {
        case move = "Move to a folder", copy = "Copy to a folder", rename = "Rename", tag = "Add a Finder tag", archive = "Archive into month folders", trash = "Move to the Trash", sort = "Sort into folders by kind"
        var id: String { rawValue }
    }

    private var actionKind: Binding<ActionKind> {
        Binding(get: {
            switch rule.action {
            case .moveTo: return .move
            case .copyTo: return .copy
            case .rename: return .rename
            case .trash: return .trash
            case .sortByKind: return .sort
            case .tag: return .tag
            case .archiveByMonth: return .archive
            }
        }, set: { kind in
            switch kind {
            case .move: rule.action = .moveTo(rule.action.folderArgument ?? NSHomeDirectory() + "/Documents")
            case .copy: rule.action = .copyTo(rule.action.folderArgument ?? NSHomeDirectory() + "/Documents")
            case .rename: rule.action = .rename("{date} {name}")
            case .trash: rule.action = .trash
            case .sort: rule.action = .sortByKind
            case .tag: rule.action = .tag("To review")
            case .archive: rule.action = .archiveByMonth
            }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $rule.name)
                    LabeledContent("Watch this folder") {
                        HStack {
                            Text((rule.folder as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            Button("Choose…") { if let path = Self.chooseFolder("Watch") { rule.folder = path } }
                        }
                    }
                }
                Section {
                    ForEach(Array(rule.conditions.enumerated()), id: \.offset) { index, _ in
                        HStack {
                            Text(index == 0 ? "When a file" : "and")
                                .foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                            ConditionEditor(condition: Binding(get: { rule.conditions[index] }, set: { rule.conditions[index] = $0 }))
                            Spacer(minLength: 0)
                            Button(role: .destructive) { rule.conditions.remove(at: index) } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove condition \(index + 1)").buttonStyle(.borderless)
                        }
                    }
                    Menu {
                        Button("Is a kind of file…") { rule.conditions.append(.kind("Documents")) }
                        Button("Has a file type…") { rule.conditions.append(.extensionIs(["pdf"])) }
                        Button("Name contains…") { rule.conditions.append(.nameContains("")) }
                        Button("Name starts with…") { rule.conditions.append(.nameStartsWith("")) }
                        Button("Name matches a pattern…") { rule.conditions.append(.nameMatches("")) }
                        Button("Is older than…") { rule.conditions.append(.olderThanDays(7)) }
                        Button("Is larger than…") { rule.conditions.append(.largerThanMB(100)) }
                        Button("Is smaller than…") { rule.conditions.append(.smallerThanMB(1)) }
                        Button("Is a copy of an older file…") { if !rule.conditions.contains(.isDuplicate) { rule.conditions.append(.isDuplicate) } }
                    } label: { Label("Add a Condition", systemImage: "plus") }
                        .menuStyle(.button).fixedSize().disabled(rule.conditions.count >= 5)
                } header: { Text("Conditions (all must be true)") }
                Section {
                    Picker("Then", selection: actionKind) { ForEach(ActionKind.allCases) { Text($0.rawValue).tag($0) } }
                    switch rule.action {
                    case .moveTo(let path), .copyTo(let path):
                        LabeledContent("Folder") {
                            HStack {
                                Text((path as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                Button("Choose…") {
                                    if let chosen = Self.chooseFolder("Choose") {
                                        if case .copyTo = rule.action { rule.action = .copyTo(chosen) } else { rule.action = .moveTo(chosen) }
                                    }
                                }
                            }
                        }
                    case .rename(let pattern):
                        TextField("New name", text: Binding(get: { pattern }, set: { rule.action = .rename($0) }))
                        Text("{name} the old name, {date} the file’s date, {time} its time, {n} a running number, {ext} its type. The type is kept if you leave {ext} out.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .tag(let name):
                        TextField("Tag", text: Binding(get: { name }, set: { rule.action = .tag($0) }))
                        Text("The tag shows in Finder and can be searched. Files that already have it are skipped, so the rule can run again and again.").font(.caption).foregroundStyle(.secondary)
                    case .archiveByMonth:
                        Text("Files go into Archive › year-month, such as 2026-10 (by the month each was last changed), inside the watched folder. Nothing is compressed or deleted.").font(.caption).foregroundStyle(.secondary)
                    case .trash:
                        Text("Files go to the Trash, not away for good, and Undo brings them back.").font(.caption).foregroundStyle(.secondary)
                    case .sortByKind:
                        Text("Images, Documents, Archives, Audio, Video and Installers get a folder each inside the watched folder. Other files stay.").font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Action") }
                if let problem { Section { Text(problem).font(.callout).foregroundStyle(Theme.danger) } }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("A saved rule starts switched off, so you can preview it first.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { problem = onSave(rule) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 600, height: 620)
    }

    static func chooseFolder(_ prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

private extension FolderAction {
    var folderArgument: String? {
        switch self {
        case .moveTo(let path), .copyTo(let path): return path
        default: return nil
        }
    }
}

/// One condition, editable in place.
private struct ConditionEditor: View {
    @Binding var condition: FolderCondition
    @State private var sample = ""
    private static let kinds = ["Images", "Documents", "Archives", "Audio", "Video", "Installers"]

    var body: some View {
        switch condition {
        case .kind(let kind):
            HStack {
                Text("is")
                Picker("Kind of file", selection: Binding(get: { kind }, set: { condition = .kind($0) })) { ForEach(Self.kinds, id: \.self) { Text($0).tag($0) } }.labelsHidden().fixedSize()
            }
        case .extensionIs(let list):
            HStack {
                Text("has the type")
                TextField("pdf, docx", text: Binding(get: { list.joined(separator: ", ") }, set: { condition = .extensionIs($0.split(whereSeparator: { ", ".contains($0) }).map(String.init)) })).frame(width: 160)
            }
        case .nameContains(let text):
            HStack { Text("has a name containing"); TextField("text", text: Binding(get: { text }, set: { condition = .nameContains($0) })).frame(width: 160) }
        case .nameStartsWith(let text):
            HStack { Text("has a name starting with"); TextField("text", text: Binding(get: { text }, set: { condition = .nameStartsWith($0) })).frame(width: 160) }
        case .nameMatches(let pattern):
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text("has a name matching"); TextField("IMG_[0-9]+\\.jpe?g", text: Binding(get: { pattern }, set: { condition = .nameMatches($0) })).frame(width: 200) }
                TextField("Try a file name", text: $sample).textFieldStyle(.roundedBorder).font(.caption)
                if let problem = NamePattern.problem(pattern) {
                    Text(problem).font(.caption).foregroundStyle(Theme.warn)
                } else if !sample.isEmpty {
                    Text(NamePattern.matches(pattern, sample) ? "Matches." : "Does not match.").font(.caption).foregroundStyle(.secondary)
                }
                Text("The whole name must fit. Capitals do not matter.").font(.caption).foregroundStyle(.tertiary)
            }
        case .olderThanDays(let days):
            HStack { Text("is older than"); Stepper("\(days) day\(days == 1 ? "" : "s")", value: Binding(get: { days }, set: { condition = .olderThanDays($0) }), in: 0...3650) }
        case .largerThanMB(let mb):
            HStack { Text("is larger than"); Stepper("\(mb) MB", value: Binding(get: { mb }, set: { condition = .largerThanMB($0) }), in: 0...100_000, step: 10) }
        case .smallerThanMB(let mb):
            HStack { Text("is smaller than"); Stepper("\(mb) MB", value: Binding(get: { mb }, set: { condition = .smallerThanMB($0) }), in: 0...100_000) }
        case .isDuplicate:
            Text("is a copy of an older file in this folder (same contents; the oldest is kept)").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview

/// What a rule would do right now, with a button to do it.
private struct FolderRulePreview: View {
    @EnvironmentObject private var service: FolderRulesService
    let rule: FolderRule
    let onClose: () -> Void
    @EnvironmentObject private var store: FolderRulesStore
    @State private var changes: [PlannedChange]?
    @State private var confirming = false

    /// Where this rule stands among the switched-on rules for the same folder.
    private var whoWins: String? {
        let folder = (rule.folder as NSString).standardizingPath
        let same = store.rules.filter { $0.enabled && ($0.folder as NSString).standardizingPath == folder }
        guard let index = same.firstIndex(where: { $0.id == rule.id }) else {
            return same.isEmpty ? nil : "This rule is off. When it is on it runs after the \(same.count) switched-on rule\(same.count == 1 ? "" : "s") for this folder."
        }
        if same.count == 1 { return "No other rule watches this folder, so nothing else competes for these files." }
        let before = same[..<index].map { "“\($0.name)”" }
        if before.isEmpty { return "This rule runs first for this folder, so it wins any file another rule also fits." }
        return "Runs after " + before.joined(separator: ", ") + ". A file one of those moves, renames or trashes is gone by the time this rule looks."
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("“\(rule.name)”").font(.headline)
                Text(rule.summary).font(.callout).foregroundStyle(.secondary)
                if let whoWins { Label(whoWins, systemImage: "list.number").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            Divider()
            if let changes {
                if changes.isEmpty {
                    Text("Nothing in that folder matches right now.").foregroundStyle(.secondary).frame(maxHeight: .infinity)
                } else {
                    List(Array(changes.enumerated()), id: \.offset) { _, change in
                        VStack(alignment: .leading, spacing: 1) {
                            Text((change.from as NSString).lastPathComponent)
                            Text(destination(change)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                    }
                }
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text(changes.map { "\($0.count) file\($0.count == 1 ? "" : "s") would change" } ?? "Looking…").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Button("Run Now") { confirming = true }.disabled((changes ?? []).isEmpty).buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 560, height: 460)
        .onAppear { service.preview(rule) { changes = $0 } }
        .confirmationDialog("Run “\(rule.name)” now?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Run Now") { service.run(rule, announce: true); onClose() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("It does what the list shows. You can undo it under Finder Actions › Recent file operations.") }
    }

    private func destination(_ change: PlannedChange) -> String {
        switch change.kind {
        case .trash: return "→ the Trash"
        case .tag: return "tag “\(change.to ?? "")”"
        case .copy: return "copy → " + ((change.to ?? "") as NSString).abbreviatingWithTildeInPath
        case .move: return "→ " + ((change.to ?? "") as NSString).abbreviatingWithTildeInPath
        }
    }
}
