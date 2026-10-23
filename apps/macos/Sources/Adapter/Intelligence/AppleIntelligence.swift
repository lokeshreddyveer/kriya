import AppKit
import Combine
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether Apple Intelligence's on-device model can be used right now, and if not, why, in words a person can act on.
enum IntelligenceAvailability: Equatable {
    case available
    case needsNewerMacOS
    case notSupportedByThisMac
    case notTurnedOn
    case modelNotReady
    case unknown

    var isAvailable: Bool { self == .available }

    var title: String {
        switch self {
        case .available: return "Ready"
        case .needsNewerMacOS: return "Needs a newer macOS"
        case .notSupportedByThisMac: return "Not supported on this Mac"
        case .notTurnedOn: return "Turned off in System Settings"
        case .modelNotReady: return "Still getting ready"
        case .unknown: return "Not available"
        }
    }

    var explanation: String {
        switch self {
        case .available: return "The on-device model is ready. Text you send it is handled on this Mac and goes nowhere else."
        case .needsNewerMacOS: return "Apple Intelligence needs macOS 26 or later. Update macOS to use it from Kriya."
        case .notSupportedByThisMac: return "This Mac cannot run Apple Intelligence. It needs a Mac with Apple silicon."
        case .notTurnedOn: return "Turn on Apple Intelligence in System Settings, then come back here."
        case .modelNotReady: return "macOS is still downloading or preparing the model. This usually takes a few minutes, and needs a network connection once."
        case .unknown: return "macOS did not say why Apple Intelligence is not available."
        }
    }
}

/// What can go wrong when asking the model, each with wording a person can use. None of these carry the text that was sent.
enum IntelligenceError: Error, Equatable, LocalizedError {
    case unavailable(IntelligenceAvailability)
    case emptyText
    /// Too little text to summarize: the answer would only repeat it.
    case tooShortToSummarize(Int)
    case tooLong
    case refused
    case unsupportedLanguage
    case busy
    case cancelled
    case failed
    /// A provider other than the on-device model said no, or could not be used; the words are Kriya's own, never the text sent.
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let why): return why.explanation
        case .emptyText: return "There is no text to work on."
        case .tooShortToSummarize(let count): return "That is only \(count) characters, so there is nothing to summarize. If you selected more than that, the app reported only part of it: select it again, or copy it and use the launcher's “Summarize the clipboard text”."
        case .tooLong: return "That text is too long for the on-device model, even after cutting it down."
        case .refused: return "Apple Intelligence declined to work on that text."
        case .unsupportedLanguage: return "Apple Intelligence does not support the language of that text yet."
        case .busy: return "Apple Intelligence is busy. Try again in a moment."
        case .cancelled: return "Stopped."
        case .failed: return "Apple Intelligence could not finish that. Try again."
        case .provider(let message): return message
        }
    }

    /// Reads which kind of failure the framework reported from the name of its case alone. The name is all that is looked
    /// at: the framework's descriptions can quote what was sent, and that must never be read, logged or shown.
    static func classify(caseName: String) -> IntelligenceError {
        switch caseName {
        case "contextSizeExceeded", "exceededContextWindowSize": return .tooLong
        case "guardrailViolation", "refusal": return .refused
        case "unsupportedLanguageOrLocale": return .unsupportedLanguage
        case "rateLimited", "concurrentRequests": return .busy
        case "assetsUnavailable": return .unavailable(.modelNotReady)
        default: return .failed
        }
    }

    static func classify(_ error: Error) -> IntelligenceError {
        if let known = error as? IntelligenceError { return known }
        if error is CancellationError { return .cancelled }
        let described = String(describing: error)
        return classify(caseName: String(described.prefix { $0 != "(" && $0 != " " }))
    }
}

/// Whatever answers a request. The real one is the on-device model; a test stands one in.
protocol TextModel {
    func availability() -> IntelligenceAvailability
    /// `rewriting` is for work on the person's own text (fixing, rewording), which the system's content checks should let
    /// through; a question typed in is checked in the usual way.
    func respond(instructions: String, prompt: String, rewriting: Bool) async throws -> String
}

/// Apple Intelligence's on-device model, through the Foundation Models framework. Nothing here can reach a network: the
/// framework's on-device model is the only one used, never its cloud one.
struct SystemTextModel: TextModel {
    func availability() -> IntelligenceAvailability {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return .needsNewerMacOS }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .notSupportedByThisMac
            case .appleIntelligenceNotEnabled: return .notTurnedOn
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unknown
            }
        @unknown default: return .unknown
        }
        #else
        return .needsNewerMacOS
        #endif
    }

    func respond(instructions: String, prompt: String, rewriting: Bool) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw IntelligenceError.unavailable(.needsNewerMacOS) }
        let model = rewriting ? SystemLanguageModel(guardrails: .permissiveContentTransformations) : SystemLanguageModel.default
        let session = LanguageModelSession(model: model, instructions: instructions)
        var options = GenerationOptions()
        options.temperature = 0.3
        options.maximumResponseTokens = 900
        let response = try await session.respond(to: prompt, options: options)
        return response.content
        #else
        throw IntelligenceError.unavailable(.needsNewerMacOS)
        #endif
    }
}

/// What the person chose about Apple Intelligence in Kriya.
struct IntelligenceSettings: Codable, Equatable {
    var inSelectionBar = true
    var inLauncher = true
    var onClipboardItems = true
    /// A language to write results in. Empty means the language of the text.
    var outputLanguage = ""
    /// Web research, off until switched on: a question's words are sent to Wikipedia so the answer can cite what it found. Optional
    /// so settings saved before it existed still load.
    var webResearchOn: Bool?
}

/// Where research finds its sources. The real one asks Wikipedia; a test stands one in.
protocol ResearchFetching {
    func sources(for question: String) async throws -> [ResearchSource]
}

struct WikipediaFetcher: ResearchFetching {
    var session: URLSession = .shared

    func sources(for question: String) async throws -> [ResearchSource] {
        var lists: [[ResearchSource]] = []
        for language in WebResearch.languages(for: question) {
            guard let url = WebResearch.requestURL(question: question, language: language) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 12)
            request.setValue("Kriya (a Mac utility; reads the opening of articles for the person who asked)", forHTTPHeaderField: "User-Agent")
            AuditLog.shared.record(.network, "Web research: GET \(url.host ?? "?")")
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { continue }
            lists.append(WebResearch.parse(data))
        }
        return WebResearch.merge(lists)
    }
}

/// Where Kriya uses Apple Intelligence's on-device model: what it is asked, in what order of fallbacks, and what the
/// person allowed. It records nothing about what was sent.
final class AppleIntelligence: ObservableObject {
    static let maxInputCharacters = 6000
    /// Fewer characters than this are not worth summarizing or listing key points from.
    static let minimumToSummarize = 140
    /// When the model says the text is still too long, it is tried again with this share of the limit.
    static let retryShare = 0.4

    @Published private(set) var availability: IntelligenceAvailability
    @Published private(set) var settings: IntelligenceSettings
    @Published private(set) var requestsInFlight = 0

    private let model: TextModel
    private let defaults: UserDefaults
    private let key = "intelligenceSettings.v1"
    private var observer: NSObjectProtocol?

    init(model: TextModel = SystemTextModel(), defaults: UserDefaults = .standard, watchSystem: Bool = true) {
        self.model = model
        self.defaults = defaults
        availability = model.availability()
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(IntelligenceSettings.self, from: data) {
            settings = decoded
        } else {
            settings = IntelligenceSettings()
        }
        if watchSystem {
            // The person may turn it on in System Settings while Kriya is running, or the model may finish downloading.
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var isAvailable: Bool { availability.isAvailable }

    func refresh() {
        let now = model.availability()
        if now != availability {
            availability = now
            Log.info("Intelligence", "Apple Intelligence: \(now.title)")
        }
    }

    func update(_ change: (inout IntelligenceSettings) -> Void) {
        var next = settings
        change(&next)
        next.outputLanguage = String(next.outputLanguage.trimmingCharacters(in: .whitespaces).prefix(40))
        guard next != settings else { return }
        settings = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: key) }
    }

    // MARK: Asking

    struct Output: Equatable {
        let text: String
        /// The text sent was cut down to fit.
        let truncated: Bool
    }

    /// Works on `text` as the task says.
    func run(_ task: IntelligenceTask, on text: String) async throws -> Output {
        // A custom instruction with nothing in it, or too much, is refused before anything is sent.
        if intelligenceCheck(task: task) != nil { throw IntelligenceError.failed }
        let instructions = withLanguage(intelligenceInstructions(task: task))
        // A summary of a couple of lines would only repeat them, so that is said instead of returning the same words.
        let minimum = (task == .summarize || task == .keyPoints) ? Self.minimumToSummarize : 0
        return try await send(minimumLength: minimum, text: text, instructions: instructions, rewriting: true, original: text) { "Text to work on:\n<<<\n\($0)\n>>>" }
    }

    /// Answers a question typed in.
    func ask(_ question: String) async throws -> Output {
        let instructions = withLanguage(intelligenceAskInstructions())
        return try await send(text: question, instructions: instructions, rewriting: false, original: "") { $0 }
    }

    /// Answers a question from sources found on the web, if the person turned web research on. The question's words go to
    /// Wikipedia; the sources are read by the on-device model, and the answer lists them. Without sources nothing is guessed.
    func research(_ question: String, fetcher: ResearchFetching = WikipediaFetcher()) async throws -> Output {
        guard settings.webResearchOn == true else {
            return Output(text: "Web research is off. Turn it on in Apple Intelligence settings to let Kriya look the question up on Wikipedia.", truncated: false)
        }
        guard !LocalOnly.isOn else { return Output(text: LocalOnly.blockedMessage, truncated: false) }
        let words = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(WebResearch.maxQuestionCharacters))
        let sources: [ResearchSource]
        do { sources = try await fetcher.sources(for: words) } catch {
            return Output(text: "The lookup could not reach Wikipedia. Check the connection and try again.", truncated: false)
        }
        guard !sources.isEmpty else {
            return Output(text: "No Wikipedia article matched that question, so there is nothing reliable to answer from. Try different words, or use “Search with” in the launcher.", truncated: false)
        }
        let answer = try await send(text: words, instructions: withLanguage(WebResearch.instructions), rewriting: false, original: "") { _ in WebResearch.prompt(question: words, sources: sources) }
        return Output(text: answer.text + "\n\nSources:\n" + WebResearch.sourceLines(sources), truncated: answer.truncated)
    }

    private func withLanguage(_ instructions: String) -> String {
        let language = settings.outputLanguage
        return language.isEmpty ? instructions : instructions + "\nWrite the result in \(language)."
    }

    private func send(minimumLength: Int = 0, text: String, instructions: String, rewriting: Bool, original: String, prompt: (String) -> String) async throws -> Output {
        refresh()
        guard availability.isAvailable else { throw IntelligenceError.unavailable(availability) }
        let length = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard length > 0 else { throw IntelligenceError.emptyText }
        guard length >= minimumLength else { throw IntelligenceError.tooShortToSummarize(length) }
        await MainActor.run { requestsInFlight += 1 }
        defer { Task { @MainActor in self.requestsInFlight = max(0, self.requestsInFlight - 1) } }

        var limit = Self.maxInputCharacters
        var cut = false
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let input = intelligenceLimitInput(text: text, maxChars: UInt32(limit))
            cut = cut || input.truncated
            do {
                let raw = try await model.respond(instructions: instructions, prompt: prompt(input.text), rewriting: rewriting)
                let cleaned = intelligenceCleanOutput(output: raw, original: original)
                guard !cleaned.isEmpty else { throw IntelligenceError.failed }
                return Output(text: cleaned, truncated: cut)
            } catch {
                let reason = IntelligenceError.classify(error)
                // Too long for the model: try once more with much less of it.
                if reason == .tooLong, attempt == 0 {
                    limit = max(200, Int(Double(limit) * Self.retryShare))
                    cut = true
                    continue
                }
                throw reason
            }
        }
        throw IntelligenceError.tooLong
    }
}
