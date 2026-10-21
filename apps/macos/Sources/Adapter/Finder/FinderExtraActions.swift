import AppKit

/// Finder actions that are a few lines each: showing hidden files and opening the folder that holds an item.
enum FinderExtraActions {
    /// Switches Finder between showing and hiding hidden files, and restarts Finder so it takes effect. Returns what to tell the person.
    static func toggleHiddenFiles() -> String {
        let current = (try? ToolRunner.run("/usr/bin/defaults", ["read", "com.apple.finder", "AppleShowAllFiles"])) ?? ""
        let showing = ["1", "true", "yes"].contains(current.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        _ = try? ToolRunner.run("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", showing ? "false" : "true"])
        _ = try? ToolRunner.run("/usr/bin/killall", ["Finder"])
        return showing ? "Hidden files are now hidden" : "Hidden files are now shown"
    }

    /// Opens the folder that holds each item, with the item selected. For the empty space of a folder, opens its parent.
    static func openParentFolders(urls: [URL], folder: URL?) {
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } else if let folder {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }
}
