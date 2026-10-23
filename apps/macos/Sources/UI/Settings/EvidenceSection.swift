import SwiftUI
import UniformTypeIdentifiers

/// One list of what Kriya has done: actions, AI requests, setting changes and problems, newest first, with a redacted export.
struct UnifiedActivitySection: View {
    @ObservedObject private var audit = AuditLog.shared
    @ObservedObject private var gateway = AIGateway.shared
    @ObservedObject private var activity = FeatureActivity.shared
    @State private var source: ActivityLine.Source?
    @State private var note: String?

    private var lines: [ActivityLine] {
        ActivityFeed.merge(audit: audit.entries, ai: gateway.history, changes: activity.log.changes, failures: activity.log.failures).filter { source == nil || $0.source == source }
    }

    var body: some View {
        Section {
            Picker("Show", selection: $source) {
                Text("Everything").tag(ActivityLine.Source?.none)
                ForEach(ActivityLine.Source.allCases) { Text($0.title).tag(ActivityLine.Source?.some($0)) }
            }
            let shown = lines
            if shown.isEmpty { Text("Nothing yet.").font(.callout).foregroundStyle(.secondary) }
            ForEach(shown.prefix(60)) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line.source.title).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.title).font(.callout)
                        Text(line.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Text(line.at.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
                }
            }
            HStack {
                Button("Export Redacted…") { export(lines) }.disabled(lines.isEmpty)
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ActivityFeed.report(lines), forType: .string); note = "Copied." }.disabled(lines.isEmpty)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Clear Feature Activity", role: .destructive) { activity.clear() }.controlSize(.small)
            }
        } header: { Text("Everything Kriya did, in one list") } footer: {
            Text("Actions Kriya ran, AI requests (sizes only), changes to settings and features that had problems. Nothing you typed, copied or sent is in it. The export removes your name, paths, addresses and keys.")
        }
    }

    private func export(_ lines: [ActivityLine]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Kriya activity.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ActivityFeed.report(lines).write(to: url, atomically: true, encoding: .utf8); note = "Saved \(url.lastPathComponent)." } catch { note = error.localizedDescription }
    }
}

/// For every feature: is it in the source, which tests cover it, and what has been recorded about whether it works on this build.
/// Tests listed are the ones in the repository; whether they passed is only known when someone records it here.
struct EvidenceSection: View {
    @ObservedObject private var evidence = EvidenceStore.shared
    @State private var recording: EvidenceTarget?

    struct EvidenceTarget: Identifiable { let id: String; let title: String }

    private var rows: [(id: String, title: String, tests: [String])] {
        FeatureId.all.map { (id: $0.key, title: $0.title, tests: FeatureRegistry.coreTests[$0.key] ?? []) }
            + FeatureRegistry.extras.map { (id: $0.id, title: $0.title, tests: $0.tests) }
    }

    var body: some View {
        Section {
            ForEach(rows, id: \.id) { item in
                let row = evidence.ledger.row(feature: item.id, testClasses: item.tests, build: SystemInfo.build)
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        Text(item.tests.isEmpty ? "No tests listed" : "\(item.tests.count) test group\(item.tests.count == 1 ? "" : "s"): " + item.tests.prefix(3).joined(separator: ", ") + (item.tests.count > 3 ? "…" : ""))
                            .font(.caption).foregroundStyle(item.tests.isEmpty ? Theme.warn : Color.secondary).lineLimit(2)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        badge("Source", row.inSource ? .current : .none, plain: true)
                        badge("Tests passed", row.tests)
                        badge("Used by hand", row.manual)
                    }
                    Button("Record…") { recording = EvidenceTarget(id: item.id, title: item.title) }.controlSize(.small)
                }
            }
        } header: { Text("What is known to work") } footer: {
            Text("“Source” means the feature is in this build. “Tests passed” and “Used by hand” appear only when you record them for this build; a record from an older build is shown as older. This list does not run anything: run the tests in Xcode, try the feature, then record it.")
        }
        .sheet(item: $recording) { target in EvidenceSheet(target: target) { recording = nil } }
    }

    private func badge(_ title: String, _ status: EvidenceStatus, plain: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: status == .current ? "checkmark.circle.fill" : (status == .none ? "circle.dashed" : "clock.arrow.circlepath"))
                .foregroundStyle(status == .current ? Theme.ok : (status == .none ? Color.secondary : Theme.warn))
            Text(plain ? title : "\(title): \(status.label)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct EvidenceSheet: View {
    let target: EvidenceSection.EvidenceTarget
    let done: () -> Void
    @ObservedObject private var evidence = EvidenceStore.shared
    @State private var testsPassed = false
    @State private var byHand = false
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Record for \(target.title)").font(.headline)
            Text("This is saved on this Mac with build \(SystemInfo.build) and today's date.").font(.callout).foregroundStyle(.secondary)
            Toggle("The tests for it passed in Xcode on this build", isOn: $testsPassed)
            Toggle("I used it on a Mac and it did what it should", isOn: $byHand)
            TextField("Note (optional)", text: $note)
            HStack {
                Button("Forget Records", role: .destructive) { evidence.forget(target.id); done() }
                Spacer()
                Button("Cancel") { done() }.keyboardShortcut(.cancelAction)
                Button("Save") { evidence.record(target.id, testsPassed: testsPassed, byHand: byHand, note: note); done() }.keyboardShortcut(.defaultAction).disabled(!testsPassed && !byHand)
            }
        }
        .padding(18).frame(width: 440)
    }
}
