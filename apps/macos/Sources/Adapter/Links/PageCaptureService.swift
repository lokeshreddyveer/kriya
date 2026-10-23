import AppKit

/// Takes a page that a browser extension left in the inbox and saves it, copies it, puts it on the shelf or makes a PDF. The page
/// was read in the browser, from the tab you chose it in; nothing here reaches the network.
final class PageCaptureService {
    private let support: URL
    private let shelf: FileShelf
    private let toast = Toast()

    /// Where Markdown and PDF files go. Replaced in tests.
    var folder: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Kriya Pages", isDirectory: true)

    init(support: URL, shelf: FileShelf) {
        self.support = support
        self.shelf = shelf
    }

    var inbox: URL { support.appendingPathComponent("Inbox", isDirectory: true) }

    /// Reads and removes the inbox file, then does the action. Anything unexpected is dropped with a message.
    func handle(file: String, action: PageAction) {
        guard PageCapture.isInboxName(file) else { return }
        let url = inbox.appendingPathComponent(file)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), data.count <= PageCapture.maxMessageBytes,
              let clip = try? JSONDecoder().decode(PageClip.self, from: data) else {
            toast.show("Kriya could not read that page.", isError: true)
            return
        }
        perform(action, on: clip)
    }

    func perform(_ action: PageAction, on clip: PageClip) {
        let markdown = PageCapture.document(for: clip)
        switch action {
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
            toast.show("Copied “\(clip.title.prefix(40))” as Markdown")
        case .markdown:
            if let url = write(Data(markdown.utf8), stem: PageCapture.fileStem(for: clip.title), ext: "md") {
                toast.show("Saved \(url.lastPathComponent) in Kriya Pages")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .summarize, .ask:
            PageAI.run(action, on: clip)
        case .shelf:
            if let url = write(Data(markdown.utf8), stem: PageCapture.fileStem(for: clip.title), ext: "md") {
                shelf.add(file: url)
                toast.show("Put “\(clip.title.prefix(40))” on the shelf")
            }
        case .pdf:
            guard let pdf = Self.pdf(html: PageMarkdown.html(markdown, title: clip.title)) else {
                toast.show("The PDF could not be made.", isError: true)
                return
            }
            if let url = write(pdf, stem: PageCapture.fileStem(for: clip.title), ext: "pdf") {
                toast.show("Saved \(url.lastPathComponent) in Kriya Pages")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private func write(_ data: Data, stem: String, ext: String) -> URL? {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let name = finderUniqueName(candidate: "\(stem).\(ext)", existing: (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            let url = folder.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            toast.show("The page could not be saved in Kriya Pages.", isError: true)
            return nil
        }
    }

    /// A paginated PDF of the page, laid out as text. Runs on the main thread.
    static func pdf(html: String) -> Data? {
        guard let source = html.data(using: .utf8),
              let text = try? NSAttributedString(data: source, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil),
              let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { return nil }
        info.leftMargin = 54; info.rightMargin = 54; info.topMargin = 54; info.bottomMargin = 54
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.textContainerInset = .zero
        view.textStorage?.setAttributedString(text)
        view.isVerticallyResizable = true
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        if let container = view.textContainer {
            view.layoutManager?.ensureLayout(for: container)
            let used = view.layoutManager?.usedRect(for: container).height ?? 100
            view.frame = NSRect(x: 0, y: 0, width: width, height: max(used, 100))
        }
        let output = NSMutableData()
        let operation = NSPrintOperation.pdfOperation(with: view, inside: view.bounds, to: output, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        return operation.run() ? output as Data : nil
    }
}
