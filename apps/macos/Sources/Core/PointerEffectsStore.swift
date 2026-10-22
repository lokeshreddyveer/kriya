import AppKit
import Combine
import SwiftUI

extension SavedPosition: Identifiable {}

extension Color {
    /// A colour from `#RRGGBB`, in sRGB. Falls back to grey if the text is not a colour.
    static func fromHex(_ text: String) -> Color {
        let parts = pointerParseColor(text: text)
        guard parts.count == 3 else { return .gray }
        return Color(.sRGB, red: parts[0], green: parts[1], blue: parts[2], opacity: 1)
    }

    /// `#RRGGBB` for a colour.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        func byte(_ v: CGFloat) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", byte(ns.redComponent), byte(ns.greenComponent), byte(ns.blueComponent))
    }
}

/// Settings for the pointer effects.
final class PointerEffectsStore: ObservableObject {
    @Published private(set) var config = PointerEffectsConfig(
        enabled: false, haloEnabled: false, haloStyle: .filled, haloSize: 64, haloColor: "#D4A84B", haloOpacity: 0.35, haloPulse: false,
        clickEnabled: false, clickSize: 56, clickDurationMs: 450, leftClickColor: "#6F94B8", rightClickColor: "#C77B6E",
        locateSize: 240, magnifierZoom: 2.5, magnifierSize: 220, magnifierShape: .circle, hideWhenIdle: false, hideAfterSeconds: 5,
        showWhenSharing: false, positions: [], doubleTapControl: true, shakeToLocate: false, magnifierHoldModifier: 0, hideWhileTyping: false, excludedAppIds: []
    )
    @Published var lastError: String?

    private let core: KriyaCore
    private let lock = NSLock()
    private var snapshot: PointerEffectsConfig?      // guarded by lock

    init(core: KriyaCore) {
        self.core = core
        reload()
    }

    func reload() {
        do {
            config = try core.pointerEffectsConfig()
        } catch {
            Log.error("Pointer", "Could not load pointer effects: \(error.userMessage)")
        }
        lock.lock()
        snapshot = config
        lock.unlock()
    }

    var current: PointerEffectsConfig {
        lock.lock()
        defer { lock.unlock() }
        return snapshot ?? config
    }

    func update(_ change: (inout PointerEffectsConfig) -> Void) {
        var next = config
        change(&next)
        do {
            try core.savePointerEffectsConfig(config: next)
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
        reload()
    }

    func upsert(_ position: SavedPosition) {
        update { config in
            if let index = config.positions.firstIndex(where: { $0.id == position.id }) {
                config.positions[index] = position
            } else {
                config.positions.append(position)
            }
        }
    }

    func delete(_ id: String) { update { $0.positions.removeAll { $0.id == id } } }

    func newPosition() -> SavedPosition {
        SavedPosition(id: UUID().uuidString, name: "", display: nil, x: 0.5, y: 0.5)
    }
}
