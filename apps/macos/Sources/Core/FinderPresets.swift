import Foundation

/// A one-click change to an item's Finder tags and comment: "Ready", "Archive", "Clear tags".
struct FinderTagPreset: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    /// Tags to add to what the item has.
    var tags: [String] = []
    /// Written as the Finder comment when set; nil leaves the comment alone.
    var comment: String? = nil
    /// Takes every tag off first.
    var clearsTags = false
}

enum FinderPresets {
    static let maxSets = 20
    static let maxFoldersPerSet = 30

    static let defaultTagPresets: [FinderTagPreset] = [
        FinderTagPreset(id: "tag-review", title: "Mark for Review", tags: ["Review"]),
        FinderTagPreset(id: "tag-ready", title: "Ready", tags: ["Ready"]),
        FinderTagPreset(id: "tag-archive", title: "Archive", tags: ["Archive"]),
        FinderTagPreset(id: "tag-client", title: "Client", tags: ["Client"]),
        FinderTagPreset(id: "tag-personal", title: "Personal", tags: ["Personal"]),
        FinderTagPreset(id: "tag-clear", title: "Remove All Tags", clearsTags: true),
    ]

    // MARK: Destinations

    /// The submenu entries for saved sets: the id is the folder's full path, the title "Set › Folder". Sets and folders without a
    /// name or a full path are left out, and a folder named the same in two sets keeps both.
    static func destinationChoices(_ sets: [FolderSet]) -> [FinderMenuFile.Named] {
        sets.prefix(maxSets).flatMap { set in
            set.paths.prefix(maxFoldersPerSet).filter { $0.hasPrefix("/") }.map { folder in
                FinderMenuFile.Named(id: folder, title: "\(set.name) › \(((folder as NSString).lastPathComponent).isEmpty ? folder : (folder as NSString).lastPathComponent)")
            }
        }
    }

    /// A request names its destination by path, so it is only honoured when the path is one the person saved in a set.
    static func isSavedDestination(_ path: String, in sets: [FolderSet]) -> Bool {
        sets.contains { $0.paths.prefix(maxFoldersPerSet).contains(path) }
    }

    // MARK: Code editors and terminals

    static let ideCatalog: [(id: String, name: String, isTerminal: Bool)] = [
        ("com.microsoft.VSCode", "Visual Studio Code", false), ("com.todesktop.230313mzl4w4u92", "Cursor", false),
        ("com.apple.dt.Xcode", "Xcode", false), ("com.jetbrains.intellij", "IntelliJ IDEA", false),
        ("com.jetbrains.intellij.ce", "IntelliJ IDEA CE", false), ("com.jetbrains.pycharm", "PyCharm", false),
        ("com.jetbrains.pycharm.ce", "PyCharm CE", false), ("com.jetbrains.WebStorm", "WebStorm", false),
        ("com.jetbrains.goland", "GoLand", false), ("com.jetbrains.rustrover", "RustRover", false),
        ("com.jetbrains.CLion", "CLion", false), ("com.google.android.studio", "Android Studio", false),
        ("com.sublimetext.4", "Sublime Text", false), ("com.sublimetext.3", "Sublime Text 3", false),
        ("dev.zed.Zed", "Zed", false), ("com.panic.Nova", "Nova", false), ("com.apple.TextEdit", "TextEdit", false),
        ("com.apple.Terminal", "Terminal", true), ("com.googlecode.iterm2", "iTerm", true), ("dev.warp.Warp-Stable", "Warp", true),
        ("com.mitchellh.ghostty", "Ghostty", true), ("net.kovidgoyal.kitty", "kitty", true),
    ]

    static func isTerminal(_ bundleID: String) -> Bool { ideCatalog.first { $0.id == bundleID }?.isTerminal ?? false }

    // MARK: Copy path formats

    static let pathFormats: [(word: String, title: String, style: PathStyle)] = [
        ("full", "POSIX path", .full), ("shell", "Shell-escaped path", .shellEscaped), ("url", "file:// URL", .fileUrl),
        ("hfs", "HFS path (Macintosh HD:Users:…)", .hfs), ("markdown", "Markdown link", .markdownLink), ("html", "HTML link", .htmlLink),
        ("json", "JSON array", .jsonArray), ("csv", "CSV list", .csvList), ("name", "File name", .name),
        ("stem", "Name without extension", .nameWithoutExtension), ("parent", "Parent folder path", .parent),
    ]

    static func pathFormat(_ word: String) -> PathStyle? { pathFormats.first { $0.word == word }?.style }

    /// A path in the old Mac style, `Macintosh HD:Users:me:file.txt`, from macOS's own conversion so the disk's real name is used.
    static func hfsPath(_ posix: String) -> String {
        let url = URL(fileURLWithPath: posix)
        func name(_ u: URL) -> String? { (try? u.resourceValues(forKeys: [.volumeNameKey]))?.volumeName }
        let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
        let startup = name(URL(fileURLWithPath: "/")) ?? "Macintosh HD"
        return hfs(posix: posix, volumeName: volume.flatMap(name) ?? startup, volumeRoot: volume?.path ?? "/", startupName: startup)
    }

    /// The old-style path from the pieces: `Disk:folder:file`, with a trailing colon for a folder. The startup disk's data volume
    /// (`/System/Volumes/Data`) is the same disk as `/` to a person, so it takes the startup disk's name.
    static func hfs(posix: String, volumeName: String, volumeRoot: String, startupName: String, isFolder: Bool = false) -> String {
        let onStartup = volumeRoot == "/" || volumeRoot == "/System/Volumes/Data"
        var relative = posix
        if !onStartup, posix.hasPrefix(volumeRoot) { relative = String(posix.dropFirst(volumeRoot.count)) }
        let parts = relative.split(separator: "/").map(String.init)
        let disk = onStartup ? startupName : volumeName
        return ([disk] + parts).joined(separator: ":") + (isFolder || parts.isEmpty ? ":" : "")
    }

    /// The text for a path format, converting HFS here and leaving every other format to the shared core.
    static func text(style: PathStyle, paths: [String]) -> String {
        style == .hfs ? paths.map(hfsPath).joined(separator: "\n") : finderPathText(style: style, paths: paths)
    }

    // MARK: Looking at a file

    static let inspections: [(id: String, title: String)] = [
        ("quicklook", "Quick Look"), ("permissions", "Permissions and owner"), ("signature", "Code signature"),
        ("quarantine", "Download warning state"), ("checksum", "SHA-256 checksum"), ("metadata", "Size and dates"),
        ("media", "Image size or audio/video length"), ("spotlight", "Spotlight details"),
    ]

    // MARK: Starter files

    /// More files "New File from Template" can make: data, config and code files.
    static let starterTemplates: [FileTemplate] = {
        func t(_ id: String, _ name: String, _ file: String, _ body: String) -> FileTemplate {
            FileTemplate(id: id, name: name, fileName: file, content: body, sourcePath: nil)
        }
        return [
            t("tpl-json", "JSON file", "untitled.json", "{\n  \n}\n"),
            t("tpl-csv", "CSV file", "untitled.csv", "column1,column2\n"),
            t("tpl-yaml", "YAML file", "untitled.yml", "# \n"),
            t("tpl-python", "Python script", "script.py", "#!/usr/bin/env python3\n\n\ndef main():\n    pass\n\n\nif __name__ == \"__main__\":\n    main()\n"),
            t("tpl-javascript", "JavaScript file", "script.js", "\"use strict\";\n\n"),
            t("tpl-typescript", "TypeScript file", "script.ts", "export {};\n"),
            t("tpl-swift", "Swift file", "main.swift", "import Foundation\n\n"),
            t("tpl-sql", "SQL file", "query.sql", "-- \n"),
            t("tpl-css", "CSS file", "style.css", "/* */\n"),
            t("tpl-markdown-front", "Markdown with front matter", "post.md", "---\ntitle: \ndate: \n---\n\n"),
        ]
    }()

    /// Starter templates not yet in `existing` (matched by id), so adding twice adds nothing.
    static func missingStarters(existing: [String]) -> [FileTemplate] {
        starterTemplates.filter { !existing.contains($0.id) }
    }

    // MARK: Tidy preview

    /// What a tidy-up would do, from the names in the folder: folder name → files that would go in it. Files of an unknown kind stay.
    static func tidyPlan(fileNames: [String], category: (String) -> String?) -> [(folder: String, names: [String])] {
        var plan: [String: [String]] = [:]
        for name in fileNames { if let kind = category(name) { plan[kind, default: []].append(name) } }
        return plan.map { ($0.key, $0.value.sorted()) }.sorted { $0.folder < $1.folder }
    }
}
