import XCTest
@testable import Kriya

final class FinderAdditionsTests: XCTestCase {
    private func file(items: [FinderMenuFile.Item], profiles: [FinderMenuFile.Profile]? = nil, extras: FinderMenuFile.Extras? = nil) -> FinderMenuFile {
        FinderMenuFile(token: "t", title: "Kriya", flat: true, items: items, templates: [], folderTemplates: [], favoriteApps: [], conversions: [:], extras: extras, profiles: profiles)
    }
    private func item(_ id: String, submenu: FinderMenuFile.Submenu? = nil) -> FinderMenuFile.Item {
        FinderMenuFile.Item(id: id, title: id, applies: "anything", extensions: [], submenu: submenu)
    }
    private func selection(folder: String?) -> FinderMenuFile.Selection {
        FinderMenuFile.Selection(count: 1, folders: 0, extensions: ["txt"], isBackground: false, folder: folder)
    }

    // MARK: Profiles

    func testAnActionInNoProfileShowsEverywhere() {
        let f = file(items: [item("a")], profiles: [.init(id: "p", name: "Dev", folders: ["/Users/me/code"], itemIDs: ["other"])])
        XCTAssertEqual(f.visibleItems(for: selection(folder: "/anywhere")).map(\.id), ["a"])
    }

    func testAProfileLimitsItsActionsToItsFoldersByWholePathPieces() {
        let f = file(items: [item("ide"), item("plain")], profiles: [.init(id: "p", name: "Dev", folders: ["/Users/me/code"], itemIDs: ["ide"])])
        XCTAssertEqual(f.visibleItems(for: selection(folder: "/Users/me/code")).map(\.id), ["ide", "plain"])
        XCTAssertEqual(f.visibleItems(for: selection(folder: "/Users/me/code/app/src")).map(\.id), ["ide", "plain"])
        XCTAssertEqual(f.visibleItems(for: selection(folder: "/Users/me/codex")).map(\.id), ["plain"], "codex is not inside code")
        XCTAssertEqual(f.visibleItems(for: selection(folder: "/Users/me/Documents")).map(\.id), ["plain"])
        XCTAssertEqual(f.visibleItems(for: selection(folder: nil)).map(\.id), ["plain"], "an unknown place is not a match")
    }

    func testTwoProfilesCombineAndAnEmptyFolderListMeansEverywhere() {
        let both = file(items: [item("x")], profiles: [.init(id: "a", name: "A", folders: ["/a"], itemIDs: ["x"]), .init(id: "b", name: "B", folders: ["/b"], itemIDs: ["x"])])
        XCTAssertFalse(both.visibleItems(for: selection(folder: "/a/1")).isEmpty)
        XCTAssertFalse(both.visibleItems(for: selection(folder: "/b")).isEmpty)
        XCTAssertTrue(both.visibleItems(for: selection(folder: "/c")).isEmpty)
        let everywhere = file(items: [item("x")], profiles: [.init(id: "a", name: "A", folders: [], itemIDs: ["x"])])
        XCTAssertFalse(everywhere.visibleItems(for: selection(folder: "/c")).isEmpty)
    }

    func testBackgroundClicksUseTheProfileToo() {
        let f = file(items: [FinderMenuFile.Item(id: "tidy", title: "t", applies: "folder_background", extensions: [], submenu: nil)],
                     profiles: [.init(id: "p", name: "Downloads", folders: ["/Users/me/Downloads"], itemIDs: ["tidy"])])
        let bg = { (folder: String) in FinderMenuFile.Selection(count: 1, folders: 1, extensions: [], isBackground: true, folder: folder) }
        XCTAssertEqual(f.visibleItems(for: bg("/Users/me/Downloads")).count, 1)
        XCTAssertTrue(f.visibleItems(for: bg("/Users/me/Desktop")).isEmpty)
    }

    // MARK: Submenus and older files

    func testNewSubmenusListTheirChoicesAndEmptyOnesAreHidden() {
        let extras = FinderMenuFile.Extras(pathFormats: [.init(id: "url", title: "URL")], ides: [], folderSets: [.init(id: "/a", title: "Set › a")], quickTags: [], inspections: [.init(id: "metadata", title: "Size")])
        let f = file(items: [item("p", submenu: .pathFormats), item("i", submenu: .ides), item("m", submenu: .folderSetsMove), item("q", submenu: .quickTags), item("s", submenu: .inspect)], extras: extras)
        XCTAssertEqual(f.visibleItems(for: selection(folder: "/x")).map(\.id), ["p", "m", "s"], "no IDE or tag presets, so those entries are left out")
    }

    func testAMenuFileFromAnOlderAppStillReads() throws {
        let old = #"{"version":1,"token":"t","title":"Kriya","flat":true,"items":[],"templates":[],"folderTemplates":[],"favoriteApps":[],"conversions":{}}"#
        let decoded = try JSONDecoder().decode(FinderMenuFile.self, from: Data(old.utf8))
        XCTAssertNil(decoded.extras); XCTAssertNil(decoded.profiles)
        XCTAssertTrue(decoded.profileAllows("anything", folder: nil))
    }

    func testTheStoreWritesNewSubmenusProfilesAndPresets() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let url = world.folder.appendingPathComponent("m.json")
        let store = FinderStore(core: world.core, menuFile: url, defaults: UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!)
        store.setActive(true)
        XCTAssertTrue(store.tagPresets.contains { $0.clearsTags }, "a preset that removes all tags ships")
        store.profiles = [.init(id: "p", name: "Dev", folders: ["/a"], itemIDs: ["x"])]
        store.addSuggested()
        let written = try JSONDecoder().decode(FinderMenuFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(written.profiles?.first?.name, "Dev")
        XCTAssertEqual(written.extras?.pathFormats.count, FinderPresets.pathFormats.count)
        XCTAssertEqual(written.extras?.quickTags.count, store.tagPresets.count)
        for id in ["copy-path-as", "open-in-ide", "move-to-set", "copy-to-set", "quick-tag", "inspect"] {
            XCTAssertNotNil(written.items.first { $0.id == id }?.submenu, "\(id) opens a submenu")
        }
    }

    func testStarterTemplatesAreAddedOnceAndKeepWhatIsThere() throws {
        let world = try TestWorld()
        defer { world.cleanUp() }
        let store = FinderStore(core: world.core, menuFile: world.folder.appendingPathComponent("m.json"), defaults: UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!)
        let before = store.fileTemplates.count
        XCTAssertEqual(store.addStarterTemplates(), FinderPresets.starterTemplates.count)
        XCTAssertEqual(store.fileTemplates.count, before + FinderPresets.starterTemplates.count)
        XCTAssertEqual(store.addStarterTemplates(), 0)
        for name in ["untitled.json", "untitled.csv", "script.py", "main.swift"] { XCTAssertTrue(store.fileTemplates.contains { $0.fileName == name }, name) }
    }

    // MARK: Destinations, formats, presets

    func testDestinationChoicesNameTheSetAndOnlySavedFoldersAreAllowed() {
        let sets = [FolderSet(name: "Client A", paths: ["/Users/me/Clients/A/docs", "relative/skip"]), FolderSet(name: "Client B", paths: ["/Users/me/Clients/B/docs"])]
        let choices = FinderPresets.destinationChoices(sets)
        XCTAssertEqual(choices.map(\.title), ["Client A › docs", "Client B › docs"])
        XCTAssertEqual(choices.map(\.id), ["/Users/me/Clients/A/docs", "/Users/me/Clients/B/docs"])
        XCTAssertTrue(FinderPresets.isSavedDestination("/Users/me/Clients/A/docs", in: sets))
        XCTAssertFalse(FinderPresets.isSavedDestination("/Users/me/Clients/A", in: sets))
        XCTAssertFalse(FinderPresets.isSavedDestination("/etc", in: sets), "a request cannot name a folder that is not in a set")
    }

    func testEveryPathFormatHasAUniqueWordAndWorks() {
        let words = FinderPresets.pathFormats.map(\.word)
        XCTAssertEqual(Set(words).count, words.count)
        for entry in FinderPresets.pathFormats {
            XCTAssertFalse(FinderPresets.text(style: entry.style, paths: ["/Users/me/a b.txt"]).isEmpty, entry.word)
        }
        XCTAssertNil(FinderPresets.pathFormat("nope"))
        XCTAssertEqual(FinderPresets.text(style: .fileUrl, paths: ["/Users/me/a b.txt"]), "file:///Users/me/a%20b.txt")
        XCTAssertEqual(FinderPresets.text(style: .markdownLink, paths: ["/x/a.txt"]), "[a.txt](file:///x/a.txt)")
        XCTAssertEqual(FinderPresets.text(style: .jsonArray, paths: ["/a", "/b"]), "[\"/a\",\"/b\"]")
    }

    func testHFSPathUsesColonsAndTheDisksName() {
        let hfs = FinderPresets.hfsPath(NSTemporaryDirectory())
        XCTAssertTrue(hfs.contains(":"))
        XCTAssertFalse(hfs.hasPrefix("/"), "starts with the disk's name, not a slash")
        XCTAssertFalse(FinderPresets.text(style: .hfs, paths: ["/Users"]).hasPrefix("/"))
    }

    func testHFSPathPiecesJoinWithColonsForEveryKindOfDisk() {
        XCTAssertEqual(FinderPresets.hfs(posix: "/Users/me/a b.txt", volumeName: "Data", volumeRoot: "/System/Volumes/Data", startupName: "Macintosh HD"), "Macintosh HD:Users:me:a b.txt")
        XCTAssertEqual(FinderPresets.hfs(posix: "/Volumes/Backup/Photos/2026", volumeName: "Backup", volumeRoot: "/Volumes/Backup", startupName: "Macintosh HD", isFolder: true), "Backup:Photos:2026:")
        XCTAssertEqual(FinderPresets.hfs(posix: "/Volumes/Backup", volumeName: "Backup", volumeRoot: "/Volumes/Backup", startupName: "Macintosh HD"), "Backup:", "a disk's own root ends with a colon")
        XCTAssertEqual(FinderPresets.hfs(posix: "/", volumeName: "Macintosh HD", volumeRoot: "/", startupName: "Macintosh HD"), "Macintosh HD:")
    }

    func testTerminalsAreToldApartFromEditors() {
        XCTAssertTrue(FinderPresets.isTerminal("com.apple.Terminal"))
        XCTAssertTrue(FinderPresets.isTerminal("com.googlecode.iterm2"))
        XCTAssertFalse(FinderPresets.isTerminal("com.microsoft.VSCode"))
        XCTAssertFalse(FinderPresets.isTerminal("com.example.unknown"))
        let ids = FinderPresets.ideCatalog.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testTidyPlanListsWhatWouldMoveAndLeavesUnknownKinds() {
        let plan = FinderPresets.tidyPlan(fileNames: ["a.png", "b.png", "c.pdf", "d.weird", "e"], category: FolderTools.category(for:))
        XCTAssertEqual(plan.map(\.folder), ["Documents", "Images"])
        XCTAssertEqual(plan.first { $0.folder == "Images" }?.names, ["a.png", "b.png"])
        XCTAssertTrue(FinderPresets.tidyPlan(fileNames: ["x.weird"], category: FolderTools.category(for:)).isEmpty)
    }

    func testPresetsAddClearAndComment() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-preset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: url)
        _ = try FileActionRunner.apply(FinderTagPreset(id: "1", title: "Ready", tags: ["Ready"], comment: "ok"), to: [url])
        XCTAssertEqual(FinderMetadata.tags(of: url), ["Ready"])
        XCTAssertEqual(FinderMetadata.comment(of: url), "ok")
        _ = try FileActionRunner.apply(FinderTagPreset(id: "2", title: "Client", tags: ["Client"]), to: [url])
        XCTAssertEqual(Set(FinderMetadata.tags(of: url)), ["Ready", "Client"], "a preset adds to what is there")
        _ = try FileActionRunner.apply(FinderTagPreset(id: "3", title: "Clear", clearsTags: true), to: [url])
        XCTAssertTrue(FinderMetadata.tags(of: url).isEmpty)
        XCTAssertEqual(FinderMetadata.comment(of: url), "ok", "no comment in the preset leaves the comment alone")
    }

    // MARK: Looking at files

    func testQuarantineMarksAreParsed() throws {
        let info = try XCTUnwrap(QuarantineInfo.parse("0083;5f3a1c2b;Safari;6E1A-uuid"))
        XCTAssertEqual(info.app, "Safari")
        XCTAssertEqual(info.date, Date(timeIntervalSince1970: 0x5f3a1c2b))
        XCTAssertFalse(info.wasApproved)
        XCTAssertTrue(try XCTUnwrap(QuarantineInfo.parse("00c3;5f3a1c2b;Chrome;x")).wasApproved)
        XCTAssertNil(QuarantineInfo.parse("garbage"))
        XCTAssertNil(QuarantineInfo.parse(""))
    }

    func testPermissionAndDurationText() {
        XCTAssertEqual(FinderInspectText.permissionString(0o755), "rwxr-xr-x")
        XCTAssertEqual(FinderInspectText.permissionString(0o600), "rw-------")
        XCTAssertEqual(FinderInspectText.duration(45), "45 s")
        XCTAssertEqual(FinderInspectText.duration(125), "2 min 05 s")
        XCTAssertEqual(FinderInspectText.duration(3723), "1 h 02 min 03 s")
        XCTAssertEqual(FinderInspectText.duration(.nan), "unknown")
    }

    func testInspectionsReadWithoutChangingAFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-inspect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: url)
        let before = try Data(contentsOf: url)
        XCTAssertTrue(FinderInspect.permissions(url).contains("Mode:"))
        XCTAssertEqual(FinderInspect.report("checksum", url), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertTrue(FinderInspect.quarantine(url).hasPrefix("No download warning"))
        XCTAssertTrue(FinderInspect.media(url).hasPrefix("Not an image"))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(FinderPresets.inspections.map(\.id).filter { $0 != "quicklook" }.count, 7)
    }

    // MARK: Previews before changes

    func testQuarantinePreviewNamesOnlyTheFilesThatHaveTheWarning() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let marked = dir.appendingPathComponent("marked.dmg"), clean = dir.appendingPathComponent("clean.txt")
        try Data("x".utf8).write(to: marked); try Data("x".utf8).write(to: clean)
        XCTAssertEqual(setxattr(marked.path, "com.apple.quarantine", "0083;5f3a1c2b;Safari;u", 22, 0, 0), 0)
        let item = try XCTUnwrap(finderSuggestedItems().first { $0.id == "remove-quarantine" })
        let text = try XCTUnwrap(FinderPreview.detail(item, urls: [marked, clean], folder: nil))
        XCTAssertTrue(text.contains("marked.dmg")); XCTAssertFalse(text.contains("clean.txt"))
        XCTAssertTrue(try XCTUnwrap(FinderPreview.detail(item, urls: [clean], folder: nil)).contains("None of the selected"))
    }

    func testTidyPreviewListsTheMovesWithoutMovingAnything() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-tidy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for n in ["a.png", "b.pdf", "c.weird"] { try Data("x".utf8).write(to: dir.appendingPathComponent(n)) }
        let item = try XCTUnwrap(finderSuggestedItems().first { $0.id == "tidy-folder" })
        let text = try XCTUnwrap(FinderPreview.detail(item, urls: [], folder: dir))
        XCTAssertTrue(text.contains("Images: 1 file")); XCTAssertTrue(text.contains("Documents: 1 file")); XCTAssertFalse(text.contains("c.weird"))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["a.png", "b.pdf", "c.weird"], "a preview moves nothing")
    }
}
