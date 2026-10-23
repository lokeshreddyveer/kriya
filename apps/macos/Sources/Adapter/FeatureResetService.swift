import AppKit
import UniformTypeIdentifiers

/// Resetting, exporting and importing the saved settings of one part of Kriya, from any screen. A reset or import keeps what was
/// there first, so it can be undone for a day, and puts it back by itself if Kriya does not restart.
enum FeatureResetService {
    static var undoStore: FeatureResetUndo { FeatureResetUndo(file: AppPaths.live.support.appendingPathComponent("last-reset.plist")) }

    /// Keeps what the area holds, clears it, restarts, and puts it back if the restart does not happen. Returns a message if it could not start.
    @discardableResult
    static func reset(_ area: ResettableArea, onRollback: @escaping (String) -> Void = { _ in }) -> String? {
        let values = FeatureReset.capture(area)
        let undo = undoStore
        do { try undo.save(area: area, values: values) } catch { return "Nothing was reset: the settings could not be kept safe first (\(error.localizedDescription))." }
        AuditLog.shared.record(.setting, "Reset \(area.title)")
        FeatureActivity.shared.changed(area.id, "Reset")
        FeatureReset.reset(area)
        UserDefaults.standard.synchronize()
        SystemInfo.relaunch(arguments: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            FeatureReset.restore(values, to: area)
            undo.clear()
            onRollback("Kriya could not restart, so \(area.title) was put back as it was.")
        }
        return nil
    }

    /// Saves the area's settings to a file the person picks.
    static func export(_ area: ResettableArea) -> String {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Kriya \(area.title) settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return "" }
        do {
            try FeatureReset.exportData(area, build: SystemInfo.build).write(to: url, options: .atomic)
            AuditLog.shared.record(.setting, "Exported \(area.title) settings")
            return "Saved \(url.lastPathComponent)."
        } catch { return "Could not save: \(error.localizedDescription)" }
    }

    /// Reads a file made by `export`, keeps what is there, replaces it, and restarts so the part picks it up.
    static func importSettings(_ area: ResettableArea) -> String {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return "" }
        do {
            let values = try FeatureReset.importValues(data, into: area)
            guard !values.isEmpty else { return "That file holds no settings for \(area.title)." }
            let alert = NSAlert()
            alert.messageText = "Replace the \(area.title) settings?"
            alert.informativeText = "\(values.count) saved setting\(values.count == 1 ? "" : "s") will replace what is there now. What is there now is kept for a day so you can undo this. Kriya restarts."
            alert.addButton(withTitle: "Replace and Restart")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return "" }
            let before = FeatureReset.capture(area)
            try undoStore.save(area: area, values: before)
            FeatureReset.reset(area)
            FeatureReset.restore(values, to: area)
            AuditLog.shared.record(.setting, "Imported \(area.title) settings")
            FeatureActivity.shared.changed(area.id, "Settings imported")
            UserDefaults.standard.synchronize()
            SystemInfo.relaunch(arguments: [])
            return ""
        } catch { return error.localizedDescription }
    }
}
