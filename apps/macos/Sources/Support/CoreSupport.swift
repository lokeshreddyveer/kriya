import CoreGraphics
import Foundation

extension Error {
    /// Plain wording for an error from the core, fit to show in the window.
    var userMessage: String {
        if let core = self as? CoreError {
            switch core {
            case .Invalid(let message), .Backup(let message):
                return message.prefix(1).uppercased() + message.dropFirst()
            case .Storage(let message):
                return "Kriya could not save that (\(message))."
            case .NotFound:
                return "That item no longer exists."
            case .NewerDatabase:
                return "Your saved data was created by a newer version of Kriya. Update Kriya to open it."
            }
        }
        return localizedDescription
    }
}

/// The core's own modifier bits (see `actions::modifiers` in the Rust core) and their macOS counterparts.
enum KeyModifiers {
    static let shift: UInt64 = 1
    static let control: UInt64 = 1 << 1
    static let option: UInt64 = 1 << 2
    static let command: UInt64 = 1 << 3
    static let function: UInt64 = 1 << 4

    static func flags(from bits: UInt64) -> CGEventFlags {
        var flags = CGEventFlags()
        if bits & shift != 0 { flags.insert(.maskShift) }
        if bits & control != 0 { flags.insert(.maskControl) }
        if bits & option != 0 { flags.insert(.maskAlternate) }
        if bits & command != 0 { flags.insert(.maskCommand) }
        if bits & function != 0 { flags.insert(.maskSecondaryFn) }
        return flags
    }

    static func bits(from flags: CGEventFlags) -> UInt64 {
        var bits: UInt64 = 0
        if flags.contains(.maskShift) { bits |= shift }
        if flags.contains(.maskControl) { bits |= control }
        if flags.contains(.maskAlternate) { bits |= option }
        if flags.contains(.maskCommand) { bits |= command }
        if flags.contains(.maskSecondaryFn) { bits |= function }
        return bits
    }
}

extension AppSettings {
    /// What a first launch starts with. Mirrors the core's defaults.
    static var defaults: AppSettings {
        AppSettings(
            appearance: .system,
            showAppIcon: false,
            automaticallyCheckForUpdates: true,
            logLevel: .info,
            enabledFeatures: [],
            hasCompletedOnboarding: false,
            autoDisableCrashingFeature: true
        )
    }
}

// The core's records that have an `id` can be listed directly in SwiftUI.
extension Profile: Identifiable {}
extension NamedAction: Identifiable {}
extension Rule: Identifiable {}
