import AppKit
import SwiftUI

/// One batch-rename step as the form edits it.
struct StepDraft: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case findReplace = "Find and replace", prefix = "Add text before", suffix = "Add text after", number = "Number the files"
        case changeCase = "Change case", trim = "Trim spaces", remove = "Remove characters", fileExtension = "Change extension"
        var id: String { rawValue }
    }

    let id = UUID()
    var kind: Kind = .findReplace
    var text = ""
    var replacement = ""
    var caseSensitive = false
    var start = 1
    var step = 1
    var digits = 2
    var atStart = false
    var separator = "-"
    var caseMode: CaseMode = .lower

    init(kind: Kind = .findReplace) { self.kind = kind }

    init(_ step: RenameStep) {
        switch step {
        case .findReplace(let find, let replace, let sensitive): kind = .findReplace; text = find; replacement = replace; caseSensitive = sensitive
        case .prefix(let t): kind = .prefix; text = t
        case .suffix(let t): kind = .suffix; text = t
        case .number(let start, let step, let digits, let position, let separator):
            kind = .number; self.start = Int(start); self.step = Int(step); self.digits = Int(digits); atStart = position == .start; self.separator = separator
        case .changeCase(let mode): kind = .changeCase; caseMode = mode
        case .trim: kind = .trim
        case .removeCharacters(let characters): kind = .remove; text = characters
        case .replaceExtension(let ext): kind = .fileExtension; text = ext
        }
    }

    var asStep: RenameStep {
        switch kind {
        case .findReplace: return .findReplace(find: text, replace: replacement, caseSensitive: caseSensitive)
        case .prefix: return .prefix(text: text)
        case .suffix: return .suffix(text: text)
        case .number: return .number(start: Int64(start), step: Int64(step), digits: UInt32(max(1, digits)), position: atStart ? .start : .end, separator: separator)
        case .changeCase: return .changeCase(mode: caseMode)
        case .trim: return .trim
        case .remove: return .removeCharacters(characters: text)
        case .fileExtension: return .replaceExtension(extension: text)
        }
    }
}

/// Renames several files by rules, showing exactly what each will become before anything changes. Nothing can be
/// applied while any name is invalid or would clash.
struct BatchRenameView: View {
    let names: [String]
    let others: [String]
    let onApply: (BatchRenameRule) -> Void
    let onCancel: () -> Void

    @State private var steps: [StepDraft]

    init(names: [String], others: [String], rule: BatchRenameRule, onApply: @escaping (BatchRenameRule) -> Void, onCancel: @escaping () -> Void) {
        self.names = names
        self.others = others
        self.onApply = onApply
        self.onCancel = onCancel
        let drafts = rule.steps.map(StepDraft.init)
        _steps = State(initialValue: drafts.isEmpty ? [StepDraft(kind: .findReplace)] : drafts)
    }

    private var rule: BatchRenameRule { BatchRenameRule(steps: steps.map(\.asStep)) }
    private var plan: [RenamePlanItem] { finderPlanBatchRename(names: names, rule: rule, others: others) }

    var body: some View {
        let current = plan
        let ready = finderRenamePlanReady(plan: current)
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename \(names.count) item\(names.count == 1 ? "" : "s")").font(.title3.bold())
            HStack(alignment: .top, spacing: 16) {
                stepsList.frame(width: 340)
                Divider()
                preview(current)
            }
            HStack {
                Menu {
                    ForEach(StepDraft.Kind.allCases) { kind in Button(kind.rawValue) { withAnimation(.smooth) { steps.append(StepDraft(kind: kind)) } } }
                } label: { Label("Add Step", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Text(summary(current)).font(.callout).foregroundStyle(ready ? Color.secondary : Theme.danger)
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Rename") { onApply(rule) }.keyboardShortcut(.defaultAction).disabled(!ready)
            }
        }
        .padding(20)
        .frame(width: 880, height: 540)
    }

    private func summary(_ plan: [RenamePlanItem]) -> String {
        let problems = plan.filter { $0.problem != nil }.count
        if problems > 0 { return "\(problems) problem\(problems == 1 ? "" : "s"): fix them to continue" }
        let changed = plan.filter { !$0.unchanged }.count
        return changed == 0 ? "Nothing would change" : "\(changed) will be renamed"
    }

    private var stepsList: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach($steps) { $step in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker("", selection: $step.kind) { ForEach(StepDraft.Kind.allCases) { Text($0.rawValue).tag($0) } }
                                .labelsHidden()
                            Button(role: .destructive) { withAnimation(.smooth) { steps.removeAll { $0.id == step.id } } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete")
                                .buttonStyle(.borderless)
                        }
                        fields(for: $step)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @ViewBuilder
    private func fields(for step: Binding<StepDraft>) -> some View {
        switch step.wrappedValue.kind {
        case .findReplace:
            TextField("Find", text: step.text)
            TextField("Replace with", text: step.replacement)
            Toggle("Match case", isOn: step.caseSensitive)
        case .prefix: TextField("Text", text: step.text)
        case .suffix: TextField("Text", text: step.text)
        case .number:
            Stepper("Start at \(step.wrappedValue.start)", value: step.start, in: -9999...999_999)
            Stepper("Count by \(step.wrappedValue.step)", value: step.step, in: -999...999)
            Stepper("Digits: \(step.wrappedValue.digits)", value: step.digits, in: 1...8)
            Picker("Put it", selection: step.atStart) { Text("After the name").tag(false); Text("Before the name").tag(true) }
            TextField("Separator", text: step.separator)
        case .changeCase:
            Picker("To", selection: step.caseMode) {
                Text("lower case").tag(CaseMode.lower); Text("UPPER CASE").tag(CaseMode.upper); Text("Title Case").tag(CaseMode.title)
            }
        case .trim: Text("Removes spaces at the start and end of each name.").font(.caption).foregroundStyle(.secondary)
        case .remove: TextField("Characters to remove", text: step.text)
        case .fileExtension: TextField("New extension, such as md", text: step.text)
        }
    }

    private func preview(_ plan: [RenamePlanItem]) -> some View {
        List(Array(plan.enumerated()), id: \.offset) { _, item in
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(item.from).foregroundStyle(item.unchanged ? .secondary : .primary).lineLimit(1)
                    if !item.unchanged {
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(item.to).foregroundStyle(item.problem == nil ? Theme.accent : Theme.danger).lineLimit(1)
                    }
                }
                if let problem = item.problem { Text(problem).font(.caption).foregroundStyle(Theme.danger) }
            }
        }
        .listStyle(.plain)
        .animation(.smooth(duration: 0.2), value: plan.map(\.to))
    }
}

/// Opens the batch rename window and keeps it alive until it is closed.
final class BatchRenameWindow {
    private var window: NSWindow?

    func present(names: [String], others: [String], rule: BatchRenameRule, apply: @escaping (BatchRenameRule) -> Void) {
        let close: () -> Void = { [weak self] in self?.window?.close(); self?.window = nil }
        let view = BatchRenameView(names: names, others: others, rule: rule, onApply: { rule in close(); apply(rule) }, onCancel: close)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 540), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Batch Rename"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
