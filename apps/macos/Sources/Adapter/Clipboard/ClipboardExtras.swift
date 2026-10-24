import AppKit
import Vision

/// The clipboard settings kept as plain preferences. Each has a safe default, so nothing here is on that was not already.
extension NSWindow {
    /// Leaves a pop-up window that shows the person's own content (text, files, notes, results) out of screen sharing and other apps'
    /// screenshots, unless they turned that off. Applied when the window is made, so a change shows on the next one opened.
    func applyPopupPrivacy() { sharingType = ClipExtraSettings.hideWhenSharing ? .none : .readOnly }
}

enum ClipExtraSettings {
    static let hideWhenSharingKey = "clipboard.hideWhenSharing"
    static let ocrImagesKey = "clipboard.ocrImages"
    static let deleteSecretsAfterPasteKey = "clipboard.deleteSecretsAfterPaste"

    /// The quick paste window is left out of screen sharing and screenshots taken by other apps.
    static var hideWhenSharing: Bool { UserDefaults.standard.object(forKey: hideWhenSharingKey) as? Bool ?? true }
    /// Words in copied pictures are read on this Mac so a picture can be found by what it says.
    static var ocrImages: Bool { UserDefaults.standard.object(forKey: ocrImagesKey) as? Bool ?? true }
    /// A secret is removed from the history, and from the clipboard, a moment after it is pasted.
    static var deleteSecretsAfterPaste: Bool { UserDefaults.standard.bool(forKey: deleteSecretsAfterPasteKey) }
}

/// Doing things with a copied picture: converting it, reading its words, reading a QR code. All of it happens on this Mac.
enum ClipImageTools {
    enum Format { case png, jpeg }

    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The picture as PNG or JPEG data (a JPEG has no transparency, so it is flattened onto white).
    static func convert(_ data: Data, to format: Format) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpeg:
            let flat = NSImage(size: rep.size)
            flat.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: rep.size).fill()
            rep.draw(in: NSRect(origin: .zero, size: rep.size))
            flat.unlockFocus()
            guard let tiff = flat.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) else { return nil }
            return out.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
    }

    static func text(in data: Data) -> String? {
        guard let image = cgImage(from: data) else { return nil }
        let text = (try? TextRecognizer().text(in: image)) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// What QR codes in the picture say.
    static func qrPayloads(in data: Data) -> [String] {
        guard let image = cgImage(from: data) else { return [] }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .microQR]
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }
}

/// Reads the words in copied pictures a few at a time in the background, so a screenshot can be found by what is written in it.
enum ClipOCRIndexer {
    private static let queue = DispatchQueue(label: "app.kriya.clipocr", qos: .background)
    private static var running = false

    static func run(store: ClipboardStore, limit: UInt32 = 5) {
        guard ClipExtraSettings.ocrImages else { return }
        queue.async {
            guard !running else { return }
            running = true
            defer { running = false }
            for id in store.imagesWithoutText(limit: limit) {
                // A picture with no words is marked read as well, so it is not looked at again.
                let text = store.blob(id)?.image.flatMap { ClipImageTools.text(in: $0) } ?? ""
                store.addSearchText(id, text)
            }
        }
    }
}

/// Things that go away by themselves: a secret kept for a set time, an item the person set to expire.
final class ClipLifetimes {
    static let shared = ClipLifetimes()
    private let key = "clipboard.expiry.v1"
    private let lock = NSLock()

    private var expiry: ClipExpiry {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ClipExpiry.self, from: $0) } ?? ClipExpiry() }
        set { if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: key) } }
    }

    func schedule(_ id: String, minutes: Int) { lock.lock(); defer { lock.unlock() }; var e = expiry; e.schedule(id, after: Double(minutes) * 60); expiry = e }
    func cancel(_ id: String) { lock.lock(); defer { lock.unlock() }; var e = expiry; e.cancel(id); expiry = e }
    func remaining(_ id: String) -> TimeInterval? { lock.lock(); defer { lock.unlock() }; return expiry.remaining(id) }

    /// Deletes what is due. Returns how many items were removed.
    @discardableResult
    func sweep(store: ClipboardStore) -> Int {
        lock.lock()
        var e = expiry
        let due = e.due()
        e.forget(due)
        expiry = e
        lock.unlock()
        for id in due where store.item(id) != nil { store.delete(id) }
        return due.count
    }
}

/// Pausing the recording for a while.
enum ClipPauseController {
    private static let key = "clipboard.pausedUntil"

    static var until: Date? {
        let t = UserDefaults.standard.double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// `minutes` of 0 pauses until it is turned back on.
    static func pause(store: ClipboardStore, minutes: Int) {
        if let end = ClipPause.resumeAt(minutes: minutes) { UserDefaults.standard.set(end.timeIntervalSince1970, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        store.updateConfig { $0.paused = true }
    }

    static func resume(store: ClipboardStore) {
        UserDefaults.standard.removeObject(forKey: key)
        store.updateConfig { $0.paused = false }
    }

    /// Turns recording back on when a timed pause has run out.
    static func resumeIfDue(store: ClipboardStore) {
        guard store.currentConfig.paused, let end = until, ClipPause.isOver(until: end) else { return }
        resume(store: store)
    }
}

enum ClipboardExtras {
    /// What happens after a copy is recorded: label a secret (how long it is kept is the "Remove sensitive items after" setting),
    /// and read the words in a picture.
    static func afterRecord(_ outcome: ClipRecordOutcome, clip: NewClip, store: ClipboardStore) {
        guard outcome.status == .stored, let id = outcome.id else { return }
        if let kind = clip.text.flatMap(ClipSecrets.classify) { store.labelSecret(id, kind) }
        if clip.image != nil { ClipOCRIndexer.run(store: store) }
    }
}
