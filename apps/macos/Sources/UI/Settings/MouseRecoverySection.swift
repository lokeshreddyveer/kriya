import SwiftUI

/// The way out when something is wrong with the mouse, and what Kriya can and cannot tell about other mouse tools.
struct MouseRecoverySection: View {
    @EnvironmentObject private var events: EventMonitor
    @EnvironmentObject private var coexistence: CoexistenceMonitor
    @State private var settings = CoexistenceStore().settings

    var body: some View {
        Section {
            HStack {
                Button(events.mouseRulesPaused ? "Resume Mouse Rules" : "Pause Mouse Rules") { events.setMouseRulesPaused(!events.mouseRulesPaused) }
                Spacer()
                Text(events.mouseRulesPaused ? "Paused: clicks, moves and scrolls go straight through." : "On")
                    .font(.callout).foregroundStyle(events.mouseRulesPaused ? .orange : .secondary)
            }
            if events.pausedAutomatically, let reason = events.pauseReason {
                Label("Kriya paused mouse rules by itself. \(reason) Keyboard features were not affected. Press Resume when you are ready.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
        } header: { Text("Pause mouse rules") } footer: {
            Text("Pausing leaves every mouse rule alone at once: button rules, gestures, drag tools, chords, button replacement, scrolling changes and click-and-drag navigation. Kriya clears its own held state and cancels its own scroll gestures; it does not send button presses or releases for you. Keyboard features are not affected. It is also in Kriya’s menu-bar menu (right-click the icon), and “Pause or resume all mouse rules” can be given a shortcut. If macOS switches Kriya’s mouse hold off for being too slow three times in ten seconds, Kriya clears its own held state, pauses mouse rules, and only then switches the hold back on. Only the number of times and when are kept.")
        }

        Section {
            LabeledContent("Scrolling") { Text(coexistence.plan.ownership.title).multilineTextAlignment(.trailing) }
            if !coexistence.plan.ownership.isKnown {
                Label("Which of them is really changing scrolling is not known.", systemImage: "questionmark.circle").font(.callout).foregroundStyle(.secondary)
            }
            if coexistence.statuses.isEmpty {
                Text("No other mouse tool that Kriya knows about is installed or open.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(coexistence.statuses) { status in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status.tool.name).font(.headline)
                        HStack(spacing: 12) {
                            fact("Installed", status.installed ? "yes" : "no")
                            fact("Open", status.running ? "yes" : "no")
                            fact("Accessibility", "cannot be checked")
                            fact("May overlap", status.knownOverlappingConfiguration ? "yes" : "no")
                            fact("Source metadata observed", status.observedSourceMetadata.isEmpty ? "no" : status.observedSourceMetadata.map(\.title).sorted().joined(separator: ", "))
                        }
                        Text(status.summary).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Toggle("Let other tools handle scrolling", isOn: $settings.yieldScrollingToOthers)
            ForEach(coexistence.plan.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(coexistence.plan.observedOverlaps, id: \.self) { name in
                Label("\(name): scroll events naming it as their source were observed while Kriya is also set to change scrolling. This is a hint, not proof that it owns scrolling.", systemImage: "info.circle.fill").font(.callout).foregroundStyle(.orange)
            }
        } header: { Text("Other mouse tools") } footer: {
            Text("Kriya can see which of these tools are installed and open, and whether scroll events name another program as their sender. It cannot see another tool’s settings or whether it has been given Accessibility or Input Monitoring, so an open tool is only a possible overlap. “Source metadata observed” is the only sign that comes from the events themselves: scroll events that Kriya received named that program as their sender. A sender can be missing or wrong, so it is a hint that the tool is active, not proof of who owns scrolling. Mouse tools listen through the same macOS feature, one after another, so what one changes the next receives. With the switch on, Kriya leaves scrolling alone while another tool that handles it is open, as a precaution; clicks, gestures and pointer speed are not touched. Kriya reads only the list of apps and which program sent a scroll event.")
        }
        .onChange(of: settings) { _, value in CoexistenceStore().settings = value }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption)
        }
    }
}
