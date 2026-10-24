import AppKit
import SwiftUI

/// How the capture modes behave: the selector, the self-timer, full-screen and window captures, scrolling captures, saved areas.
struct CaptureModesSection: View {
    @ObservedObject var capture: ScreenCaptureService
    @State private var modes = CaptureExtraSettings.modes
    @State private var areaName = ""
    @State private var areaApp = false
    @State private var message: String?

    private func bind<T>(_ path: WritableKeyPath<CaptureModeSettings, T>) -> Binding<T> {
        Binding(get: { modes[keyPath: path] }, set: { value in
            modes[keyPath: path] = value
            CaptureExtraSettings.modes = modes
        })
    }

    private var timerChoice: Binding<Int> {
        Binding(get: { modes.timer.seconds }, set: { modes.timer.seconds = SelfTimer.clamped($0); CaptureExtraSettings.modes = modes })
    }

    var body: some View {
        Group {
            Section {
                Toggle("Use macOS's own selection tool instead of Kriya's", isOn: bind(\.useMacOSSelector))
                Picker("Self-timer", selection: timerChoice) {
                    Text("Off").tag(0)
                    ForEach(SelfTimer.presets, id: \.self) { Text("\($0) seconds").tag($0) }
                    if !SelfTimer.presets.contains(modes.timer.seconds), modes.timer.seconds > 0 { Text("\(modes.timer.seconds) seconds").tag(modes.timer.seconds) }
                }
                if modes.timer.isOn {
                    Stepper("Custom: \(modes.timer.seconds) seconds", value: timerChoice, in: 1...SelfTimer.longest)
                }
                Picker("Full screen captures", selection: bind(\.display)) {
                    ForEach(DisplayChoice.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Leave the desktop's icons out", isOn: bind(\.hideDesktopIcons))
                Toggle("Cut the camera notch's strip off the top", isOn: bind(\.cropNotch))
                Picker("Window captures", selection: bind(\.windowLook)) {
                    ForEach(WindowLook.allCases) { Text($0.title).tag($0) }
                }
                Text(modes.windowLook.detail).font(.caption).foregroundStyle(.secondary)
            } header: { Text("How capturing works") } footer: {
                Text("Kriya's selector freezes the screen so what you choose is exactly what you saw: crosshair and magnifier, the size beside the area, edges that snap to the screen and to windows, ⇧ for a fixed shape (R changes the shape), ⌥ to grow from the centre, Space to move the area while dragging, the arrow keys to nudge it (⌥ to resize, ⇧ for ten), ⏎ to capture and ⎋ to cancel. The self-timer counts down on screen with a Cancel, for areas, windows, full screens, menus and recordings. Use macOS's tool if you prefer its look.")
            }

            Section {
                Picker("Direction", selection: bind(\.scrollAxis)) {
                    ForEach(CaptureScrollAxis.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Scrolling", selection: bind(\.scrollMode)) {
                    ForEach(ScrollMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if modes.scrollMode == .automatic {
                    LabeledContent("Each scroll goes") {
                        HStack {
                            Slider(value: bind(\.scrollStep), in: 0.3...0.9, step: 0.05).frame(width: 160)
                            Text("\(Int(modes.scrollStep * 100))% of the area").font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        }
                    }
                }
                Toggle("Take a PDF that is open in a viewer whole, from its file", isOn: bind(\.scrollUsesDocument))
            } header: { Text("Scrolling capture") } footer: {
                Text("Choose the area that scrolls. “Kriya scrolls” moves the page for you, as fast as the page settles: in a browser it asks the browser to scroll (turn on “Allow JavaScript from Apple Events” for this), in apps with a scroll bar it moves the bar, and otherwise it turns the mouse wheel, then tries Page Down and the arrow keys. Keep the mouse still. It joins pictures even when a few pixels change between them (a blinking cursor, an animation), says how sure each join was, and never drops a picture it cannot join: that one starts a new section below a red line. “I scroll” shows the latest picture and lets you capture a position, undo the last one, or keep a picture that does not overlap as a section of its own. A PDF open in a viewer is taken whole from its file. Where scrolling reaches the end, Kriya waits a moment in case more is still loading. Needs Accessibility to press keys.")
            }

            Section {
                if modes.namedAreas.isEmpty { Text("None saved.").font(.callout).foregroundStyle(.secondary) }
                ForEach(modes.namedAreas) { area in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(area.name)
                            Text("\(Int(area.width)) × \(Int(area.height))" + (area.appBundleID.map { " · only in \(AppChoice.name(for: $0))" } ?? "") + (area.valid(for: AreaPicker.currentLayout) == nil ? " · the displays changed" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Capture") { _ = capture.run(command: area.command) }.controlSize(.small)
                        Button(role: .destructive) { capture.deleteNamedArea(id: area.id); modes = CaptureExtraSettings.modes } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).accessibilityLabel("Delete \(area.name)")
                    }
                }
                HStack {
                    TextField("Name for the previous area", text: $areaName)
                    Toggle("Only in the front app", isOn: $areaApp).toggleStyle(.checkbox)
                    Button("Save") {
                        let app = areaApp ? NSWorkspace.shared.frontmostApplication?.bundleIdentifier : nil
                        message = capture.saveNamedArea(areaName, appBundleID: app) ? nil : "Capture an area first, then save it under a name."
                        modes = CaptureExtraSettings.modes
                        if message == nil { areaName = "" }
                    }
                    .disabled(areaName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let message { Text(message).font(.caption).foregroundStyle(Theme.warn) }
            } header: { Text("Saved areas") } footer: {
                Text("Capture an area, then save it under a name. Each saved area is a command (capture.area.…) that can have a shortcut, a mouse button or a hot corner, and is listed in the capture menu. It only applies on the display arrangement it was saved on, and, if you choose, only while one app is in front.")
            }

            Section {
                Toggle("Show the recording time beside the menu-bar icon", isOn: bind(\.showRecordingTimer))
            } header: { Text("Menu-bar icon") } footer: {
                Text("The icon turns red while anything is recording. Set when the icon shows (always, only when there is something to show, or only while recording) under Quick Access.")
            }
        }
        .onAppear { modes = CaptureExtraSettings.modes }
    }
}
