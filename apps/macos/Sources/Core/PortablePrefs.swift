import Foundation

/// Settings the app keeps in its own preferences rather than in the core's database, packed as one JSON object so they travel
/// in a backup. Only settings are listed. Timelines, logs, usage counts and anything with a secret in it are left out on purpose.
enum PortablePrefs {
    /// Settings only, from the registry. History, approvals and anything tied to this Mac are never listed.
    static var keys: [String] { SettingsRegistry.backupKeys }

    /// Each saved value as a property list, text-encoded, so strings, numbers, lists and data all survive.
    static func pack(from defaults: UserDefaults = .standard) -> String? {
        var object: [String: String] = [:]
        for key in keys {
            guard let value = defaults.object(forKey: key),
                  let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) else { continue }
            object[key] = data.base64EncodedString()
        }
        guard !object.isEmpty, let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: json, encoding: .utf8)
    }

    /// The packed preferences inside a backup file, or nil for a backup made before they were part of it.
    static func packed(inBackup json: String) -> String? {
        guard let data = json.data(using: .utf8), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let extras = root["extras"] as? [String: Any] else { return nil }
        return extras["app_prefs"] as? String
    }

    /// Writes back only the listed keys, whatever else the file holds. Returns the keys that were applied.
    @discardableResult
    static func applyKeys(_ json: String, to defaults: UserDefaults = .standard) -> [String] {
        guard let data = json.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return [] }
        var applied: [String] = []
        for key in keys {
            guard let text = object[key], let blob = Data(base64Encoded: text),
                  let value = try? PropertyListSerialization.propertyList(from: blob, options: [], format: nil) else { continue }
            defaults.set(value, forKey: key)
            applied.append(key)
        }
        return applied
    }

    /// How many keys `applyKeys` wrote.
    @discardableResult
    static func apply(_ json: String, to defaults: UserDefaults = .standard) -> Int { applyKeys(json, to: defaults).count }
}
