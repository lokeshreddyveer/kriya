import AppKit

/// Finder tags and comments on files, and the share menu. Tags and comments are kept by macOS with the file itself.
enum FinderMetadata {
    // MARK: Tags

    /// The tag names parsed from what was typed: split at commas and new lines, trimmed, without repeats.
    static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 50 && seen.insert($0.lowercased()).inserted }
            .prefix(20).map { $0 }
    }

    /// The tags to write: those the file has, then the new ones that it does not.
    static func merged(existing: [String], adding new: [String]) -> [String] {
        var result = existing
        for tag in new where !result.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { result.append(tag) }
        return result
    }

    static func tags(of url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    static func addTags(_ names: [String], to urls: [URL]) throws -> FileActionRunner.Outcome {
        var failures: [String] = []
        var changed = 0
        for url in urls {
            var values = URLResourceValues()
            values.tagNames = merged(existing: tags(of: url), adding: names)
            do { var target = url; try target.setResourceValues(values); changed += 1 } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        let message = failures.isEmpty ? "Tagged \(changed) item\(changed == 1 ? "" : "s")" : "Tagged \(changed), \(failures.count) could not be tagged"
        return FileActionRunner.Outcome(message: message, reveal: [], steps: [], failures: failures, isError: changed == 0)
    }

    static func askTags(existing: [String], count: Int) -> [String]? {
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Tags" : "Add Tags to \(count) Items"
        alert.informativeText = count == 1 ? "Type tags separated by commas. Tags it already has are kept." : "Type tags separated by commas. They are added to what each item already has."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = existing.isEmpty ? "Work, Receipts" : "Has: " + existing.joined(separator: ", ")
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let names = parseTags(field.stringValue)
        return names.isEmpty ? nil : names
    }

    // MARK: Comments

    private static let commentAttribute = "com.apple.metadata:kMDItemFinderComment"

    static func comment(of url: URL) -> String {
        url.path.withCString { path in
            let size = getxattr(path, commentAttribute, nil, 0, 0, 0)
            guard size > 0 else { return "" }
            var buffer = [UInt8](repeating: 0, count: size)
            guard getxattr(path, commentAttribute, &buffer, size, 0, 0) == size,
                  let value = try? PropertyListSerialization.propertyList(from: Data(buffer), options: [], format: nil) as? String else { return "" }
            return value
        }
    }

    /// An empty comment removes it.
    static func setComment(_ text: String, on urls: [URL]) throws -> FileActionRunner.Outcome {
        var failures: [String] = []
        var changed = 0
        for url in urls {
            let result: Int32 = url.path.withCString { path in
                if text.isEmpty { return removexattr(path, commentAttribute, 0) }
                guard let data = try? PropertyListSerialization.data(fromPropertyList: text, format: .binary, options: 0) else { return -1 }
                return data.withUnsafeBytes { setxattr(path, commentAttribute, $0.baseAddress, data.count, 0, 0) }
            }
            if result == 0 || (text.isEmpty && errno == ENOATTR) { changed += 1 } else { failures.append("\(url.lastPathComponent): could not write the comment") }
        }
        let message = failures.isEmpty ? (text.isEmpty ? "Removed the comment" : "Commented on \(changed) item\(changed == 1 ? "" : "s")") : "Commented on \(changed), \(failures.count) failed"
        return FileActionRunner.Outcome(message: message, reveal: [], steps: [], failures: failures, isError: changed == 0)
    }

    static func askComment(existing: String, count: Int) -> String? {
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Comment" : "Comment on \(count) Items"
        alert.informativeText = "This replaces the Finder comment. Leave it empty to remove the comment."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = existing
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Sharing

    private static var anchor: NSWindow?

    /// The system share menu for the files, at the pointer.
    static func share(_ urls: [URL]) {
        let pointer = NSEvent.mouseLocation
        let window = NSWindow(contentRect: NSRect(x: pointer.x, y: pointer.y, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .popUpMenu
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        window.contentView = view
        window.orderFrontRegardless()
        anchor = window
        NSSharingServicePicker(items: urls).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            anchor?.orderOut(nil)
            anchor = nil
        }
    }
}
