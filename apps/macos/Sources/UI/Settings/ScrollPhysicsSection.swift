import SwiftUI

/// Scrolling that behaves like a trackpad: a gesture that begins, changes and ends, then momentum that carries on and stops. Off by
/// default; Kriya's other smooth scrolling is not touched until this is switched on.
struct ScrollPhysicsSection: View {
    @State private var settings = ScrollPhysicsStore().settings

    private let keys: [(String, UInt64)] = [("None", 0), ("⌥ Option", KeyModifiers.option), ("⌃ Control", KeyModifiers.control), ("⇧ Shift", KeyModifiers.shift), ("⌘ Command", KeyModifiers.command)]

    private func keyPicker(_ title: String, _ value: Binding<UInt64>) -> some View {
        Picker(title, selection: value) { ForEach(keys, id: \.1) { Text($0.0).tag($0.1) } }
    }

    var body: some View {
        Section {
            Toggle("Scroll like a trackpad", isOn: $settings.enabled)
            if settings.enabled {
                Picker("Curve", selection: $settings.config.curve) { ForEach(ScrollCurve.allCases) { Text($0.title).tag($0) } }
                LabeledContent("Distance of one notch") {
                    HStack { Slider(value: $settings.config.pixelsPerLine, in: ScrollPhysicsConfig.stepRange).frame(width: 150); Text("\(Int(settings.config.pixelsPerLine)) px").monospacedDigit().frame(width: 54, alignment: .trailing) }
                }
                LabeledContent("Length of the glide") {
                    HStack { Slider(value: $settings.config.glideMs, in: ScrollPhysicsConfig.glideRange).frame(width: 150); Text("\(Int(settings.config.glideMs)) ms").monospacedDigit().frame(width: 62, alignment: .trailing) }
                }
                Toggle("Carry on after the wheel stops (momentum)", isOn: $settings.config.momentum)
                if settings.config.momentum {
                    LabeledContent("Momentum fades over") {
                        HStack { Slider(value: $settings.config.momentumMs, in: ScrollPhysicsConfig.momentumRange).frame(width: 150); Text("\(Int(settings.config.momentumMs)) ms").monospacedDigit().frame(width: 62, alignment: .trailing) }
                    }
                }
                keyPicker("Hold for quick scrolling", $settings.config.quickModifier)
                keyPicker("Hold for precise scrolling", $settings.config.preciseModifier)
                keyPicker("Hold to zoom", $settings.config.zoomModifier)
                Toggle("Reverse up and down", isOn: $settings.config.invertVertical)
                Picker("Sideways", selection: $settings.config.horizontal) { ForEach(HorizontalTransform.allCases) { Text($0.title).tag($0) } }
                HStack {
                    Button("Reset These Settings") { settings.config = ScrollPhysicsConfig() }.controlSize(.small)
                    Spacer()
                }
            }
        } header: { Text("Trackpad-style scrolling") } footer: {
            Text("A turn of a notched wheel becomes a gesture that begins, changes and ends, with momentum after it, drawn once per screen refresh. Clicking stops a glide at once. Quick scrolling takes larger steps; precise scrolling takes small steps and does not carry on. Holding the zoom keys zooms using macOS's own scroll-to-zoom, which must be switched on in System Settings › Accessibility › Zoom. Scroll-to-rotate is not offered: macOS gives apps no way to send a rotation. A trackpad or Magic Mouse is left alone, since it already scrolls this way.")
        }
        .onChange(of: settings) { _, value in ScrollPhysicsStore().settings = value }
    }
}
