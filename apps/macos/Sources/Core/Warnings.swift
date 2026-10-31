import Foundation

/// A warning the person chose to stop seeing, and when.
struct WarningRecord: Codable, Equatable, Identifiable {
    var id: String
    var dismissedAt: Date
}

/// One warning Kriya can show, with a name that never changes. A person's choice to stop seeing it is kept under that name, so it must
/// survive every release: add new names, never rename or reuse one.
struct WarningDefinition: Identifiable, Equatable {
    /// Lower-case words joined by dots, starting with the feature: "capture.editor.discard-marks".
    let id: String
    /// The feature that shows it (a managed feature's id where there is one).
    let feature: String
    let featureTitle: String
    let title: String
    let detail: String
    /// Preferences an older version used to remember that this was dismissed. They count as a dismissal and are cleared by a reset.
    var legacyKeys: [String] = []
}

enum WarningCatalog {
    /// Every warning that can be switched off. A confirmation that guards against losing files (moving old captures to the Trash, for one)
    /// is not here and can never be switched off.
    static let all: [WarningDefinition] = [
        WarningDefinition(id: "capture.editor.discard-marks", feature: "capture", featureTitle: "Screen Capture and Recording",
                          title: "Discarding marks in the capture editor",
                          detail: "Asks before closing the editor when you have drawn marks that would be lost."),
        WarningDefinition(id: "backup.icloud.newer-from-other-mac", feature: "backup", featureTitle: "Backup and sync",
                          title: "A newer backup from another Mac",
                          detail: "Says when iCloud holds a backup from another Mac that is newer than this one.",
                          legacyKeys: ["iCloudSyncDismissedAt"]),
    ]

    static func definition(_ id: String) -> WarningDefinition? { all.first { $0.id == id } }

    static func warnings(for feature: String) -> [WarningDefinition] { all.filter { $0.feature == feature } }

    /// The features that have warnings, in the order they first appear.
    static var features: [(id: String, title: String)] {
        var seen = Set<String>()
        return all.compactMap { seen.insert($0.feature).inserted ? (id: $0.feature, title: $0.featureTitle) : nil }
    }
}

/// The warnings that were dismissed. A record for a warning this version does not know (from a newer one) is kept as it is.
struct WarningLedger: Codable, Equatable {
    private(set) var records: [WarningRecord] = []

    init(records: [WarningRecord] = []) { self.records = records }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records = c.value(.records, [WarningRecord]())
    }

    func record(_ id: String) -> WarningRecord? { records.first { $0.id == id } }

    func adding(_ id: String, at date: Date) -> WarningLedger {
        var next = records.filter { $0.id != id }
        next.append(WarningRecord(id: id, dismissedAt: date))
        return WarningLedger(records: next)
    }

    func removing(_ id: String) -> WarningLedger { WarningLedger(records: records.filter { $0.id != id }) }

    /// Everything dismissed for one feature's warnings.
    func removing(feature: String, in catalog: [WarningDefinition] = WarningCatalog.all) -> WarningLedger {
        let ids = Set(catalog.filter { $0.feature == feature }.map(\.id))
        return WarningLedger(records: records.filter { !ids.contains($0.id) })
    }
}

/// Reads and writes the dismissed warnings. Takes the preferences to use, so a check never touches the real ones.
struct WarningStore {
    static let key = "warnings.dismissed.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var ledger: WarningLedger {
        get { defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(WarningLedger.self, from: $0) } ?? WarningLedger() }
        nonmutating set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.key) } }
    }

    private func legacyDismissed(_ id: String) -> Bool {
        WarningCatalog.definition(id)?.legacyKeys.contains { defaults.object(forKey: $0) != nil } ?? false
    }

    /// Whether the person stopped this warning from showing.
    func isDismissed(_ id: String) -> Bool { ledger.record(id) != nil || legacyDismissed(id) }

    /// Whether to show it: the opposite of `isDismissed`. A warning this version does not know always shows.
    func shouldShow(_ id: String) -> Bool { WarningCatalog.definition(id) == nil || !isDismissed(id) }

    /// When it was dismissed, if it was.
    func dismissedAt(_ id: String) -> Date? {
        if let recorded = ledger.record(id)?.dismissedAt { return recorded }
        guard let legacy = WarningCatalog.definition(id)?.legacyKeys.compactMap({ defaults.object(forKey: $0) as? Date }).first else { return nil }
        return legacy
    }

    /// Stops this warning from showing. Only warnings in the catalog can be switched off.
    @discardableResult
    func dismiss(_ id: String, at date: Date = Date()) -> Bool {
        guard WarningCatalog.definition(id) != nil else { return false }
        ledger = ledger.adding(id, at: date)
        return true
    }

    /// Reset this warning: it shows again.
    func reset(_ id: String) {
        ledger = ledger.removing(id)
        WarningCatalog.definition(id)?.legacyKeys.forEach { defaults.removeObject(forKey: $0) }
    }

    /// Reset warnings for this feature.
    func reset(feature: String) {
        ledger = ledger.removing(feature: feature)
        WarningCatalog.warnings(for: feature).flatMap(\.legacyKeys).forEach { defaults.removeObject(forKey: $0) }
    }

    /// Reset all warnings, including records this version does not know.
    func resetAll() {
        defaults.removeObject(forKey: Self.key)
        WarningCatalog.all.flatMap(\.legacyKeys).forEach { defaults.removeObject(forKey: $0) }
    }

    /// How many known warnings are switched off now.
    var dismissedCount: Int { WarningCatalog.all.filter { isDismissed($0.id) }.count }
}
