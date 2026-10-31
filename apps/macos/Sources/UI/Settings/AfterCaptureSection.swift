import SwiftUI

/// What happens after a capture, for each kind of capture on its own: a grid with a column for screenshots, recordings, GIFs and text
/// read from a picture. However they are chosen, the steps always run in the same order.
struct AfterCaptureSection: View {
    @EnvironmentObject private var capture: ScreenCaptureService
    @State private var policy = CaptureExtraSettings.delivery

    private enum Row: CaseIterable {
        case card, copy, save, upload, copyLink, editor, trim, pin

        var title: String {
            switch self {
            case .card: return "Show the Quick Access card"
            case .copy: return "Copy"
            case .save: return "Save"
            case .upload: return "Upload"
            case .copyLink: return "Copy a link"
            case .editor: return "Open the annotate tool"
            case .trim: return "Open the trimmer"
            case .pin: return "Pin to the screen"
            }
        }

        /// Whether this step means anything for the kind of capture. The others are shown as a dash.
        func applies(to kind: CaptureKind) -> Bool {
            switch self {
            case .card: return kind != .ocr
            case .copy, .upload, .copyLink: return true
            case .save: return kind == .screenshot || kind == .ocr
            case .editor, .pin: return kind == .screenshot
            case .trim: return kind == .recording || kind == .gif
            }
        }

        func value(_ s: DeliverySteps) -> Bool {
            switch self {
            case .card: return s.showQuickAccessCard
            case .copy: return s.copy
            case .save: return s.save
            case .upload: return s.upload
            case .copyLink: return s.copyLink
            case .editor: return s.annotate
            case .trim: return s.trim
            case .pin: return s.pin
            }
        }

        func set(_ on: Bool, in s: inout DeliverySteps) {
            switch self {
            case .card: s.showQuickAccessCard = on
            case .copy: s.copy = on
            case .save: s.save = on
            case .upload: s.upload = on
            case .copyLink: s.copyLink = on
            case .editor: s.annotate = on
            case .trim: s.trim = on
            case .pin: s.pin = on
            }
        }
    }

    private let kinds: [CaptureKind] = [.screenshot, .recording, .gif, .ocr]

    private func steps(_ kind: CaptureKind) -> DeliverySteps { policy.steps(for: kind, settings: capture.settings.settings) }

    private func set(_ kind: CaptureKind, _ row: Row, _ on: Bool) {
        var s = steps(kind)
        row.set(on, in: &s)
        let normalized = s.normalized(for: kind)
        switch kind {
        case .screenshot: policy.screenshot = normalized
        case .recording: policy.recording = normalized
        case .gif: policy.gif = normalized
        case .ocr: policy.ocr = normalized
        }
    }

    var body: some View {
        Section {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    ForEach(kinds) { Text($0 == .ocr ? "Text" : $0.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                }
                ForEach(Row.allCases, id: \.title) { row in
                    GridRow {
                        Text(row.title)
                        ForEach(kinds) { kind in
                            if row.applies(to: kind) {
                                Toggle("", isOn: Binding(get: { row.value(steps(kind)) }, set: { set(kind, row, $0) }))
                                    .labelsHidden()
                                    .accessibilityLabel("\(row.title), \(kind.title)")
                                    // A recording and a GIF are always kept in the capture folder, where the recorder writes them.
                                    .disabled((kind == .recording || kind == .gif) && row == .save)
                            } else {
                                Text("–").foregroundStyle(.tertiary).accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
            HStack {
                Button("Use the Older Options") { policy.screenshot = nil; policy.recording = nil; policy.gif = nil; policy.ocr = nil }.controlSize(.small)
                Spacer()
            }
        } header: { Text("After a capture, by kind") } footer: {
            Text("Each kind of capture has its own choices. Whatever is chosen, the steps run in this order: save the output, copy, upload, make a link, open the annotate tool or trimmer, pin, show the card, then remove any file that was only there for the steps. A recording or GIF is always kept in the capture folder. Nothing is chosen until you change it here: until then screenshots follow “Copy”, “Save” and “Open the editor” above, recordings are saved, and text is copied. “Copy a link” puts the link to the uploaded copy on the clipboard, or to the saved file when nothing was uploaded.")
        }
        .onChange(of: policy) { _, value in CaptureExtraSettings.delivery = value }
    }
}
