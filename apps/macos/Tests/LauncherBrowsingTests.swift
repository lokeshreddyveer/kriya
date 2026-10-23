import XCTest
@testable import Kriya

final class FileNavigationTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("kriya-nav-\(UUID().uuidString)", isDirectory: true)
        for folder in ["Documents", "Downloads", ".hidden", "Pictures"] { try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true) }
        for file in ["notes.txt", "Data.csv", ".secret"] { try "x".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8) }
        try fm.createDirectory(at: root.appendingPathComponent("Tool.app"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    func testAPathIsRecognizedAndSplitIntoAFolderAndWhatIsTypedOfTheNextName() {
        XCTAssertTrue(FileNavigation.isPath("/usr"))
        XCTAssertTrue(FileNavigation.isPath("~"))
        XCTAssertTrue(FileNavigation.isPath("~/Doc"))
        XCTAssertFalse(FileNavigation.isPath("12/3"))
        XCTAssertFalse(FileNavigation.isPath("safari"))
        let a = FileNavigation.split("~/Doc", home: "/Users/me")
        XCTAssertEqual(a?.folder, "/Users/me")
        XCTAssertEqual(a?.prefix, "Doc")
        XCTAssertEqual(FileNavigation.split("~", home: "/Users/me")?.folder, "/Users/me")
        XCTAssertEqual(FileNavigation.split("/Users/me/Downloads/", home: "/Users/me")?.prefix, "")
        XCTAssertEqual(FileNavigation.split("/a/b/../c/", home: "/h")?.folder, "/a/c", "dots are resolved")
        XCTAssertNil(FileNavigation.split("hello", home: "/h"))
    }

    func testAFolderListsFoldersFirstWithoutHiddenItemsAndFiltersByPrefix() {
        let all = FileNavigation.list(folder: root.path, prefix: "")
        XCTAssertEqual(all.map { $0.url.lastPathComponent }, ["Documents", "Downloads", "Pictures", "Data.csv", "notes.txt", "Tool.app"])
        XCTAssertEqual(all.filter(\.isDirectory).count, 3, "an app is opened, not entered")
        XCTAssertEqual(FileNavigation.list(folder: root.path, prefix: "do").map { $0.url.lastPathComponent }, ["Documents", "Downloads"], "ignoring case")
        XCTAssertTrue(FileNavigation.list(folder: root.path, prefix: "zzz").isEmpty)
        XCTAssertEqual(FileNavigation.list(folder: root.path, prefix: ".").map { $0.url.lastPathComponent }, [".hidden", ".secret"], "hidden items appear when asked for")
        XCTAssertTrue(FileNavigation.list(folder: "/no/such/folder", prefix: "").isEmpty)
    }

    func testGoingInAndUpWritesTheTextToType() {
        XCTAssertEqual(FileNavigation.enter(URL(fileURLWithPath: "/Users/me/Documents"), home: "/Users/me"), "~/Documents/")
        XCTAssertEqual(FileNavigation.enter(URL(fileURLWithPath: "/Users/me"), home: "/Users/me"), "~/")
        XCTAssertEqual(FileNavigation.enter(URL(fileURLWithPath: "/usr/local"), home: "/Users/me"), "/usr/local/")
        XCTAssertEqual(FileNavigation.up(from: "~/Documents/Taxes/", home: "/Users/me"), "~/Documents/")
        XCTAssertEqual(FileNavigation.up(from: "~/Doc", home: "/Users/me"), "~/", "with part of a name typed, up first clears it")
        XCTAssertEqual(FileNavigation.up(from: "/usr/", home: "/Users/me"), "/")
        XCTAssertNil(FileNavigation.up(from: "/", home: "/Users/me"), "nothing above the top")
        XCTAssertNil(FileNavigation.up(from: "hello", home: "/Users/me"))
    }

    func testTheFileBufferKeepsEachFileOnceAndDropsOnesThatAreGone() {
        let buffer = FileBuffer()
        let a = URL(fileURLWithPath: "/tmp/a.txt"), b = URL(fileURLWithPath: "/tmp/b.txt")
        buffer.add(a); buffer.add(b); buffer.add(URL(fileURLWithPath: "/tmp/../tmp/a.txt"))
        XCTAssertEqual(buffer.urls.count, 2, "the same file is not added twice, however it is written")
        buffer.prune(exists: { $0 == a })
        XCTAssertEqual(buffer.urls, [a])
        buffer.remove(a)
        XCTAssertTrue(buffer.isEmpty)
        for index in 0..<(FileBuffer.limit + 20) { buffer.add(URL(fileURLWithPath: "/tmp/f\(index)")) }
        XCTAssertEqual(buffer.urls.count, FileBuffer.limit)
        buffer.clear()
        XCTAssertTrue(buffer.isEmpty)
    }
}

final class RecentFilesTests: XCTestCase {
    func testSpotlightOutputBecomesTheNewestFilesWorthShowing() {
        let output = """
        /Users/me/Documents/a.pdf   kMDItemLastUsedDate = 2026-10-20 10:00:00 +0000
        /Users/me/Documents/b.pdf   kMDItemLastUsedDate = 2026-10-22 09:00:00 +0000
        /Users/me/Library/Caches/x.db   kMDItemLastUsedDate = 2026-10-22 12:00:00 +0000
        /Users/me/Applications/Tool.app   kMDItemLastUsedDate = 2026-10-22 12:00:00 +0000
        /Users/me/Projects/node_modules/pkg/index.js   kMDItemLastUsedDate = 2026-10-22 12:00:00 +0000
        /Users/me/Documents/c.txt   kMDItemLastUsedDate = not a date
        garbage line
        """
        let files = RecentFiles.parse(output, home: "/Users/me", limit: 5)
        XCTAssertEqual(files.map(\.lastPathComponent), ["b.pdf", "a.pdf"], "newest first; Library, apps, dependencies and bad lines are left out")
        XCTAssertEqual(RecentFiles.parse(output, home: "/Users/me", limit: 1).map(\.lastPathComponent), ["b.pdf"])
        XCTAssertTrue(RecentFiles.parse("", home: "/Users/me", limit: 5).isEmpty)
    }
}

final class ScriptFileTests: XCTestCase {
    func testTheHeaderOfARaycastScriptIsRead() throws {
        let text = """
        #!/bin/bash

        # Required parameters:
        # @raycast.schemaVersion 1
        # @raycast.title Say Hello
        # @raycast.mode fullOutput
        # @raycast.packageName Examples
        # @raycast.description Greets someone
        # @raycast.argument1 { "type": "text", "placeholder": "First name" }
        # @raycast.argument2 { "type": "password", "placeholder": "Secret", "optional": true }
        # @kriya.keyword Hi!
        echo hello
        """
        let script = try XCTUnwrap(ScriptFileParser.parse(text, path: "/s/hello.sh"))
        XCTAssertEqual(script.title, "Say Hello")
        XCTAssertEqual(script.mode, .fullOutput)
        XCTAssertEqual(script.packageName, "Examples")
        XCTAssertEqual(script.subtitle, "Examples · Greets someone")
        XCTAssertEqual(script.keyword, "hi")
        XCTAssertEqual(script.arguments, [ScriptFile.Argument(placeholder: "First name", optional: false, secure: false), ScriptFile.Argument(placeholder: "Secret", optional: true, secure: true)])
        XCTAssertEqual(script.fileName, "hello.sh")
    }

    func testOtherCommentStylesAndMissingTitlesAreHandled() throws {
        XCTAssertEqual(ScriptFileParser.parse("// @raycast.title From JS\nconsole.log(1)", path: "/s/a.js")?.title, "From JS")
        XCTAssertEqual(ScriptFileParser.parse("-- @kriya.title From AppleScript", path: "/s/a.scpt")?.title, "From AppleScript")
        XCTAssertNil(ScriptFileParser.parse("#!/bin/sh\necho no title here", path: "/s/b.sh"), "no title: not a script command")
        XCTAssertNil(ScriptFileParser.parse("# @raycast.title", path: "/s/c.sh"))
        XCTAssertEqual(ScriptFileParser.parse("# @raycast.title X\n# @raycast.mode nonsense", path: "/s/d.sh")?.mode, .compact)
        XCTAssertNil(ScriptFileParser.parse("# @raycast.title X\n# @raycast.argument1 {not json", path: "/s/e.sh")?.arguments.first)
        let tooMany = ScriptFileParser.parse("# @raycast.title X\n# @raycast.argument4 {\"type\":\"text\"}", path: "/s/f.sh")
        XCTAssertEqual(tooMany?.arguments.count, 0, "only three arguments exist")
    }

    func testHowAFileIsRunAndHowTypedWordsBecomeArguments() {
        XCTAssertEqual(ScriptFileParser.launch(for: "/s/a.sh", isExecutable: true, firstLine: "#!/bin/zsh")?.executable, "/s/a.sh")
        let viaInterpreter = ScriptFileParser.launch(for: "/s/b.py", isExecutable: false, firstLine: "#!/usr/bin/env python3")
        XCTAssertEqual(viaInterpreter?.executable, "/usr/bin/env")
        XCTAssertEqual(viaInterpreter?.arguments, ["python3", "/s/b.py"])
        XCTAssertNil(ScriptFileParser.launch(for: "/s/c", isExecutable: false, firstLine: "no shebang"))
        XCTAssertNil(ScriptFileParser.launch(for: "/s/d", isExecutable: false, firstLine: "#!relative"))
        XCTAssertEqual(ScriptFileParser.split("Ada Lovelace", into: 1), ["Ada Lovelace"])
        XCTAssertEqual(ScriptFileParser.split("Ada Lovelace was here", into: 2), ["Ada", "Lovelace was here"])
        XCTAssertEqual(ScriptFileParser.split("one", into: 3), ["one"])
        XCTAssertEqual(ScriptFileParser.split("  ", into: 2), [])
        XCTAssertEqual(ScriptFileParser.split("x", into: 0), [])
    }

    func testAFolderIsIndexedAndOnlyChangedFilesAreReadAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-scripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "#!/bin/sh\n# @raycast.title One\n".write(to: folder.appendingPathComponent("one.sh"), atomically: true, encoding: .utf8)
        try "just some notes".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "# @raycast.title Hidden".write(to: folder.appendingPathComponent(".hidden.sh"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let index = ScriptFolderIndex()
        XCTAssertEqual(index.scripts(in: [folder.path]).map(\.title), ["One"])
        try "#!/bin/sh\n# @raycast.title Renamed\n".write(to: folder.appendingPathComponent("one.sh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: folder.appendingPathComponent("one.sh").path)
        XCTAssertEqual(index.scripts(in: [folder.path]).map(\.title), ["Renamed"])
        XCTAssertTrue(index.scripts(in: ["/no/such/folder"]).isEmpty)
    }

    func testScriptFoldersAreCheckedWhenAdded() {
        let extras = LauncherExtras(defaults: UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!)
        XCTAssertNotNil(extras.addScriptFolder("/no/such", folderExists: { _ in false }))
        XCTAssertNotNil(extras.addScriptFolder(NSHomeDirectory(), folderExists: { _ in true }), "not the whole home folder")
        XCTAssertNotNil(extras.addScriptFolder("/", folderExists: { _ in true }))
        XCTAssertNil(extras.addScriptFolder("/Users/x/Scripts", folderExists: { _ in true }))
        XCTAssertNotNil(extras.addScriptFolder("/Users/x/Scripts/", folderExists: { _ in true }), "the same folder twice")
        XCTAssertEqual(extras.scriptFolders, ["/Users/x/Scripts"])
        extras.removeScriptFolder("/Users/x/Scripts")
        XCTAssertTrue(extras.scriptFolders.isEmpty)
    }
}

final class LauncherPrefsExtrasTests: XCTestCase {
    private func prefs() -> LauncherPrefs { LauncherPrefs(defaults: UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!) }

    private func candidate(_ id: String, _ title: String, _ category: LauncherCategory = .app) -> LauncherCandidate {
        LauncherCandidate(id: id, title: title, subtitle: "", keywords: [], category: category, queryScore: nil, rememberable: true)
    }

    func testHiddenResultsNeverAppearAndAreUnhiddenAgain() {
        let p = prefs()
        let items = [candidate("a", "Safari"), candidate("b", "Safari Technology Preview")]
        XCTAssertEqual(LauncherEngine.rank(items, query: "safari", prefs: p.data).count, 2)
        p.togglePin("b")
        p.hide("b")
        XCTAssertEqual(LauncherEngine.rank(items, query: "safari", prefs: p.data), ["a"])
        XCTAssertFalse(p.isPinned("b"), "hiding also unpins")
        p.unhide("b")
        XCTAssertEqual(LauncherEngine.rank(items, query: "safari", prefs: p.data).count, 2)
    }

    func testResetRankingForgetsWhatWasLearned() {
        let p = prefs()
        p.record("a"); p.record("a")
        XCTAssertNotNil(p.data.usage["a"])
        p.resetRanking("a")
        XCTAssertNil(p.data.usage["a"])
    }

    func testKeysForResultsAreKeptAndAKeyWithoutAModifierIsRefused() {
        let p = prefs()
        p.setHotkey(LauncherHotkey(keyCode: 1, modifiers: 8), for: "app:x")
        XCTAssertEqual(p.hotkey(for: "app:x"), LauncherHotkey(keyCode: 1, modifiers: 8))
        p.setHotkey(LauncherHotkey(keyCode: 2, modifiers: 0), for: "app:y")
        XCTAssertNil(p.hotkey(for: "app:y"), "a bare key would take over typing")
        p.setHotkey(nil, for: "app:x")
        XCTAssertNil(p.hotkey(for: "app:x"))
    }

    func testStrictnessDecidesWhetherSpreadLettersMatch() {
        let p = prefs()
        let items = [candidate("m", "Messages"), candidate("s", "Spotify")]
        XCTAssertEqual(p.data.matchStrictness, .medium)
        p.setStrictness(.low)
        XCTAssertTrue(LauncherEngine.rank(items, query: "msg", prefs: p.data).contains("m"), "loose: letters in order")
        p.setStrictness(.high)
        XCTAssertFalse(LauncherEngine.rank(items, query: "msg", prefs: p.data).contains("m"), "strict wants word starts")
        XCTAssertTrue(LauncherEngine.rank(items, query: "mess", prefs: p.data).contains("m"))
        XCTAssertTrue(LauncherEngine.rank(items, query: "spot", prefs: p.data).contains("s"))
    }

    func testFallbacksStartAsTheWebAndCanBeReorderedAndSurviveARestart() {
        let store = UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!
        let p = LauncherPrefs(defaults: store)
        XCTAssertEqual(p.data.activeFallbacks, ["web"])
        p.setFallbacks(["ai", "web", "quicklink:q1"])
        XCTAssertEqual(LauncherPrefs(defaults: store).data.activeFallbacks, ["ai", "web", "quicklink:q1"])
        p.setFallbacks(["web"])
        XCTAssertNil(p.data.fallbacks, "back to the default")
    }

    func testTheOpeningListCallsPinnedResultsFavorites() {
        let p = prefs()
        p.togglePin("a")
        XCTAssertEqual(LauncherEngine.startSection(for: "a", prefs: p.data), "Favorites")
    }
}

final class PaletteTokenTests: XCTestCase {
    private func model() -> PaletteModel {
        let model = PaletteModel(prefs: LauncherPrefs(defaults: UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!))
        model.tokenProvider = { word in word == "gh" ? ArgumentToken(keyword: "gh", title: "GitHub", symbol: "link", placeholder: "Search GitHub for…") : nil }
        model.queryProviders = [{ text in
            guard text.hasPrefix("gh ") else { return [] }
            return [PaletteEntry(id: "gh:\(text)", title: "Search GitHub: \(text.dropFirst(3))", subtitle: nil, symbol: "link", rememberable: false, queryScore: 990, run: {})]
        }]
        return model
    }

    func testAKeywordAndASpaceBecomeAChipAndTheRestIsTheArgument() {
        let m = model()
        m.load([])
        m.query = "gh "
        XCTAssertEqual(m.token?.title, "GitHub")
        XCTAssertEqual(m.query, "")
        XCTAssertEqual(m.effectiveQuery, "gh")
        XCTAssertEqual(m.results.first?.id, "token:hint", "with nothing after it yet, it says what to type")
        m.query = "swift ui"
        XCTAssertEqual(m.effectiveQuery, "gh swift ui")
        XCTAssertEqual(m.results.first?.title, "Search GitHub: swift ui")
    }

    func testAWordThatIsNotAKeywordStaysText() {
        let m = model()
        m.load([])
        m.query = "hello "
        XCTAssertNil(m.token)
        XCTAssertEqual(m.query, "hello ")
        m.query = "gh"
        XCTAssertNil(m.token, "no space yet")
    }

    func testTakingTheChipOffReturnsTheKeywordAsText() {
        let m = model()
        m.load([])
        m.query = "gh "
        m.clearToken()
        XCTAssertNil(m.token)
        XCTAssertEqual(m.query, "gh")
        m.query = "gh "
        m.load([])
        XCTAssertNil(m.token, "a fresh opening starts clean")
    }

    func testSelectedTextShowsItsActionsFirstAndTypingNarrowsThem() {
        let m = model()
        m.selectionProvider = { text in
            [PaletteEntry(id: "sel:copy", title: "Copy the text", subtitle: text, symbol: "doc.on.doc", rememberable: false, queryScore: 990, run: {}),
             PaletteEntry(id: "sel:upper", title: "Make it UPPER CASE", subtitle: nil, symbol: "textformat", rememberable: false, queryScore: 900, run: {})]
        }
        m.load([], selection: "hello")
        XCTAssertEqual(m.results.map(\.id), ["sel:copy", "sel:upper"])
        XCTAssertEqual(m.sections, ["Selected text", "Selected text"])
        m.query = "upper"
        XCTAssertEqual(m.results.first?.id, "sel:upper")
    }

    func testTheOpeningListGetsExtraRowsUnderTheirOwnHeadings() {
        let m = model()
        m.startProvider = { [(PaletteEntry(id: "recent:a", title: "a.pdf", subtitle: nil, symbol: "doc", rememberable: false, run: {}), "Recent files")] }
        m.load([PaletteEntry(id: "app:x", title: "X", subtitle: "Running", symbol: "app", category: .app, run: {})])
        XCTAssertTrue(m.results.contains { $0.id == "recent:a" })
        XCTAssertEqual(m.sections.last, "Recent files")
    }

    func testFallbacksAreListedApartFromRealResults() {
        let m = model()
        var fallback = PaletteEntry(id: "web:g:all:zzz", title: "Search Google for “zzz”", subtitle: nil, symbol: "magnifyingglass", category: .web, rememberable: false, queryScore: 10, run: {})
        fallback.isFallback = true
        m.queryProviders = [{ _ in [fallback] }]
        m.load([])
        m.query = "zzz"
        XCTAssertEqual(m.sections, ["Search with"])
    }

    func testSingleWordDetection() {
        XCTAssertEqual(PaletteModel.singleWord("gh "), "gh")
        XCTAssertEqual(PaletteModel.singleWord("GH "), "gh")
        XCTAssertNil(PaletteModel.singleWord("gh swift "))
        XCTAssertNil(PaletteModel.singleWord("  "))
    }
}

final class LauncherExtrasLogicTests: XCTestCase {
    func testQuitRequestsAreUnderstood() {
        XCTAssertEqual(LauncherSystemCommands.quitRequest(in: "quit safari")?.name, "safari")
        XCTAssertEqual(LauncherSystemCommands.quitRequest(in: "quit safari")?.force, false)
        XCTAssertEqual(LauncherSystemCommands.quitRequest(in: "Force Quit Slack")?.force, true)
        XCTAssertEqual(LauncherSystemCommands.quitRequest(in: "kill chrome")?.force, true)
        XCTAssertNil(LauncherSystemCommands.quitRequest(in: "quit"))
        XCTAssertNil(LauncherSystemCommands.quitRequest(in: "quit  "))
        XCTAssertNil(LauncherSystemCommands.quitRequest(in: "quiet safari"))
    }

    func testAColourResultShowsASwatch() {
        XCTAssertTrue(ColorTool.results(for: "#ff8800").allSatisfy { $0.swatchHex == "#FF8800" })
    }
}

final class PaletteChipFallbackTests: XCTestCase {
    func testWithAChipNoFallbackIsOfferedTheWords() {
        let m = PaletteModel(prefs: LauncherPrefs(defaults: UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!))
        m.tokenProvider = { $0 == "gh" ? ArgumentToken(keyword: "gh", title: "GitHub", symbol: "link", placeholder: "Search GitHub for…") : nil }
        var fallback = PaletteEntry(id: "web:g:all", title: "Search Google", subtitle: nil, symbol: "magnifyingglass", category: .web, rememberable: false, queryScore: 10, run: {})
        fallback.isFallback = true
        m.queryProviders = [{ _ in [fallback] }]
        m.load([])
        m.query = "plain words"
        XCTAssertTrue(m.results.contains { $0.id == "web:g:all" }, "without a chip the fallback is offered")
        m.query = ""
        m.query = "gh "
        m.query = "swift"
        XCTAssertFalse(m.results.contains { $0.id == "web:g:all" })
    }
}

final class SpotlightShortcutTests: XCTestCase {
    func testASpotlightShortcutThatWasNeverChangedIsOn() {
        XCTAssertTrue(SpotlightShortcut.isEnabled(in: nil))
        XCTAssertTrue(SpotlightShortcut.isEnabled(in: [:]))
        XCTAssertTrue(SpotlightShortcut.isEnabled(in: ["15": ["enabled": 0]]), "another shortcut's setting is not Spotlight's")
    }

    func testTurningItOffIsNoticedWhateverTheTypeOfTheValue() {
        XCTAssertFalse(SpotlightShortcut.isEnabled(in: ["64": ["enabled": 0]]))
        XCTAssertFalse(SpotlightShortcut.isEnabled(in: ["64": ["enabled": false]]))
        XCTAssertTrue(SpotlightShortcut.isEnabled(in: ["64": ["enabled": 1]]))
        XCTAssertTrue(SpotlightShortcut.isEnabled(in: ["64": ["enabled": true]]))
        XCTAssertTrue(SpotlightShortcut.isEnabled(in: ["64": ["value": "x"]]), "no word on it: still on")
        XCTAssertFalse(SpotlightShortcut.isEnabled("65", in: ["65": ["enabled": 0]]))
    }
}

final class QuicklinkVariableTests: XCTestCase {
    func testClipboardAndSelectionFillTheAddress() {
        let link = Quicklink(name: "Look up", keyword: "lk", template: "https://example.com/?a={clipboard}&b={selection}")
        XCTAssertTrue(link.usesVariables)
        XCTAssertEqual(link.url(for: "", clipboard: "hello world", selection: "x&y")?.absoluteString, "https://example.com/?a=hello%20world&b=x%26y")
    }

    func testKeywordAloneFindsAVariableLinkButNotAQueryLink() {
        let variable = Quicklink(name: "V", keyword: "vv", template: "https://e.com/?c={clipboard}")
        let query = Quicklink(name: "Q", keyword: "qq", template: "https://e.com/?q={query}")
        XCTAssertEqual(LauncherExtraMatch.variableLink(in: "vv", among: [variable, query])?.name, "V")
        XCTAssertNil(LauncherExtraMatch.variableLink(in: "qq", among: [variable, query]))
        XCTAssertNil(LauncherExtraMatch.variableLink(in: "vv extra", among: [variable]))
    }
}
