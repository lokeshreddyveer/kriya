import AppKit

/// Delivering a capture through the pipeline: write it, copy it, upload it, make a link, open the editor, pin it, show its card, remove
/// what was only temporary, always in that order and only the parts that were chosen.
extension ScreenCaptureService {
    /// Hands a screenshot on as the After Capture choices say. `original` is the picture before editing, kept beside the edited one when
    /// that is turned on. Returns once every stage has run.
    @MainActor
    func deliver(_ image: CGImage, settings: CaptureSettings, hidden: Int, original: CGImage? = nil, edited: Bool = false) async {
        let screenshot = screenshotRequest(settings: settings)
        let output = screenshot.delivery.output
        let background = screenshot.delivery.background

        // The picture is written as the output policy says (size), then given the backdrop chosen for screenshots (left out when Shift is
        // held), unless it was styled in the editor. Nothing changes until one of these is chosen.
        var sized = output
        sized.convertToSRGB = false
        // A picture marked up in the editor keeps the size it was edited at.
        if edited { sized.scale = .native }
        let plain = CaptureRenderer.written(image, output: sized, backingScale: screenshot.backingScale)
        var exported = plain
        // The backdrop; and the border from the output settings, on the backdrop when it has none of its own, or alone when there is no
        // backdrop. The border goes in the ring around the picture on a canvas made to hold it, so it is never cut off.
        var style = edited ? nil : screenshot.background(legacy: CaptureExtraSettings.beautify, modifiersNow: .current)
        if !edited, output.border.enabled {
            if var withBackdrop = style {
                if !withBackdrop.borderEnabled { withBackdrop.border = output.border }
                style = withBackdrop
            } else {
                var onlyBorder = CaptureBeautify(background: .none, padding: 0, corners: 0, shadow: false)
                onlyBorder.border = output.border
                style = onlyBorder
            }
        }
        if let style, let styled = CaptureRenderer.beautified(exported, style) { exported = styled }
        // The colour profile last, so the backdrop and the border are converted with the picture.
        if output.convertToSRGB { exported = CaptureRenderer.srgb(exported) }
        // With "export only" the backdrop stays off the card, the pin and the editor: only what leaves Kriya has it.
        let shown = background.exportOnly && !edited ? CaptureRenderer.srgbIfAsked(plain, output: output) : exported

        var steps = deliveryPolicy().steps(for: .screenshot, settings: settings)
        // "Capture an area and copy / save / upload it": what that command asks for, once, whatever the After Capture grid says.
        if let adjust = deliveryAdjustment { adjust(&steps); deliveryAdjustment = nil }
        // A picture just edited is copied and saved, as before; it is not uploaded, pinned or edited again.
        if edited { steps.upload = false; steps.copyLink = false; steps.annotate = false; steps.pin = false }
        // The older "open the editor first" option edits before anything is delivered. Only an editor chosen in After Capture opens last.
        if settings.openEditor { steps.annotate = false }

        let actions = ScreenshotDelivery(service: self, exported: exported, shown: shown, original: original, edited: edited, settings: settings, output: output, hidden: hidden)
        let report = await DeliveryPipeline.run(DeliveryJob(kind: .screenshot, steps: steps, copyNeedsFile: output.clipboard != .image), actions: actions)
        let parts = actions.done + report.messages.filter { !actions.done.contains($0) }
        toast.show(parts.isEmpty ? "Captured, but nothing was chosen to happen to it." : "Captured: " + parts.joined(separator: ", "))
    }

    /// Hands text read from a picture on as the After Capture choices for text say: copied by default, and saved, uploaded or linked when
    /// chosen. Links found in it are offered, never opened.
    @MainActor
    func deliverText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toast.show("No text found in that picture.", isError: true)
            return
        }
        let steps = deliveryPolicy().steps(for: .ocr, settings: settings.settings)
        let actions = TextDelivery(service: self, text: trimmed, folder: settings.settings.folder)
        let report = await DeliveryPipeline.run(DeliveryJob(kind: .ocr, steps: steps), actions: actions)
        let found = OCRLinks.offers(in: trimmed, policy: deliveryPolicy().text, ignored: IgnoredLinkStore().links).count
        var message = steps.copy ? "Copied \(trimmed.count) characters of text" : "Read \(trimmed.count) characters of text"
        message += actions.done.isEmpty ? "" : ", " + actions.done.joined(separator: ", ")
        message += report.messages.isEmpty ? "" : ". " + report.messages.joined(separator: " ")
        if found > 0 { message += ", \(found) link\(found == 1 ? "" : "s") found" }
        toast.show(message)
        // Listed for the person to choose from; never opened by itself.
        if found > 0 { offerLinks(in: trimmed) }
    }
}

extension CaptureRenderer {
    /// The picture in sRGB if the output policy asks for it, otherwise as it is.
    static func srgbIfAsked(_ image: CGImage, output: OutputPolicy) -> CGImage { output.convertToSRGB ? srgb(image) : image }
}

/// What each stage does for a screenshot.
@MainActor
final class ScreenshotDelivery: DeliveryActions {
    private unowned let service: ScreenCaptureService
    /// What is written, copied and uploaded: the picture with its backdrop and profile.
    private let exported: CGImage
    /// What is shown, edited and pinned: the same, unless the backdrop is for export only.
    private let shown: CGImage
    private let original: CGImage?
    private let edited: Bool
    private let settings: CaptureSettings
    private let output: OutputPolicy
    /// What happened, for the message afterwards.
    private(set) var done: [String] = []
    private var uploadDeletedTheFile = false

    init(service: ScreenCaptureService, exported: CGImage, shown: CGImage, original: CGImage?, edited: Bool, settings: CaptureSettings, output: OutputPolicy, hidden: Int) {
        self.service = service; self.exported = exported; self.shown = shown; self.original = original; self.edited = edited
        self.settings = settings; self.output = output
        if hidden > 0 { done.append("\(hidden) private place\(hidden == 1 ? "" : "s") hidden") }
    }

    func saveOutput(permanent: Bool) -> DeliveredFile? {
        guard permanent else {
            guard let url = ClipboardWriter.temporaryFile(png: exported.pngData) else { return nil }
            return DeliveredFile(url: url, isTemporary: true)
        }
        // With "ask for a name", the capture is shown a name to confirm or change first. Choosing not to save only skips the file: the
        // copy, the pin and the card still happen as set.
        var typedName: String?
        if output.askForName {
            let backing = service.screenshotRequest(settings: settings).backingScale
            let suggested = CaptureNaming.stem(pattern: service.settings.settings.namePattern, date: Date(), app: service.frontApp, mode: "capture")
            let ext = CaptureExtraSettings.format.fileExtension
            let output = self.output
            guard let typed = service.askForFileName(suggested, ext, settings.folder, { output.retinaSuffix(for: $0, backingScale: backing) }) else {
                done.append("not saved")
                return nil
            }
            typedName = typed
        }
        guard let name = service.save(exported, to: settings.folder, stem: typedName) else {
            service.toast.show("The capture could not be saved in \(settings.folder.lastPathComponent).", isError: true)
            return nil
        }
        done.append("saved as \(name)")
        if edited, CaptureExtraSettings.keepOriginal, let original, service.save(original, to: settings.folder, original: true, stem: typedName.map { $0 + " original" }) != nil {
            done.append("original kept")
        }
        return DeliveredFile(url: settings.folder.appendingPathComponent(name), isTemporary: false)
    }

    func copy(file: URL?) -> String? {
        if let note = service.copyToClipboard(exported, mode: output.clipboard, savedFile: file) {
            // What was chosen could not be done in full; the message says what was copied instead, or that the clipboard was left alone.
            done.append(note.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
            return nil
        }
        done.append("copied")
        return nil
    }

    func upload(file: URL) async -> UploadResult {
        guard CaptureUploadStore.shared.ready else { return .failed("Uploading is not set up, so nothing was uploaded.") }
        let result = await CaptureOverlay.shared.uploadReturningLink(file)
        if case .uploaded = result {
            done.append("uploaded")
            if CaptureUploadStore.shared.config.deleteLocalAfterUpload, !file.path.contains("kriya-clipboard") {
                try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
                uploadDeletedTheFile = true
            }
        }
        return result
    }

    func copyLink(uploaded: String?, keptFile: URL?) -> String? {
        let kept = keptFile.flatMap { !uploadDeletedTheFile && FileManager.default.fileExists(atPath: $0.path) ? CaptureLinks.fileURL($0.path) : nil }
        let link = uploaded ?? kept
        guard let link else { return nil }
        service.pasteboard.clearContents()
        service.pasteboard.setString(link, forType: .string)
        done.append("link copied")
        return link
    }

    func openEditor() {
        let service = service, settings = settings, shown = shown
        service.showEditor(shown) { finished in
            guard let finished else { return }
            Task { @MainActor in await service.deliver(finished, settings: settings, hidden: 0, original: shown, edited: true) }
        }
    }

    func pin() { PinnedShots.shared.pin(NSImage(cgImage: shown, size: NSSize(width: shown.width, height: shown.height))) }

    func showQuickAccessCard(keptFile: URL?) {
        service.showCard(shown, file: uploadDeletedTheFile ? nil : keptFile, recording: false, settings: settings)
    }

    func removeTemporary(_ files: [URL]) { files.forEach { try? FileManager.default.removeItem(at: $0) } }
}

/// What each stage does for text read from a picture.
@MainActor
final class TextDelivery: DeliveryActions {
    private unowned let service: ScreenCaptureService
    private let text: String
    private let folder: URL
    private(set) var done: [String] = []

    init(service: ScreenCaptureService, text: String, folder: URL) {
        self.service = service; self.text = text; self.folder = folder
    }

    func saveOutput(permanent: Bool) -> DeliveredFile? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "Kriya Text \(formatter.string(from: Date())) \(UUID().uuidString.prefix(4)).txt"
        let directory = permanent ? folder : FileManager.default.temporaryDirectory.appendingPathComponent("kriya-clipboard", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent(name)
            try Data(text.utf8).write(to: url, options: .atomic)
            if permanent { done.append("saved as \(name)") }
            return DeliveredFile(url: url, isTemporary: !permanent)
        } catch {
            return nil
        }
    }

    func copy(file: URL?) -> String? {
        service.pasteboard.clearContents()
        service.pasteboard.setString(text, forType: .string)
        return nil
    }

    func upload(file: URL) async -> UploadResult {
        guard CaptureUploadStore.shared.ready else { return .failed("Uploading is not set up, so nothing was uploaded.") }
        let result = await CaptureOverlay.shared.uploadReturningLink(file, contentType: "text/plain")
        if case .uploaded = result { done.append("uploaded") }
        return result
    }

    func copyLink(uploaded: String?, keptFile: URL?) -> String? {
        guard let link = uploaded ?? keptFile.map({ CaptureLinks.fileURL($0.path) }) else { return nil }
        service.pasteboard.clearContents()
        service.pasteboard.setString(link, forType: .string)
        done.append("link copied")
        return link
    }

    // Text has no editor, no pin and no card.
    func openEditor() {}
    func pin() {}
    func showQuickAccessCard(keptFile: URL?) {}
    func removeTemporary(_ files: [URL]) { files.forEach { try? FileManager.default.removeItem(at: $0) } }
}

/// What each stage does for a recording or a GIF. The file is already in the capture folder, where the recorder wrote it, so it is kept;
/// the picture on its card is a frame (with the backdrop for recording thumbnails, if one is chosen).
@MainActor
final class RecordingDelivery: DeliveryActions {
    private unowned let service: ScreenCaptureService
    private let file: URL
    private let thumbnail: CGImage
    private let settings: CaptureSettings
    private(set) var done: [String] = []

    init(service: ScreenCaptureService, file: URL, thumbnail: CGImage, settings: CaptureSettings) {
        self.service = service; self.file = file; self.thumbnail = thumbnail; self.settings = settings
    }

    func saveOutput(permanent: Bool) -> DeliveredFile? { DeliveredFile(url: file, isTemporary: false) }

    func copy(file: URL?) -> String? {
        guard let file else { return nil }
        service.pasteboard.clearContents()
        service.pasteboard.writeObjects([file as NSURL])
        done.append("copied")
        return nil
    }

    func upload(file: URL) async -> UploadResult {
        guard CaptureUploadStore.shared.ready else { return .failed("Uploading is not set up, so nothing was uploaded.") }
        let result = await CaptureOverlay.shared.uploadReturningLink(file)
        if case .uploaded = result { done.append("uploaded") }
        return result
    }

    func copyLink(uploaded: String?, keptFile: URL?) -> String? {
        guard let link = uploaded ?? keptFile.map({ CaptureLinks.fileURL($0.path) }) else { return nil }
        service.pasteboard.clearContents()
        service.pasteboard.setString(link, forType: .string)
        done.append("link copied")
        return link
    }

    /// For a recording this is the trimmer, not the picture editor.
    func openEditor() { service.trimRecording(file: file) }
    func pin() {}

    func showQuickAccessCard(keptFile: URL?) { service.showCard(thumbnail, file: keptFile ?? file, recording: true, settings: settings) }

    func removeTemporary(_ files: [URL]) {}
}
