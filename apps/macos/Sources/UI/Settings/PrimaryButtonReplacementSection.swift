import SwiftUI

/// Replacing what the left and right buttons do. The riskiest setting in Kriya: if it goes wrong the mouse cannot click. So it is off,
/// even when switched on it does nothing until it is confirmed, and there are several ways out that need no click at all.
struct PrimaryButtonReplacementSection: View {
    @EnvironmentObject private var replacement: PrimaryButtonReplacementController
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var crash: CrashGuard
    @State private var settings = PrimaryButtonReplacementStore().settings
    @State private var problem: String?
    @State private var understood = false

    private static let choices: [(String, ReplacementTarget?)] = [
        ("Normal", nil), ("Acts as the left button", .button(0)), ("Acts as the right button", .button(1)), ("Acts as the middle button", .button(2)),
        ("Acts as button 4", .button(3)), ("Acts as button 5", .button(4)), ("Runs an action", .action("")),
    ]

    private func isAction(_ t: ReplacementTarget?) -> Bool { if case .action = t { return true }; return false }

    /// A picker value that treats every "runs an action" as one choice, whatever action it holds.
    private func choice(_ keyPath: WritableKeyPath<PrimaryButtonReplacementConfig, ReplacementTarget?>) -> Binding<ReplacementTarget?> {
        Binding(get: { let t = settings.config[keyPath: keyPath]; return isAction(t) ? .action("") : t },
                set: { new in
                    if isAction(new), isAction(settings.config[keyPath: keyPath]) { return }
                    settings.config[keyPath: keyPath] = new
                })
    }

    private func action(_ keyPath: WritableKeyPath<PrimaryButtonReplacementConfig, ReplacementTarget?>) -> Binding<String?> {
        Binding(get: { if case .action(let id)? = settings.config[keyPath: keyPath], !id.isEmpty { return id }; return nil },
                set: { settings.config[keyPath: keyPath] = .action($0 ?? "") })
    }

    @ViewBuilder private func row(_ title: String, _ keyPath: WritableKeyPath<PrimaryButtonReplacementConfig, ReplacementTarget?>) -> some View {
        Picker(title, selection: choice(keyPath)) {
            ForEach(Self.choices.indices, id: \.self) { Text(Self.choices[$0].0).tag(Self.choices[$0].1) }
        }
        if isAction(settings.config[keyPath: keyPath]) { ActionPicker(actionID: action(keyPath)) }
    }

    private var statusText: String {
        switch replacement.status {
        case .off: return "Not on. Nothing is replaced."
        case .countdown(let confirm, let seconds): return "Press the \(ButtonChord.name(confirm).lowercased()) button within \(seconds) seconds to confirm."
        case .armed: return "On. The buttons are replaced."
        case .paused: return "Paused. Nothing is replaced."
        case .stopped(let why): return why
        }
    }

    var body: some View {
        Section {
            Toggle("Allow replacing the left and right buttons", isOn: $settings.enabled)
            if settings.enabled {
                if !understood {
                    Label("If this goes wrong, the mouse may not be able to click. Before you go on, know the ways out: press Escape three times; choose “Pause Button Replacement” from Kriya’s menu-bar icon (right-click it); or use a keyboard shortcut for “Pause or resume left and right button replacement”. It also turns itself off for Safe Mode, sleep, and a button pressed many times quickly.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                    Toggle("I know how to turn it off without clicking", isOn: $understood)
                } else {
                    row("Left button", \.left)
                    row("Right button", \.right)
                    ForEach(Array(settings.config.issues.enumerated()), id: \.offset) { _, issue in
                        switch issue {
                        case .nothingToReplace:
                            Label("Choose what a button should become.", systemImage: "info.circle").foregroundStyle(.secondary).font(.callout)
                        case .losesPrimaryClick:
                            Label("No button would be left that clicks. Keep the left button, or make the right button act as the left. This cannot be turned on.", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
                        case .losesSecondaryClick:
                            Label("No button would be left that right-clicks, so menus could not be opened with the mouse. A keyboard shortcut still works.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                        }
                    }
                    LabeledContent("Status") { Text(statusText).multilineTextAlignment(.trailing).foregroundStyle(replacement.status == .armed ? .primary : .secondary) }
                    HStack {
                        switch replacement.status {
                        case .armed, .countdown:
                            Button("Pause Now") { replacement.pause() }
                        default:
                            Button("Turn On (5-Second Check)…") { problem = replacement.arm() }
                                .disabled(!settings.config.canArm || !permissions.isGranted(.inputMonitoring) || crash.isSafeMode)
                        }
                        Spacer()
                    }
                    if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
                    if !permissions.isGranted(.inputMonitoring) {
                        Label("Input Monitoring is off, so this cannot run.", systemImage: "lock.fill").font(.callout).foregroundStyle(.secondary)
                    }
                    if crash.isSafeMode {
                        Label("Safe Mode is on, so this is off until Kriya starts normally.", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        } header: { Text("Replace the left and right buttons") } footer: {
            Text("Off by default. After you choose what a button becomes and press Turn On, a window counts down five seconds and names a physical button to press; if you do not press it, nothing changes. It is off again every time Kriya starts, and Safe Mode keeps it off. Escape pressed three times, a button pressed many times quickly, sleep, a locked screen, a change of displays, losing Input Monitoring or losing the mouse hold all turn it off at once, and the menu-bar icon changes while it is on. Replacement acts on the button as the Mac sees it, before Kriya’s other mouse rules, so those rules do not see a replaced button.")
        }
        .onChange(of: settings) { _, value in PrimaryButtonReplacementStore().settings = value }
        .onChange(of: settings.enabled) { _, on in if !on { understood = false; problem = nil } }
    }
}
