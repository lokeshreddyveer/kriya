import XCTest
import CryptoKit
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

final class PermissionChangeTests: XCTestCase {
    func testOnlyRealChangesAreAnnounced() {
        XCTAssertNil(PermissionChange.notice(.accessibility, from: nil, to: .denied), "the first check says nothing")
        XCTAssertNil(PermissionChange.notice(.accessibility, from: .granted, to: .granted))
        XCTAssertNil(PermissionChange.notice(.inputMonitoring, from: .notDetermined, to: .denied), "asked but not answered is not a change")
        XCTAssertTrue(PermissionChange.notice(.screenRecording, from: .granted, to: .denied)?.contains("turned off") == true)
        XCTAssertTrue(PermissionChange.notice(.accessibility, from: .denied, to: .granted)?.contains("is on") == true)
    }
}

final class MIDITriggerTests: XCTestCase {
    func testMessagesAreReadFromBytes() {
        let bytes: [UInt8] = [0x90, 60, 100,  0x90, 62, 0,  0xB1, 7, 64,  0xC2, 5,  0xF8,  0x80, 60, 0]
        XCTAssertEqual(MIDIMessage.parse(bytes), [
            MIDIMessage(kind: .noteOn, channel: 1, number: 60, value: 100),
            MIDIMessage(kind: .controlChange, channel: 2, number: 7, value: 64),
            MIDIMessage(kind: .programChange, channel: 3, number: 5, value: 0),
        ], "a note on with no force, clock and note off are skipped")
        XCTAssertTrue(MIDIMessage.parse([0x90, 60]).isEmpty, "a cut-off message is ignored")
        XCTAssertTrue(MIDIMessage.parse([]).isEmpty)
    }

    func testATriggerMatchesItsControlOnly() {
        var trigger = MIDITrigger()
        trigger.number = 60; trigger.channel = 1; trigger.targetID = "wf1"
        let hit = MIDIMessage(kind: .noteOn, channel: 1, number: 60, value: 90)
        XCTAssertTrue(trigger.matches(hit))
        XCTAssertFalse(trigger.matches(MIDIMessage(kind: .noteOn, channel: 2, number: 60, value: 90)))
        XCTAssertFalse(trigger.matches(MIDIMessage(kind: .noteOn, channel: 1, number: 61, value: 90)))
        XCTAssertFalse(trigger.matches(MIDIMessage(kind: .controlChange, channel: 1, number: 60, value: 90)))
        trigger.channel = nil
        XCTAssertTrue(trigger.matches(MIDIMessage(kind: .noteOn, channel: 9, number: 60, value: 1)), "any channel")
        trigger.enabled = false
        XCTAssertFalse(trigger.matches(hit))
    }

    func testOnlyTriggersWithAValidTargetFire() {
        var good = MIDITrigger(); good.targetID = "wf-1"
        var bad = MIDITrigger(); bad.targetID = "a b; rm"
        let message = MIDIMessage(kind: .noteOn, channel: 1, number: 60, value: 50)
        XCTAssertEqual(MIDITriggers.firing(for: message, in: [good, bad]).map(\.id), [good.id])
        XCTAssertEqual(good.remoteCommand, .workflow("wf-1"))
        good.target = .command
        XCTAssertEqual(good.remoteCommand, .command("wf-1"))
    }

    func testLearningMakesATriggerFromTheMessage() {
        let trigger = MIDITriggers.learned(from: MIDIMessage(kind: .controlChange, channel: 4, number: 21, value: 99))
        XCTAssertEqual(trigger.kind, .controlChange)
        XCTAssertEqual(trigger.channel, 4)
        XCTAssertEqual(trigger.number, 21)
        XCTAssertEqual(trigger.minValue, 0, "a knob fires at every position")
    }
}

final class PlaceRuleTests: XCTestCase {
    private let home = PlaceRule(name: "Home", latitude: 51.5007, longitude: -0.1246, radius: 200, outputContains: "Speakers")
    private let work = PlaceRule(name: "Work", latitude: 51.5033, longitude: -0.1195, radius: 200, outputContains: "Display")

    func testDistanceIsInMetres() {
        XCTAssertEqual(PlaceRules.distance(0, 0, 0, 0), 0, accuracy: 0.001)
        XCTAssertEqual(PlaceRules.distance(0, 0, 0, 1), 111_195, accuracy: 200)
    }

    func testTheNearestPlaceInsideItsRadiusWins() {
        XCTAssertEqual(PlaceRules.place(at: 51.5008, -0.1245, in: [work, home])?.name, "Home")
        XCTAssertEqual(PlaceRules.place(at: 51.5033, -0.1196, in: [work, home])?.name, "Work")
        XCTAssertNil(PlaceRules.place(at: 40, -74, in: [work, home]))
    }

    func testBadPositionsAndSwitchedOffPlacesMatchNothing() {
        XCTAssertNil(PlaceRules.place(at: 999, 0, in: [home]))
        var off = home; off.enabled = false
        XCTAssertNil(PlaceRules.place(at: 51.5007, -0.1246, in: [off]))
        var noOutput = home; noOutput.outputContains = ""
        XCTAssertNil(PlaceRules.place(at: 51.5007, -0.1246, in: [noOutput]))
    }
}

final class FeatureResetTests: XCTestCase {
    func testResettingOneAreaLeavesTheOthersAlone() throws {
        let defaults = UserDefaults(suiteName: "kriya-reset-\(UUID().uuidString)")!
        defaults.set("a", forKey: "soundRules.v1")
        defaults.set("b", forKey: "soundModes.v1")
        defaults.set("c", forKey: "launcherPrefs.v1")
        let sound = try XCTUnwrap(FeatureReset.areas.first { $0.id == "sound" })
        XCTAssertEqual(FeatureReset.reset(sound, in: defaults), 2)
        XCTAssertNil(defaults.object(forKey: "soundRules.v1"))
        XCTAssertEqual(defaults.string(forKey: "launcherPrefs.v1"), "c")
        XCTAssertEqual(FeatureReset.reset(sound, in: defaults), 0, "nothing left to remove")
    }

    func testNoKeyBelongsToTwoAreas() {
        let keys = FeatureReset.areas.flatMap(\.keys)
        XCTAssertEqual(keys.count, Set(keys).count)
        XCTAssertEqual(FeatureReset.areas.count, Set(FeatureReset.areas.map(\.id)).count)
    }
}

final class PlaceStabilityTests: XCTestCase {
    func testOldOrRoughReadingsAreNotUsed() {
        XCTAssertTrue(PlaceRules.isUsable(accuracy: 50, age: 10))
        XCTAssertFalse(PlaceRules.isUsable(accuracy: 50, age: 600), "stale")
        XCTAssertFalse(PlaceRules.isUsable(accuracy: 5000, age: 1), "too rough")
        XCTAssertFalse(PlaceRules.isUsable(accuracy: -1, age: 1), "invalid")
    }

    func testThePlaceIsKeptWhileTheEdgeWobbles() {
        let home = PlaceRule(name: "Home", latitude: 0, longitude: 0, radius: 200, outputContains: "Speakers")
        // About 230 m east: outside the 200 m radius, inside the 1.3 × margin (260 m).
        let wobble = 230.0 / 111_320.0
        XCTAssertNil(PlaceRules.place(at: 0, wobble, in: [home]))
        XCTAssertEqual(PlaceRules.place(at: 0, wobble, in: [home], current: home)?.name, "Home")
        XCTAssertNil(PlaceRules.place(at: 0, 400.0 / 111_320.0, in: [home], current: home), "clearly gone")
        var off = home; off.enabled = false
        XCTAssertNil(PlaceRules.place(at: 0, 0, in: [off], current: home), "a place switched off is left")
    }
}

final class PlaceSwitcherTests: XCTestCase {
    private let home = PlaceRule(name: "Home", latitude: 0, longitude: 0, outputContains: "Speakers", fallbacks: ["Headphones"], dwellSeconds: 60)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testItWaitsOutThePassThroughThenSwitchesOnce() {
        var state = PlaceSwitchState()
        XCTAssertNil(PlaceSwitcher.decide(&state, place: home, now: t0, outputIsOurs: true), "first sight starts the wait")
        XCTAssertNil(PlaceSwitcher.decide(&state, place: home, now: t0.addingTimeInterval(30), outputIsOurs: true))
        XCTAssertEqual(PlaceSwitcher.decide(&state, place: home, now: t0.addingTimeInterval(61), outputIsOurs: true)?.name, "Home")
        XCTAssertNil(PlaceSwitcher.decide(&state, place: home, now: t0.addingTimeInterval(200), outputIsOurs: true), "once only")
    }

    func testLeavingBeforeTheWaitIsOverCancelsIt() {
        var state = PlaceSwitchState()
        _ = PlaceSwitcher.decide(&state, place: home, now: t0, outputIsOurs: true)
        _ = PlaceSwitcher.decide(&state, place: nil, now: t0.addingTimeInterval(30), outputIsOurs: true)
        XCTAssertNil(PlaceSwitcher.decide(&state, place: home, now: t0.addingTimeInterval(90), outputIsOurs: true), "the wait starts again")
    }

    func testAManualChoiceIsRespectedUntilTheMacLeaves() {
        var state = PlaceSwitchState()
        _ = PlaceSwitcher.decide(&state, place: home, now: t0, outputIsOurs: true)
        _ = PlaceSwitcher.decide(&state, place: home, now: t0.addingTimeInterval(61), outputIsOurs: true)
        XCTAssertNil(PlaceSwitcher.decide(&state, place: home, now: t0.addingTimeInterval(100), outputIsOurs: false))
        XCTAssertEqual(state.overriddenID, home.id)
        XCTAssertNil(PlaceSwitcher.decide(&state, place: home, now: t0.addingTimeInterval(1000), outputIsOurs: false))
        _ = PlaceSwitcher.decide(&state, place: nil, now: t0.addingTimeInterval(2000), outputIsOurs: false)
        XCTAssertNil(state.overriddenID, "leaving clears it")
    }

    func testAShortHopBetweenPlacesRestsAfterASwitch() {
        var state = PlaceSwitchState()
        var work = PlaceRule(name: "Work", latitude: 1, longitude: 1, outputContains: "Display"); work.dwellSeconds = 10
        _ = PlaceSwitcher.decide(&state, place: home, now: t0, outputIsOurs: true)
        XCTAssertNotNil(PlaceSwitcher.decide(&state, place: home, now: t0.addingTimeInterval(61), outputIsOurs: true))
        _ = PlaceSwitcher.decide(&state, place: work, now: t0.addingTimeInterval(70), outputIsOurs: true)
        XCTAssertNil(PlaceSwitcher.decide(&state, place: work, now: t0.addingTimeInterval(90), outputIsOurs: true), "inside the five-minute rest")
        XCTAssertNotNil(PlaceSwitcher.decide(&state, place: work, now: t0.addingTimeInterval(400), outputIsOurs: true))
    }

    func testOutputsAreListedBestFirst() {
        XCTAssertEqual(home.outputs, ["Speakers", "Headphones"])
        XCTAssertEqual(PlaceRule(name: "x", latitude: 0, longitude: 0, outputContains: " ").outputs, [])
    }

    func testPlacesSavedBeforeTheNewFieldsStillLoad() throws {
        let old = #"{"id":"1","name":"Home","latitude":1,"longitude":2,"radius":150,"outputContains":"Speakers","enabled":true}"#
        let rule = try JSONDecoder().decode(PlaceRule.self, from: Data(old.utf8))
        XCTAssertNil(rule.fallbacks)
        XCTAssertEqual(rule.outputs, ["Speakers"])
    }

    func testMIDIDeviceNameNarrowsATrigger() {
        var trigger = MIDITrigger(); trigger.targetID = "wf"
        let pad = MIDIMessage(kind: .noteOn, channel: 1, number: 60, value: 90, device: "Launchpad Mini")
        XCTAssertTrue(trigger.matches(pad), "no device means any")
        trigger.device = "launchpad"
        XCTAssertTrue(trigger.matches(pad))
        trigger.device = "keystation"
        XCTAssertFalse(trigger.matches(pad))
        XCTAssertEqual(MIDITriggers.learned(from: pad).device, "Launchpad Mini")
    }
}

final class MIDIRunningStatusTests: XCTestCase {
    func testDataOnlyBytesUseTheLastStatus() {
        var running: UInt8?
        let first = MIDIMessage.parse([0xB0, 21, 10, 21, 11, 21, 12], running: &running)
        XCTAssertEqual(first.map(\.value), [10, 11, 12])
        XCTAssertEqual(running, 0xB0)
        let next = MIDIMessage.parse([21, 99], running: &running)
        XCTAssertEqual(next.first?.value, 99, "it carries over between calls")
    }

    func testClockKeepsItAndBadDataOrSystemMessagesEndIt() {
        var running: UInt8? = 0x90
        XCTAssertEqual(MIDIMessage.parse([0xF8, 60, 100], running: &running).count, 1, "clock does not end it")
        XCTAssertTrue(MIDIMessage.parse([0xF0, 1, 2, 0xF7, 60, 100], running: &running).isEmpty, "sysex ends it")
        XCTAssertNil(running)
        running = 0x90
        XCTAssertTrue(MIDIMessage.parse([0x90, 60], running: &running).isEmpty, "a cut-off message")
        XCTAssertNil(running, "and it ends running status")
        XCTAssertTrue(MIDIMessage.parse([60, 100], running: &running).isEmpty, "so loose data after it is ignored")
    }

    func testTriggersThatWouldBothFireAreFlagged() {
        var a = MIDITrigger(); a.number = 60; a.channel = 1
        var b = MIDITrigger(); b.number = 60; b.channel = nil
        var c = MIDITrigger(); c.number = 60; c.channel = 2
        var d = MIDITrigger(); d.number = 61
        XCTAssertEqual(MIDITriggers.conflicts(of: a, in: [a, b, c, d]).map(\.id), [b.id], "same note, overlapping channel")
        c.minValue = 50; c.maxValue = 60; b.channel = 2; b.minValue = 70
        XCTAssertTrue(MIDITriggers.conflicts(of: c, in: [b, c]).isEmpty, "value ranges that do not meet")
        a.device = "Launchpad"; b.channel = 1; b.minValue = 1; b.device = "Keystation"
        XCTAssertTrue(MIDITriggers.conflicts(of: a, in: [a, b]).isEmpty, "different devices")
        b.enabled = false; b.device = nil
        XCTAssertTrue(MIDITriggers.conflicts(of: a, in: [a, b]).isEmpty, "switched off")
    }
}

final class ResetRollbackTests: XCTestCase {
    func testAResetCanBeTakenBackAndTheFileIsOnlyTrustedForOurAreas() throws {
        let defaults = UserDefaults(suiteName: "kriya-undo-\(UUID().uuidString)")!
        defaults.set("rules", forKey: "soundRules.v1")
        defaults.set(true, forKey: "soundNotifiesDevices")
        defaults.set("keep", forKey: "launcherPrefs.v1")
        let sound = try XCTUnwrap(FeatureReset.areas.first { $0.id == "sound" })
        let held = FeatureReset.capture(sound, in: defaults)
        XCTAssertEqual(held.count, 2)
        FeatureReset.reset(sound, in: defaults)
        XCTAssertNil(defaults.object(forKey: "soundRules.v1"))

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-undo-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: file) }
        let undo = FeatureResetUndo(file: file)
        try undo.save(area: sound, values: held.merging(["launcherPrefs.v1": "evil"]) { a, _ in a })
        let loaded = try XCTUnwrap(undo.load())
        XCTAssertEqual(loaded.area.id, "sound")
        XCTAssertEqual(FeatureReset.restore(loaded.values, to: loaded.area, in: defaults), 2, "a key from another area is not written")
        XCTAssertEqual(defaults.string(forKey: "soundRules.v1"), "rules")
        XCTAssertEqual(defaults.string(forKey: "launcherPrefs.v1"), "keep")
        XCTAssertNil(undo.load(now: Date().addingTimeInterval(FeatureResetUndo.keepFor + 60)), "a day later it is no longer offered")
        undo.clear()
        XCTAssertNil(undo.load())
    }
}

final class PreviousAreaTests: XCTestCase {
    func testAnAreaIsOnlyValidOnTheSameDisplays() throws {
        let one = PreviousArea.layoutKey([CGRect(x: 0, y: 0, width: 1512, height: 982)], scales: [2])
        let two = PreviousArea.layoutKey([CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: 0, width: 2560, height: 1440)], scales: [2, 2])
        let area = try XCTUnwrap(PreviousArea(rect: CGRect(x: 100.4, y: 200.6, width: 300, height: 150), layout: one))
        XCTAssertEqual(area.valid(for: one), CGRect(x: 100, y: 201, width: 300, height: 150))
        XCTAssertNil(area.valid(for: two), "a display was added")
    }

    func testTooSmallOrNonsenseRectanglesAreRefused() {
        XCTAssertNil(PreviousArea(rect: CGRect(x: 0, y: 0, width: 3, height: 300), layout: "a"))
        XCTAssertNil(PreviousArea(rect: CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100), layout: "a"))
    }

    func testAppKitCoordinatesBecomeTopLeftOnes() {
        let converted = PreviousArea.fromAppKit(CGRect(x: 50, y: 100, width: 200, height: 80), mainHeight: 1000)
        XCTAssertEqual(converted, CGRect(x: 50, y: 820, width: 200, height: 80))
    }

    func testTheCaptureCommandNamesTheAreaAndNothingElseIsAsked() throws {
        let area = try XCTUnwrap(PreviousArea(rect: CGRect(x: 10, y: 20, width: 300, height: 200), layout: "a"))
        let out = URL(fileURLWithPath: "/tmp/x.png")
        XCTAssertEqual(ScreenCaptureArguments.area(area, delay: 0, sound: false, output: out), ["-R", "10,20,300,200", "-x", "-t", "png", "/tmp/x.png"])
        XCTAssertFalse(ScreenCaptureArguments.area(area, delay: 3, sound: true, output: out).contains("-i"), "no interactive selection")
    }
}

final class TimingTableTests: XCTestCase {
    func testTotalsAverageAndWorstAreKept() {
        var table = TimingTable()
        table.record("a", microseconds: 100)
        table.record("a", microseconds: 300)
        table.record("b", microseconds: 1000)
        let a = table.stats["a"]
        XCTAssertEqual(a?.count, 2)
        XCTAssertEqual(a?.averageMicroseconds, 200)
        XCTAssertEqual(a?.worstMicroseconds, 300)
        XCTAssertEqual(table.ranked.map(\.name), ["b", "a"], "busiest first")
        table.record("c", microseconds: -5)
        XCTAssertNil(table.stats["c"], "a negative reading is ignored")
    }

    func testTheNumberOfNamesIsBounded() {
        var table = TimingTable()
        for i in 0..<(TimingTable.maxNames + 20) { table.record("n\(i)", microseconds: 1) }
        XCTAssertEqual(table.stats.count, TimingTable.maxNames)
        table.record("n0", microseconds: 1)
        XCTAssertEqual(table.stats["n0"]?.count, 2, "names already known keep counting")
    }

    func testMeasuringWhileOffJustRunsTheWork() {
        let timings = FeatureTimings.shared
        let was = timings.enabled
        timings.enabled = false
        XCTAssertEqual(timings.measure("x") { 41 + 1 }, 42)
        XCTAssertTrue(timings.table.stats.isEmpty)
        timings.enabled = was
    }

    func testMemoryCanBeRead() {
        XCTAssertGreaterThan(ProcessMemory.residentBytes() ?? 0, 0)
    }
}

final class DDCTests: XCTestCase {
    func testSetPacketsCarryTheValueAndAChecksum() {
        let packet = DDC.setPacket(0x10, value: 0x0032)
        XCTAssertEqual(Array(packet.prefix(5)), [0x84, 0x03, 0x10, 0x00, 0x32])
        XCTAssertEqual(packet.last, 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x32)
        XCTAssertEqual(DDC.getRequest(0x60), [0x82, 0x01, 0x60, 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x60])
    }

    func testRepliesAreReadOnlyWhenTheyAnswerTheQuestionAsked() {
        let good: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0x00]
        XCTAssertEqual(DDC.parseReply(good, vcp: 0x10), DDC.Reading(current: 50, maximum: 100))
        XCTAssertNil(DDC.parseReply(good, vcp: 0x60), "an answer about a different feature")
        var unsupported = good; unsupported[3] = 0x01
        XCTAssertNil(DDC.parseReply(unsupported, vcp: 0x10), "the monitor says it has no such feature")
        XCTAssertNil(DDC.parseReply(Array(good.prefix(6)), vcp: 0x10), "too short")
        var zeroMax = good; zeroMax[6] = 0; zeroMax[7] = 0
        XCTAssertNil(DDC.parseReply(zeroMax, vcp: 0x10), "brightness with no range")
    }

    func testBrightnessScalesToTheMonitorsOwnRange() {
        XCTAssertEqual(DDC.raw(fromPercent: 50, maximum: 100), 50)
        XCTAssertEqual(DDC.raw(fromPercent: 50, maximum: 255), 128)
        XCTAssertEqual(DDC.raw(fromPercent: 500, maximum: 100), 100, "never past the maximum")
        XCTAssertEqual(DDC.raw(fromPercent: -5, maximum: 100), 0)
        XCTAssertEqual(DDC.percent(fromRaw: 128, maximum: 255), 50)
        XCTAssertEqual(DDC.percent(fromRaw: 5, maximum: 0), 0)
    }

    func testInputNamesAndPresetPlans() {
        XCTAssertEqual(DDC.inputName(0x11), "HDMI 1")
        XCTAssertEqual(DDC.inputName(0x2A), "Input 0x2A")
        let preset = MonitorPreset(name: "Desk", settings: [
            MonitorSetting(monitor: "Studio", brightnessPercent: 40, inputCode: 0x0F),
            MonitorSetting(monitor: "Gone", brightnessPercent: 10, inputCode: nil),
        ])
        XCTAssertEqual(MonitorPresets.plan(preset, connected: ["Studio"]), ["Studio: brightness 40%, input DisplayPort 1", "Gone: not connected, skipped"])
    }
}

final class ExtensionBundleTests: XCTestCase {
    private func draft() -> ExtensionManifest {
        ExtensionManifest(id: "acme.tools", name: "Acme Tools", version: "1.0.0", author: "Acme", summary: nil, publisherKey: "", permissions: [.clipboard],
                          commands: [ExtensionCommand(id: "hello", title: "Say hello", subtitle: nil, script: "scripts/hello.sh", arguments: nil, symbol: nil)], files: [:], signature: nil)
    }
    private let files: [String: Data] = ["scripts/hello.sh": Data("echo hi".utf8)]

    func testASignedBundleVerifiesAndATamperedOneDoesNot() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signed = try ExtensionBundle.sign(draft(), files: files, with: key)
        XCTAssertNoThrow(try ExtensionBundle.verify(signed, listing: ["scripts/hello.sh"]) { self.files[$0] })

        XCTAssertThrowsError(try ExtensionBundle.verify(signed, listing: ["scripts/hello.sh"]) { _ in Data("echo evil".utf8) }) { XCTAssertEqual($0 as? ExtensionProblem, .fileChanged("scripts/hello.sh")) }
        XCTAssertThrowsError(try ExtensionBundle.verify(signed, listing: ["scripts/hello.sh", "extra.sh"]) { self.files[$0] }) { XCTAssertEqual($0 as? ExtensionProblem, .unlistedFile("extra.sh")) }
        XCTAssertThrowsError(try ExtensionBundle.verify(signed, listing: []) { _ in nil }) { XCTAssertEqual($0 as? ExtensionProblem, .fileMissing("scripts/hello.sh")) }

        var renamed = signed; renamed.name = "Evil Tools"
        XCTAssertThrowsError(try ExtensionBundle.verify(renamed, listing: ["scripts/hello.sh"]) { self.files[$0] }) { XCTAssertEqual($0 as? ExtensionProblem, .badSignature) }
        var permitted = signed; permitted.permissions = [.clipboard, .network]
        XCTAssertThrowsError(try ExtensionBundle.verify(permitted, listing: ["scripts/hello.sh"]) { self.files[$0] }, "adding a permission breaks the signature")

        var swapped = signed; swapped.publisherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertThrowsError(try ExtensionBundle.verify(swapped, listing: ["scripts/hello.sh"]) { self.files[$0] }) { XCTAssertEqual($0 as? ExtensionProblem, .badSignature) }

        var unsigned = signed; unsigned.signature = nil
        XCTAssertThrowsError(try ExtensionBundle.verify(unsigned, listing: ["scripts/hello.sh"]) { self.files[$0] }) { XCTAssertEqual($0 as? ExtensionProblem, .notSigned) }
    }

    func testPathsCannotEscapeTheBundle() {
        for bad in ["../x.sh", "/etc/passwd", "a/../../b", ".hidden", "a//b", "manifest.json", "", "a/.git/x", "x;rm.sh"] {
            XCTAssertFalse(ExtensionBundle.isSafeRelativePath(bad), bad)
        }
        XCTAssertTrue(ExtensionBundle.isSafeRelativePath("scripts/hello world.sh"))
        var m = draft(); m.commands[0].script = "../outside.sh"
        XCTAssertThrowsError(try ExtensionBundle.sign(m, files: ["../outside.sh": Data()], with: Curve25519.Signing.PrivateKey()))
    }

    func testUpdatesNeedTheSamePublisherAndANewerVersion() throws {
        let key = Curve25519.Signing.PrivateKey()
        let v1 = try ExtensionBundle.sign(draft(), files: files, with: key)
        var next = draft(); next.version = "1.1.0"
        let v2 = try ExtensionBundle.sign(next, files: files, with: key)
        XCTAssertNoThrow(try ExtensionBundle.checkUpdate(new: v2, installed: v1))
        XCTAssertThrowsError(try ExtensionBundle.checkUpdate(new: v1, installed: v2)) { XCTAssertEqual($0 as? ExtensionProblem, .olderVersion(installed: "1.1.0")) }
        let other = try ExtensionBundle.sign(next, files: files, with: Curve25519.Signing.PrivateKey())
        XCTAssertThrowsError(try ExtensionBundle.checkUpdate(new: other, installed: v1)) { XCTAssertEqual($0 as? ExtensionProblem, .sameIDDifferentPublisher) }
        XCTAssertNoThrow(try ExtensionBundle.checkUpdate(new: v1, installed: nil))
        XCTAssertEqual(ExtensionBundle.compareVersions("1.10", "1.9"), 1)
        XCTAssertEqual(ExtensionBundle.compareVersions("2", "2.0.0"), 0)
    }

    func testShapeAndFingerprints() throws {
        var m = draft(); m.id = "Bad ID"; m.commands.append(m.commands[0])
        let problems = ExtensionBundle.shapeProblems(m)
        XCTAssertTrue(problems.contains { $0.contains("id must be") })
        XCTAssertTrue(problems.contains { $0.contains("share an id") })
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let print = ExtensionBundle.fingerprint(ofKey: key)
        XCTAssertEqual(print.split(separator: " ").count, 4)
        XCTAssertEqual(print, ExtensionBundle.fingerprint(ofKey: key))
        XCTAssertEqual(ExtensionBundle.interpreter(for: "a/b.py")?.path, "/usr/bin/python3")
        XCTAssertNil(ExtensionBundle.interpreter(for: "tool"))
    }
}

final class FinderDrawerListTests: XCTestCase {
    func testFilesAreKeptOnceInOrderAndBounded() {
        var list = FinderDrawerList()
        XCTAssertEqual(list.add(["/a", "/b", "/a", ""]), 2)
        XCTAssertEqual(list.paths, ["/a", "/b"])
        let many = (0..<(FinderDrawerList.capacity + 5)).map { "/f\($0)" }
        list.add(many)
        XCTAssertEqual(list.paths.count, FinderDrawerList.capacity)
    }

    func testReorderingMatchesAListsDrag() {
        var list = FinderDrawerList()
        list.add(["/a", "/b", "/c", "/d"])
        list.move(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(list.paths, ["/b", "/c", "/a", "/d"])
        list.move(from: IndexSet(integer: 3), to: 0)
        XCTAssertEqual(list.paths, ["/d", "/b", "/c", "/a"])
        list.move(from: IndexSet(integer: 99), to: 0)
        XCTAssertEqual(list.paths.count, 4, "a drag from nowhere changes nothing")
    }

    func testMissingFilesAreDroppedAndRemovalWorks() {
        var list = FinderDrawerList()
        list.add(["/a", "/gone", "/b"])
        list.prune { $0 != "/gone" }
        XCTAssertEqual(list.paths, ["/a", "/b"])
        list.remove("/a")
        XCTAssertEqual(list.paths, ["/b"])
        list.clear()
        XCTAssertTrue(list.paths.isEmpty)
    }
}

final class TextSizeTests: XCTestCase {
    func testTheLargerOfTheChoiceAndTheWindowIsUsed() {
        XCTAssertEqual(TextSize.larger(of: .standard, .large), .large)
        XCTAssertEqual(TextSize.larger(of: .larger, .large), .larger)
        XCTAssertEqual(TextSize.forWidth(900), .standard)
        XCTAssertEqual(TextSize.forWidth(1500), .large)
        XCTAssertEqual(TextSize.forWidth(2400), .larger)
        XCTAssertNil(TextSize.standard.points, "standard leaves the system size alone")
        XCTAssertEqual(TextSize.allCases.map(\.level), [0, 1, 2, 3])
    }

    func testHigherContrastReallyIsHigherContrast() {
        let lightBackground: (CGFloat, CGFloat, CGFloat) = (1, 1, 1)
        let darkBackground: (CGFloat, CGFloat, CGFloat) = (0.1, 0.1, 0.1)
        let warnLight: (CGFloat, CGFloat, CGFloat) = (0.60, 0.44, 0.12)
        let warnDark: (CGFloat, CGFloat, CGFloat) = (0.83, 0.66, 0.37)
        XCTAssertGreaterThan(ContrastBoost.ratio(ContrastBoost.adjust(warnLight, dark: false), lightBackground), ContrastBoost.ratio(warnLight, lightBackground))
        XCTAssertGreaterThan(ContrastBoost.ratio(ContrastBoost.adjust(warnDark, dark: true), darkBackground), ContrastBoost.ratio(warnDark, darkBackground))
        XCTAssertEqual(ContrastBoost.ratio(lightBackground, (0, 0, 0)), 21, accuracy: 0.01)
        let boosted = ContrastBoost.adjust((1, 1, 1), dark: true)
        XCTAssertLessThanOrEqual(max(boosted.0, boosted.1, boosted.2), 1)
    }
}

final class ClipSyncTests: XCTestCase {
    private func item(_ text: String, _ kind: ClipSyncItem.Kind = .snippet, title: String = "", at: Double = 100, origin: String? = nil) -> ClipSyncItem {
        ClipSyncItem(key: ClipSync.key(kind: kind, title: title, text: text), kind: kind, title: title, text: text, updatedAt: at, origin: origin)
    }
    private func file(_ items: [ClipSyncItem], _ tombs: [ClipSyncTombstone] = [], mac: String = "Other") -> ClipSyncFile {
        ClipSyncFile(mac: mac, macID: UUID().uuidString, written: 0, items: items, tombstones: tombs)
    }

    func testSecretsImagesAndHugeTextAreNeverShared() {
        XCTAssertTrue(ClipSync.isShareable(isText: true, sensitive: false, text: "hello"))
        XCTAssertFalse(ClipSync.isShareable(isText: true, sensitive: true, text: "hunter2"))
        XCTAssertFalse(ClipSync.isShareable(isText: false, sensitive: false, text: "x"))
        XCTAssertFalse(ClipSync.isShareable(isText: true, sensitive: false, text: "   \n"))
        XCTAssertFalse(ClipSync.isShareable(isText: true, sensitive: false, text: String(repeating: "a", count: ClipSync.maxTextLength + 1)))
    }

    func testNewThingsFromOtherMacsAreAddedOnce() {
        let mine = [item("a")]
        let theirs = file([item("a"), item("b"), item("b", at: 200)])
        let plan = ClipSync.merge(local: mine, localTombstones: [], remote: [theirs, file([item("b", at: 300)])], includeHistory: false)
        XCTAssertEqual(plan.add.map(\.text), ["b"], "already-held and duplicate items are not added twice")
        XCTAssertEqual(plan.add.first?.updatedAt, 300, "the newest copy wins")
        XCTAssertTrue(plan.remove.isEmpty)
    }

    func testHistoryIsOnlyTakenWhenAskedFor() {
        let theirs = file([item("h", .history), item("p", .pinned)])
        XCTAssertEqual(ClipSync.merge(local: [], localTombstones: [], remote: [theirs], includeHistory: false).add.map(\.text), ["p"])
        XCTAssertEqual(Set(ClipSync.merge(local: [], localTombstones: [], remote: [theirs], includeHistory: true).add.map(\.text)), ["p", "h"])
    }

    func testARemovalTravelsButOnlyIfItIsNewerThanTheItem() {
        let old = item("gone", at: 100)
        let theirs = file([], [ClipSyncTombstone(key: old.key, at: 150)])
        XCTAssertEqual(ClipSync.merge(local: [old], localTombstones: [], remote: [theirs], includeHistory: false).remove, [old.key])
        let readded = item("gone", at: 200)
        XCTAssertTrue(ClipSync.merge(local: [readded], localTombstones: [], remote: [theirs], includeHistory: false).remove.isEmpty, "added again after it was removed")
        XCTAssertTrue(ClipSync.merge(local: [], localTombstones: [], remote: [file([old]), theirs], includeHistory: false).add.isEmpty, "a removed item is not brought back")
        let hist = item("h", .history, at: 100)
        XCTAssertTrue(ClipSync.merge(local: [hist], localTombstones: [], remote: [file([], [ClipSyncTombstone(key: hist.key, at: 500)])], includeHistory: true).remove.isEmpty, "history ages out by itself")
    }

    func testTwoSnippetsWithTheSameNameAreBothKept() {
        let mine = [item("my text", title: "Sig")]
        let plan = ClipSync.merge(local: mine, localTombstones: [], remote: [file([item("their text", title: "Sig", origin: "Studio")])], includeHistory: false)
        XCTAssertEqual(plan.add.first?.title, "Sig (from Studio)")
    }

    func testTombstonesComeFromWhatWentMissingAndAreForgottenAfterAWhile() {
        let t = ClipSync.newTombstones(previous: ["a", "b"], current: ["b", "c"], now: 1000)
        XCTAssertEqual(t, [ClipSyncTombstone(key: "a", at: 1000)])
        let old = ClipSyncTombstone(key: "x", at: 0)
        XCTAssertTrue(ClipSync.pruned([old], now: 100 * 86_400).isEmpty)
        XCTAssertEqual(ClipSync.pruned([ClipSyncTombstone(key: "y", at: 5), ClipSyncTombstone(key: "y", at: 9)], now: 10).map(\.at), [9])
    }

    func testFilesAreEncryptedAndOnlyOpenWithThePassphrase() throws {
        let f = file([item("secret-ish snippet")])
        let data = try ClipSync.encode(f, passphrase: "correct horse")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret-ish"), "the text is not readable in the file")
        XCTAssertEqual(try ClipSync.decode(data, passphrase: "correct horse").items, f.items)
        XCTAssertThrowsError(try ClipSync.decode(data, passphrase: "wrong passphrase")) { XCTAssertEqual($0 as? BackupCryptoError, .wrongPassphrase) }
        XCTAssertTrue(ClipSync.isSyncFileName(ClipSync.fileName(macID: UUID().uuidString)))
        XCTAssertFalse(ClipSync.isSyncFileName("clipboard-../x.kriyasync"))
    }
}
