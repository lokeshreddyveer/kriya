import AppKit
import UniformTypeIdentifiers

/// Terminal apps "Open in Terminal" can use. Each opens a new window in the folder when handed it.
enum Terminals {
    static let known: [(id: String, name: String)] = [
        ("com.apple.Terminal", "Terminal"),
        ("com.googlecode.iterm2", "iTerm"),
        ("dev.warp.Warp-Stable", "Warp"),
        ("com.mitchellh.ghostty", "Ghostty"),
        ("net.kovidgoyal.kitty", "kitty"),
        ("org.alacritty", "Alacritty"),
        ("com.github.wez.wezterm", "WezTerm"),
        ("co.zeit.hyper", "Hyper"),
    ]

    static var installed: [(id: String, name: String)] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }
}

/// Folders Kriya will not rename or move, however it is asked: renaming the home folder or a system folder can break the Mac.
enum ProtectedPaths {
    private static let exact: Set<String> = [
        "/", "/Users", "/Applications", "/Library", "/System", "/usr", "/bin", "/sbin", "/private", "/var", "/etc", "/opt", "/Volumes",
    ]

    static func isProtected(_ path: String) -> Bool {
        let clean = (path as NSString).standardizingPath
        if exact.contains(clean) || clean == NSHomeDirectory() { return true }
        return clean.hasPrefix("/System/") || clean.hasPrefix("/usr/") || clean.hasPrefix("/bin/") || clean.hasPrefix("/sbin/")
    }
}

/// A short message at the bottom of the screen that fades by itself.
final class Toast: NSObject {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    @objc private func dismiss() {
        hideWork?.cancel()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 }, completionHandler: { panel.orderOut(nil) })
    }

    func show(_ text: String, isError: Bool = false) {
        DispatchQueue.main.async { [self] in
            hideWork?.cancel()
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 3
            label.preferredMaxLayoutWidth = 420
            let size = label.fittingSize
            let box = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: size.width + 36, height: size.height + 20))
            box.material = .hudWindow
            box.state = .active
            box.wantsLayer = true
            box.layer?.cornerRadius = 12
            if isError { box.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.7).cgColor; box.layer?.borderWidth = 1.5 }
            label.frame = NSRect(x: 18, y: 10, width: size.width, height: size.height)
            box.addSubview(label)
            let click = NSClickGestureRecognizer(target: self, action: #selector(self.dismiss))
            box.addGestureRecognizer(click)

            let panel = self.panel ?? NSPanel(contentRect: box.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            self.panel = panel
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .statusBar
            // A click puts it away at once.
            panel.ignoresMouseEvents = false
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = box
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                panel.setFrame(NSRect(x: frame.midX - box.frame.width / 2, y: frame.minY + 60, width: box.frame.width, height: box.frame.height), display: true)
            }
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
            let work = DispatchWorkItem { [weak panel] in
                guard let panel else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }, completionHandler: { panel.orderOut(nil) })
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 4.5 : 2.2), execute: work)
        }
    }
}

/// What "Copy File Info" puts on the clipboard.
enum FileMetadata {
    static func describe(_ url: URL) -> String {
        let keys: Set<URLResourceKey> = [
            .nameKey, .localizedTypeDescriptionKey, .fileSizeKey, .totalFileSizeKey, .isDirectoryKey,
            .creationDateKey, .contentModificationDateKey, .contentAccessDateKey, .isPackageKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        var lines: [(String, String)] = []
        lines.append(("Name", values?.name ?? url.lastPathComponent))
        lines.append(("Path", url.path))
        if let kind = values?.localizedTypeDescription { lines.append(("Kind", kind)) }
        if values?.isDirectory == true && values?.isPackage != true {
            let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
            lines.append(("Contains", "\(count) item\(count == 1 ? "" : "s")"))
        } else if let size = values?.totalFileSize ?? values?.fileSize {
            lines.append(("Size", "\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) (\(size) bytes)"))
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        if let date = values?.creationDate { lines.append(("Created", formatter.string(from: date))) }
        if let date = values?.contentModificationDate { lines.append(("Modified", formatter.string(from: date))) }
        if let date = values?.contentAccessDate { lines.append(("Last opened", formatter.string(from: date))) }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), let permissions = attributes[.posixPermissions] as? NSNumber {
            lines.append(("Permissions", String(permissions.intValue, radix: 8)))
        }
        if let item = MDItemCreateWithURL(nil, url as CFURL) {
            func attribute(_ name: CFString) -> Any? { MDItemCopyAttribute(item, name) }
            if let w = attribute(kMDItemPixelWidth) as? Int, let h = attribute(kMDItemPixelHeight) as? Int { lines.append(("Dimensions", "\(w) × \(h) pixels")) }
            if let seconds = attribute(kMDItemDurationSeconds) as? Double { lines.append(("Duration", String(format: "%.1f seconds", seconds))) }
            if let from = attribute(kMDItemWhereFroms) as? [String], !from.isEmpty { lines.append(("Where from", from.joined(separator: ", "))) }
        }
        return lines.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }
}

struct FileActionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Lets a running tool be stopped from another thread.
final class CancelToken {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func cancel() {
        lock.lock()
        stopped = true
        let running = process
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }

    fileprivate func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let already = stopped
        lock.unlock()
        if already { process.terminate() }
    }
}

/// A yes-or-no that one thread sets and another reads.
final class SyncFlag {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/// Runs a system tool with an argument list, never through a shell, and reports what it printed on failure.
enum ToolRunner {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], in directory: URL? = nil, environment: [String: String] = [:], timeout: TimeInterval = 600, cancel: CancelToken? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if !environment.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new } }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw FileActionError("Could not start \((executable as NSString).lastPathComponent).") }
        cancel?.attach(process)
        let timedOut = SyncFlag()
        let watchdog = DispatchWorkItem { if process.isRunning { timedOut.value = true; process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cancel?.isCancelled == true { throw FileActionError("Stopped.") }
        if timedOut.value { throw FileActionError("It took too long and was stopped.") }
        if process.terminationStatus != 0 {
            throw FileActionError(output.isEmpty ? "It failed (code \(process.terminationStatus))." : String(output.suffix(300)))
        }
        return output
    }
}

/// Changing a file's format with the tools macOS ships: sips for images, textutil for documents, afconvert for audio and
/// avconvert for video. The original is never replaced; the result is a new file beside it.
struct ConversionTarget: Equatable {
    enum Tool: Equatable {
        case sips(String)
        case textutil(String)
        case afconvert(file: String, data: String)
        case avconvert(preset: String)
    }

    let id: String
    let title: String
    let fileExtension: String
    let tool: Tool
}

enum Converter {
    private static let imageInputs: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"]
    private static let documentInputs: Set<String> = ["txt", "rtf", "rtfd", "html", "htm", "doc", "docx", "odt", "wordml"]
    private static let audioInputs: Set<String> = ["aiff", "aif", "wav", "caf", "m4a", "mp3", "aac", "flac"]
    private static let videoInputs: Set<String> = ["mov", "mp4", "m4v"]

    private static let imageTargets = [
        ConversionTarget(id: "png", title: "PNG image", fileExtension: "png", tool: .sips("png")),
        ConversionTarget(id: "jpeg", title: "JPEG image", fileExtension: "jpg", tool: .sips("jpeg")),
        ConversionTarget(id: "heic", title: "HEIC image", fileExtension: "heic", tool: .sips("heic")),
        ConversionTarget(id: "tiff", title: "TIFF image", fileExtension: "tiff", tool: .sips("tiff")),
        ConversionTarget(id: "gif", title: "GIF image", fileExtension: "gif", tool: .sips("gif")),
        ConversionTarget(id: "bmp", title: "BMP image", fileExtension: "bmp", tool: .sips("bmp")),
        ConversionTarget(id: "pdf", title: "PDF", fileExtension: "pdf", tool: .sips("pdf")),
    ]
    private static let documentTargets = [
        ConversionTarget(id: "txt", title: "Plain text", fileExtension: "txt", tool: .textutil("txt")),
        ConversionTarget(id: "rtf", title: "Rich text (RTF)", fileExtension: "rtf", tool: .textutil("rtf")),
        ConversionTarget(id: "html", title: "HTML", fileExtension: "html", tool: .textutil("html")),
        ConversionTarget(id: "docx", title: "Word document (DOCX)", fileExtension: "docx", tool: .textutil("docx")),
        ConversionTarget(id: "doc", title: "Word 97 document (DOC)", fileExtension: "doc", tool: .textutil("doc")),
        ConversionTarget(id: "odt", title: "OpenDocument text (ODT)", fileExtension: "odt", tool: .textutil("odt")),
    ]
    private static let audioTargets = [
        ConversionTarget(id: "m4a", title: "AAC audio (M4A)", fileExtension: "m4a", tool: .afconvert(file: "m4af", data: "aac")),
        ConversionTarget(id: "wav", title: "WAV audio", fileExtension: "wav", tool: .afconvert(file: "WAVE", data: "LEI16")),
        ConversionTarget(id: "aiff", title: "AIFF audio", fileExtension: "aiff", tool: .afconvert(file: "AIFF", data: "BEI16")),
        ConversionTarget(id: "caf", title: "CAF audio", fileExtension: "caf", tool: .afconvert(file: "caff", data: "LEI16")),
    ]
    private static let videoTargets = [
        ConversionTarget(id: "m4v-1080", title: "Video 1080p (M4V)", fileExtension: "m4v", tool: .avconvert(preset: "PresetAppleM4V1080pHD")),
        ConversionTarget(id: "m4v-720", title: "Video 720p (M4V)", fileExtension: "m4v", tool: .avconvert(preset: "PresetAppleM4V720pHD")),
        ConversionTarget(id: "m4a-audio", title: "Audio only (M4A)", fileExtension: "m4a", tool: .avconvert(preset: "PresetAppleM4A")),
    ]

    private static func canonical(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpg": return "jpeg"
        case "tif": return "tiff"
        case "aif": return "aiff"
        case "htm": return "html"
        case let other: return other
        }
    }

    /// What a file with this extension can be converted to.
    static func targets(forExtension ext: String) -> [ConversionTarget] {
        let lower = ext.lowercased()
        let same = canonical(lower)
        let pool: [ConversionTarget]
        if imageInputs.contains(lower) {
            pool = imageTargets
        } else if lower == "pdf" {
            pool = imageTargets.filter { ["png", "jpeg", "tiff"].contains($0.id) }
        } else if documentInputs.contains(lower) {
            pool = documentTargets
        } else if audioInputs.contains(lower) {
            pool = audioTargets
        } else if videoInputs.contains(lower) {
            pool = videoTargets
        } else {
            pool = []
        }
        return pool.filter { canonical($0.fileExtension) != same }
    }

    static func target(id: String) -> ConversionTarget? {
        (imageTargets + documentTargets + audioTargets + videoTargets).first { $0.id == id }
    }

    /// The map the Finder menu uses to offer the right formats for the selected files.
    static func menuMap() -> [String: [FinderMenuFile.Named]] {
        let inputs = imageInputs.union(documentInputs).union(audioInputs).union(videoInputs).union(["pdf"])
        return Dictionary(uniqueKeysWithValues: inputs.map { ext in
            (ext, targets(forExtension: ext).map { FinderMenuFile.Named(id: $0.id, title: $0.title) })
        })
    }

    /// Converts `input` into `folder`, under a name that is not already taken. Returns the new file.
    static func convert(_ input: URL, to target: ConversionTarget, into folder: URL) throws -> URL {
        let stem = input.deletingPathExtension().lastPathComponent
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let name = finderUniqueName(candidate: "\(stem).\(target.fileExtension)", existing: existing)
        let output = folder.appendingPathComponent(name)
        switch target.tool {
        case .sips(let format):
            try ToolRunner.run("/usr/bin/sips", ["-s", "format", format, input.path, "--out", output.path])
        case .textutil(let format):
            try ToolRunner.run("/usr/bin/textutil", ["-convert", format, input.path, "-output", output.path])
        case .afconvert(let file, let data):
            try ToolRunner.run("/usr/bin/afconvert", ["-f", file, "-d", data, input.path, output.path])
        case .avconvert(let preset):
            try ToolRunner.run("/usr/bin/avconvert", ["--source", input.path, "--preset", preset, "--output", output.path])
        }
        guard FileManager.default.fileExists(atPath: output.path) else { throw FileActionError("The converter did not produce a file.") }
        return output
    }
}
