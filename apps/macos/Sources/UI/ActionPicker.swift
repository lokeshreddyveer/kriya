import AppKit
import SwiftUI

/// A menu of the saved actions, with a way to make a new one on the spot. Used wherever a button, gesture or shortcut
/// needs an action.
struct ActionPicker: View {
    @Binding var actionID: String?
    var allowNone = true
    var noneTitle = "None"

    @EnvironmentObject private var library: ActionLibrary
    @State private var creating = false

    private var current: NamedAction? {
        actionID.flatMap { id in library.actions.first { $0.id == id } }
    }

    var body: some View {
        Menu {
            if allowNone {
                Button(noneTitle) { actionID = nil }
                Divider()
            }
            ForEach(library.actions) { saved in
                Button { actionID = saved.id } label: { Label(saved.name, systemImage: saved.action.symbol) }
            }
            if !library.actions.isEmpty { Divider() }
            Button("New Action…") { creating = true }
        } label: {
            if let current {
                Label(current.name, systemImage: current.action.symbol)
            } else {
                Text(allowNone ? noneTitle : "Choose an action")
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .sheet(isPresented: $creating) {
            ActionEditor(onSaved: { actionID = $0 })
        }
    }
}

/// Choosing an app by its bundle identifier.
enum AppChoice {
    /// Shows the open panel and returns the chosen app's bundle identifier.
    static func choose(prompt: String = "Choose") -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    /// The app's name for showing in a list, or its identifier if it is not installed.
    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url) else { return bundleID }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }
}

/// A labelled slider with its value shown beside it.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    var help: String?

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: $value, in: range)
                    .frame(minWidth: 160)
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let help { Text(help).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

extension MouseStore {
    /// A binding into one part of a preset's settings. Edits show at once and are saved a moment later.
    func binding<T>(_ presetID: String, _ keyPath: WritableKeyPath<MouseSettings, T>) -> Binding<T> {
        Binding(
            get: { (self.preset(presetID)?.settings ?? defaultMouseSettings())[keyPath: keyPath] },
            set: { new in self.update(presetID: presetID) { $0[keyPath: keyPath] = new } }
        )
    }
}
