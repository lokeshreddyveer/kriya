import AppKit
import SwiftUI

extension CodableColor {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent), alpha: Double(ns.alphaComponent))
    }

    var swiftUIColor: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

/// How pinned pictures look: corners, shadow, border, how see-through they start, and a colour behind the picture. Changes reach the
/// pins already on the screen at once, and never move or resize them.
struct PinStyleSection: View {
    @State private var look = CaptureExtraSettings.delivery.pin
    @State private var color = CaptureExtraSettings.delivery.pin.background?.swiftUIColor ?? .white

    var body: some View {
        Section {
            Toggle("Rounded corners", isOn: $look.roundedCorners)
            Toggle("Shadow", isOn: $look.shadow)
            Toggle("Border", isOn: $look.border)
            LabeledContent("Opacity") {
                HStack(spacing: 8) {
                    Slider(value: $look.opacity, in: PinPolicy.opacityRange).frame(width: 160)
                    Text("\(Int((look.opacity * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                }
            }
            Toggle("A colour behind the picture", isOn: Binding(
                get: { look.background != nil },
                set: { look.background = $0 ? CodableColor(color) : nil }
            ))
            if look.background != nil {
                ColorPicker("Colour", selection: Binding(get: { color }, set: { color = $0; look.background = CodableColor($0) }), supportsOpacity: true)
            }
            HStack {
                Button("Pin a Sample") { PinnedShots.shared.pin(Self.sample()) }.controlSize(.small)
                Spacer()
            }
        } header: { Text("Pinned pictures") } footer: {
            Text("How pins look is separate from where they are and how big: dragging or resizing a pin is yours, and changing these settings never moves or resizes one. Opacity is where a pin starts; ⌥-scroll over a pin to change just that one, and a change here puts every pin back to this opacity. The colour shows through any see-through parts of a picture.")
        }
        .onChange(of: look) { _, value in
            var policy = CaptureExtraSettings.delivery
            policy.pin = value.sanitized()
            CaptureExtraSettings.delivery = policy
            PinnedShots.shared.restyle()
        }
    }

    /// A picture with a clear margin, so the colour behind it can be seen.
    private static func sample() -> NSImage {
        NSImage(size: NSSize(width: 240, height: 150), flipped: false) { rect in
            NSColor.systemBlue.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 22, dy: 22), xRadius: 14, yRadius: 14).fill()
            return true
        }
    }
}
