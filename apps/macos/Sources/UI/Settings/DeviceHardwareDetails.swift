import SwiftUI

/// What a mouse or trackpad says about itself: who made it, how many buttons it has, what kind of wheel, and how often it reports.
/// Read from the system and never changed; nothing is sent to the device and it is not taken over.
struct DeviceHardwareDetails: View {
    let device: InputDevice
    @EnvironmentObject private var registry: DeviceRegistry
    @State private var open = false
    @State private var compensation = PointerCompensationStore().settings
    @State private var cpiText = ""
    @State private var referenceText = ""

    private var info: DeviceCapabilities? { registry.capabilities[device.id] }

    private func line(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).textSelection(.enabled).multilineTextAlignment(.trailing) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            if let info {
                line("Maker", info.manufacturer ?? "Not given")
                line("Model", info.product ?? device.record.name)
                line("Vendor and product", info.idText)
                if let version = info.versionNumber { line("Version", String(version)) }
                if let serial = info.serial { line("Serial number", serial) }
                line("Connected through", info.transport ?? device.record.transport)
                line("Buttons", info.buttonCount == 0 ? "None listed" : info.highestButton > info.buttonCount ? "\(info.buttonCount) (up to button \(info.highestButton))" : "\(info.buttonCount)")
                line("Wheel", info.wheel.title)
                line("Sideways scrolling", info.hasTilt ? "Yes (a sideways or tilting wheel)" : info.isTouch ? "By touch" : "No")
                line("Reports per second (information only)", rateText(info))
                compensationControls
                HStack {
                    Button(registry.rateStates[device.id] == .measuring ? "Measuring…" : "Measure the Rate") { registry.measurePollingRate(for: device.id) }
                        .controlSize(.small)
                        .disabled(!device.isConnected || registry.rateStates[device.id] == .measuring || info.isTouch)
                    Spacer()
                }
                Text("To measure, move the mouse steadily for four seconds after pressing the button. A trackpad is not measured. What a device lists is what it says about itself; some wireless receivers list more than the mouse has.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(device.isConnected ? "Nothing was read from this device." : "Connect this device to read its details.").font(.callout).foregroundStyle(.secondary)
            }
        } label: {
            Text("Hardware details").font(.callout)
        }
        .animation(.smooth(duration: 0.2), value: open)
        .onChange(of: compensation) { _, value in PointerCompensationStore().settings = value }
        .onAppear {
            cpiText = compensation[device.id].cpi.map(String.init) ?? ""
            referenceText = compensation[device.id].referenceCPI.map(String.init) ?? ""
        }
    }

    /// The best rate known for this device, with where it came from.
    private func rate(_ info: DeviceCapabilities) -> PollingRateInfo {
        var measured: Int?
        if case .measured(let hz)? = registry.rateStates[device.id] { measured = hz }
        return PollingRateInfo.resolve(declaredHz: info.declaredRateHz, measuredHz: measured, connection: device.connection)
    }

    /// Estimated pointer-speed compensation. Everything it uses is typed here; the mouse is never read or changed, and it applies only
    /// when one of Kriya’s pointer-speed presets sets this device’s tracking speed.
    @ViewBuilder private var compensationControls: some View {
        let binding = Binding<DeviceCompensation>(get: { compensation[device.id] }, set: { compensation[device.id] = $0 })
        VStack(alignment: .leading, spacing: 8) {
            Text("Estimated pointer-speed compensation").font(.callout.weight(.semibold))
            Toggle("Match another mouse’s resolution", isOn: Binding(get: { binding.wrappedValue.enabled }, set: { binding.wrappedValue.enabled = $0 }))
            if binding.wrappedValue.enabled {
                LabeledContent("This mouse (CPI)") {
                    TextField("e.g. 1600", text: $cpiText).multilineTextAlignment(.trailing).frame(width: 90)
                        .onSubmit { binding.wrappedValue.cpi = Int(cpiText.trimmingCharacters(in: .whitespaces)) }
                }
                LabeledContent("Match this (CPI)") {
                    TextField("e.g. 800", text: $referenceText).multilineTextAlignment(.trailing).frame(width: 90)
                        .onSubmit { binding.wrappedValue.referenceCPI = Int(referenceText.trimmingCharacters(in: .whitespaces)) }
                }
                if PointerCompensation.result(for: binding.wrappedValue)?.cap ?? .none != .none {
                    Label("The change is held at its limit (\u{00D7}\(PointerCompensation.multiplierRange.lowerBound) to \u{00D7}\(PointerCompensation.multiplierRange.upperBound)), so the match is not complete.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            Text(PointerCompensation.explanation(binding.wrappedValue)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Reset") {
                    compensation[device.id] = DeviceCompensation()
                    cpiText = ""; referenceText = ""
                }.controlSize(.small).disabled(compensation[device.id] == DeviceCompensation())
                Spacer()
            }
            Text(PointerCompensation.label + " It multiplies the tracking speed Kriya sets for this mouse by the number above, and does nothing while the System preset is in use. The polling rate is shown for information only: it changes how often and how finely movement is reported, not how far the pointer goes, and it is not used in this sum.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func rateText(_ info: DeviceCapabilities) -> String {
        switch registry.rateStates[device.id] {
        case .measuring: return "Measuring…"
        case .measured: return "About " + rate(info).text
        case .notEnoughMovement: return "Not enough movement. Try again, moving steadily."
        case nil: return rate(info).text
        }
    }
}
