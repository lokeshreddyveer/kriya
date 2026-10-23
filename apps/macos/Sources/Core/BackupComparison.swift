import Foundation

/// What a restore would change, in words: each kind of setting with how many there are now and how many the backup has.
enum BackupComparison {
    struct Line: Equatable {
        let label: String
        let now: Int
        let backup: Int

        var change: Int { backup - now }

        /// "Profiles: 3 → 5 (2 added)" or "Rules: 4 (same count)".
        var text: String {
            if change == 0 { return "\(label): \(now) (same count)" }
            let amount = abs(change)
            return "\(label): \(now) → \(backup) (\(amount) \(change > 0 ? "added" : "removed"))"
        }
    }

    static func lines(now: BackupSummary, backup: BackupSummary) -> [Line] {
        [
            Line(label: "Profiles", now: Int(now.profiles), backup: Int(backup.profiles)),
            Line(label: "Saved actions", now: Int(now.actions), backup: Int(backup.actions)),
            Line(label: "Rules", now: Int(now.rules), backup: Int(backup.rules)),
            Line(label: "Mouse presets", now: Int(now.mousePresets), backup: Int(backup.mousePresets)),
            Line(label: "Window layouts", now: Int(now.windowLayouts), backup: Int(backup.windowLayouts)),
            Line(label: "Device names", now: Int(now.devices), backup: Int(backup.devices)),
        ]
    }

    /// The preview text for the restore question. Anything the restore would remove is called out first.
    static func preview(now: BackupSummary, backup: BackupSummary, madeAt: String) -> String {
        let all = lines(now: now, backup: backup)
        let removed = all.filter { $0.change < 0 }
        var parts = ["Made \(madeAt) with Kriya \(backup.appVersion)."]
        parts.append(all.map(\.text).joined(separator: "\n"))
        if !removed.isEmpty {
            parts.append("Restoring would remove: " + removed.map { "\(-$0.change) \($0.label.lowercased())" }.joined(separator: ", ") + ".")
        }
        parts.append("Your current settings are saved first, so you can undo this.")
        return parts.joined(separator: "\n\n")
    }
}
