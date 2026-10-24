import Foundation

/// A request typed in plain words, once it has been understood: one typed value for everything the launcher can be asked to do.
/// Nothing here runs anything. The intent is checked (`IntentValidator`), judged (`IntentPolicy`), shown to the person, and only
/// then handed to the existing commands, actions and windows, which are the only things that act.
indirect enum LauncherIntent: Equatable {
    /// Plain launcher search; also what a request becomes when it cannot be understood.
    case search(String)
    case openApp(bundleID: String)
    case openFile(URL)
    case searchFiles(query: String, range: IntentDateRange?)
    case searchNotes(String)
    case searchClipboard(String)
    case searchBrowserTabs(String)
    case webSearch(engine: String, query: String)
    case askAI(String)
    case startTimer(seconds: TimeInterval, label: String?)
    case startFocusSession(minutes: Int)
    case runWorkflow(id: String)
    /// A command from the command registry (`ActionExecutor`), by name. Never text that is run by a shell.
    case runCommand(String, arguments: [String: String])
    /// `appID` is a bundle identifier, or `IntentWorld.systemApp` for all sound. `value` is 0...1 for 0...100%.
    case setVolume(appID: String, value: Double)
    /// Mutes for `seconds`, or until it is unmuted when nil.
    case muteApp(appID: String, seconds: TimeInterval?)
    case unmuteApp(appID: String)
    case muteAllExcept(appID: String)
    /// A sound output by its device identifier; nil asks which.
    case chooseAudioOutput(deviceUID: String?)
    case moveWindow(WindowPlacement)
    case capture(CaptureMode, action: CaptureAction)
    case addToShelf([URL])
    case openSettings(SettingsPane, tab: String?)
    /// Several requests said in one sentence ("mute Spotify and move this window left"), run in order.
    case sequence([LauncherIntent])

    /// The name used in logs and in what an AI may answer with. Only this, never the arguments, goes in the audit log.
    var kind: String {
        switch self {
        case .search: return "search"
        case .openApp: return "openApp"
        case .openFile: return "openFile"
        case .searchFiles: return "searchFiles"
        case .searchNotes: return "searchNotes"
        case .searchClipboard: return "searchClipboard"
        case .searchBrowserTabs: return "searchBrowserTabs"
        case .webSearch: return "webSearch"
        case .askAI: return "askAI"
        case .startTimer: return "startTimer"
        case .startFocusSession: return "startFocusSession"
        case .runWorkflow: return "runWorkflow"
        case .runCommand: return "runCommand"
        case .setVolume: return "setVolume"
        case .muteApp: return "muteApp"
        case .unmuteApp: return "unmuteApp"
        case .muteAllExcept: return "muteAllExcept"
        case .chooseAudioOutput: return "chooseAudioOutput"
        case .moveWindow: return "moveWindow"
        case .capture: return "capture"
        case .addToShelf: return "addToShelf"
        case .openSettings: return "openSettings"
        case .sequence: return "sequence"
        }
    }
}

/// Where a window goes. The same layouts the window manager already has.
typealias WindowPlacement = WindowLayout

enum IntentDateRange: Equatable {
    case today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth
    case lastDays(Int)

    var phrase: String {
        switch self {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .thisWeek: return "this week"
        case .lastWeek: return "last week"
        case .thisMonth: return "this month"
        case .lastMonth: return "last month"
        case .lastDays(let n): return "the last \(n) days"
        }
    }

    /// The dates it covers, from the start (included) to the end (excluded), by the calendar's own idea of a week and a month.
    func interval(now: Date, calendar: Calendar) -> DateInterval {
        let startOfToday = calendar.startOfDay(for: now)
        func week(_ offset: Int) -> DateInterval {
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: startOfToday, duration: 7 * 86_400)
            let start = calendar.date(byAdding: .weekOfYear, value: offset, to: thisWeek.start) ?? thisWeek.start
            return DateInterval(start: start, end: calendar.date(byAdding: .weekOfYear, value: 1, to: start) ?? thisWeek.end)
        }
        func month(_ offset: Int) -> DateInterval {
            let thisMonth = calendar.dateInterval(of: .month, for: now) ?? DateInterval(start: startOfToday, duration: 30 * 86_400)
            let start = calendar.date(byAdding: .month, value: offset, to: thisMonth.start) ?? thisMonth.start
            return DateInterval(start: start, end: calendar.date(byAdding: .month, value: 1, to: start) ?? thisMonth.end)
        }
        switch self {
        case .today: return DateInterval(start: startOfToday, end: calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now)
        case .yesterday:
            let start = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            return DateInterval(start: start, end: startOfToday)
        case .thisWeek: return week(0)
        case .lastWeek: return week(-1)
        case .thisMonth: return month(0)
        case .lastMonth: return month(-1)
        case .lastDays(let n):
            let start = calendar.date(byAdding: .day, value: -max(n, 1), to: startOfToday) ?? startOfToday
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now)
        }
    }
}

/// Whether a request may run at once or must be confirmed first, and why.
enum IntentRisk: Equatable {
    case safe
    case confirm(reason: String)

    var needsConfirmation: Bool { if case .confirm = self { return true }; return false }
}

/// Where a reading of the request came from.
enum IntentSource: String, Equatable {
    /// An explicit keyword command ("timer 5m", "yt cats"), which the launcher already handles. Never reinterpreted.
    case keyword
    /// A deterministic pattern, on this Mac, with no AI.
    case pattern
    /// A model's answer, checked against a strict schema.
    case ai
}

/// A request that was understood: the intent, how it reads to a person, why it was read that way, and whether it asks first.
struct ResolvedIntent: Equatable {
    var intent: LauncherIntent
    /// "Mute Spotify for 1 hour". The words on the row, and in the confirmation.
    var title: String
    /// What it will do, in a sentence.
    var detail: String
    /// How the words were read: "“mute” + an app + a time".
    var why: String
    var risk: IntentRisk
    var source: IntentSource
    /// 1 for an exact pattern with a single match; lower when a name was matched loosely.
    var confidence: Double
    /// The shortcut or command that does the same thing, so a repeated request can be a shortcut instead.
    var shortcutHint: String?
}

/// What came of reading a request.
enum IntentParseResult: Equatable {
    /// Not a request: normal search carries on, and nothing here shows.
    case notAnIntent
    case intent(ResolvedIntent)
    /// Several things it could mean ("I found two apps named Music."); the person picks one, nothing is guessed.
    case ambiguous(question: String, choices: [ResolvedIntent])
    /// Something is missing ("Which output device should I use?"); the choices, if any, are offered.
    case needsInput(question: String, choices: [ResolvedIntent])
    /// Understood and refused, with the reason ("The requested workflow does not exist.").
    case rejected(reason: String)

    var isRequest: Bool { if case .notAnIntent = self { return false }; return true }
}
