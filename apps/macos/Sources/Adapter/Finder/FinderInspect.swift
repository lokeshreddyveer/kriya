import AppKit
import AVFoundation
import ImageIO

/// Read-only looks at the selected items, shown in one window with a Copy button. Nothing here changes a file.
enum FinderInspect {
    static let maxItems = 20

    static func run(_ id: String, urls: [URL]) {
        if id == "quicklook" { DiskTools.quickLook(urls); return }
        guard !urls.isEmpty else { Toast().show("Select the items to look at.", isError: true); return }
        let title = FinderPresets.inspections.first { $0.id == id }?.title ?? "Details"
        let shown = Array(urls.prefix(maxItems))
        DispatchQueue.global(qos: .userInitiated).async {
            var text = shown.map { "\($0.lastPathComponent)\n" + report(id, $0).split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n") }.joined(separator: "\n\n")
            if urls.count > maxItems { text += "\n\n…and \(urls.count - maxItems) more not shown." }
            DispatchQueue.main.async { present(title: title, text: text) }
        }
    }

    static func report(_ id: String, _ url: URL) -> String {
        switch id {
        case "permissions": return permissions(url)
        case "signature": return signature(url)
        case "quarantine": return quarantine(url)
        case "checksum": return (try? FolderTools.checksum(of: url)) ?? "A folder or an unreadable file has no checksum."
        case "metadata": return FileMetadata.describe(url)
        case "media": return media(url)
        case "spotlight": return spotlight(url)
        default: return "Nothing to show."
        }
    }

    static func permissions(_ url: URL) -> String {
        let fm = FileManager.default
        guard let a = try? fm.attributesOfItem(atPath: url.path) else { return "Could not read the permissions." }
        let mode = (a[.posixPermissions] as? Int) ?? 0
        return [
            "Mode: \(String(mode, radix: 8)) (\(FinderInspectText.permissionString(mode)))",
            "Owner: \(a[.ownerAccountName] as? String ?? "?")  Group: \(a[.groupOwnerAccountName] as? String ?? "?")",
            "You can: \([fm.isReadableFile(atPath: url.path) ? "read" : nil, fm.isWritableFile(atPath: url.path) ? "write" : nil, fm.isExecutableFile(atPath: url.path) ? "run" : nil].compactMap { $0 }.joined(separator: ", "))",
        ].joined(separator: "\n")
    }

    static func signature(_ url: URL) -> String {
        func output(_ path: String, _ args: [String]) -> String {
            do { return try ToolRunner.run(path, args, timeout: 20) } catch { return (error as? FileActionError)?.message ?? "\(error)" }
        }
        let codesign = output("/usr/bin/codesign", ["-dv", "--verbose=2", url.path])
        let spctl = output("/usr/sbin/spctl", ["-a", "-vv", url.path])
        let trust = AppTrust.parse(codesign: codesign, spctl: spctl)
        return [trust.title, trust.signer.map { "Signed by \($0)" }, trust.teamID.map { "Team \($0)" }].compactMap { $0 }.joined(separator: "\n")
    }

    static func quarantine(_ url: URL) -> String {
        let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return "No download warning on this item." }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, "com.apple.quarantine", &buffer, size, 0, XATTR_NOFOLLOW) == size,
              let info = QuarantineInfo.parse(String(decoding: buffer, as: UTF8.self)) else { return "It has a download warning that could not be read." }
        var lines = ["Has the download warning.", "Downloaded by: \(info.app.isEmpty ? "an unknown app" : info.app)"]
        if let date = info.date { lines.append("When: \(date.formatted(date: .abbreviated, time: .shortened))") }
        lines.append(info.wasApproved ? "You have already approved opening it." : "macOS will ask before it opens the first time.")
        return lines.joined(separator: "\n")
    }

    static func media(_ url: URL) -> String {
        var lines: [String] = []
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
            lines.append("Image: \(w) × \(h) pixels")
            if let dpi = p[kCGImagePropertyDPIWidth] as? Double { lines.append("Resolution: \(Int(dpi)) dpi") }
        }
        let asset = AVURLAsset(url: url)
        let seconds = asset.duration.seconds
        if seconds.isFinite, seconds > 0 {
            lines.append("Length: \(FinderInspectText.duration(seconds))")
            if let track = asset.tracks(withMediaType: .video).first {
                let size = track.naturalSize
                lines.append("Video: \(Int(size.width)) × \(Int(size.height))")
            }
        }
        return lines.isEmpty ? "Not an image, audio or video file." : lines.joined(separator: "\n")
    }

    static func spotlight(_ url: URL) -> String {
        let names = ["kMDItemKind", "kMDItemContentType", "kMDItemWhereFroms", "kMDItemLastUsedDate", "kMDItemUseCount", "kMDItemFSCreationDate"]
        let args = names.flatMap { ["-name", $0] } + [url.path]
        return ((try? ToolRunner.run("/usr/bin/mdls", args, timeout: 10)) ?? "Spotlight has nothing on this item.").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func present(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.string = text
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Copy")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

/// What an action is about to do, written out so the question before it can show the real list instead of a count.
enum FinderPreview {
    /// Extra lines for the confirmation of the actions that change or replace things; nil when the plain question is enough.
    static func detail(_ item: FinderItem, urls: [URL], folder: URL?) -> String? {
        switch item.kind {
        case .removeQuarantine:
            let marked = urls.filter { getxattr($0.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0 }
            guard !urls.isEmpty else { return nil }
            let inside = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            let note = inside.isEmpty ? "" : "\nFolders also lose the warning on everything inside them."
            return marked.isEmpty ? "None of the selected items has a download warning right now." + note
                : "These have the warning and will lose it:\n" + list(marked.map(\.lastPathComponent)) + note
        case .cleanupFolder:
            let root = urls.first.map { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true ? $0 : $0.deletingLastPathComponent() } ?? folder
            guard let root, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
            let loose = names.filter { !$0.hasPrefix(".") && (try? root.appendingPathComponent($0).resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            let plan = FinderPresets.tidyPlan(fileNames: loose, category: FolderTools.category(for:))
            guard !plan.isEmpty else { return "No loose files of a known kind, so nothing would move." }
            return "These would move into subfolders of “\(root.lastPathComponent)”:\n" + plan.prefix(8).map { "• \($0.folder): \($0.names.count) file\($0.names.count == 1 ? "" : "s") (\($0.names.prefix(3).joined(separator: ", "))\($0.names.count > 3 ? "…" : ""))" }.joined(separator: "\n")
        case .convert(let target):
            guard let id = target, let conversion = Converter.target(id: id) else { return "The new files are made beside the originals; the originals are kept." }
            return "Each file becomes \(conversion.title) and is saved beside the original. The originals are kept."
        default:
            return nil
        }
    }

    private static func list(_ names: [String]) -> String {
        names.prefix(8).map { "• " + $0 }.joined(separator: "\n") + (names.count > 8 ? "\n…and \(names.count - 8) more" : "")
    }
}
