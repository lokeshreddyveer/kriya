import SwiftUI

/// Hold a side button and drag: the page scrolls, or a drag sideways goes back, forward or to another Space. Off by default, because it
/// takes hold of the mouse button and of the real pointer while the button is down.
struct NavigateDragSection: View {
    @State private var settings = NavigateDragStore().settings

    private let buttons: [(UInt32, String)] = [(2, "Middle button"), (3, "Side button 1"), (4, "Side button 2"), (5, "Button 6")]
    private let keys: [(String, UInt64)] = [("None", 0), ("⌥ Option", KeyModifiers.option), ("⌃ Control", KeyModifiers.control), ("⇧ Shift", KeyModifiers.shift), ("⌘ Command", KeyModifiers.command)]

    private func mapping(_ direction: NavigateDirection) -> Binding<NavigateDragAction> {
        Binding(get: { settings.config.action(for: direction) }, set: { settings.config.mapping[direction] = $0 })
    }

    private func actions(for direction: NavigateDirection) -> [NavigateDragAction] {
        NavigateDragAction.allCases.filter { $0.suits(direction) }
    }

    var body: some View {
        Section {
            Toggle("Click-and-drag navigation", isOn: $settings.enabled)
            if settings.enabled {
                Picker("Button", selection: $settings.config.button) { ForEach(buttons, id: \.0) { Text($0.1).tag($0.0) } }
                Picker("Hold with it", selection: $settings.config.modifier) { ForEach(keys, id: \.1) { Text($0.0).tag($0.1) } }
                ForEach(NavigateDirection.allCases) { direction in
                    Picker("Drag \(direction.rawValue)", selection: mapping(direction)) {
                        ForEach(actions(for: direction)) { Text($0.title).tag($0) }
                    }
                }
                LabeledContent("Distance before it decides") {
                    HStack { Slider(value: $settings.config.threshold, in: NavigateDragConfig.thresholdRange).frame(width: 150); Text("\(Int(settings.config.threshold)) pt").monospacedDigit().frame(width: 54, alignment: .trailing) }
                }
                LabeledContent("Speed") {
                    HStack { Slider(value: $settings.config.speed, in: NavigateDragConfig.speedRange).frame(width: 150); Text(String(format: "%.1f×", settings.config.speed)).monospacedDigit().frame(width: 54, alignment: .trailing) }
                }
                Toggle("Reverse the scroll", isOn: $settings.config.reverseScroll)
                Toggle("Show a pointer while dragging", isOn: $settings.config.showVirtualPointer)
                Toggle("Put the pointer back where the drag began", isOn: $settings.config.returnsToStart)
                LabeledContent("Always let go after") {
                    HStack { Slider(value: $settings.config.maxSeconds, in: NavigateDragConfig.secondsRange).frame(width: 150); Text("\(Int(settings.config.maxSeconds)) s").monospacedDigit().frame(width: 54, alignment: .trailing) }
                }
                ForEach(settings.config.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    Button("Reset These Settings") { settings.config = NavigateDragConfig() }.controlSize(.small)
                    Spacer()
                }
            }
        } header: { Text("Click-and-drag navigation") } footer: {
            Text("While the button is held, the real pointer stays where it was and a small pointer moves with the mouse. Letting go, pressing Escape, waiting out the time limit, sleep, or quitting Kriya all give the pointer back. A press and release with no drag is sent on as an ordinary click. Only the middle and side buttons can be used. Back, forward, Spaces, App Exposé and Show Desktop use macOS’s own shortcuts, which must be on in System Settings › Keyboard › Shortcuts; zoom needs scroll-to-zoom in Accessibility. Scroll-to-rotate is not offered: macOS gives apps no way to send a rotation. A button that Drag to scroll, a gesture or a hold rule already uses is theirs, and this leaves it alone.")
        }
        .onChange(of: settings) { _, value in NavigateDragStore().settings = value }
    }
}
