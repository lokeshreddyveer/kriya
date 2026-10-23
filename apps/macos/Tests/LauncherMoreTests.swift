import XCTest
@testable import Kriya

final class LauncherFilterTests: XCTestCase {
    func testAKindPrefixLimitsTheSearch() {
        XCTAssertEqual(LauncherFilter.parse("apps: saf")?.category, .app)
        XCTAssertEqual(LauncherFilter.parse("apps: saf")?.rest, "saf")
        XCTAssertEqual(LauncherFilter.parse("Files:budget 2025")?.category, .file)
        XCTAssertEqual(LauncherFilter.parse("clip: invoice")?.category, .clipboard)
        XCTAssertEqual(LauncherFilter.parse("wf: tidy")?.category, .workflow)
        XCTAssertEqual(LauncherFilter.parse("apps:")?.rest, "")
    }

    func testAddressesAndOtherColonsAreNotFilters() {
        XCTAssertNil(LauncherFilter.parse("https://apple.com"))
        XCTAssertNil(LauncherFilter.parse("note: buy milk"))
        XCTAssertNil(LauncherFilter.parse("12:30 meeting"))
        XCTAssertNil(LauncherFilter.parse("plain words"))
        XCTAssertNil(LauncherFilter.parse(""))
    }

    func testExcludedFoldersCoverWholeFolderNamesOnly() {
        let folders = ["/Users/me/Work", "/Users/me/Secret/"]
        XCTAssertTrue(FileSearchFilter.isExcluded("/Users/me/Work/plan.txt", folders: folders))
        XCTAssertTrue(FileSearchFilter.isExcluded("/Users/me/Work", folders: folders))
        XCTAssertTrue(FileSearchFilter.isExcluded("/Users/me/Secret/a/b.txt", folders: folders))
        XCTAssertFalse(FileSearchFilter.isExcluded("/Users/me/Workshop/plan.txt", folders: folders))
        XCTAssertFalse(FileSearchFilter.isExcluded("/Users/me/Other/x", folders: []))
    }
}

final class RecentAppsTests: XCTestCase {
    func testTheMostRecentIsFirstRepeatsMoveUpAndOthersAreIgnored() {
        var apps = RecentApps()
        apps.record("a"); apps.record("b"); apps.record("c"); apps.record("a")
        XCTAssertEqual(apps.ids, ["a", "c", "b"])
        apps.record("com.apple.dock", ignoring: ["com.apple.dock"])
        apps.record(nil); apps.record("")
        XCTAssertEqual(apps.ids, ["a", "c", "b"])
        XCTAssertEqual(apps.recent(2, excluding: "a"), ["c", "b"], "the app in front is left out")
    }

    func testOnlyTheLatestAreKept() {
        var apps = RecentApps()
        for i in 0..<(RecentApps.capacity + 5) { apps.record("app.\(i)") }
        XCTAssertEqual(apps.ids.count, RecentApps.capacity)
        XCTAssertEqual(apps.ids.first, "app.\(RecentApps.capacity + 4)")
        apps.remove("app.\(RecentApps.capacity + 4)")
        XCTAssertFalse(apps.ids.contains("app.\(RecentApps.capacity + 4)"))
    }
}

final class MusicControlTests: XCTestCase {
    func testScriptsNameThePlayerAndTheCommand() {
        XCTAssertTrue(MusicControl.script(.playPause, player: .music).contains("tell application \"Music\""))
        XCTAssertTrue(MusicControl.script(.playPause, player: .spotify).contains("playpause"))
        XCTAssertTrue(MusicControl.script(.next, player: .music).contains("next track"))
        XCTAssertTrue(MusicControl.script(.previous, player: .spotify).contains("previous track"))
        XCTAssertTrue(MusicControl.script(.nowPlaying, player: .music).contains("name of current track"))
        XCTAssertEqual(MusicControl.Command.playPause.commandName, "music.playpause")
    }

    func testWhatIsPlayingIsReadFromTheAnswer() {
        let answer = "Blue in Green\u{1F}Miles Davis\u{1F}playing\n"
        XCTAssertEqual(MusicControl.parse(answer), MusicControl.NowPlaying(title: "Blue in Green", artist: "Miles Davis", state: "playing"))
        XCTAssertEqual(MusicControl.parse(answer)?.text, "Blue in Green — Miles Davis")
        XCTAssertNil(MusicControl.parse(""))
        XCTAssertNil(MusicControl.parse("garbage"))
    }

    func testOnlyRunningPlayersAreOffered() {
        XCTAssertEqual(MusicControl.running(["com.spotify.client", "com.apple.finder"]), [.spotify])
        XCTAssertTrue(MusicControl.running([]).isEmpty)
    }
}

final class PasswordItemTests: XCTestCase {
    private let json = """
    [{"id":"abcdefghijklmnopqrstuvwxyz","title":"GitHub","vault":{"name":"Personal"},"additional_information":"me@example.com","urls":[{"href":"https://github.com/login"},{"href":"javascript:alert(1)"}]},
     {"id":"short","title":"Bad id"},
     {"id":"zyxwvutsrqponmlkjihgfedcba","title":"Bank","vault":{"name":"Work"},"additional_information":"acct 42"},
     {"id":"qrstuvwxyzabcdefghijklmnop","title":""}]
    """

    func testItemsAreReadWithoutAnySecrets() {
        let items = PasswordItems.parse(Data(json.utf8))
        XCTAssertEqual(items.map(\.title), ["GitHub", "Bank"], "a bad id and an empty title are dropped")
        XCTAssertEqual(items[0].vault, "Personal")
        XCTAssertEqual(items[0].username, "me@example.com")
        XCTAssertEqual(items[0].urls, ["https://github.com/login"], "only web addresses are kept")
        XCTAssertTrue(PasswordItems.parse(Data("nope".utf8)).isEmpty)
    }

    func testSearchMatchesEveryWordAndTitlesStartingWithItComeFirst() {
        let items = PasswordItems.parse(Data(json.utf8)) + [PasswordItem(id: "mnopqrstuvwxyzabcdefghijkl", title: "My GitHub work", vault: "", username: "", urls: [])]
        XCTAssertEqual(PasswordItems.search("git", in: items).map(\.title), ["GitHub", "My GitHub work"])
        XCTAssertEqual(PasswordItems.search("example.com", in: items).map(\.title), ["GitHub"], "user names are searched too")
        XCTAssertTrue(PasswordItems.search("", in: items).isEmpty)
        XCTAssertTrue(PasswordItems.search("zzz", in: items).isEmpty)
    }

    func testCommandsAreBuiltOnlyFromValidIDsAndFixedFields() throws {
        let id = "abcdefghijklmnopqrstuvwxyz"
        XCTAssertEqual(PasswordItems.arguments(for: .password, id: id), ["item", "get", id, "--fields", "label=password", "--reveal"])
        XCTAssertEqual(PasswordItems.arguments(for: .otp, id: id), ["item", "get", id, "--otp"])
        XCTAssertNil(PasswordItems.arguments(for: .password, id: "x; rm -rf /"))
        XCTAssertNil(PasswordItems.arguments(for: .username, id: "--help"))
    }

    func testACopiedSecretIsTakenBackOnlyIfNothingElseWasCopied() {
        XCTAssertTrue(SecretClipboard.shouldClear(changeCountAtCopy: 7, now: 7))
        XCTAssertFalse(SecretClipboard.shouldClear(changeCountAtCopy: 7, now: 8))
    }
}

final class LauncherApprovalTests: XCTestCase {
    func testApprovalIsByExactContent() {
        let defaults = UserDefaults(suiteName: "kriya-approvals-\(UUID().uuidString)")!
        let approvals = LauncherApprovals(defaults: defaults)
        XCTAssertFalse(approvals.isApproved(kind: "script", content: "echo hi"))
        approvals.approve(kind: "script", content: "echo hi", label: "Hi")
        XCTAssertTrue(approvals.isApproved(kind: "script", content: "echo hi"))
        XCTAssertFalse(approvals.isApproved(kind: "script", content: "echo hi; rm x"), "a changed script asks again")
        XCTAssertFalse(approvals.isApproved(kind: "api", content: "echo hi"), "the kind is part of it")
        XCTAssertTrue(LauncherApprovals(defaults: defaults).isApproved(kind: "script", content: "echo hi"), "it survives a restart")
        approvals.revoke(LauncherApprovals.fingerprint(kind: "script", content: "echo hi"))
        XCTAssertFalse(approvals.isApproved(kind: "script", content: "echo hi"))
    }

    func testTurningTheQuestionOffApprovesEverything() {
        let approvals = LauncherApprovals(defaults: UserDefaults(suiteName: "kriya-approvals-\(UUID().uuidString)")!)
        approvals.asksFirst = false
        XCTAssertTrue(approvals.isApproved(kind: "script", content: "anything"))
    }

    func testTheSpotlightLineIsReadFromMdutil() {
        XCTAssertTrue(LauncherPane.describeSpotlight("/System/Volumes/Data:\n\tIndexing enabled.").contains("on"))
        XCTAssertTrue(LauncherPane.describeSpotlight("Indexing disabled.").contains("off"))
        XCTAssertTrue(LauncherPane.describeSpotlight("").contains("could not"))
    }
}

final class FinderWindowTests: XCTestCase {
    func testClosedWindowsAreRememberedAndReopenedOnesAreNot() {
        var history = FinderWindowHistory()
        history.observe(["/a", "/b/"])
        XCTAssertEqual(history.open, ["/a", "/b"])
        history.observe(["/b"])
        XCTAssertEqual(history.closed, ["/a"])
        history.observe(["/b", "/c"])
        history.observe(["/c"])
        XCTAssertEqual(history.closed, ["/b", "/a"], "newest closed first")
        history.observe(["/c", "/a"])
        XCTAssertEqual(history.closed, ["/b"], "an open window is not closed")
    }

    func testExcludedFoldersAreNeverKeptAndOnlyTheLatestAreKept() {
        var history = FinderWindowHistory()
        history.observe(["/x/secret", "/y"]) { $0.hasPrefix("/x") }
        history.observe([])
        XCTAssertEqual(history.closed, ["/y"])
        for i in 0..<(FinderWindowHistory.capacity + 5) { history.observe(["/f\(i)"]) }
        history.observe([])
        XCTAssertEqual(history.closed.count, FinderWindowHistory.capacity)
    }

    func testFolderSetsKeepExistingFoldersOnceInOrder() {
        let set = FolderSet(name: "Project", paths: ["/a", "/gone", "/a/", "/b"])
        XCTAssertEqual(set.openable { $0 != "/gone" }, ["/a", "/b"])
        XCTAssertNil(FolderSets.from(open: [], named: "x"))
        XCTAssertNil(FolderSets.from(open: ["/a"], named: "  "))
        XCTAssertEqual(FolderSets.from(open: ["/a"], named: " Work ")?.name, "Work")
    }

    func testRecentFoldersSkipExcludedOnes() {
        let defaults = UserDefaults(suiteName: "kriya-dest-\(UUID().uuidString)")!
        let destinations = FolderDestinations(defaults: defaults, key: "k", isFolder: { _ in true }, isProtected: { _ in false })
        destinations.used("/tmp/kriya-a/one")
        destinations.exclude("/tmp/kriya-a")
        XCTAssertTrue(destinations.recents.isEmpty, "excluding drops what was already there")
        destinations.used("/tmp/kriya-a/two")
        XCTAssertTrue(destinations.recents.isEmpty)
        XCTAssertTrue(FolderSets.isExcluded("/tmp/kriya-a/two", folders: ["/tmp/kriya-a"]))
        XCTAssertFalse(FolderSets.isExcluded("/tmp/kriya-ab", folders: ["/tmp/kriya-a"]))
    }
}

final class AudioProfileTests: XCTestCase {
    func testAProfileSurvivesAFileAndKeepsVolumesInRange() throws {
        var volumes = DeviceVolumes()
        volumes.remember("Desk Speakers", percent: 40)
        volumes.remember("Loud", percent: 900)
        let profile = AudioProfile(
            rules: [SoundRule(trigger: .deviceConnected(contains: "Pods"), action: .setVolume(percent: 300))],
            modes: SoundMode.starters, deviceVolumes: volumes)
        let back = try AudioProfile.decode(try profile.encoded())
        XCTAssertEqual(back.modes, SoundMode.starters)
        XCTAssertEqual(back.rules.first?.action, .setVolume(percent: 100), "a volume past 100 is brought back to 100")
        XCTAssertEqual(back.deviceVolumes.level(for: "Desk Speakers"), 40)
        XCTAssertEqual(back.deviceVolumes.level(for: "Loud"), 100)
    }

    func testAFileThatIsNotAProfileOrIsTooNewIsRefused() throws {
        XCTAssertThrowsError(try AudioProfile.decode(Data("nope".utf8))) { XCTAssertEqual($0 as? AudioProfile.Problem, .unreadable) }
        var newer = AudioProfile()
        newer.version = AudioProfile.currentVersion + 1
        XCTAssertThrowsError(try AudioProfile.decode(try newer.encoded())) { XCTAssertEqual($0 as? AudioProfile.Problem, .newer(2)) }
        let crowded = AudioProfile(rules: Array(repeating: SoundRule(trigger: .appQuit(bundleID: "a"), action: .muteMic(true)), count: AudioProfile.limit + 1))
        XCTAssertThrowsError(try AudioProfile.decode(try crowded.encoded())) { XCTAssertEqual($0 as? AudioProfile.Problem, .tooLarge) }
    }

    func testRememberedVolumesAreBoundedAndForgettable() {
        var volumes = DeviceVolumes()
        for i in 0..<(DeviceVolumes.capacity + 10) { volumes.remember("dev\(i)", percent: i) }
        XCTAssertEqual(volumes.levels.count, DeviceVolumes.capacity)
        volumes.remember("", percent: 5)
        XCTAssertNil(volumes.level(for: ""))
        volumes.clear()
        XCTAssertTrue(volumes.levels.isEmpty)
    }

    func testTheTestToneIsQuietBoundedAndFadesAtTheEnds() {
        let tone = ToneGenerator.samples(frequency: 440, seconds: 1)
        XCTAssertEqual(tone.count, 44_100)
        XCTAssertLessThanOrEqual(tone.map { abs($0) }.max() ?? 1, 0.25 + 0.001)
        XCTAssertEqual(tone.first ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(tone.last ?? 1, 0, accuracy: 0.01)
        XCTAssertEqual(ToneGenerator.samples(frequency: .nan, seconds: 100).count, 5 * 44_100, "a long time is cut to 5 seconds")
        XCTAssertLessThanOrEqual(ToneGenerator.samples(frequency: 440, seconds: 1, amplitude: 9).map { abs($0) }.max() ?? 1, 0.5 + 0.001)
    }

    func testTrimTimesAreReadAndRangesChecked() {
        XCTAssertEqual(RecordingTrim.seconds(from: "75"), 75)
        XCTAssertEqual(RecordingTrim.seconds(from: "1:15.5"), 75.5)
        XCTAssertEqual(RecordingTrim.seconds(from: "1:00:00"), 3600)
        XCTAssertNil(RecordingTrim.seconds(from: "a:b"))
        XCTAssertNil(RecordingTrim.seconds(from: "-5"))
        XCTAssertNil(RecordingTrim.seconds(from: ""))
        XCTAssertEqual(RecordingTrim.range(start: 2, end: 99, duration: 10)?.end, 10)
        XCTAssertEqual(RecordingTrim.range(start: -3, end: 4, duration: 10)?.start, 0)
        XCTAssertNil(RecordingTrim.range(start: 5, end: 5.05, duration: 10))
        XCTAssertNil(RecordingTrim.range(start: 11, end: 20, duration: 10))
        XCTAssertNil(RecordingTrim.range(start: 0, end: 5, duration: 0))
    }
}
