import Foundation

/// A part of Kriya with its own on/off state or its own place in the settings, listed once so every screen that talks about
/// features (the Overview, permissions, evidence, reset, search) is describing the same set. The eight original features come from
/// `FeatureId`; these are the others.
struct ManagedFeature: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String
    let symbol: String
    /// The settings pane that owns it (`SettingsPane.rawValue`) and the tab inside it.
    let pane: String
    let tab: String?
    /// The system permissions it needs, written for a person.
    let permissions: [String]
    /// Other features it relies on (ids from this registry or `FeatureId.key`).
    let dependsOn: [String]
    /// The reset area (`ResettableArea.id`) that clears its saved settings.
    let resetArea: String?
    /// The test classes in the repository that cover it.
    let tests: [String]
}

enum FeatureRegistry {
    static let extras: [ManagedFeature] = [
        ManagedFeature(id: "launcher", title: "Launcher", summary: "Search apps, files, windows, clipboard, notes and commands from one box.", symbol: "magnifyingglass", pane: "launcher", tab: nil, permissions: [], dependsOn: [], resetArea: "launcher",
                       tests: ["LauncherEngineTests", "LauncherPrefsTests", "LauncherFilterTests", "PaletteLayoutPlacementTests", "LauncherApprovalTests", "FuzzyMatcherTests"]),
        ManagedFeature(id: "midi", title: "MIDI Triggers", summary: "Start workflows and commands from a MIDI pad, key or knob.", symbol: "pianokeys", pane: "automation", tab: "Safety", permissions: [], dependsOn: ["automation"], resetArea: "midi",
                       tests: ["MIDITriggerTests", "MIDIRunningStatusTests"]),
        ManagedFeature(id: "locationAudio", title: "Sound by Place", summary: "Switch the sound output when this Mac arrives somewhere.", symbol: "location.circle", pane: "sound", tab: nil, permissions: ["Location"], dependsOn: [], resetArea: "sound",
                       tests: ["PlaceRuleTests", "PlaceStabilityTests", "PlaceSwitcherTests"]),
        ManagedFeature(id: "extensions", title: "Launcher Extensions", summary: "Signed folders of scripts that add commands to the launcher.", symbol: "puzzlepiece.extension", pane: "launcher", tab: nil, permissions: [], dependsOn: ["launcher"], resetArea: nil,
                       tests: ["ExtensionBundleTests"]),
        ManagedFeature(id: "ddc", title: "Monitor Controls", summary: "Brightness and input of external monitors that accept DDC/CI.", symbol: "display", pane: "displays", tab: "Monitor Controls", permissions: [], dependsOn: [], resetArea: nil,
                       tests: ["DDCTests"]),
        ManagedFeature(id: "finderDrawer", title: "Finder Drawer", summary: "A floating list of Finder's selection and kept files to drag from.", symbol: "tray", pane: "finder", tab: "Setup", permissions: ["Automation"], dependsOn: [], resetArea: nil,
                       tests: ["FinderDrawerListTests"]),
        ManagedFeature(id: "finderWindows", title: "Finder Window History", summary: "Remembers closed Finder windows so they can be reopened.", symbol: "macwindow.on.rectangle", pane: "finder", tab: "Setup", permissions: ["Automation"], dependsOn: [], resetArea: "finder",
                       tests: ["FinderWindowTests", "FolderDestinationsTests"]),
        ManagedFeature(id: "clipboardSync", title: "Clipboard Sync", summary: "Shares snippets and pinned text between your Macs through iCloud Drive, encrypted.", symbol: "icloud", pane: "clipboard", tab: "Settings", permissions: [], dependsOn: ["clipboard"], resetArea: "clipsync",
                       tests: ["ClipSyncTests", "BackupCryptoTests"]),
        ManagedFeature(id: "aiProviders", title: "AI Providers", summary: "On-device and chosen AI providers, with the rules for what may be sent.", symbol: "sparkles", pane: "intelligence", tab: nil, permissions: [], dependsOn: [], resetArea: "ai",
                       tests: ["AIProviderConfigTests", "AIWireTests", "AIPolicyTests", "AIContextTests", "AIToolPolicyTests", "AIGatewayTests", "AIToolEngineTests", "AppleIntelligenceTests"]),
        ManagedFeature(id: "semanticSearch", title: "Search by Meaning", summary: "A local index of notes and other sources, searched by words and by meaning.", symbol: "sparkle.magnifyingglass", pane: "intelligence", tab: nil, permissions: [], dependsOn: ["aiProviders"], resetArea: "ai",
                       tests: ["SemanticSearchTests"]),
        ManagedFeature(id: "mcpServer", title: "Kriya as an MCP Server", summary: "Lets other programs on this Mac use Kriya's tools, with a secret and confirmations.", symbol: "server.rack", pane: "intelligence", tab: nil, permissions: [], dependsOn: ["aiProviders"], resetArea: "ai",
                       tests: ["MCPServerCoreTests", "LoopbackRulesTests", "MCPClientRulesTests", "KriyaToolsTests"]),
        ManagedFeature(id: "safariExtension", title: "Safari Extension", summary: "Send links, pages and selections from Safari to Kriya.", symbol: "safari", pane: "links", tab: "Browsers", permissions: ["Safari extension switched on in Safari"], dependsOn: [], resetArea: nil,
                       tests: ["SafariInboxTests", "BrowserBridgeTests"]),
        ManagedFeature(id: "capture", title: "Screen Capture and Recording", summary: "Screenshots, text from pictures, screen recording, GIFs, the pixel ruler and pinned pictures.", symbol: "camera.viewfinder", pane: "capture", tab: nil, permissions: ["Screen Recording"], dependsOn: [], resetArea: "capture",
                       tests: ["CaptureSettingsTests", "CaptureExtrasTests", "CaptureProfileTests", "ScreenCaptureServiceTests"]),
        ManagedFeature(id: "shelf", title: "File Shelf", summary: "Named shelves for files you are moving around, with expiry reminders and warnings for missing or duplicate files.", symbol: "tray", pane: "shelf", tab: nil, permissions: ["Notifications"], dependsOn: [], resetArea: "shelfreminders",
                       tests: ["ShelfLibraryTests", "ShelfCareTests", "ShelfGroupAndReminderTests"]),
        ManagedFeature(id: "notes", title: "Notes", summary: "Markdown notes with tags, pins, templates, attachments and locked notes.", symbol: "note.text", pane: "notes", tab: nil, permissions: [], dependsOn: [], resetArea: "notes",
                       tests: ["NoteStoreTests", "NoteToolsTests", "NoteVersionTests"]),
        ManagedFeature(id: "powerSaving", title: "Power Saving", summary: "Slows Kriya's own background checks while the Mac is on battery or in Low Power Mode.", symbol: "bolt.circle", pane: "power", tab: nil, permissions: [], dependsOn: [], resetArea: "powersaving",
                       tests: ["PowerSavingTests"]),
    ]

    /// The tests that cover each of the original eight features, by `FeatureId.key`.
    static let coreTests: [String: [String]] = [
        "mouse": ["MouseFeatureTests", "MouseTraceTests", "HoldTrackerTests", "HoldRuleCompilingTests", "AutoScrollTests", "DeviceClassificationTests"],
        "windowManagement": ["WindowManagementTests", "GroupGeometryTests", "LayoutDesignTests", "RestoreDiagnosisTests"],
        "trafficLights": ["TrafficLightTests"],
        "contextMenu": ["FinderActionTests", "FileUndoTests"],
        "selectionBar": ["SelectionBarTests"],
        "clipboard": ["ClipboardTests", "ClipboardRulesTests", "ClipboardLockTests", "ClipboardVaultTests", "EncryptedSnippetExportTests"],
        "keyboard": ["KeyboardAndExpansionTests", "KeyboardHealthTests", "CapsLockMappingTests", "SnippetPreprocessorTests", "ShortcutRegistryTests"],
        "automation": ["AutomationTests", "AutomationFlowTests", "ActionExecutorTests"],
    ]

    /// Titles of the original eight, for lists that only have their keys.
    static let coreTitles: [String: String] = [
        "mouse": "Mouse & Trackpad", "windowManagement": "Window Management", "trafficLights": "Window Buttons", "contextMenu": "Right-Click Menu",
        "selectionBar": "Selection Bar", "clipboard": "Clipboard", "keyboard": "Keyboard & Text Expansion", "automation": "Automation",
    ]

    static func feature(_ id: String) -> ManagedFeature? { extras.first { $0.id == id } }

    /// The titles of every feature that needs a system permission: the original features and the others in this registry.
    static func features(needing permission: Permission) -> [String] {
        let core = FeatureId.all.filter { $0.requiredPermissions.contains(permission) }.map(\.title)
        let more = extras.filter { $0.permissions.contains(permission.title) }.map(\.title)
        return core + more
    }

    /// The features that rely on this one.
    static func dependents(of id: String) -> [ManagedFeature] { extras.filter { $0.dependsOn.contains(id) } }

    /// For each permission, the titles of the features that need it. Original features are passed in because their titles live in `FeatureId`.
    static func permissionMatrix(core: [(title: String, permissions: [String])]) -> [(permission: String, features: [String])] {
        var map: [String: [String]] = [:]
        for item in core { for p in item.permissions { map[p, default: []].append(item.title) } }
        for feature in extras { for p in feature.permissions { map[p, default: []].append(feature.title) } }
        return map.map { (permission: $0.key, features: $0.value.sorted()) }.sorted { $0.permission < $1.permission }
    }

    /// Problems in the registry itself: a dependency on something unknown, a loop of dependencies, or a reset area that does not exist.
    static func problems(coreKeys: Set<String>, resetAreas: Set<String>) -> [String] {
        var out: [String] = []
        let ids = Set(extras.map(\.id))
        if ids.count != extras.count { out.append("two features share an id") }
        for f in extras {
            for d in f.dependsOn where !ids.contains(d) && !coreKeys.contains(d) { out.append("\(f.id) depends on unknown \(d)") }
            if let area = f.resetArea, !resetAreas.contains(area) { out.append("\(f.id) names a reset area that does not exist: \(area)") }
        }
        func reaches(_ from: String, _ target: String, _ seen: inout Set<String>) -> Bool {
            guard seen.insert(from).inserted, let f = feature(from) else { return false }
            return f.dependsOn.contains(target) || f.dependsOn.contains { reaches($0, target, &seen) }
        }
        for f in extras { var seen = Set<String>(); if reaches(f.id, f.id, &seen) { out.append("\(f.id) depends on itself through a loop") } }
        return out
    }
}

// MARK: - What each feature has been doing

/// When each feature was last used, how often it failed, and what the person changed about it lately. Counts and short labels only.
struct FeatureActivityLog: Codable, Equatable {
    struct Change: Codable, Equatable, Identifiable {
        var id = UUID().uuidString
        var feature: String
        var what: String
        var at: Date
    }
    struct Failure: Codable, Equatable {
        var count: Int
        var last: String
        var at: Date
    }

    static let changeLimit = 60
    private(set) var lastUsed: [String: Date] = [:]
    private(set) var failures: [String: Failure] = [:]
    private(set) var changes: [Change] = []

    mutating func used(_ id: String, at date: Date = Date()) { lastUsed[id] = date }

    mutating func failed(_ id: String, _ message: String, at date: Date = Date()) {
        var f = failures[id] ?? Failure(count: 0, last: "", at: date)
        f.count += 1
        f.last = String(SecretRedactor.redact(message).text.prefix(120))
        f.at = date
        failures[id] = f
    }

    mutating func clearFailures(_ id: String) { failures[id] = nil }

    mutating func changed(_ id: String, _ what: String, at date: Date = Date()) {
        changes.insert(Change(feature: id, what: String(what.prefix(80)), at: date), at: 0)
        if changes.count > Self.changeLimit { changes.removeLast(changes.count - Self.changeLimit) }
    }

    func recentChanges(within days: Double = 7, now: Date = Date()) -> [Change] { changes.filter { now.timeIntervalSince($0.at) <= days * 86_400 } }

    mutating func clear() { self = FeatureActivityLog() }
}

// MARK: - Evidence

/// What is known about whether a feature works: that it is in the source, which tests cover it, and what the person recorded.
struct EvidenceRecord: Codable, Equatable {
    var build: String
    var date: Date
    /// The person ran the repository's tests on that build and they passed.
    var testsPassed: Bool
    /// The person used the feature on a Mac and it did what it should.
    var verifiedByHand: Bool
    var note: String
}

enum EvidenceStatus: Equatable {
    case none
    case staleBuild(recorded: String)
    case current

    var label: String {
        switch self {
        case .none: return "Not recorded"
        case .staleBuild(let build): return "Recorded on build \(build)"
        case .current: return "Recorded on this build"
        }
    }
}

struct EvidenceRow: Equatable {
    var feature: String
    var inSource: Bool
    var testClasses: [String]
    var tests: EvidenceStatus
    var manual: EvidenceStatus
}

struct EvidenceLedger: Codable, Equatable {
    private(set) var records: [String: EvidenceRecord] = [:]

    mutating func record(_ id: String, build: String, testsPassed: Bool, verifiedByHand: Bool, note: String, at date: Date = Date()) {
        var r = records[id] ?? EvidenceRecord(build: build, date: date, testsPassed: false, verifiedByHand: false, note: "")
        if r.build != build { r = EvidenceRecord(build: build, date: date, testsPassed: false, verifiedByHand: false, note: "") }
        r.date = date
        r.testsPassed = r.testsPassed || testsPassed
        r.verifiedByHand = r.verifiedByHand || verifiedByHand
        if !note.isEmpty { r.note = String(note.prefix(200)) }
        records[id] = r
    }

    mutating func forget(_ id: String) { records[id] = nil }

    func row(feature id: String, testClasses: [String], build: String) -> EvidenceRow {
        func status(_ ok: (EvidenceRecord) -> Bool) -> EvidenceStatus {
            guard let r = records[id], ok(r) else { return .none }
            return r.build == build ? .current : .staleBuild(recorded: r.build)
        }
        return EvidenceRow(feature: id, inSource: true, testClasses: testClasses, tests: status { $0.testsPassed }, manual: status { $0.verifiedByHand })
    }
}

// MARK: - One list of what happened

struct ActivityLine: Identifiable, Equatable {
    enum Source: String, CaseIterable, Identifiable {
        case action, ai, change, failure
        var id: String { rawValue }
        var title: String {
            switch self {
            case .action: return "Actions"
            case .ai: return "AI"
            case .change: return "Settings changes"
            case .failure: return "Problems"
            }
        }
    }
    var id: String
    var at: Date
    var source: Source
    var title: String
    var detail: String
}

enum ActivityFeed {
    /// The audit log, the AI history, setting changes and failures as one list, newest first. Nothing here holds what was typed,
    /// copied or sent: every line is a label the app wrote itself.
    static func merge(audit: [AuditLog.Entry], ai: [AIActivity], changes: [FeatureActivityLog.Change], failures: [String: FeatureActivityLog.Failure], limit: Int = 300) -> [ActivityLine] {
        var lines: [ActivityLine] = []
        lines += audit.map { ActivityLine(id: "a:" + $0.id, at: $0.at, source: .action, title: $0.kind.title, detail: $0.summary) }
        lines += ai.map {
            ActivityLine(id: "i:" + $0.id, at: $0.at, source: .ai, title: "\($0.feature) · \($0.provider)",
                         detail: "\($0.inputCharacters) characters sent" + ($0.secretsHidden > 0 ? ", \($0.secretsHidden) secrets hidden" : "") + ($0.status == "ok" ? "" : ", \($0.status)"))
        }
        lines += changes.map { ActivityLine(id: "c:" + $0.id, at: $0.at, source: .change, title: title(for: $0.feature), detail: $0.what) }
        lines += failures.map { ActivityLine(id: "f:" + $0.key, at: $0.value.at, source: .failure, title: title(for: $0.key), detail: "\($0.value.count) failure\($0.value.count == 1 ? "" : "s"); last: \($0.value.last)") }
        return Array(lines.sorted { $0.at != $1.at ? $0.at > $1.at : $0.id < $1.id }.prefix(limit))
    }

    static func title(for feature: String) -> String {
        if feature.hasPrefix("permission:") { return "Permission" }
        return FeatureRegistry.feature(feature)?.title ?? FeatureRegistry.coreTitles[feature] ?? ResettableAreaTitles.title(feature) ?? feature
    }

    /// A plain-text report for sharing. Personal details, paths and keys are taken out.
    static func report(_ lines: [ActivityLine]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let text = lines.map { "\(formatter.string(from: $0.at))  [\($0.source.title)]  \($0.title): \($0.detail)" }.joined(separator: "\n")
        return SupportScrubber.scrub(SecretRedactor.redact(text).text)
    }
}

// MARK: - A setting inside a pane

struct SettingsIndexEntry: Identifiable, Equatable {
    let pane: String
    let tab: String?
    let title: String
    let keywords: String
    var id: String { pane + "|" + (tab ?? "") + "|" + title }
}

enum SettingsIndex {
    private static func e(_ pane: String, _ tab: String?, _ title: String, _ keywords: String = "") -> SettingsIndexEntry { SettingsIndexEntry(pane: pane, tab: tab, title: title, keywords: keywords) }

    static let entries: [SettingsIndexEntry] = [
        e("mouse", "Devices", "Mouse devices", "battery reconnect per device preset"), e("mouse", "Presets", "Mouse presets", "scroll speed acceleration direction buttons gestures"),
        e("mouse", "Apps", "Mouse behaviour per app", "profile"), e("mouse", "Drag", "Drag to scroll", "auto-scroll window follows pointer"),
        e("pointer", "Everyday", "Pointer highlight and click rings", "find pointer spotlight"), e("pointer", "Presentation", "Presentation mode", "magnifier screen sharing recording"),
        e("pointer", "Accessibility", "Hide pointer while typing", "idle"), e("pointer", "Advanced", "Saved pointer positions", "app exclusions"),
        e("keyboard", "Shortcuts", "Keyboard shortcuts", "global app-specific hotkey conflict"), e("keyboard", "Keys", "Remap keys", "caps lock hyper tap hold"),
        e("keyboard", "Snippets", "Snippets", "text insert"), e("keyboard", "Expansion", "Text expansion", "placeholders date clipboard cursor password"), e("keyboard", "Launcher", "Launcher shortcut", "command palette hotkey"),
        e("shortcutMap", nil, "Shortcut map and conflicts", "what owns this shortcut order"),
        e("windows", "Snap", "Window snapping shortcuts", "halves thirds quarters sixths maximize"), e("windows", "Triggers", "Window options", "edges drop zones stash todo"),
        e("windows", "Sizes", "Window sizes", "resize"), e("windows", "Layouts", "Saved window layouts", "restore designer diagnostics"), e("windows", "Apps", "Window management exclusions", "apps"),
        e("workspaces", nil, "Workspaces", "app groups focus favourite windows"), e("buttons", nil, "Window buttons", "red yellow green traffic lights"),
        e("displays", "Displays", "Displays and resolution", "refresh dimming arrangement"), e("displays", "Monitor Controls", "Monitor brightness and input (DDC)", "external monitor preset hdmi displayport"),
        e("displays", "Profiles", "Display profiles", "save arrangement"), e("displays", "Hot Corners", "Hot corners", "screen edges"),
        e("finder", "Actions", "Finder actions", "copy move rename compress convert undo recent operations"), e("finder", "Templates", "File and folder templates", "new file"),
        e("finder", "Apps", "Open With and app defaults", "terminal"), e("finder", "Pointer Menu", "Pointer menu", "right-click"),
        e("finder", "Setup", "Finder extension", "drawer window history folder sets open save dialog folders"),
        e("folderRules", nil, "Folder rules", "watch move archive trash dry run undo"),
        e("clipboard", "History", "Clipboard history", "search pin collections"), e("clipboard", "Snippets", "Snippets and encrypted export", "import"),
        e("clipboard", "Privacy", "Clipboard privacy", "excluded apps secrets lock auto-delete"), e("clipboard", "Settings", "Clipboard sync between Macs", "icloud encrypted rules paste stack"),
        e("selection", nil, "Selection bar", "paste bar actions translate rewrite apple intelligence"),
        e("capture", nil, "Screen capture", "region window display ocr redact annotate"), e("capture", nil, "Screen recording", "pause microphone system audio gif webcam keystrokes trim"),
        e("capture", nil, "Previous area capture", "repeat"), e("capture", nil, "Subject cutout", "remove background"),
        e("links", "Rules", "Link routing rules", "browser profile per app tracking parameters"), e("links", "Options", "Link routing options", "fallback browser"),
        e("links", "Browsers", "Browser extensions", "chrome firefox safari native messaging"), e("links", "Log & Test", "Test a link", "log route"),
        e("shelf", nil, "File shelf", "drag named shelves expiry"),
        e("apps", "Installed", "Installed apps", "inventory"), e("apps", "Install", "Install apps with Homebrew", "cask search log stop"), e("apps", "Leftovers", "App leftovers", "uninstall"),
        e("apps", "Updates", "App updates", "check homebrew sparkle history"), e("apps", "Background", "Launch agents and login items", "background"),
        e("launcher", nil, "Launcher placement", "top bottom left right pointer remembered"), e("launcher", nil, "Launcher search sources", "files apps filters history bookmarks"),
        e("launcher", nil, "Quick links", "web search"), e("launcher", nil, "Launcher scripts and API commands", "approvals timeout"), e("launcher", nil, "1Password in the launcher", "password manager cli"),
        e("launcher", nil, "Launcher extensions", "signed bundles trust publisher"), e("launcher", nil, "Files left out of search", "spotlight exclusions"),
        e("intelligence", nil, "AI providers", "openai anthropic gemini ollama lm studio api key keychain byok"), e("intelligence", nil, "Tools the AI can use", "approvals risk mcp"),
        e("intelligence", nil, "MCP server", "loopback secret connect tools"), e("intelligence", nil, "Search by meaning", "embeddings index semantic"), e("intelligence", nil, "AI activity and history", "delete usage budget"),
        e("intelligence", nil, "Apple Intelligence", "on-device summarize rewrite explain web research"),
        e("automation", "Workflows", "Workflows", "triggers variables loops retry templates draft with ai"), e("automation", "History", "Workflow run history", "debugger"),
        e("automation", "Safety", "Automation safety and authorization", "midi triggers revoke"), e("automation", "Safety", "MIDI triggers", "learn pad knob device"),
        e("devices", nil, "Connected devices", "battery input tester"), e("profiles", nil, "App profiles", "per-app"), e("actions", nil, "Saved actions", "reusable commands"),
        e("focus", nil, "Focus sessions", "timer hide quit apps"), e("menuBar", nil, "Menu bar window", "tiles layout theme"), e("system", nil, "System monitor", "cpu memory disk network battery thermal processes"),
        e("diskMap", nil, "Disk map", "treemap largest files storage"), e("sound", nil, "Per-app volume and output", "mixer equalizer"), e("sound", nil, "Sound by place", "location audio output fallback dwell"),
        e("sound", nil, "Sound modes and rules", "meeting presentation bluetooth"), e("sound", nil, "Remember device volumes", "test tone profile export"),
        e("sound", nil, "Dictation", "speech"), e("notes", nil, "Notes", "markdown quick jot"), e("clock", nil, "World clock", "time zones"),
        e("power", nil, "Keep awake", "sleep display assertion"), e("general", nil, "Appearance and text size", "contrast reduce motion login updates"),
        e("general", nil, "Local-only mode", "network offline"), e("permissions", nil, "Permissions", "accessibility input monitoring screen recording automation location bluetooth"),
        e("backup", nil, "Backup and restore", "export import icloud encrypted"), e("diagnostics", "Overview", "Diagnostics", "report safe mode reset one part"),
        e("diagnostics", "Health", "Health checks", "permissions"), e("diagnostics", "Trace", "Event trace", "tap"), e("diagnostics", "Audit", "Activity log", "audit unified evidence"),
        e("about", nil, "About Kriya", "version build commit signature architecture"),
        e("shortcutMap", nil, "Fix This (resolve a shortcut clash)", "conflict wizard keep trigger turn off others suggest free shortcut undo"),
        e("automation", "Workflows", "Version history", "revisions go back restore earlier save"), e("automation", "Safety", "Pause all automation", "emergency stop banner"),
        e("windows", "Window List", "Window list", "search windows thumbnails favorites recent minimized hidden switch go to why shown display"),
        e("windows", "Triggers", "Double-tap a modifier", "option shift control command fn trigger shortcut tap"), e("windows", "Triggers", "When an app opens or comes forward", "layout launch activate place window automatically"),
        e("windows", "Triggers", "Hide the Dock for some apps", "dock autohide per app"), e("windows", "Triggers", "Pointer wrap", "cursor warp wrap edges displays"),
        e("windows", "Triggers", "Control windows from outside", "url terminal applescript shell kriya run window command api"), e("windows", "Snap", "Throw a window to an edge", "quick throw flick edge corner"),
        e("sound", nil, "Quick Configs", "save sound setup restore apply export import shortcut"), e("sound", nil, "Favorite apps in the mixer", "star pin recent apps top"),
        e("sound", nil, "Timed mute", "mute for 30 seconds minutes fade turn down temporary timer"), e("sound", nil, "Audio Unit effects", "plugin plug-in au compressor reverb limiter third-party magic boost preamp balance bypass"),
        e("sound", nil, "Apps left alone", "exclude bypass never touch audio"), e("sound", nil, "Device nicknames and icons", "rename output input latency delay"),
        e("sound", nil, "Sound alerts", "errors problems history"), e("sound", nil, "Menu-bar speaker options", "icon style volume device compact per app icon"),
        e("windows", "Snap", "Reflow the other windows", "tile around snapped window space beside"), e("finder", "Pointer Menu", "Favorite menu items", "app menu option click pin item"),
        e("windows", "Layouts", "Windows that stay put", "lock pin window restore placement"), e("windows", "Layouts", "Spaces", "desktop arrange windows when space changes"),
        e("power", nil, "Power saving", "low power mode battery throttle monitor"), e("apps", "Installed", "Check Signature", "notarization signing developer id gatekeeper"),
        e("launcher", nil, "Check Links", "quicklinks broken url test"), e("capture", nil, "Capture profiles", "quick copy documentation tutorial pointer"),
        e("capture", nil, "Text in pictures", "ocr languages recognition"), e("launcher", nil, "Why was this shown?", "score ranking explain result"),
        e("selection", nil, "Open straight in keyboard mode", "arrows tab return voiceover shortcut twice"), e("folderRules", nil, "Two rules want the same file", "overlap who wins order"),
        e("diskMap", nil, "Likely rebuildable files", "cache build folders trash cleanup suggestions largest duplicates snapshots purgeable full disk access sunburst"), e("notes", nil, "Locked notes and templates", "encrypt keychain pinned attachments"),
    ]

    /// Entries that match every word, best first: a title that starts with the word, then one that contains it, then keywords.
    static func search(_ query: String, in list: [SettingsIndexEntry] = entries, limit: Int = 12) -> [SettingsIndexEntry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let scored: [(SettingsIndexEntry, Int)] = list.compactMap { entry in
            let title = entry.title.lowercased(), keys = entry.keywords.lowercased()
            var score = 0
            for word in words {
                if title.hasPrefix(word) { score += 30 }
                else if title.contains(" " + word) { score += 22 }
                else if title.contains(word) { score += 14 }
                else if keys.contains(word) { score += 6 }
                else { return nil }
            }
            return (entry, score)
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title < $1.0.title }.prefix(limit).map(\.0)
    }
}

// MARK: - Export and import of one part's settings

extension FeatureReset {
    static let exportFormat = "kriya-settings-area"

    private static func tagged(_ value: Any) -> Any? {
        switch value {
        case let d as Data: return ["$data": d.base64EncodedString()]
        case let d as Date: return ["$date": d.timeIntervalSince1970]
        case let s as String: return s
        case let n as NSNumber: return n
        case let a as [Any]: return a.compactMap(tagged)
        case let d as [String: Any]: return d.compactMapValues(tagged)
        default: return nil
        }
    }

    private static func untagged(_ value: Any) -> Any {
        if let d = value as? [String: Any] {
            if d.count == 1, let s = d["$data"] as? String, let data = Data(base64Encoded: s) { return data }
            if d.count == 1, let t = d["$date"] as? Double { return Date(timeIntervalSince1970: t) }
            return d.mapValues(untagged)
        }
        if let a = value as? [Any] { return a.map(untagged) }
        return value
    }

    /// The saved settings of one part as a file. It holds preferences only: no keys, no clipboard text, no files.
    static func exportData(_ area: ResettableArea, build: String, in defaults: UserDefaults = .standard) throws -> Data {
        let values = capture(area, in: defaults).compactMapValues(tagged)
        let object: [String: Any] = ["format": exportFormat, "area": area.id, "build": build, "values": values]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    enum ImportProblem: Error, Equatable, LocalizedError {
        case notOurs, wrongArea(String), tooLarge
        var errorDescription: String? {
            switch self {
            case .notOurs: return "That file is not an exported Kriya settings file."
            case .wrongArea(let id): return "That file holds settings for “\(id)”, a different part."
            case .tooLarge: return "That file is too large."
            }
        }
    }

    /// Reads a file made by `exportData` and returns the values, only for keys that belong to the area. The caller keeps the old values first.
    static func importValues(_ data: Data, into area: ResettableArea) throws -> [String: Any] {
        guard data.count < 2_000_000 else { throw ImportProblem.tooLarge }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["format"] as? String == exportFormat,
              let id = object["area"] as? String, let values = object["values"] as? [String: Any] else { throw ImportProblem.notOurs }
        guard id == area.id else { throw ImportProblem.wrongArea(id) }
        return values.filter { area.keys.contains($0.key) }.mapValues(untagged)
    }
}


enum ResettableAreaTitles {
    static func title(_ id: String) -> String? { FeatureReset.areas.first { $0.id == id }?.title }
}
