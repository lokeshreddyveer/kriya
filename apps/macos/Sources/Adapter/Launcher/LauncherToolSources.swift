import AppKit
import CoreImage
import EventKit
import Foundation

/// The next calendar event, read with the person's permission. It never leaves the Mac and is never stored.
struct NextMeeting: Equatable {
    let title: String
    let start: Date
    let link: URL?
    let calendar: String
}

final class MeetingSource {
    private let store = EKEventStore()
    private var cached: (meeting: NextMeeting?, at: Date)?

    var isAllowed: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var isDenied: Bool { [EKAuthorizationStatus.denied, .restricted].contains(EKEventStore.authorizationStatus(for: .event)) }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { granted, _ in DispatchQueue.main.async { done(granted) } }
    }

    /// The event that is on now or starts within the next 12 hours, preferring one that has a video link. Cached for a minute.
    func next(now: Date = Date()) -> NextMeeting? {
        guard isAllowed else { return nil }
        if let cached, now.timeIntervalSince(cached.at) < 60 { return cached.meeting }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-15 * 60), end: now.addingTimeInterval(12 * 3600), calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
        let meetings = events.map { event in
            NextMeeting(title: event.title ?? "Event", start: event.startDate,
                        link: MeetingLink.extract(from: [event.location, event.notes, event.url?.absoluteString]), calendar: event.calendar.title)
        }
        let choice = meetings.first
        cached = (choice, now)
        return choice
    }
}

/// Daily reference rates for the currency converter. Off unless the person turns it on; only currency codes are ever sent.
final class CurrencyRates {
    private let defaults: UserDefaults
    private let key = "launcherRates.v1"
    private var fetching = false
    var onUpdate: () -> Void = {}

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    struct Snapshot: Codable { var rates: [String: Double]; var date: String?; var fetchedAt: Date }

    var snapshot: Snapshot? { defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } }

    var isFresh: Bool { snapshot.map { Date().timeIntervalSince($0.fetchedAt) < 6 * 3600 } ?? false }

    func refreshIfNeeded() {
        guard !isFresh, !fetching else { return }
        fetching = true
        var request = URLRequest(url: CurrencyConverter.ratesURL, timeoutInterval: 10)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            defer { DispatchQueue.main.async { self.fetching = false } }
            guard let data, let parsed = CurrencyConverter.parseRates(data) else { return }
            let snapshot = Snapshot(rates: parsed.rates, date: parsed.date, fetchedAt: Date())
            if let encoded = try? JSONEncoder().encode(snapshot) { self.defaults.set(encoded, forKey: self.key) }
            DispatchQueue.main.async { self.onUpdate() }
        }.resume()
    }
}

/// Runs a script the person wrote, away from the main thread, and reports what it printed as they chose.
enum ScriptRunner {
    static func run(_ script: ScriptCommand, argument: String, toast: Toast) {
        DispatchQueue.global(qos: .userInitiated).async {
            let environment = ["PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "KRIYA_ARGUMENT": argument]
            do {
                let output = try ToolRunner.run("/bin/zsh", ["-c", script.source, "kriya-script", argument], environment: environment, timeout: 60)
                DispatchQueue.main.async {
                    let line = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                    switch script.output {
                    case .message: toast.show(line.isEmpty ? "\(script.name) finished" : String(line.prefix(160)))
                    case .clipboard:
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output, forType: .string)
                        toast.show("Copied what “\(script.name)” printed")
                    case .nothing: break
                    }
                }
            } catch {
                DispatchQueue.main.async { toast.show("“\(script.name)” failed: \(error.localizedDescription)", isError: true) }
            }
        }
    }
}

/// What the launcher shows for quicklinks, scripts, converters, generators and the next meeting.
final class LauncherToolSources: ObservableObject {
    let extras: LauncherExtras
    let meetings = MeetingSource()
    let rates = CurrencyRates()
    private let toast = Toast()
    private let prefs: LauncherPrefs
    var onChange: () -> Void = {}

    init(extras: LauncherExtras, prefs: LauncherPrefs) {
        self.extras = extras
        self.prefs = prefs
        rates.onUpdate = { [weak self] in self?.onChange() }
    }

    private func copy(_ text: String, message: String = "Copied") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toast.show(message)
    }

    // MARK: Always listed

    func staticEntries() -> [PaletteEntry] {
        var list: [PaletteEntry] = []
        let data = prefs.data
        if data.isEnabled(.web) {
            for link in extras.quicklinks {
                guard let url = link.url(for: "") else { continue }
                list.append(PaletteEntry(
                    id: "quicklink:\(link.id)", title: link.name, subtitle: link.takesQuery && !link.keyword.isEmpty ? "Quicklink · type “\(link.keyword) …”" : "Quicklink",
                    symbol: "link", category: .web, keywords: [link.keyword]
                ) { NSWorkspace.shared.open(url) })
            }
        }
        for script in extras.scripts {
            list.append(PaletteEntry(
                id: "script:\(script.id)", title: script.name, subtitle: script.keyword.isEmpty ? "Script" : "Script · type “\(script.keyword)”", symbol: "terminal", category: .command,
                keywords: [script.keyword]
            ) { [weak self] in
                guard let self else { return }
                ScriptRunner.run(script, argument: "", toast: self.toast)
            })
        }
        if data.isEnabled(.tools) {
            list.append(PaletteEntry(id: "tool:pick-color", title: "Pick a color from the screen", subtitle: "Copies its hex code", symbol: "eyedropper", category: .tools, keywords: ["colour", "eyedropper", "hex"]) { [weak self] in
                self?.pickColor()
            })
            list.append(PaletteEntry(id: "tool:uuid", title: "New UUID", subtitle: "Copies it", symbol: "number.square", category: .tools, keywords: ["guid", "identifier"], rememberable: false) { [weak self] in
                self?.copy(UUID().uuidString.lowercased(), message: "Copied a new UUID")
            })
        }
        return list
    }

    /// The next meeting and a way to join it, when the person allowed their calendar.
    func meetingEntries() -> [PaletteEntry] {
        guard prefs.data.isEnabled(.tools), prefs.data.showMeeting == true, let meeting = meetings.next() else { return [] }
        let when = MeetingLink.relative(meeting.start)
        var entries: [PaletteEntry] = []
        if let link = meeting.link {
            entries.append(PaletteEntry(
                id: "meeting:join", title: "Join “\(meeting.title)”", subtitle: "\(when) · \(meeting.calendar)", symbol: "video", category: .tools,
                keywords: ["meeting", "call", "zoom", "meet", "teams", "next"], rememberable: false, queryScore: nil,
                actions: [PaletteAction(title: "Copy the Link", symbol: "doc.on.doc") { [weak self] in self?.copy(link.absoluteString) }]
            ) { NSWorkspace.shared.open(link) })
        } else {
            entries.append(PaletteEntry(
                id: "meeting:next", title: meeting.title, subtitle: "Next event \(when) · \(meeting.calendar)", symbol: "calendar", category: .tools,
                keywords: ["meeting", "next", "calendar"], rememberable: false
            ) { NSWorkspace.shared.open(URL(string: "ical://")!) })
        }
        return entries
    }

    // MARK: Depends on what was typed

    func queryEntries(_ text: String) -> [PaletteEntry] {
        var found: [PaletteEntry] = []
        let data = prefs.data

        if data.isEnabled(.web), let (link, query) = LauncherExtraMatch.quicklink(in: text, among: extras.quicklinks), let url = link.url(for: query) {
            found.append(PaletteEntry(
                id: "quicklink:\(link.id):\(query)", title: "\(link.name): \(query.count > 60 ? String(query.prefix(60)) + "…" : query)", subtitle: "Opens in your browser", symbol: "link",
                category: .web, rememberable: false, queryScore: 990
            ) { NSWorkspace.shared.open(url) })
        }
        if let (script, argument) = LauncherExtraMatch.script(in: text, among: extras.scripts) {
            found.append(PaletteEntry(
                id: "script:\(script.id):\(argument)", title: argument.isEmpty ? "Run “\(script.name)”" : "Run “\(script.name)” with “\(argument.prefix(40))”", subtitle: "Script", symbol: "terminal",
                category: .command, rememberable: false, queryScore: 985
            ) { [weak self] in
                guard let self else { return }
                ScriptRunner.run(script, argument: argument, toast: self.toast)
            })
        }
        guard data.isEnabled(.tools) else { return found }

        var results: [ToolResult] = []
        if let unit = UnitConverter.convert(text) { results.append(unit) }
        if let time = TimeZoneTool.answer(text) { results.append(time) }
        results += ColorTool.results(for: text)
        results += TextTool.answer(text)
        results += GeneratorTool.answer(text)
        for result in results {
            found.append(PaletteEntry(
                id: result.id, title: result.title, subtitle: result.subtitle, symbol: result.symbol, category: .tools, rememberable: false, queryScore: result.sensitive ? 880 : 940,
                actions: [PaletteAction(title: "Copy", symbol: "doc.on.doc") { [weak self] in self?.copy(result.copy) }]
            ) { [weak self] in self?.copy(result.copy, message: result.sensitive ? "Copied the password" : "Copied") })
        }
        if data.currencyRates == true, let ask = CurrencyConverter.parse(text) {
            if let snapshot = rates.snapshot, let result = CurrencyConverter.result(amount: ask.amount, from: ask.from, to: ask.to, rates: snapshot.rates, date: snapshot.date) {
                found.append(PaletteEntry(id: result.id, title: result.title, subtitle: result.subtitle, symbol: result.symbol, category: .tools, rememberable: false, queryScore: 945) { [weak self] in self?.copy(result.copy) })
            } else {
                found.append(PaletteEntry(id: "fx:wait", title: "Getting today’s rates…", subtitle: "Currency conversion", symbol: "dollarsign.circle", category: .tools, rememberable: false, queryScore: 945) {})
            }
            rates.refreshIfNeeded()
        }
        if let code = Self.qrText(in: text) {
            found.append(PaletteEntry(
                id: "qr:\(code.prefix(50))", title: "Make a QR code for “\(code.count > 40 ? String(code.prefix(40)) + "…" : code)”", subtitle: "Copies the picture", symbol: "qrcode", category: .tools, rememberable: false, queryScore: 920
            ) { [weak self] in self?.copyQR(code) })
        }
        return found
    }

    /// "qr some text" → "some text".
    static func qrText(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " "), trimmed[..<space].lowercased() == "qr" else { return nil }
        let rest = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty || rest.count > 1000 ? nil : rest
    }

    private func copyQR(_ text: String) {
        guard let image = Self.qrImage(for: text) else { toast.show("That could not be made into a QR code.", isError: true); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        toast.show("Copied the QR code. Paste it anywhere.")
    }

    static func qrImage(for text: String, size: CGFloat = 512) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale.rounded(.down), y: scale.rounded(.down)))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private func pickColor() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            NSColorSampler().show { color in
                guard let self, let color = color?.usingColorSpace(.sRGB) else { return }
                let c = (r: Int((color.redComponent * 255).rounded()), g: Int((color.greenComponent * 255).rounded()), b: Int((color.blueComponent * 255).rounded()))
                self.copy(ColorTool.hex(c), message: "Copied \(ColorTool.hex(c))")
            }
        }
    }
}
