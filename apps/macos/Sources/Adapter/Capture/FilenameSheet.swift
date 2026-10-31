import AppKit

/// The question shown after a capture when "Ask for a name" is on: a name to confirm or change, checked as it is typed, and a line that
/// says what the file will be called. Saving or not saving only decides about the file; copying and pinning are not asked about.
enum FilenameSheet {
    /// Returns the name the person typed (without its extension), or nil if they chose not to save. Blocks until they answer; call it on
    /// the main thread.
    static func ask(suggested: String, ext: String, folder: URL, suffix: @escaping (String) -> String) -> String? {
        let existing: (String) -> Bool = { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        let controller = Controller(model: FileNameEntryModel(typed: suggested, ext: ext, existing: existing, suffix: suffix))

        let alert = NSAlert()
        alert.messageText = "Name this capture"
        alert.informativeText = "It will be saved in “\(folder.lastPathComponent)”. Copying and pinning do not depend on this."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.accessoryView = controller.view
        controller.saveButton = alert.buttons.first
        controller.refresh()
        alert.window.initialFirstResponder = controller.field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, controller.model.canSave else { return nil }
        return FileNameEntry.stem(from: controller.model.typed, ext: ext)
    }

    private final class Controller: NSObject, NSTextFieldDelegate {
        var model: FileNameEntryModel
        let field = NSTextField(string: "")
        private let preview = NSTextField(wrappingLabelWithString: "")
        private let note = NSTextField(wrappingLabelWithString: "")
        let view = NSStackView()
        weak var saveButton: NSButton?

        init(model: FileNameEntryModel) {
            self.model = model
            super.init()
            field.stringValue = model.typed
            field.delegate = self
            field.setAccessibilityLabel("File name")
            preview.font = .systemFont(ofSize: 12)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            view.orientation = .vertical
            view.alignment = .leading
            view.spacing = 6
            [field, preview, note].forEach { view.addArrangedSubview($0) }
            field.widthAnchor.constraint(equalToConstant: 340).isActive = true
            preview.preferredMaxLayoutWidth = 340
            note.preferredMaxLayoutWidth = 340
            view.frame = NSRect(x: 0, y: 0, width: 340, height: 84)
        }

        func controlTextDidChange(_ notification: Notification) {
            model.typed = field.stringValue
            refresh()
        }

        /// The preview line, the reason a name cannot be used, and whether Save can be pressed.
        func refresh() {
            let bad = model.problem != nil
            preview.stringValue = model.preview
            preview.textColor = bad ? .systemRed : .labelColor
            note.stringValue = model.note ?? ""
            note.isHidden = model.note == nil
            saveButton?.isEnabled = model.canSave
        }
    }
}
