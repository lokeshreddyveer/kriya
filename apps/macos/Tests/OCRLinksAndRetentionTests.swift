import XCTest
@testable import Kriya

final class OCRLinksTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: Finding links in text read from a picture

    func testLinksAreFoundWithWhereTheySit() {
        let text = "Docs at https://example.com/guide and mail help@example.com or see www.example.org today."
        let links = OCRLinks.detect(in: text)
        XCTAssertEqual(links.map(\.shown), ["https://example.com/guide", "help@example.com", "www.example.org"])
        XCTAssertEqual(links[0].url.absoluteString, "https://example.com/guide")
        XCTAssertEqual(links[1].url.scheme, "mailto")
        for link in links {
            let range = Range(link.range, in: text)!
            XCTAssertEqual(String(text[range]), link.shown, "the range points at the words")
        }
    }

    func testOnlyWebAddressesCanBeOpenedOrRouted() {
        let links = OCRLinks.detect(in: "https://example.com and help@example.com")
        XCTAssertTrue(links[0].isWeb)
        XCTAssertFalse(links[1].isWeb)
        XCTAssertTrue(OCRLinkAction.open.isAvailable(for: links[0]))
        XCTAssertTrue(OCRLinkAction.route.isAvailable(for: links[0]))
        XCTAssertFalse(OCRLinkAction.open.isAvailable(for: links[1]))
        XCTAssertFalse(OCRLinkAction.route.isAvailable(for: links[1]))
        XCTAssertTrue(OCRLinkAction.copy.isAvailable(for: links[1]))
        XCTAssertTrue(OCRLinkAction.ignore.isAvailable(for: links[1]))
    }

    func testTextWithNoLinkGivesNoLinks() {
        XCTAssertTrue(OCRLinks.detect(in: "").isEmpty)
        XCTAssertTrue(OCRLinks.detect(in: "Nothing to see here, just words.").isEmpty)
    }

    func testOtherSchemesAreNotOffered() {
        XCTAssertTrue(OCRLinks.detect(in: "javascript:alert(1) and file:///etc/hosts").isEmpty)
    }

    func testTheResultKeepsTheTextAsItWasAndDropsRepeats() {
        let text = "a https://example.com/x b https://example.com/x/ c https://EXAMPLE.com/x#top"
        let result = OCRLinks.result(for: text)
        XCTAssertEqual(result.text, text, "the text is not changed")
        XCTAssertEqual(result.links.count, 1, "the same address written three ways is one link")
    }

    func testNoMoreThanEightAreOffered() {
        let text = (1...20).map { "https://example.com/\($0)" }.joined(separator: " ")
        XCTAssertEqual(OCRLinks.result(for: text).links.count, OCRLinks.maxOffered)
    }

    // MARK: Ignoring a link

    func testAnIgnoredLinkIsNotOfferedAgainEvenWrittenAnotherWay() {
        let ignored = IgnoredLinks().adding(url("https://example.com/x"))
        XCTAssertTrue(ignored.contains(url("https://EXAMPLE.com/x/")))
        XCTAssertTrue(ignored.contains(url("https://example.com/x#part")))
        XCTAssertFalse(ignored.contains(url("https://example.com/y")))
        XCTAssertFalse(ignored.contains(url("http://example.com/x")), "another scheme is another link")
        let result = OCRLinks.result(for: "https://example.com/x and https://example.com/y", ignored: ignored)
        XCTAssertEqual(result.links.map(\.url.absoluteString), ["https://example.com/y"])
    }

    func testIgnoredLinksAreKeptInTheStoreAndCapped() throws {
        let suite = "kriya.test.ignored.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IgnoredLinkStore(defaults: defaults)
        XCTAssertEqual(store.links, IgnoredLinks())
        var list = IgnoredLinks()
        for n in 0..<(IgnoredLinks.limit + 20) { list = list.adding(url("https://example.com/\(n)")) }
        XCTAssertEqual(list.keys.count, IgnoredLinks.limit)
        XCTAssertFalse(list.contains(url("https://example.com/0")), "the oldest are forgotten first")
        XCTAssertTrue(list.contains(url("https://example.com/\(IgnoredLinks.limit + 19)")))
        store.links = list
        XCTAssertEqual(IgnoredLinkStore(defaults: defaults).links, list)
        XCTAssertFalse(list.removing(url("https://example.com/\(IgnoredLinks.limit + 19)")).contains(url("https://example.com/\(IgnoredLinks.limit + 19)")))
    }

    func testDamagedIgnoredLinksLoadEmpty() throws {
        let list = try JSONDecoder().decode(IgnoredLinks.self, from: Data(#"{"keys":5}"#.utf8))
        XCTAssertEqual(list, IgnoredLinks())
    }

    // MARK: Nothing opens by itself

    func testOfferingLinksOpensNothingAndFollowsTheSetting() {
        var policy = TextPolicy()
        let text = "see https://example.com/a"
        XCTAssertEqual(OCRLinks.offers(in: text, policy: policy, ignored: IgnoredLinks()).count, 1)
        policy.detectLinks = false
        XCTAssertTrue(OCRLinks.offers(in: text, policy: policy, ignored: IgnoredLinks()).isEmpty, "turned off, nothing is offered")
    }

    func testEachActionDoesOnlyWhatWasChosen() {
        var calls: [String] = []
        let handlers = OCRLinkHandlers(open: { calls.append("open \($0.absoluteString)") }, copy: { calls.append("copy \($0)") },
                                       route: { calls.append("route \($0.absoluteString)") }, ignore: { calls.append("ignore \($0.absoluteString)") })
        let web = OCRLinks.detect(in: "https://example.com/a")[0]
        let mail = OCRLinks.detect(in: "help@example.com")[0]
        XCTAssertTrue(calls.isEmpty, "finding a link calls nothing")
        OCRLinks.perform(.copy, on: web, using: handlers)
        XCTAssertEqual(calls, ["copy https://example.com/a"])
        OCRLinks.perform(.route, on: web, using: handlers)
        OCRLinks.perform(.open, on: web, using: handlers)
        OCRLinks.perform(.ignore, on: web, using: handlers)
        XCTAssertEqual(calls.count, 4)
        calls = []
        OCRLinks.perform(.open, on: mail, using: handlers)
        OCRLinks.perform(.route, on: mail, using: handlers)
        XCTAssertTrue(calls.isEmpty, "an e-mail address is never opened as a web page")
        OCRLinks.perform(.copy, on: mail, using: handlers)
        XCTAssertEqual(calls, ["copy mailto:help@example.com"])
    }

    func testEveryActionHasAClearTitle() {
        XCTAssertEqual(OCRLinkAction.allCases.map(\.title), ["Open link", "Copy link", "Route through Link Routing", "Ignore this link"])
    }

    func testTheIgnoredLinksAreRegisteredForBackupAndReset() throws {
        let entry = try XCTUnwrap(SettingsRegistry.entries.first { $0.key == IgnoredLinkStore.key })
        XCTAssertEqual(entry.kind, .setting)
        XCTAssertEqual(entry.area, "capture")
    }
}

final class CaptureRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    func testNothingIsLimitedByDefault() {
        let retention = CaptureRetention()
        XCTAssertNil(retention.historyCutoff(now: now))
        XCTAssertTrue(retention.keepsInHistory(.distantPast, now: now))
        XCTAssertFalse(retention.fileIsExpired(.distantPast, isRecording: false, now: now))
        XCTAssertFalse(retention.fileIsExpired(.distantPast, isRecording: true, now: now))
    }

    func testTheThreeLimitsAreSeparate() {
        var retention = CaptureRetention()
        retention.captureHistoryDays = 7
        retention.screenshotFileDays = 30
        retention.recordingFileDays = 3
        XCTAssertFalse(retention.keepsInHistory(ago(8), now: now))
        XCTAssertTrue(retention.keepsInHistory(ago(6), now: now))
        XCTAssertFalse(retention.fileIsExpired(ago(20), isRecording: false, now: now))
        XCTAssertTrue(retention.fileIsExpired(ago(40), isRecording: false, now: now))
        XCTAssertTrue(retention.fileIsExpired(ago(5), isRecording: true, now: now), "recordings follow their own, shorter limit")
        XCTAssertFalse(retention.fileIsExpired(ago(2), isRecording: true, now: now))
    }

    func testALimitOnOneKindLeavesTheOtherAlone() {
        var retention = CaptureRetention()
        retention.recordingFileDays = 1
        XCTAssertFalse(retention.fileIsExpired(ago(500), isRecording: false, now: now), "pictures have no limit")
        XCTAssertTrue(retention.fileIsExpired(ago(500), isRecording: true, now: now))
    }

    func testLimitsAreMovedToALengthThatCanBeChosen() {
        var retention = CaptureRetention()
        retention.captureHistoryDays = 10
        retention.screenshotFileDays = -5
        retention.recordingFileDays = 9_999
        let clean = retention.sanitized()
        XCTAssertTrue(CaptureRetention.choices.contains(clean.captureHistoryDays))
        XCTAssertEqual(clean.screenshotFileDays, 0)
        XCTAssertEqual(clean.recordingFileDays, 365)
        XCTAssertEqual(CaptureRetention().sanitized(), CaptureRetention())
    }

    func testOldSettingsAndDamagedOnesLoad() throws {
        XCTAssertEqual(try JSONDecoder().decode(CaptureRetention.self, from: Data("{}".utf8)), CaptureRetention())
        let damaged = try JSONDecoder().decode(CaptureRetention.self, from: Data(#"{"captureHistoryDays":"x","recordingFileDays":14}"#.utf8))
        XCTAssertEqual(damaged.captureHistoryDays, 0)
        XCTAssertEqual(damaged.recordingFileDays, 14)
    }

    func testTheHistoryListLeavesOutEntriesPastTheLimitButNotTheFiles() {
        let files = [(path: "/c/new.png", date: ago(1)), (path: "/c/old.png", date: ago(40)), (path: "/c/old.mov", date: ago(90)), (path: "/c/notes.txt", date: ago(1))]
        XCTAssertEqual(CaptureHistory.recent(files, limit: 10, now: now).map(\.name), ["new.png", "old.png", "old.mov"], "no limit: all captures")
        var retention = CaptureRetention()
        retention.captureHistoryDays = 7
        XCTAssertEqual(CaptureHistory.recent(files, limit: 10, retention: retention, now: now).map(\.name), ["new.png"])
    }

    func testGIFsFollowTheRecordingLimit() {
        XCTAssertTrue(CaptureCleanup.isRecording(extension: "gif"))
        XCTAssertTrue(CaptureCleanup.isRecording(extension: "MOV"))
        XCTAssertTrue(CaptureCleanup.isRecording(extension: "mp4"))
        XCTAssertFalse(CaptureCleanup.isRecording(extension: "png"))
        XCTAssertFalse(CaptureCleanup.isRecording(extension: "heic"))
    }

    private func file(_ name: String, _ days: Double, _ bytes: Int64 = 1_000_000, recording: Bool = false) -> CaptureCleanup.File {
        CaptureCleanup.File(path: "/c/\(name)", date: ago(days), bytes: bytes, isRecording: recording)
    }

    func testOnlyFilesPastTheirOwnLimitAreListedOldestFirst() {
        var retention = CaptureRetention()
        retention.screenshotFileDays = 30
        retention.recordingFileDays = 7
        let files = [file("a.png", 10), file("b.png", 50), file("c.mov", 8, recording: true), file("d.mov", 3, recording: true), file("e.png", 400)]
        XCTAssertEqual(CaptureCleanup.expired(files, retention: retention, now: now).map(\.path), ["/c/e.png", "/c/b.png", "/c/c.mov"])
        XCTAssertTrue(CaptureCleanup.expired(files, retention: CaptureRetention(), now: now).isEmpty, "no limit, nothing is ever listed")
    }

    func testTheSummaryCountsAndSizesWhatWouldMove() {
        let files = [file("a.png", 50, 2_000_000), file("b.png", 60, 3_000_000), file("c.mov", 9, 50_000_000, recording: true)]
        let text = CaptureCleanup.summary(files)
        XCTAssertTrue(text.hasPrefix("2 pictures and 1 recording ("), text)
        XCTAssertTrue(text.hasSuffix(") older than the limits."), text)
        XCTAssertEqual(CaptureCleanup.summary([]), "Nothing is older than the limits.")
        XCTAssertTrue(CaptureCleanup.summary([file("a.png", 50)]).hasPrefix("1 picture ("))
    }

    func testNothingIsMovedUnlessTheAnswerIsYes() {
        let files = [file("a.png", 50), file("b.mov", 20, recording: true)]
        var trashed: [String] = []
        var asked: [[CaptureCleanup.File]] = []
        let no = CaptureCleanup.run(files, confirm: { asked.append($0); return false }, trash: { trashed.append($0) })
        XCTAssertEqual(asked.count, 1, "the person was shown the files")
        XCTAssertEqual(asked.first, files)
        XCTAssertTrue(trashed.isEmpty, "declined: nothing moved")
        XCTAssertTrue(no.declined)
        XCTAssertEqual(no.message, "Nothing was moved to the Trash.")
        let yes = CaptureCleanup.run(files, confirm: { _ in true }, trash: { trashed.append($0) })
        XCTAssertEqual(trashed, ["/c/a.png", "/c/b.mov"])
        XCTAssertEqual(yes.trashed, 2)
        XCTAssertEqual(yes.message, "Moved 2 captures to the Trash.")
    }

    func testNothingToMoveAsksNothing() {
        var asked = false
        let result = CaptureCleanup.run([], confirm: { _ in asked = true; return true }, trash: { _ in })
        XCTAssertFalse(asked)
        XCTAssertEqual(result, CaptureCleanup.Result())
    }

    func testAFileThatCannotBeMovedIsReportedAndTheRestAreStillMoved() {
        struct Locked: Error {}
        let files = [file("a.png", 50), file("b.png", 60), file("c.png", 70)]
        var trashed: [String] = []
        let result = CaptureCleanup.run(files, confirm: { _ in true }, trash: { path in
            if path.hasSuffix("b.png") { throw Locked() }
            trashed.append(path)
        })
        XCTAssertEqual(trashed, ["/c/a.png", "/c/c.png"])
        XCTAssertEqual(result.trashed, 2)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.message, "Moved 2 captures to the Trash. 1 could not be moved.")
    }

    func testTheFolderScanFindsCapturesAndLeavesOtherFilesAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(count: 10).write(to: folder.appendingPathComponent("shot.png"))
        try Data(count: 20).write(to: folder.appendingPathComponent("clip.mov"))
        try Data(count: 5).write(to: folder.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("inner.png"), withIntermediateDirectories: false)
        let found = CaptureCleanup.files(in: folder)
        XCTAssertEqual(Set(found.map { ($0.path as NSString).lastPathComponent }), ["shot.png", "clip.mov"])
        XCTAssertEqual(found.first { $0.path.hasSuffix("clip.mov") }?.isRecording, true)
        XCTAssertEqual(found.first { $0.path.hasSuffix("shot.png") }?.bytes, 10)
    }

    func testThePolicyKeepsTheLimitsAndTheyTravelInABackup() throws {
        var policy = CaptureDeliveryPolicy()
        policy.retention.captureHistoryDays = 14
        policy.retention.recordingFileDays = 30
        let decoded = try JSONDecoder().decode(CaptureDeliveryPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertEqual(decoded.retention.captureHistoryDays, 14)
        XCTAssertEqual(decoded.retention.screenshotFileDays, 0)
        XCTAssertEqual(decoded.retention.recordingFileDays, 30)
    }

    func testPruningAnOverlayWithNothingClosedIsHarmless() {
        // The rule that decides what is forgotten is tested above; this only checks the overlay can be pruned with nothing in it.
        let overlay = CaptureOverlay()
        overlay.pruneHistory(now: now)
        XCTAssertFalse(overlay.canRestore)
    }
}
