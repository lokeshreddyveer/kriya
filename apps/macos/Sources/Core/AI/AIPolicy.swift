import Foundation

/// What a provider has been used for today, for the daily limits. Kept per provider per day, with counts only.
struct AIUsageLedger: Codable, Equatable {
    struct Day: Codable, Equatable {
        var tokens = 0
        var cost = 0.0
        var requests = 0
    }

    static let keepDays = 31
    private(set) var days: [String: Day] = [:]

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func key(_ provider: String, _ date: Date, _ calendar: Calendar) -> String { provider + "|" + dayKey(date, calendar: calendar) }

    func today(_ provider: String, now: Date = Date(), calendar: Calendar = .current) -> Day { days[Self.key(provider, now, calendar)] ?? Day() }

    mutating func record(provider: String, usage: AIUsage?, config: AIProviderConfig, estimatedInputTokens: Int, now: Date = Date(), calendar: Calendar = .current) {
        let input = usage?.inputTokens ?? estimatedInputTokens
        let output = usage?.outputTokens ?? 0
        var day = today(provider, now: now, calendar: calendar)
        day.tokens += input + output
        day.requests += 1
        day.cost += Double(input) / 1_000_000 * (config.costPerMillionInput ?? 0) + Double(output) / 1_000_000 * (config.costPerMillionOutput ?? 0)
        days[Self.key(provider, now, calendar)] = day
        prune(now: now, calendar: calendar)
    }

    private mutating func prune(now: Date, calendar: Calendar) {
        let oldest = Self.dayKey(calendar.date(byAdding: .day, value: -Self.keepDays, to: now) ?? now, calendar: calendar)
        days = days.filter { ($0.key.split(separator: "|").last.map(String.init) ?? "") >= oldest }
    }

    mutating func clear() { days = [:] }
}

/// A sliding window of recent request times.
struct AIRateLimiter: Equatable {
    static let window: TimeInterval = 60
    private(set) var times: [Date] = []

    mutating func count(now: Date = Date()) -> Int {
        times = times.filter { now.timeIntervalSince($0) < Self.window }
        return times.count
    }

    mutating func record(now: Date = Date()) { _ = count(now: now); times.append(now) }
}

struct AIPolicyInput {
    var config: AIProviderConfig
    var feature: AIFeature
    var localOnlyMode: Bool
    var inputCharacters: Int
    var usageToday: AIUsageLedger.Day
    var requestsInLastMinute: Int
}

enum AIPolicy {
    static let maxInputCharacters = 120_000
    static let maxOutputCharacters = 200_000
    static let maxRequestsPerMinute = 20

    /// Rough size of a request in tokens, for the budget before the provider says what it really was.
    static func estimateTokens(characters: Int) -> Int { max(1, characters / 4) }

    /// Whether a request may be sent at all. Nil means it may. The checks run in the order a person would want to hear about them.
    static func check(_ i: AIPolicyInput) -> AIError? {
        guard i.config.enabled else { return .notConfigured("it is switched off") }
        if !i.config.problems.isEmpty { return .notConfigured(i.config.problems[0]) }
        if i.localOnlyMode && !i.config.isOnThisMac { return .blockedByLocalOnly }
        guard i.config.enabledFeatures.contains(i.feature) else { return .providerOffForFeature(i.feature.title) }
        if i.inputCharacters > maxInputCharacters { return .inputTooLarge(maxInputCharacters) }
        if i.requestsInLastMinute >= maxRequestsPerMinute { return .rateLimited }
        if let limit = i.config.dailyTokenLimit, i.usageToday.tokens + estimateTokens(characters: i.inputCharacters) > limit { return .budgetExceeded("token") }
        if let limit = i.config.dailyCostLimit, i.usageToday.cost >= limit { return .budgetExceeded("cost") }
        return nil
    }
}
