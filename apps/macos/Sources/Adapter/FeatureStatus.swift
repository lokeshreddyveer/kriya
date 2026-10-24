import AppKit

/// Keeps when each feature was last used, how often it failed, and what was changed about it lately. Counts and short labels only;
/// nothing a feature handled is recorded here.
final class FeatureActivity: ObservableObject {
    static let shared = FeatureActivity()
    private static let key = "featureActivity.v1"

    @Published private(set) var log: FeatureActivityLog
    private var lastWrite = Date.distantPast
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        log = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(FeatureActivityLog.self, from: $0) } ?? FeatureActivityLog()
    }

    private func save(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastWrite) > 20 else { return }
        lastWrite = Date()
        if let data = try? JSONEncoder().encode(log) { defaults.set(data, forKey: Self.key) }
    }

    func used(_ id: String) {
        DispatchQueue.main.async { self.log.used(id); self.log.clearFailures(id); self.save() }
    }

    func failed(_ id: String, _ message: String) {
        DispatchQueue.main.async { self.log.failed(id, message); self.save(force: true) }
    }

    func changed(_ id: String, _ what: String) {
        DispatchQueue.main.async { self.log.changed(id, what); self.save(force: true) }
    }

    func clear() { log.clear(); save(force: true) }

    func clearProblems(_ id: String) { log.clearFailures(id); save(force: true) }
}

/// What the Overview needs to know about the features that are not among the original eight: whether each is on, whether it can be
/// switched from there, and whether anything is wrong with it.
final class FeatureSwitchboard {
    static let shared = FeatureSwitchboard()

    /// A feature with its own on/off switch in the app.
    func isSwitchable(_ id: String) -> Bool {
        ["midi", "locationAudio", "soundDevices", "finderWindows", "clipboardSync", "semanticSearch", "mcpServer", "safariExtension"].contains(id)
    }

    func isOn(_ id: String) -> Bool {
        switch id {
        case "midi": return MIDITriggerRunner.shared.enabled
        case "locationAudio": return LocationAudioRunner.shared.enabled
        case "soundDevices": return DevicePriorityRunner.shared.enabled
        case "finderWindows": return FinderWindowTracker.shared.enabled
        case "clipboardSync": return ClipboardSyncService.shared.enabled
        case "semanticSearch": return AIIndexer.shared.enabled
        case "mcpServer": return MCPHTTPServer.shared.enabled
        case "safariExtension": return SafariInboxWatcher.current?.enabled ?? false
        case "extensions": return ExtensionCatalog.shared.installed.contains { $0.enabled }
        case "ddc": return !DDCController.shared.monitors.isEmpty
        case "aiProviders": return AIProviderStore.shared.providers.contains { $0.enabled && $0.kind != .appleIntelligence }
        default: return true
        }
    }

    func set(_ id: String, _ on: Bool) {
        switch id {
        case "midi": MIDITriggerRunner.shared.enabled = on
        case "locationAudio": LocationAudioRunner.shared.enabled = on
        case "soundDevices": DevicePriorityRunner.shared.enabled = on
        case "finderWindows": FinderWindowTracker.shared.enabled = on
        case "clipboardSync": ClipboardSyncService.shared.enabled = on
        case "semanticSearch": AIIndexer.shared.enabled = on
        case "mcpServer": MCPHTTPServer.shared.enabled = on
        case "safariExtension": SafariInboxWatcher.current?.enabled = on
        default: break
        }
    }

    /// A short note about what it has found, or what is wrong.
    func problem(_ id: String) -> String? {
        switch id {
        case "locationAudio": return LocationAudioRunner.shared.enabled ? LocationAudioRunner.shared.problem : nil
        case "mcpServer": return MCPHTTPServer.shared.status.flatMap { $0.hasPrefix("Could not") ? $0 : nil }
        case "semanticSearch": return AIIndexer.shared.status.flatMap { $0.contains("not available") ? $0 : nil }
        case "clipboardSync": return ClipboardSyncService.shared.enabled ? ClipboardSyncService.shared.status.flatMap { $0.hasPrefix("Could not") || $0.contains("not turned on") || $0.contains("Choose a sync passphrase") ? $0 : nil } : nil
        case "ddc": return DDCController.shared.monitors.isEmpty ? DDCController.shared.status : nil
        default: return nil
        }
    }

    func headline(_ id: String) -> String? {
        switch id {
        case "extensions":
            let on = ExtensionCatalog.shared.installed.filter(\.enabled).count
            return "\(ExtensionCatalog.shared.installed.count) installed, \(on) on"
        case "ddc": let n = DDCController.shared.monitors.count; return n == 0 ? nil : "\(n) monitor\(n == 1 ? "" : "s") answering"
        case "aiProviders":
            let n = AIProviderStore.shared.providers.filter { $0.enabled && $0.kind != .appleIntelligence }.count
            return n == 0 ? "On this Mac only" : "\(n) outside provider\(n == 1 ? "" : "s") on"
        case "midi": return MIDITriggerRunner.shared.enabled ? "\(MIDITriggerRunner.shared.triggers.count) trigger\(MIDITriggerRunner.shared.triggers.count == 1 ? "" : "s")" : nil
        case "locationAudio": return LocationAudioRunner.shared.enabled ? LocationAudioRunner.shared.currentPlace.map { "At \($0)" } : nil
        default: return nil
        }
    }
}

/// The records people made of what they ran and tried, per feature and per build.
final class EvidenceStore: ObservableObject {
    static let shared = EvidenceStore()
    private static let key = "evidenceLedger.v1"

    @Published private(set) var ledger: EvidenceLedger
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ledger = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(EvidenceLedger.self, from: $0) } ?? EvidenceLedger()
    }

    func record(_ id: String, testsPassed: Bool, byHand: Bool, note: String) {
        ledger.record(id, build: SystemInfo.build, testsPassed: testsPassed, verifiedByHand: byHand, note: note)
        save()
    }

    func forget(_ id: String) { ledger.forget(id); save() }

    private func save() { if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: Self.key) } }
}
