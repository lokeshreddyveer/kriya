import AppKit
import SwiftUI

/// The first-run walkthrough: what Kriya does, the permissions it uses, and switching on the Finder extension.
/// Opens by itself on the first launch and any time from the Overview.
final class SetupGuideController: NSObject, NSWindowDelegate {
    private let env: AppEnvironment
    private var window: NSWindow?
    private let finish: () -> Void

    init(env: AppEnvironment, finish: @escaping () -> Void) {
        self.env = env
        self.finish = finish
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        env.config.applyActivationPolicy(forWindowOpen: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .alertPanel
        let root = SetupGuideView(close: { [weak self] in self?.close() }).injecting(env)
        window.contentViewController = NSHostingController(rootView: root)
        window.center()
        window.delegate = self
        return window
    }

    private func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        env.config.settings.hasCompletedOnboarding = true
        env.config.applyActivationPolicy()
        finish()
    }
}

private enum SetupStep: Int, CaseIterable {
    case welcome, permissions, finder, done
}

struct SetupGuideView: View {
    let close: () -> Void

    @State private var step = SetupStep.welcome
    @State private var goingForward = true

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case .welcome: WelcomeStep().transition(slide)
                case .permissions: PermissionsStep().transition(slide)
                case .finder: FinderStep().transition(slide)
                case .done: DoneStep().transition(slide)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            footer
        }
        .frame(width: 560, height: 540)
        .background(.background)
    }

    private var slide: AnyTransition {
        .asymmetric(
            insertion: .move(edge: goingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: goingForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private var footer: some View {
        HStack {
            Button("Back") { move(-1) }
                .opacity(step == .welcome ? 0 : 1)
                .disabled(step == .welcome)
            Spacer()
            HStack(spacing: 7) {
                ForEach(SetupStep.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s == step ? Theme.accent : Color.primary.opacity(0.18))
                        .frame(width: 7, height: 7)
                }
            }
            .animation(.smooth(duration: 0.25), value: step)
            Spacer()
            if step == .done {
                Button("Open Kriya") { close() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button(step == .welcome ? "Get Started" : "Continue") { move(1) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.bar)
    }

    private func move(_ delta: Int) {
        guard let next = SetupStep(rawValue: step.rawValue + delta) else { return }
        goingForward = delta > 0
        withAnimation(.smooth(duration: 0.35)) { step = next }
    }
}

// MARK: Steps

private struct StepLayout<Content: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 8)
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
                .frame(height: 48)
            Text(title).font(.title.weight(.semibold))
            Text(message)
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
            content().padding(.top, 6)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        StepLayout(
            symbol: "cursorarrow.click.2", title: "Welcome to Kriya",
            message: "Mouse and keyboard control, window management, sound, screen capture, Finder actions, a clipboard history, a launcher and more, all from the menu bar."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(FeatureId.all.prefix(6)) { feature in
                    HStack(spacing: 12) {
                        Image(systemName: feature.symbol).frame(width: 22).foregroundStyle(Theme.accent)
                        Text(feature.title)
                        Spacer()
                    }
                }
            }
            .frame(width: 280)
            .padding(16)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct PermissionsStep: View {
    @EnvironmentObject private var permissions: PermissionManager

    private let needed: [Permission] = [.accessibility, .inputMonitoring]

    var body: some View {
        StepLayout(
            symbol: "lock.shield", title: "Allow what Kriya needs",
            message: "macOS keeps these off until you allow them. Kriya records your screen only when you use Screen Capture, and sends nothing away unless you turn on a feature that needs the network. You can skip this and do it later from Permissions."
        ) {
            VStack(spacing: 10) {
                ForEach(needed) { permission in
                    SetupPermissionRow(permission: permission)
                }
            }
            .frame(width: 440)
        }
    }
}

private struct SetupPermissionRow: View {
    let permission: Permission
    @EnvironmentObject private var permissions: PermissionManager

    var body: some View {
        let status = permissions.status(permission)
        HStack(spacing: 12) {
            Image(systemName: permission.symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(status == .granted ? Theme.ok : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.headline)
                Text(permission.reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch status {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok).labelStyle(.titleAndIcon).font(.callout)
            case .notDetermined:
                Button("Allow…") { permissions.request(permission) }
            case .denied, .onDemand:
                Button("Open Settings") { permissions.openSettings(permission) }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.smooth(duration: 0.25), value: status)
    }
}

private struct FinderStep: View {
    var body: some View {
        StepLayout(
            symbol: "contextualmenu.and.cursorarrow", title: "Switch on the Finder extension",
            message: "To add Kriya's actions to Finder's right-click menu, turn on the Kriya extension in System Settings. macOS only lets you do this yourself."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                numbered(1, "Open the extension settings below.")
                numbered(2, "Under Finder, switch on Kriya.")
                numbered(3, "Press Restart Finder so the menu shows up.")
                HStack(spacing: 10) {
                    Button("Open Extension Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") { NSWorkspace.shared.open(url) }
                    }
                    Button("Restart Finder") { restartFinder() }
                }
                .padding(.top, 2)
            }
            .frame(width: 400, alignment: .leading)
        }
    }

    private func numbered(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Theme.accent, in: Circle())
            Text(text)
        }
    }

    private func restartFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        try? process.run()
    }
}

private struct DoneStep: View {
    var body: some View {
        StepLayout(
            symbol: "checkmark.circle", title: "You're set",
            message: "Kriya lives in the menu bar. Click its icon any time to switch features on or off, or open Settings to change how each one works."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                tip("menubar.rectangle", "Menu-bar icon: quick switches for every feature")
                tip("square.grid.2x2", "Overview: turn features on and jump to their settings")
                tip("magnifyingglass", "Search in the sidebar to find any setting")
            }
            .frame(width: 400, alignment: .leading)
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(Theme.accent)
            Text(text).font(.callout)
        }
    }
}
